--!strict
-- Grafana 11/12 auto-migration of legacy angular panels, ported from v12.4.0
-- so those panels render through the native timeseries/stat/table renderers:
--
--   public/app/features/dashboard/state/PanelModel.ts (autoMigrateAngular,
--     getOptionsToRemember, clearPropertiesBeforePluginChange,
--     callPanelTypeChangeHandler) and getPanelPluginToMigrateTo.ts;
--   public/app/plugins/panel/timeseries/migrations.ts
--     (graphPanelChangedHandler, graphToTimeseriesOptions);
--   public/app/plugins/panel/stat/StatMigrations.ts (statPanelChangedHandler);
--   packages/grafana-ui/.../SingleStatBaseOptions.ts
--     (sharedSingleStatPanelChangedHandler, migrateFromAngularSinglestat,
--     sharedSingleStatMigrationHandler);
--   packages/grafana-data/src/utils/valueMappings.ts
--     (convertOldAngularValueMappings);
--   public/app/plugins/panel/table/migrations.ts (tablePanelChangedHandler,
--     then tableMigrationHandler's migrateHiddenFields).
--
-- Grafana iterates object keys in JSON order. Dashboards served by the API are
-- marshalled from Go maps, so that order is alphabetical; Luau tables have no
-- order, so every key walk here sorts keys to reproduce it.

local Env = require("../env")
local Json = require("./json")
local Tbl = require("../tbl")

type Env = Env.Env

local M = {}

M.LEGACY = {
	graph = "timeseries",
	singlestat = "stat",
	["grafana-singlestat-panel"] = "stat",
	["table-old"] = "table",
} :: { [string]: string }

-- PanelModel.ts mustKeepProps: everything else is legacy panel state that
-- becomes prevOptions.angular and is then deleted from the panel.
local KEEP = {
	id = true,
	gridPos = true,
	type = true,
	title = true,
	scopedVars = true,
	["repeat"] = true,
	repeatPanelId = true,
	repeatDirection = true,
	repeatedByRow = true,
	minSpan = true,
	collapsed = true,
	panels = true,
	targets = true,
	datasource = true,
	timeFrom = true,
	timeShift = true,
	hideTimeOverride = true,
	description = true,
	links = true,
	fullscreen = true,
	cacheTimeout = true,
	queryCachingTTL = true,
	transparent = true,
	pluginVersion = true,
	transformations = true,
	fieldConfig = true,
	maxDataPoints = true,
	interval = true,
	libraryPanel = true,
}

-- fieldReducer.ts registry: ids and aliasIds, as fieldReducers.getIfExists
-- resolves them.
local REDUCERS: { [string]: string } = {
	current = "lastNotNull",
	avg = "mean",
	total = "sum",
}
for _, id in
	{
		"sum",
		"max",
		"min",
		"logmin",
		"mean",
		"variance",
		"stdDev",
		"last",
		"median",
		"first",
		"count",
		"countAll",
		"range",
		"diff",
		"diffperc",
		"delta",
		"step",
		"firstNotNull",
		"lastNotNull",
		"changeCount",
		"distinctCount",
		"allIsZero",
		"allIsNull",
		"allValues",
		"uniqueValues",
	}
do
	REDUCERS[id] = id
end
for p = 1, 99 do
	REDUCERS["p" .. p] = "p" .. p
end

local function present(env: Env, v: any): boolean
	return v ~= nil and v ~= env.null
end

-- JavaScript truthiness of a decoded JSON value.
local function truthy(env: Env, v: any): boolean
	if v == nil or v == env.null or v == false or v == 0 or v == "" then
		return false
	end
	return not (type(v) == "number" and v ~= v)
end

-- JavaScript Number(v) for strings and numbers; nil stands for NaN.
local function jsNumber(env: Env, v: any): number?
	if type(v) == "number" then
		return if v == v then v else nil
	elseif type(v) == "boolean" then
		return if v then 1 else 0
	elseif v == env.null then
		return 0
	elseif type(v) ~= "string" then
		return nil
	end
	local s = string.match(v, "^%s*(.-)%s*$") or ""
	if s == "" then
		return 0
	elseif s == "Infinity" or s == "+Infinity" then
		return math.huge
	elseif s == "-Infinity" then
		return -math.huge
	end
	local n = tonumber(s)
	return if n and n == n then n else nil
end

-- A fresh list, tagged so it encodes as `[]` when empty.
local function newList(env: Env): { any }
	local l: { any } = {}
	return if env.array then env.array(l) else l
end

local function deepCopy(env: Env, v: any): any
	if type(v) ~= "table" or v == env.null then
		return v
	end
	local out = Tbl.copy(v)
	for k, x in out do
		if type(x) == "table" and x ~= env.null then
			out[k] = deepCopy(env, x)
		end
	end
	return out
end

local function sortedKeys(t: { [any]: any }): { string }
	local keys: { string } = {}
	for k in t do
		if type(k) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	return keys
end

-- lodash omitBy(t, isNil), in place.
local function omitNil(env: Env, t: { [any]: any }): { [any]: any }
	for k, v in t do
		if v == env.null then
			t[k] = nil
		end
	end
	return t
end

-- Legend keys that name a reducer, in key order (getReducersFromLegend);
-- only enabled (truthy) keys, as callers pickBy first.
local function legendReducers(env: Env, legend: { [any]: any }): { any }
	local ids = newList(env)
	for _, k in sortedKeys(legend) do
		if truthy(env, legend[k]) and REDUCERS[k] then
			table.insert(ids, REDUCERS[k])
		end
	end
	return ids
end

-- graph migrations.ts getFieldConfigFromOldAxis.
local function axisConfig(env: Env, obj: any): { [string]: any }
	if not truthy(env, obj) or type(obj) ~= "table" then
		return {}
	end
	local graph: { [string]: any } = {
		axisPlacement = if truthy(env, obj.show) then "auto" else "hidden",
	}
	if truthy(env, obj.label) then
		graph.axisLabel = obj.label
	end
	if truthy(env, obj.logBase) then
		local log = obj.logBase
		if log == 2 or log == 10 then
			graph.scaleDistribution = { type = "log", log = log }
		end
	end
	-- validNumber: numbers, or strings Number() accepts.
	local function valid(v: any): number?
		if type(v) == "number" then
			return v
		elseif type(v) == "string" then
			return jsNumber(env, v)
		end
		return nil
	end
	return {
		unit = if present(env, obj.format) then obj.format else nil,
		decimals = valid(obj.decimals),
		min = valid(obj.min),
		max = valid(obj.max),
		custom = graph,
	}
end

local function prop(id: string, value: any): { [string]: any }
	return { id = id, value = value }
end

-- graph migrations.ts fillY2DynamicValues.
local function fillY2(y1: { [string]: any }, y2: { [string]: any }, props: { any })
	for _, key in { "unit", "decimals", "min", "max" } do
		local value = y2[key]
		if value ~= nil and value ~= y1[key] then
			table.insert(props, prop(key, value))
		end
	end
	table.insert(props, prop("custom.axisPlacement", "right"))
	local y1G = y1.custom or {}
	local y2G = y2.custom or {}
	for _, key in sortedKeys(y2G) do
		if y2G[key] ~= y1G[key] then
			table.insert(props, prop("custom." .. key, y2G[key]))
		end
	end
end

local function thresholdColor(env: Env, t: { [any]: any }): any
	if t.colorMode == "critical" then
		return "red"
	elseif t.colorMode == "warning" then
		return "orange"
	elseif t.colorMode == "custom" then
		return if truthy(env, t.fillColor) then t.fillColor else t.lineColor
	end
	return "red"
end

local function legendHideFrom(env: Env, reducer: string): { [string]: any }
	local props = newList(env)
	table.insert(props, prop("custom.hideFrom", { tooltip = true, viz = false, legend = true }))
	return {
		matcher = { id = "byValue", options = { reducer = reducer, op = "gte", value = 0 } },
		properties = props,
	}
end

-- The timeseries options and fieldConfig of graphToTimeseriesOptions.
-- timeRegions are skipped: Grafana turns them into dashboard-level annotation
-- queries (addAnnotationsToDashboard), not panel state.
local function graphToTimeseries(env: Env, angular: { [any]: any }, fieldConfig: { [string]: any }): (any, any)
	local overrides: { any } = fieldConfig.overrides
	local yaxes = Json.list(env, angular.yaxes)
	local y1 = axisConfig(env, yaxes[1])
	do
		local merged: { [string]: any } = Tbl.copy(fieldConfig.defaults)
		for k, v in y1 do
			merged[k] = v
		end
		y1 = merged
	end

	local dash = {
		fill = if truthy(env, angular.dashes) then "dash" else "solid",
		-- `??` keeps any present value, numeric or not.
		dash = {
			if present(env, angular.dashLength) then angular.dashLength else 10,
			if present(env, angular.spaceLength) then angular.spaceLength else 10,
		},
	}

	local aliasColors = Json.tbl(env, angular.aliasColors)
	if aliasColors then
		for _, alias in sortedKeys(aliasColors) do
			local color = aliasColors[alias]
			if truthy(env, color) then
				local props = newList(env)
				table.insert(props, prop("color", { mode = "fixed", fixedColor = color }))
				table.insert(overrides, { matcher = { id = "byName", options = alias }, properties = props })
			end
		end
	end

	local hasFillBelowTo = false
	for _, raw in Json.list(env, angular.seriesOverrides) do
		local so = Json.tbl(env, raw)
		if so == nil or not truthy(env, so.alias) then
			continue
		end
		local alias = so.alias
		-- /^([/~@;%#'])(.*?)\1([gimsuy]*)$/
		local aliasIsRegex = false
		if type(alias) == "string" and #alias >= 2 then
			local d = string.sub(alias, 1, 1)
			if string.find("/~@;%#'", d, 1, true) then
				local last = #alias
				while last > 1 and string.find("gimsuy", string.sub(alias, last, last), 1, true) do
					last -= 1
				end
				-- The lazy body still needs the closing delimiter right before the flags.
				for i = last, 2, -1 do
					if string.sub(alias, i, i) == d then
						aliasIsRegex = string.match(string.sub(alias, i + 1), "^[gimsuy]*$") ~= nil
						break
					end
				end
			end
		end
		local props = newList(env)
		local rule =
			{ matcher = { id = if aliasIsRegex then "byRegexp" else "byName", options = alias }, properties = props }
		local dashOverride: { fill: any, dash: { any } }? = nil

		for _, p in sortedKeys(so) do
			local v = so[p]
			if p == "alias" or p == "$$hashKey" then
				continue
			elseif p == "yaxis" then
				if v == 2 then
					fillY2(y1, axisConfig(env, yaxes[2]), props)
				end
			elseif p == "fill" then
				table.insert(props, prop("custom.fillOpacity", (jsNumber(env, v) or 0 / 0) * 10))
			elseif p == "fillBelowTo" then
				hasFillBelowTo = true
				table.insert(props, prop("custom.fillBelowTo", v))
			elseif p == "fillGradient" then
				if truthy(env, v) then
					table.insert(props, prop("custom.fillGradient", "opacity"))
					table.insert(props, prop("custom.fillOpacity", (jsNumber(env, v) or 0 / 0) * 10))
				end
			elseif p == "points" then
				table.insert(props, prop("custom.showPoints", if truthy(env, v) then "always" else "never"))
			elseif p == "bars" then
				if truthy(env, v) then
					table.insert(props, prop("custom.drawStyle", "bars"))
					table.insert(props, prop("custom.fillOpacity", 100))
				else
					table.insert(props, prop("custom.drawStyle", "line"))
				end
			elseif p == "lines" then
				if truthy(env, v) then
					table.insert(props, prop("custom.drawStyle", "line"))
				else
					table.insert(props, prop("custom.lineWidth", 0))
				end
			elseif p == "linewidth" then
				table.insert(props, prop("custom.lineWidth", v))
			elseif p == "pointradius" then
				table.insert(props, prop("custom.pointSize", 2 + (jsNumber(env, v) or 0 / 0) * 2))
			elseif p == "dashLength" or p == "spaceLength" or p == "dashes" then
				local d: any = dashOverride or { fill = dash.fill, dash = { dash.dash[1], dash.dash[2] } }
				dashOverride = d
				if p == "dashLength" then
					d.dash[1] = v
				elseif p == "spaceLength" then
					d.dash[2] = v
				else
					d.fill = if truthy(env, v) then "dash" else "solid"
				end
			elseif p == "stack" then
				-- getStackingFromOverrides
				table.insert(
					props,
					prop("custom.stacking", {
						mode = if truthy(env, v) then "normal" else "none",
						group = if type(v) == "string" then v else "A",
					})
				)
			elseif p == "color" then
				table.insert(props, prop("color", { fixedColor = v, mode = "fixed" }))
			elseif p == "transform" then
				table.insert(props, prop("custom.transform", if v == "negative-Y" then "negative-Y" else "constant"))
			end
		end
		if dashOverride then
			table.insert(props, prop("custom.lineStyle", dashOverride))
		end
		if #props > 0 then
			table.insert(overrides, rule)
		end
	end

	local graph: { [string]: any } = y1.custom or {}
	graph.drawStyle = if truthy(env, angular.bars)
		then "bars"
		elseif truthy(env, angular.lines) then "line"
		else "points"

	if truthy(env, angular.points) then
		graph.showPoints = "always"
		if type(angular.pointradius) == "number" then
			graph.pointSize = 2 + angular.pointradius * 2
		end
	elseif graph.drawStyle ~= "points" then
		graph.showPoints = "never"
	end

	graph.lineWidth = if present(env, angular.linewidth) then angular.linewidth else nil
	if dash.fill ~= "solid" then
		graph.lineStyle = dash
	end

	if hasFillBelowTo then
		graph.fillOpacity = 35 -- bands are hardcoded in flot
	elseif type(angular.fill) == "number" then
		graph.fillOpacity = angular.fill * 10
	end

	if type(angular.fillGradient) == "number" and angular.fillGradient > 0 then
		graph.gradientMode = "opacity"
		graph.fillOpacity = angular.fillGradient * 10
	end

	graph.spanNulls = angular.nullPointMode == "connected"

	if truthy(env, angular.steppedLine) then
		graph.lineInterpolation = "stepAfter"
	end

	if graph.drawStyle == "bars" then
		graph.fillOpacity = 100
	end

	if truthy(env, angular.stack) then
		local percentage = truthy(env, angular.percentage)
		graph.stacking = { mode = if percentage then "percent" else "normal", group = "A" }
		-- Grafana tests `angular.yaxis` (the alignment object), not yaxes.
		if percentage and truthy(env, angular.yaxis) then
			y1.min = nil
			y1.max = nil
			if y1.decimals == 0 then
				y1.decimals = nil
			end
		end
	end

	y1.custom = omitNil(env, graph)
	y1.nullValueMode = if present(env, angular.nullPointMode) then angular.nullPointMode else nil

	local legendOpts: { [string]: any } =
		{ displayMode = "list", showLegend = true, placement = "bottom", calcs = newList(env) }
	local options = { legend = legendOpts, tooltip = { mode = "single", sort = "none" } }

	local legend = Json.tbl(env, angular.legend)
	if legend and truthy(env, angular.legend) then
		if truthy(env, legend.show) then
			legendOpts.displayMode = if truthy(env, legend.alignAsTable) then "table" else "list"
		else
			legendOpts.showLegend = false
		end
		if truthy(env, legend.rightSide) then
			legendOpts.placement = "right"
		end
		if truthy(env, legend.values) then
			legendOpts.calcs = legendReducers(env, legend)
		end
		if truthy(env, legend.sideWidth) then
			legendOpts.width = legend.sideWidth
		end
		if truthy(env, legend.hideZero) then
			table.insert(overrides, legendHideFrom(env, "allIsZero"))
		end
		if truthy(env, legend.hideEmpty) then
			table.insert(overrides, legendHideFrom(env, "allIsNull"))
		end
	end

	local tooltip = Json.tbl(env, angular.tooltip)
	if tooltip and truthy(env, angular.tooltip) then
		if tooltip.shared ~= nil then
			options.tooltip.mode = if truthy(env, tooltip.shared) then "multi" else "single"
		end
		if tooltip.sort ~= nil and truthy(env, tooltip.shared) then
			options.tooltip.sort = if tooltip.sort == 1 then "asc" elseif tooltip.sort == 2 then "desc" else "none"
		end
	end

	local thresholds: { { [any]: any } } = {}
	for _, raw in Json.list(env, angular.thresholds) do
		local th = Json.tbl(env, raw)
		if th then
			table.insert(thresholds, th)
		end
	end
	if #thresholds > 0 then
		local steps = newList(env)
		local area, line = false, false
		table.sort(thresholds, function(a, b)
			return (Json.num(env, a.value) or 0) < (Json.num(env, b.value) or 0)
		end)
		for idx, th in thresholds do
			local nextTh = thresholds[idx + 1]
			if truthy(env, th.fill) then
				area = true
			end
			if truthy(env, th.line) then
				line = true
			end
			if th.op == "gt" then
				table.insert(steps, { value = th.value, color = thresholdColor(env, th) })
			end
			if th.op == "lt" then
				if #steps == 0 then
					table.insert(steps, { value = -math.huge, color = thresholdColor(env, th) })
				end
				-- Transparent up to the next gt threshold (or the end); a following lt
				-- continues with that threshold's color.
				local isGap = nextTh
					and nextTh.op == "gt"
					and (Json.num(env, nextTh.value) or 0) > (Json.num(env, th.value) or 0)
				if not isGap and nextTh and nextTh.op == "lt" then
					table.insert(steps, { value = th.value, color = thresholdColor(env, nextTh) })
				else
					table.insert(steps, { value = th.value, color = "transparent" })
				end
			end
		end
		if #steps > 0 and steps[1].value ~= -math.huge then
			table.insert(steps, 1, { color = "transparent", value = -math.huge })
		end
		local mode = if area then "area" else "line"
		if line and area then
			mode = "line+area"
		end
		y1.custom.thresholdsStyle = { mode = mode }
		y1.thresholds = { mode = "absolute", steps = steps }
	end

	local xaxis = Json.tbl(env, angular.xaxis)
	if xaxis and xaxis.show == false and xaxis.mode == "time" then
		local props = newList(env)
		table.insert(props, prop("custom.axisPlacement", "hidden"))
		table.insert(overrides, { matcher = { id = "byType", options = "time" }, properties = props })
	end

	return { defaults = omitNil(env, y1), overrides = overrides }, options
end

-- valueMappings.ts getActiveThreshold.
local function activeThreshold(value: number, steps: { any }): any
	local active = steps[1]
	for i = 2, #steps do
		local s = steps[i]
		if s.value ~= nil and value >= s.value then
			active = s
		else
			break
		end
	end
	return active
end

local function jsString(v: any): string
	if type(v) == "number" and v == math.floor(v) and math.abs(v) < 1e21 then
		return string.format("%d", v)
	end
	return tostring(v)
end

-- valueMappings.ts upgradeOldAngularValueMapping.
local function upgradeMapping(env: Env, old: { [any]: any }, kind: number, thresholds: any): any
	local valueOptions: { [string]: any } = {}
	local out: { any } = {}
	local color = nil
	-- parseFloat(old.text): the longest numeric prefix.
	local numeric: number? = nil
	if type(old.text) == "string" then
		local lead = string.match(old.text, "^%s*([%+%-]?%d*%.?%d+[eE][%+%-]?%d+)")
			or string.match(old.text, "^%s*([%+%-]?%d*%.?%d+)")
			or string.match(old.text, "^%s*([%+%-]?%d+)")
		numeric = if lead then tonumber(lead) else nil
	end
	if type(old.text) == "number" then
		numeric = old.text
	end
	if thresholds and numeric then
		local level = activeThreshold(numeric, thresholds.steps)
		if level and truthy(env, level.color) then
			color = level.color
		end
	end
	if kind == 1 then
		if present(env, old.value) then
			if old.value == "null" then
				table.insert(
					out,
					{ type = "special", options = { match = "null", result = { text = old.text, color = color } } }
				)
			else
				valueOptions[jsString(old.value)] = { text = old.text, color = color }
			end
		end
	else
		if old.from == "null" or old.to == "null" then
			table.insert(
				out,
				{ type = "special", options = { match = "null", result = { text = old.text, color = color } } }
			)
		else
			table.insert(out, {
				type = "range",
				options = {
					from = jsNumber(env, old.from),
					to = jsNumber(env, old.to),
					result = { text = old.text, color = color },
				},
			})
		end
	end
	if next(valueOptions) ~= nil then
		table.insert(out, 1, { type = "value", options = valueOptions })
	end
	return out[1]
end

-- valueMappings.ts convertOldAngularValueMappings.
local function angularMappings(env: Env, prev: { [any]: any }, thresholds: any): { any }
	local mappings = newList(env)
	local kind = prev.mappingType
	if not truthy(env, kind) then
		if #Json.list(env, prev.valueMaps) > 0 then
			kind = 1
		elseif #Json.list(env, prev.rangeMaps) > 0 then
			kind = 2
		end
	end
	local list = if kind == 1 then prev.valueMaps elseif kind == 2 then prev.rangeMaps else nil
	-- `fieldConfig.defaults.thresholds` of the legacy panel wins, as in Grafana.
	local own = Json.path(env, prev, "fieldConfig", "defaults", "thresholds")
	local th = if truthy(env, own) then own else thresholds
	for _, raw in Json.list(env, list) do
		local map = Json.tbl(env, raw)
		if map then
			local m = upgradeMapping(env, map, kind, th)
			if m then
				table.insert(mappings, m)
			end
		end
	end
	return mappings
end

-- SingleStatBaseOptions.ts migrateFromAngularSinglestat plus the angular part
-- of StatMigrations.ts statPanelChangedHandler.
local function singlestatToStat(env: Env, prev: { [any]: any }, fieldConfig: { [string]: any }, pluginVersion: any): any
	local calcs = newList(env)
	table.insert(
		calcs,
		if type(prev.valueName) == "string" and REDUCERS[prev.valueName] then REDUCERS[prev.valueName] else "mean"
	)
	local reduceOptions: { [string]: any } = { calcs = calcs }
	local options: { [string]: any } = { reduceOptions = reduceOptions, orientation = "horizontal" }
	local defaults: { [string]: any } = {}

	if truthy(env, prev.format) then
		defaults.unit = prev.format
	end
	if truthy(env, prev.tableColumn) then
		reduceOptions.fields = "/^" .. tostring(prev.tableColumn) .. "$/"
	end
	if truthy(env, prev.nullPointMode) then
		defaults.nullValueMode = prev.nullPointMode
	end
	if truthy(env, prev.nullText) then
		defaults.noValue = prev.nullText
	end
	if truthy(env, prev.decimals) or prev.decimals == 0 then
		defaults.decimals = prev.decimals
	end

	if truthy(env, prev.thresholds) and truthy(env, prev.colors) and type(prev.thresholds) == "string" then
		local levels: { number | false } = {}
		for part in string.gmatch(prev.thresholds .. ",", "([^,]*),") do
			table.insert(levels, jsNumber(env, part) or false)
		end
		local steps = newList(env)
		for _, color in Json.list(env, prev.colors) do
			local idx = #steps
			if idx >= 1 then
				local level = levels[idx]
				table.insert(steps, { value = if level then level else nil, color = color })
			else
				table.insert(steps, { value = -math.huge, color = color })
			end
		end
		defaults.thresholds = { mode = "absolute", steps = steps }
	end

	local mappings = angularMappings(env, prev, defaults.thresholds)
	if #mappings > 0 then
		defaults.mappings = mappings
	end

	local gauge = Json.tbl(env, prev.gauge)
	if gauge and truthy(env, gauge.show) then
		defaults.min = if present(env, gauge.minValue) then gauge.minValue else nil
		defaults.max = if present(env, gauge.maxValue) then gauge.maxValue else nil
	end

	-- statPanelChangedHandler
	local sparkline = Json.tbl(env, prev.sparkline)
	options.graphMode = if sparkline and truthy(env, sparkline.show) then "area" else "none"
	if truthy(env, prev.colorBackground) then
		options.colorMode = "background"
	elseif truthy(env, prev.colorValue) then
		options.colorMode = "value"
	else
		options.colorMode = "none"
		if sparkline and truthy(env, sparkline.lineColor) and options.graphMode == "area" then
			defaults.color = { mode = "fixed", fixedColor = sparkline.lineColor }
		end
	end
	if prev.valueName == "name" then
		options.textMode = "name"
	end

	-- The stat plugin's migration handler (sharedSingleStatMigrationHandler)
	-- runs next; on these fresh options only its pre-8.0 rule has an effect:
	-- explicit min/max for percent units.
	local lead = string.match(Json.str(env, pluginVersion) or "6.1", "^%s*(%d+%.?%d*)")
	local version = if lead then tonumber(lead) else nil
	if version and version < 8.0 then
		if defaults.unit == "percent" then
			defaults.min = if type(defaults.min) == "number" then defaults.min else 0
			defaults.max = if type(defaults.max) == "number" then defaults.max else 100
		elseif defaults.unit == "percentunit" then
			defaults.min = if type(defaults.min) == "number" then defaults.min else 0
			defaults.max = if type(defaults.max) == "number" then defaults.max else 1
		end
	end

	fieldConfig.defaults = defaults
	return options
end

-- table/migrations.ts transformsMap, columnsMap and colorModeMap.
local TABLE_TRANSFORMS: { [string]: string } = {
	timeseries_to_rows = "seriesToRows",
	timeseries_to_columns = "seriesToColumns",
	timeseries_aggregations = "reduce",
	table = "merge",
}
local TABLE_COLUMNS: { [string]: string } = {
	avg = "mean",
	min = "min",
	max = "max",
	total = "sum",
	current = "lastNotNull",
	count = "count",
}
local TABLE_COLOR_MODES: { [string]: string } = {
	cell = "color-background",
	row = "color-background",
	value = "color-text",
}

-- JavaScript parseInt(s, 10); nil stands for NaN.
local function parseInt(s: any): number?
	if type(s) == "number" then
		return if s == s then (if s < 0 then math.ceil(s) else math.floor(s)) else nil
	elseif type(s) ~= "string" then
		return nil
	end
	local digits = string.match(s, "^%s*([+-]?%d+)")
	return if digits then tonumber(digits) else nil
end

-- generateThresholds: -Infinity first, numbers kept, strings parseInt'ed.
local function tableThresholds(env: Env, thresholds: any, colors: any): { [string]: any }
	local colorList = Json.list(env, colors)
	local steps = newList(env)
	table.insert(steps, { value = -math.huge, color = colorList[1] })
	for i, t in Json.list(env, thresholds) do
		table.insert(steps, { value = if type(t) == "number" then t else parseInt(t), color = colorList[i + 1] })
	end
	return { mode = "absolute", steps = steps }
end

-- migrateTransformations: the panel's own, then the old `transform`.
local function tableOldTransformations(env: Env, own: any, angular: { [any]: any }): { any }
	local out = newList(env)
	for _, t in Json.list(env, own) do
		table.insert(out, t)
	end
	local kind = angular.transform
	local id = if type(kind) == "string" then TABLE_TRANSFORMS[kind] else nil
	if id then
		local options: { [string]: any } = { reducers = newList(env) }
		if kind == "timeseries_aggregations" then
			options.includeTimeField = false
			for _, column in Json.list(env, angular.columns) do
				local value = Json.str(env, Json.path(env, column, "value"))
				table.insert(options.reducers, if value then TABLE_COLUMNS[value] or env.null else env.null)
			end
		end
		table.insert(out, { id = id, options = options })
	end
	return out
end

-- `Json.list` of a value, or nil when it is not a non-empty list.
local function nonEmpty(env: Env, v: any): { any }?
	local l = Json.list(env, v)
	return if #l > 0 then l else nil
end

-- migrateTableStyleToOverride, with migrateHiddenFields' custom.hidden ->
-- custom.hideFrom.viz.
local function tableStyleOverride(env: Env, style: { [any]: any }): { [string]: any }
	local pattern = Json.str(env, style.pattern)
	local regex = pattern ~= nil and string.match(pattern, "^/.*/$") ~= nil
	local props = newList(env)
	if truthy(env, style.alias) then
		table.insert(props, prop("displayName", style.alias))
	end
	if truthy(env, style.unit) then
		table.insert(props, prop("unit", style.unit))
	end
	if style.decimals ~= nil then
		table.insert(props, prop("decimals", style.decimals))
	end
	if style.type == "date" then
		-- A template string: an absent format reads "undefined".
		table.insert(props, prop("unit", "time: " .. (Json.str(env, style.dateFormat) or "undefined")))
	end
	if style.type == "hidden" then
		table.insert(props, prop("custom.hideFrom.viz", true))
	end
	if truthy(env, style.link) then
		local links = newList(env)
		table.insert(links, {
			title = if present(env, style.linkTooltip) then style.linkTooltip else "",
			url = if present(env, style.linkUrl) then style.linkUrl else "",
			targetBlank = if present(env, style.linkTargetBlank) then style.linkTargetBlank else false,
		})
		table.insert(props, prop("links", links))
	end
	if truthy(env, style.colorMode) then
		local mode = Json.str(env, style.colorMode)
		table.insert(props, prop("custom.cellOptions", { type = if mode then TABLE_COLOR_MODES[mode] else nil }))
	end
	if truthy(env, style.align) then
		table.insert(props, prop("custom.align", if style.align == "auto" then env.null else style.align))
	end
	if nonEmpty(env, style.thresholds) and nonEmpty(env, style.colors) then
		table.insert(props, prop("thresholds", tableThresholds(env, style.thresholds, style.colors)))
	end
	return { matcher = { id = if regex then "byRegexp" else "byName", options = pattern }, properties = props }
end

-- migrateDefaults of the `/.*/` style.
local function tableDefaults(env: Env, style: { [any]: any }?): { [string]: any }
	if style == nil then
		return { custom = {} }
	end
	local s = style :: { [any]: any }
	local custom: { [string]: any } = {}
	if present(env, s.align) then
		custom.align = if s.align == "auto" then env.null else s.align
	end
	local defaults: { [string]: any } = omitNil(env, {
		unit = s.unit,
		decimals = s.decimals,
		displayName = s.alias,
		custom = custom,
	})
	if nonEmpty(env, s.thresholds) then
		defaults.thresholds = tableThresholds(env, s.thresholds, s.colors)
	end
	if truthy(env, s.colorMode) then
		local mode = Json.str(env, s.colorMode)
		custom.cellOptions = { type = if mode then TABLE_COLOR_MODES[mode] else nil }
	end
	return defaults
end

-- tablePanelChangedHandler: field config from the angular `styles`.
local function tableOldFieldConfig(env: Env, angular: { [any]: any }): { [string]: any }
	local defaultStyle: { [any]: any }? = nil
	local overrides = newList(env)
	for _, raw in Json.list(env, angular.styles) do
		local style = Json.tbl(env, raw)
		if style == nil then
			continue
		end
		if style.pattern == "/.*/" then
			defaultStyle = defaultStyle or style
		else
			table.insert(overrides, tableStyleOverride(env, style))
		end
	end
	return { defaults = tableDefaults(env, defaultStyle), overrides = overrides }
end

-- The panel JSON Grafana would render after auto-migrating a legacy type, or nil + reason
-- when the type is not a legacy one / cannot be migrated mechanically.
function M.migrate(panel: any, env: Env): (any?, string?)
	local src = Json.tbl(env, panel)
	if src == nil then
		return nil, "panel is not an object"
	end
	local from = Json.str(env, src.type)
	local target = if from then M.LEGACY[from] else nil
	if from == nil or target == nil then
		return nil, "panel type " .. tostring(from) .. " is not a legacy angular type"
	end
	if from == "graph" then
		-- getPanelPluginToMigrateTo.ts picks other panels for these x axis modes.
		local mode = Json.path(env, src, "xaxis", "mode")
		if mode == "series" then
			return nil,
				"graph with xaxis.mode series migrates to " .. (if truthy(env, Json.path(env, src, "legend", "values"))
					then "bargauge"
					else "barchart") .. ", not timeseries"
		elseif mode == "histogram" then
			return nil, "graph with xaxis.mode histogram migrates to histogram, not timeseries"
		end
	end

	local copy = deepCopy(env, src)
	local out: { [any]: any } = {}
	local angular: { [any]: any } = {}
	for k, v in copy do
		if KEEP[k] then
			out[k] = v
		else
			angular[k] = v
		end
	end
	out.type = target

	-- clearPropertiesBeforePluginChange: custom defaults and custom.* override
	-- properties belong to the old plugin.
	local fc = Json.obj(env, copy.fieldConfig)
	local defaults: { [string]: any } = Tbl.copy(Json.obj(env, fc.defaults))
	defaults.custom = {}
	local overrides = newList(env)
	for _, raw in Json.list(env, fc.overrides) do
		local rule = Json.tbl(env, raw)
		if rule then
			local props = newList(env)
			for _, p in Json.list(env, rule.properties) do
				local id = Json.str(env, Json.path(env, p, "id"))
				if not (id and string.sub(id, 1, 7) == "custom.") then
					table.insert(props, p)
				end
			end
			local kept: { [any]: any } = Tbl.copy(rule)
			kept.properties = props
			table.insert(overrides, kept)
		end
	end
	local fieldConfig: { [string]: any } = { defaults = defaults, overrides = overrides }

	if from == "graph" then
		local newFieldConfig, options = graphToTimeseries(env, angular, fieldConfig)
		out.fieldConfig = newFieldConfig
		out.options = options
		out.alert = angular.alert
	elseif from == "table-old" then
		out.options = {}
		out.transformations = tableOldTransformations(env, copy.transformations, angular)
		out.fieldConfig = tableOldFieldConfig(env, angular)
	else
		out.options = singlestatToStat(env, angular, fieldConfig, copy.pluginVersion)
		out.fieldConfig = fieldConfig
	end
	return out, nil
end

return M
