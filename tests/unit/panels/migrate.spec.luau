--!strict
-- Legacy angular panel auto-migration (Grafana v12.4.0). Dashboards still
-- carrying `graph` and `singlestat` panels render in Grafana 11/12 as the
-- timeseries/stat panels PanelModel.ts migrates them to; the native block must
-- show the same thing. Cases are ported from
-- public/app/plugins/panel/timeseries/migrations.test.ts (+ its snapshots),
-- public/app/plugins/panel/stat/StatMigrations.test.ts and
-- packages/grafana-ui/.../SingleStatBaseOptions.test.ts.
local t = require("../../lib/test")
local S = require("./support")
local Migrate = require("../../../plugin/lib/panels/migrate")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

-- One fieldConfig override property.
local function P(id: string, value: any): any
	return { id = id, value = value }
end

local function migrate(text: string): any
	local out, reason = Migrate.migrate(S.json(text), env)
	assert(out, reason)
	return out
end

-- migrations.test.ts `twoYAxis` fixture.
local TWO_Y_AXIS = [[{
	"type": "graph",
	"yaxes": [
		{"label": "Y111", "show": true, "logBase": 10, "min": "0", "max": "1000", "format": "areaMI2", "$$hashKey": "object:19", "decimals": 3},
		{"label": "Y222", "show": true, "logBase": 1, "min": "-10", "max": "25", "format": "degree", "$$hashKey": "object:20", "decimals": 2}
	],
	"xaxis": {"show": true, "mode": "time", "name": null, "values": [], "buckets": null},
	"yaxis": {"align": false, "alignLevel": null},
	"lines": true, "fill": 1, "linewidth": 1, "dashLength": 10, "spaceLength": 10, "pointradius": 2,
	"legend": {"show": true, "values": false, "min": false, "max": false, "current": false, "total": false, "avg": false},
	"nullPointMode": "null",
	"tooltip": {"value_type": "individual", "shared": true, "sort": 0},
	"aliasColors": {},
	"seriesOverrides": [{"alias": "B-series", "yaxis": 2, "dashLength": 5, "dashes": true, "spaceLength": 8}],
	"thresholds": [], "timeRegions": [],
	"targets": [{"refId": "A"}, {"refId": "B"}],
	"fillGradient": 0, "dashes": true, "hiddenSeries": false, "points": false, "bars": false,
	"stack": false, "percentage": false, "steppedLine": false, "timeFrom": null, "timeShift": null, "datasource": null
}]]

-- migrations.test.ts `customColorRegex` fixture.
local CUSTOM_COLOR_REGEX = [[{
	"type": "graph", "title": "Panel Title",
	"aliasColors": {}, "dashLength": 10, "fill": 5, "fillGradient": 6,
	"legend": {"avg": true, "current": true, "max": true, "min": true, "show": true, "total": true, "values": true, "alignAsTable": true},
	"lines": true, "linewidth": 1, "nullPointMode": "null", "options": {"alertThreshold": true}, "pointradius": 2,
	"seriesOverrides": [
		{"$$hashKey": "object:12", "alias": "/^A-/", "color": "rgba(165, 72, 170, 0.77)"},
		{"$$hashKey": "object:13", "alias": "/.*Status: 2[0-9]+.*/i", "color": "rgba(16, 72, 170, 0.77)"}
	],
	"spaceLength": 10, "steppedLine": true, "thresholds": [], "timeRegions": [],
	"tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
	"xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
	"yaxes": [
		{"$$hashKey": "object:42", "format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": false},
		{"$$hashKey": "object:43", "format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
	],
	"yaxis": {"align": false, "alignLevel": null},
	"timeFrom": null, "timeShift": null, "bars": false, "dashes": false, "hiddenSeries": false,
	"percentage": false, "points": false, "stack": false, "decimals": 1, "datasource": null
}]]

describe("graph -> timeseries (timeseries/migrations.ts)", function()
	it("matches Grafana's twoYAxis snapshot: right axis via an override, dashes per series", function()
		local p = migrate(TWO_Y_AXIS)
		expect(p.type).toBe("timeseries")
		expect(p.fieldConfig).toEqual({
			defaults = {
				custom = {
					axisLabel = "Y111",
					axisPlacement = "auto",
					drawStyle = "line",
					fillOpacity = 10,
					lineStyle = { dash = { 10, 10 }, fill = "dash" },
					lineWidth = 1,
					scaleDistribution = { log = 10, type = "log" },
					showPoints = "never",
					spanNulls = false,
				},
				decimals = 3,
				max = 1000,
				min = 0,
				nullValueMode = "null",
				unit = "areaMI2",
			},
			overrides = {
				{
					matcher = { id = "byName", options = "B-series" },
					properties = {
						P("unit", "degree"),
						P("decimals", 2),
						P("min", -10),
						P("max", 25),
						P("custom.axisPlacement", "right"),
						P("custom.axisLabel", "Y222"),
						P("custom.lineStyle", { dash = { 5, 8 }, fill = "dash" }),
					},
				},
			},
		})
		expect(p.options).toEqual({
			legend = { calcs = {}, displayMode = "list", placement = "bottom", showLegend = true },
			tooltip = { mode = "multi", sort = "none" },
		})
	end)

	it("matches Grafana's regex alias snapshot: byRegexp matchers, table legend calcs in key order", function()
		local p = migrate(CUSTOM_COLOR_REGEX)
		expect(p.fieldConfig).toEqual({
			defaults = {
				custom = {
					axisPlacement = "hidden",
					drawStyle = "line",
					fillOpacity = 60,
					gradientMode = "opacity",
					lineInterpolation = "stepAfter",
					lineWidth = 1,
					showPoints = "never",
					spanNulls = false,
				},
				nullValueMode = "null",
				unit = "short",
			},
			overrides = {
				{
					matcher = { id = "byRegexp", options = "/^A-/" },
					properties = {
						{ id = "color", value = { fixedColor = "rgba(165, 72, 170, 0.77)", mode = "fixed" } },
					},
				},
				{
					matcher = { id = "byRegexp", options = "/.*Status: 2[0-9]+.*/i" },
					properties = {
						{ id = "color", value = { fixedColor = "rgba(16, 72, 170, 0.77)", mode = "fixed" } },
					},
				},
			},
		})
		expect(p.options.legend).toEqual({
			calcs = { "mean", "lastNotNull", "max", "min", "sum" },
			displayMode = "table",
			placement = "bottom",
			showLegend = true,
		})
	end)

	-- One panel exercising the common real-world mix at once: stacked filled
	-- lines, a second axis for a regex-matched series, alias colors and a
	-- table legend with values.
	it("migrates stack, fill, both axes, series overrides, alias colors and a table legend together", function()
		local p = migrate([[{
			"id": 7, "title": "Requests", "type": "graph",
			"gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
			"targets": [{"refId": "A", "expr": "sum(rate(http_requests_total[5m])) by (code)"}],
			"datasource": {"type": "prometheus", "uid": "prom"},
			"lines": true, "fill": 2, "linewidth": 2, "stack": true, "percentage": false,
			"nullPointMode": "null as zero",
			"yaxes": [
				{"format": "reqps", "min": 0, "max": null, "decimals": 1, "show": true, "logBase": 1},
				{"format": "percentunit", "min": "0", "max": "1", "decimals": null, "show": true, "logBase": 2, "label": "errors"}
			],
			"seriesOverrides": [
				{"alias": "/5\\d\\d/", "yaxis": 2, "stack": false, "color": "#F2495C", "fill": 0}
			],
			"aliasColors": {"200": "green", "404": "", "301": "blue"},
			"legend": {"show": true, "alignAsTable": true, "rightSide": true, "values": true, "current": true, "max": true, "min": false, "avg": true, "sideWidth": 300},
			"tooltip": {"shared": true, "sort": 2}
		}]])
		expect(p.type).toBe("timeseries")
		expect(p.id).toBe(7)
		expect(p.targets[1].expr).toBe("sum(rate(http_requests_total[5m])) by (code)")
		expect(p.fieldConfig).toEqual({
			defaults = {
				custom = {
					axisPlacement = "auto",
					drawStyle = "line",
					fillOpacity = 20,
					lineWidth = 2,
					showPoints = "never",
					spanNulls = false,
					stacking = { mode = "normal", group = "A" },
				},
				decimals = 1,
				min = 0,
				nullValueMode = "null as zero",
				unit = "reqps",
			},
			overrides = {
				{
					matcher = { id = "byName", options = "200" },
					properties = { { id = "color", value = { mode = "fixed", fixedColor = "green" } } },
				},
				{
					matcher = { id = "byName", options = "301" },
					properties = { { id = "color", value = { mode = "fixed", fixedColor = "blue" } } },
				},
				{
					matcher = { id = "byRegexp", options = "/5\\d\\d/" },
					properties = {
						P("color", { fixedColor = "#F2495C", mode = "fixed" }),
						P("custom.fillOpacity", 0),
						P("custom.stacking", { mode = "none", group = "A" }),
						P("unit", "percentunit"),
						-- y2 min 0 equals y1 min 0, so fillY2DynamicValues skips it.
						P("max", 1),
						P("custom.axisPlacement", "right"),
						P("custom.axisLabel", "errors"),
						P("custom.scaleDistribution", { type = "log", log = 2 }),
					},
				},
			},
		})
		expect(p.options).toEqual({
			legend = {
				calcs = { "mean", "lastNotNull", "max" },
				displayMode = "table",
				placement = "right",
				showLegend = true,
				width = 300,
			},
			tooltip = { mode = "multi", sort = "desc" },
		})
		-- Legacy keys are gone, as clearPropertiesBeforePluginChange deletes them.
		expect(p.yaxes).toBeNil()
		expect(p.seriesOverrides).toBeNil()
	end)

	it("orders gt thresholds into steps with a transparent base (thresholds: Only gt)", function()
		local p = migrate([[{"type": "graph", "thresholds": [
			{"colorMode": "critical", "fill": true, "line": false, "op": "gt", "value": 80, "yaxis": "left"},
			{"colorMode": "warning", "fill": true, "line": false, "op": "gt", "value": 50, "yaxis": "left"}
		]}]])
		expect(p.fieldConfig.defaults.custom.thresholdsStyle.mode).toBe("area")
		expect(p.fieldConfig.defaults.thresholds).toEqual({
			mode = "absolute",
			steps = {
				{ color = "transparent", value = -math.huge },
				{ color = "orange", value = 50 },
				{ color = "red", value = 80 },
			},
		})
	end)

	it("fills solid bars and keeps points-only panels free of showPoints (simple bars, x axis)", function()
		local bars = migrate([[{"type": "graph", "bars": true}]])
		expect(bars.fieldConfig.defaults.custom).toEqual({
			drawStyle = "bars",
			fillOpacity = 100,
			showPoints = "never",
			spanNulls = false,
		})
		local hidden = migrate([[{"type": "graph", "xaxis": {"show": false, "mode": "time"}}]])
		expect(hidden.fieldConfig).toEqual({
			defaults = { custom = { drawStyle = "points", spanNulls = false } },
			overrides = {
				{
					matcher = { id = "byType", options = "time" },
					properties = { { id = "custom.axisPlacement", value = "hidden" } },
				},
			},
		})
	end)

	it("hides all-zero series from legend and tooltip (legend hide allZeros)", function()
		local p = migrate([[{"type": "graph", "legend": {"show": true, "values": false, "hideZero": true}}]])
		expect(p.fieldConfig.overrides).toEqual({
			{
				matcher = { id = "byValue", options = { reducer = "allIsZero", op = "gte", value = 0 } },
				properties = { { id = "custom.hideFrom", value = { tooltip = true, viz = false, legend = true } } },
			},
		})
	end)

	it("drops a lines: false series' line width to 0 (seriesOverride lines: false)", function()
		local p = migrate([[{"type": "graph", "seriesOverrides": [{"alias": "A-series", "lines": false}]}]])
		expect(p.fieldConfig.overrides[1]).toEqual({
			matcher = { id = "byName", options = "A-series" },
			properties = { { id = "custom.lineWidth", value = 0 } },
		})
	end)

	-- PanelModel.clearPropertiesBeforePluginChange: the old plugin's custom
	-- options do not carry over, standard ones do.
	it("keeps standard fieldConfig and drops the graph's custom options", function()
		local p = migrate([[{"type": "graph", "fieldConfig": {
			"defaults": {"custom": {"lineWidth": 9}, "displayName": "D", "links": []},
			"overrides": [{"matcher": {"id": "byName", "options": "x"}, "properties": [
				{"id": "custom.width", "value": 3}, {"id": "displayName", "value": "X"}
			]}]
		}}]])
		expect(p.fieldConfig.defaults.displayName).toBe("D")
		expect(p.fieldConfig.defaults.custom.lineWidth).toBeNil()
		expect(p.fieldConfig.overrides[1].properties).toEqual({ { id = "displayName", value = "X" } })
	end)

	it("never mutates the decoded input", function()
		local input = S.json(TWO_Y_AXIS)
		local before = env.encode(input)
		Migrate.migrate(input, env)
		expect(env.encode(input)).toBe(before)
		expect(input.type).toBe("graph")
	end)

	-- getPanelPluginToMigrateTo.ts sends these graphs to other panels.
	it("declines graphs Grafana migrates to bar chart, bar gauge or histogram", function()
		local out, reason = Migrate.migrate(S.json([[{"type": "graph", "xaxis": {"mode": "series"}}]]), env)
		expect(out).toBeNil()
		expect(reason).toBe("graph with xaxis.mode series migrates to barchart, not timeseries")
		out, reason = Migrate.migrate(S.json([[{"type": "graph", "xaxis": {"mode": "histogram"}}]]), env)
		expect(out).toBeNil()
		expect(reason).toBe("graph with xaxis.mode histogram migrates to histogram, not timeseries")
	end)

	it("declines non-legacy panel types", function()
		local out, reason = Migrate.migrate(S.json([[{"type": "timeseries"}]]), env)
		expect(out).toBeNil()
		expect(reason).toBe("panel type timeseries is not a legacy angular type")
	end)
end)

describe("singlestat -> stat (StatMigrations.ts, SingleStatBaseOptions.ts)", function()
	it("maps sparkline.show to graphMode (sparkline disabled / enabled)", function()
		expect(
			migrate([[{"type": "singlestat", "format": "ms", "decimals": 7, "sparkline": {"show": false}}]]).options.graphMode
		).toBe("none")
		expect(
			migrate([[{"type": "singlestat", "format": "ms", "decimals": 7, "sparkline": {"show": true}}]]).options.graphMode
		).toBe("area")
	end)

	it("uses no color unless one was configured", function()
		local p = migrate([[{"type": "grafana-singlestat-panel", "valueName": "name"}]])
		expect(p.type).toBe("stat")
		expect(p.options.colorMode).toBe("none")
		expect(p.options.textMode).toBe("name")
		-- `name` is no reducer: Grafana falls back to mean.
		expect(p.options.reduceOptions.calcs).toEqual({ "mean" })
		expect(migrate([[{"type": "singlestat", "valueName": "name", "colorBackground": true}]]).options.colorMode).toBe(
			"background"
		)
	end)

	it("moves format/decimals to defaults and ignores a hidden gauge's range (no enabled gauge)", function()
		local p = migrate([[{"type": "singlestat", "format": "ms", "decimals": 7,
			"gauge": {"maxValue": 150, "minValue": -10, "show": false}}]])
		expect(p.fieldConfig.defaults.unit).toBe("ms")
		expect(p.fieldConfig.defaults.decimals).toBe(7)
		expect(p.fieldConfig.defaults.min).toBeNil()
		expect(p.fieldConfig.defaults.max).toBeNil()
		local shown = migrate([[{"type": "singlestat", "gauge": {"maxValue": 150, "minValue": -10, "show": true}}]])
		expect(shown.fieldConfig.defaults.min).toBe(-10)
		expect(shown.fieldConfig.defaults.max).toBe(150)
		expect(shown.type).toBe("stat")
	end)

	it("reduces a table column by field regex (tableColumn set)", function()
		local p = migrate([[{"type": "singlestat", "tableColumn": "info"}]])
		expect(p.options.reduceOptions).toEqual({ calcs = { "mean" }, fields = "/^info$/" })
		expect(p.options.orientation).toBe("horizontal")
	end)

	it("resolves reducer aliases: current is lastNotNull", function()
		expect(migrate([[{"type": "singlestat", "valueName": "current"}]]).options.reduceOptions.calcs).toEqual({
			"lastNotNull",
		})
	end)

	it("turns threshold levels and colors into steps and colors value maps by threshold", function()
		local p = migrate([[{"type": "singlestat", "pluginVersion": "8.5.0",
			"thresholds": "50, 80", "colors": ["green", "orange", "red"], "colorValue": true,
			"nullText": "n/a", "nullPointMode": "connected",
			"valueMaps": [{"op": "=", "text": "90", "value": "1"}, {"op": "=", "text": "Down", "value": "null"}],
			"mappingType": 1}]])
		expect(p.options.colorMode).toBe("value")
		expect(p.fieldConfig.defaults).toEqual({
			thresholds = {
				mode = "absolute",
				steps = {
					{ value = -math.huge, color = "green" },
					{ value = 50, color = "orange" },
					{ value = 80, color = "red" },
				},
			},
			mappings = {
				{ type = "value", options = { ["1"] = { text = "90", color = "red" } } },
				{ type = "special", options = { match = "null", result = { text = "Down" } } } :: any,
			},
			noValue = "n/a",
			nullValueMode = "connected",
		})
	end)

	it("converts range maps, null bounds to a special match", function()
		local p = migrate([[{"type": "singlestat",
			"rangeMaps": [{"from": "0", "to": "10", "text": "low"}, {"from": "null", "to": "null", "text": "none"}]}]])
		expect(p.fieldConfig.defaults.mappings).toEqual({
			{ type = "range", options = { from = 0, to = 10, result = { text = "low" } } },
			{ type = "special", options = { match = "null", result = { text = "none" } } } :: any,
		})
	end)

	it("paints the sparkline with its line color when nothing else is colored", function()
		local p = migrate([[{"type": "singlestat", "sparkline": {"show": true, "lineColor": "#3274D9"}}]])
		expect(p.fieldConfig.defaults.color).toEqual({ mode = "fixed", fixedColor = "#3274D9" })
	end)

	-- sharedSingleStatMigrationHandler (auto set min/max for percent units before 8.0).
	it("pins percent units to 0..100 for panels saved before 8.0", function()
		local old = migrate([[{"type": "singlestat", "format": "percent"}]])
		expect(old.fieldConfig.defaults.min).toBe(0)
		expect(old.fieldConfig.defaults.max).toBe(100)
		local new = migrate([[{"type": "singlestat", "format": "percent", "pluginVersion": "9.0.0"}]])
		expect(new.fieldConfig.defaults.min).toBeNil()
	end)
end)

-- public/app/plugins/panel/table/migrations.test.ts (Grafana v12.4.0): the
-- `tablePanelChangedHandler` cases, then tableMigrationHandler's
-- migrateHiddenFields, as Grafana runs both on an auto-migrated table-old.
describe("table-old -> table (table/migrations.ts)", function()
	local function tableOld(extra: string): any
		return migrate('{"type": "table-old", "id": 3, "title": "T", "targets": [{"refId": "A"}], ' .. extra .. "}")
	end

	it("turns the old transform into a core transformation (migrates transform out to core transforms)", function()
		local columns = tableOld('"columns": [], "styles": [], "transform": "timeseries_to_columns"')
		expect(columns.type).toBe("table")
		expect(columns.transformations).toEqual({ { id = "seriesToColumns", options = { reducers = {} } } })
		expect(columns.fieldConfig).toEqual({ defaults = { custom = {} }, overrides = {} })
		expect(tableOld('"styles": [], "transform": "timeseries_to_rows"').transformations[1].id).toBe("seriesToRows")
		expect(tableOld('"styles": [], "transform": "table"').transformations[1].id).toBe("merge")
		local agg = tableOld(
			'"columns": [{"text": "Avg", "value": "avg"}, {"text": "Max", "value": "max"}, {"text": "Current", "value": "current"}],'
				.. ' "styles": [], "transform": "timeseries_aggregations"'
		)
		expect(agg.transformations).toEqual({
			{ id = "reduce", options = { includeTimeField = false, reducers = { "mean", "max", "lastNotNull" } } },
		})
		expect(agg.targets[1].refId).toBe("A")
	end)

	it("moves the /.*/ style to defaults and the others to overrides (migrates styles)", function()
		local p = tableOld([=["columns": [], "styles": [
			{"alias": "Time", "align": "auto", "dateFormat": "YYYY-MM-DD HH:mm:ss", "pattern": "Time", "type": "date"},
			{"alias": "", "align": "left", "colorMode": "cell",
			 "colors": ["rgba(245, 54, 54, 0.9)", "rgba(237, 129, 40, 0.89)", "rgba(50, 172, 45, 0.97)"],
			 "dateFormat": "YYYY-MM-DD HH:mm:ss", "decimals": 2, "mappingType": 1, "pattern": "ColorCell",
			 "thresholds": ["5", "10"], "type": "number", "unit": "currencyUSD"},
			{"alias": "", "align": "auto", "colorMode": "value",
			 "colors": ["rgba(245, 54, 54, 0.9)", "rgba(237, 129, 40, 0.89)", "rgba(50, 172, 45, 0.97)"],
			 "dateFormat": "YYYY-MM-DD HH:mm:ss", "decimals": 2, "link": true, "linkTargetBlank": true,
			 "linkTooltip": "", "linkUrl": "http://www.grafana.com", "mappingType": 1, "pattern": "ColorValue",
			 "thresholds": ["5", "10"], "type": "number", "unit": "Bps"},
			{"unit": "short", "type": "number", "alias": "", "decimals": 2,
			 "colors": ["rgba(245, 54, 54, 0.9)", "rgba(237, 129, 40, 0.89)", "rgba(50, 172, 45, 0.97)"],
			 "colorMode": null, "pattern": "/.*/", "thresholds": [], "align": "right"}
		]]=])
		local steps = {
			{ color = "rgba(245, 54, 54, 0.9)", value = -math.huge },
			{ color = "rgba(237, 129, 40, 0.89)", value = 5 },
			{ color = "rgba(50, 172, 45, 0.97)", value = 10 },
		}
		expect(p.fieldConfig.defaults).toEqual({
			custom = { align = "right" },
			decimals = 2,
			displayName = "",
			unit = "short",
		})
		expect(p.transformations).toEqual({})
		expect(p.fieldConfig.overrides).toEqual({
			{
				matcher = { id = "byName", options = "Time" },
				properties = {
					P("displayName", "Time"),
					P("unit", "time: YYYY-MM-DD HH:mm:ss"),
					P("custom.align", env.null),
				},
			},
			{
				matcher = { id = "byName", options = "ColorCell" },
				properties = {
					P("unit", "currencyUSD"),
					P("decimals", 2),
					P("custom.cellOptions", { type = "color-background" }),
					P("custom.align", "left"),
					P("thresholds", { mode = "absolute", steps = steps }),
				},
			},
			{
				matcher = { id = "byName", options = "ColorValue" },
				properties = {
					P("unit", "Bps"),
					P("decimals", 2),
					P("links", { { targetBlank = true, title = "", url = "http://www.grafana.com" } }),
					P("custom.cellOptions", { type = "color-text" }),
					P("custom.align", env.null),
					P("thresholds", { mode = "absolute", steps = steps }),
				},
			},
		})
	end)

	it("hides hidden-style columns from the visualization (migrates hidden fields, migrateHiddenFields)", function()
		local p = tableOld(
			'"styles": [{"dateFormat": "YYYY-MM-DD HH:mm:ss", "pattern": "time", "type": "hidden"},'
				.. ' {"pattern": "/^cpu.*/", "type": "number", "unit": "percent"}]'
		)
		expect(p.fieldConfig.overrides).toEqual({
			{ matcher = { id = "byName", options = "time" }, properties = { P("custom.hideFrom.viz", true) } },
			{ matcher = { id = "byRegexp", options = "/^cpu.*/" }, properties = { P("unit", "percent") } },
		})
	end)
end)

return nil
