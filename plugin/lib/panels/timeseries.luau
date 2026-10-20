--!strict
-- The time series panel (public/app/plugins/panel/timeseries: panelcfg.cue,
-- packages/grafana-schema common GraphFieldConfig) mapped onto
-- lib/render/svg_timeseries:
-- - fieldConfig unit, decimals, min, max, thresholds, per series: series
--   whose unit, bounds, soft bounds (custom.axisSoftMin/Max), placement
--   (custom.axisPlacement), label (custom.axisLabel) or scale distribution
--   (custom.scaleDistribution linear|log|symlog) differ get their own y
--   axis, as Grafana's buildScaleKey groups them (a per-series unit
--   override draws a second axis on the right); custom.axisCenteredZero,
--   custom.axisGridShow;
-- - custom.drawStyle line|bars|points, fillOpacity, spanNulls (true
--   connects; false or a gap threshold keeps gaps), stacking.mode
--   none|normal|percent and stacking.group per series (stacks per scale),
--   custom.transform negative-Y|constant, thresholdsStyle.mode (off, line,
--   dashed, area, line+area, dashed+area; "series" colors by value, drawn
--   as off);
-- - overrides (lib/panels/fieldconfig) for display names, colors and
--   hidden series (custom.hideFrom.viz, .legend, .tooltip);
-- - series colors: palette-classic keeps the chart palette; fixed and
--   by-value modes (thresholds, continuous) paint the whole series in the
--   tone of its `seriesBy` value (getFieldSeriesColor);
-- - options.legend: showLegend, displayMode list|table|hidden, calcs (any
--   lib/panels/reduce reducer, formatted with the series' own config);
-- - exemplars (opts.exemplars) as markers, the selected one (opts.exemplar)
--   read out under the legend.

local Assets = require("../render/assets")
local Axis = require("../render/axis")
local ChartView = require("../render/chart_view")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Grid = require("../render/grid")
local Json = require("./json")
local Reduce = require("./reduce")
local SvgTimeseries = require("../render/svg_timeseries")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

local M = {}

M.WIDTH = 960
M.HEIGHT = 300

local function legendCalcs(panel: any, env: Env): { string }
	local out: { string } = {}
	for _, c in Json.list(env, Json.path(env, panel, "options", "legend", "calcs")) do
		if type(c) == "string" then
			table.insert(out, c)
		end
	end
	return out
end

local function legendWhy(panel: any, env: Env): string?
	for _, c in legendCalcs(panel, env) do
		if not Reduce.supports(c) then
			return string.format("legend reducer %s is not supported", c)
		end
	end
	return nil
end

-- gradientMode hue (a hue shift along the fill) and scheme (line and fill
-- colored by value along the color scheme; drawn plainly with a fixed
-- color, UPlotSeriesBuilder getLineColor/getFill) need colors the
-- class-only SVG cannot express.
local function gradientWhy(mode: string?, fixedColor: boolean): string?
	if mode == "hue" then
		return "custom.gradientMode hue (a hue-shifted fill) is not drawn natively"
	elseif mode == "scheme" and not fixedColor then
		return "custom.gradientMode scheme (series colored by value) is not drawn natively"
	end
	return nil
end

function M.unsupported(panel: any, env: Env): string?
	local defaults = Json.obj(env, Json.path(env, panel, "fieldConfig", "defaults"))
	local fixed = Json.str(env, Json.path(env, defaults.color, "mode")) == "fixed"
	local why = gradientWhy(Json.str(env, Json.path(env, defaults.custom, "gradientMode")), fixed)
	if why then
		return why
	end
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		for _, p in Json.list(env, Json.path(env, o, "properties")) do
			local id = Json.str(env, Json.path(env, p, "id"))
			if id == "custom.gradientMode" then
				why = gradientWhy(Json.str(env, Json.path(env, p, "value")), fixed)
			elseif id == "custom" then
				why = gradientWhy(Json.str(env, Json.path(env, p, "value", "gradientMode")), fixed)
			end
			if why then
				return "override " .. why
			end
		end
	end
	return legendWhy(panel, env)
end

-- For panels drawn on one y scale (lib/render/svg_xy: trend): per-series
-- stacking and per-series units have no second stack or axis there.
function M.singleAxisUnsupported(panel: any, env: Env): string?
	local defaultsUnit = Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "unit"))
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		for _, p in Json.list(env, Json.path(env, o, "properties")) do
			local id = Json.str(env, Json.path(env, p, "id"))
			local value = Json.path(env, p, "value")
			if id == "custom.stacking" then
				return "per-series stacking (custom.stacking override) is not supported"
			elseif id == "unit" and Json.str(env, value) ~= defaultsUnit then
				return "a per-series unit override (second y axis) is not supported"
			end
		end
	end
	return legendWhy(panel, env)
end

local THRESHOLD_STYLES: { [string]: SvgTimeseries.ThresholdStyle } = {
	line = "line",
	dashed = "line",
	area = "area",
	["line+area"] = "line+area",
	["dashed+area"] = "line+area",
}

type Drawn = { item: FieldConfig.Item, class: string }

local function swatch(class: string): Node
	return { k = "el", p = { tag = "span", class = "tg-swatch " .. class } }
end

local function legendView(
	key: string,
	drawn: { Drawn },
	calcs: { string },
	mode: string,
	dropped: number,
	opts: Common.Options,
	env: Env
): Node
	local rows: { { class: string, name: string, values: { string } } } = {}
	for _, d in drawn do
		local item = d.item
		if Json.bool(env, Json.path(env, item.config.custom.hideFrom, "legend")) == true then
			continue
		end
		local results = Reduce.calcs(item.field.values, calcs, item.field.type, item.config.null_mode)
		local values: { string } = {}
		for k, c in calcs do
			local v = results[c]
			values[k] = if v == nil
				then "-"
				else FieldConfig.joined(
					FieldConfig.display(item, v, { theme = opts.theme, offset_min = opts.offset_min })
				)
		end
		table.insert(rows, { class = d.class, name = item.name, values = values })
	end
	local children: { Node } = {}
	if mode == "table" then
		local columns: { Grid.Column } = { { head = "Name" } }
		for _, c in calcs do
			table.insert(columns, { head = Reduce.name(c), numeric = true })
		end
		local gridRows: { Grid.Row } = table.create(#rows)
		for i, r in rows do
			local cells: { Node } = {
				{ k = "row", p = { gap = "xs", align = "center" }, c = { swatch(r.class), Grid.text(r.name) } },
			}
			for _, v in r.values do
				table.insert(cells, Grid.text(v))
			end
			gridRows[i] = { key = "s" .. i, cells = cells }
		end
		table.insert(children, Grid.grid(key .. ".t", columns, gridRows, "tern-grafana.legend"))
	else
		local entries: { Node } = table.create(#rows)
		for i, r in rows do
			local spans: { ui.SpanLike } = { r.name }
			if #r.values > 0 then
				table.insert(spans, ui.span(" " .. table.concat(r.values, " "), "strong"))
			end
			entries[i] = {
				k = "row",
				p = { key = "s" .. i, gap = "xs", align = "center" },
				c = { swatch(r.class), ui.text(spans) },
			}
		end
		table.insert(children, {
			k = "row",
			p = { key = key .. ".l", gap = "md", wrap = true, role = "tern-grafana.legend" },
			c = entries,
		})
	end
	if dropped > 0 then
		table.insert(
			children,
			ui.muted(string.format("%d more series not shown (chart limit %d)", dropped, #drawn), { key = "dropped" })
		)
	end
	return { k = "col", p = { key = key, gap = "xs" }, c = children }
end

-- The SVG render options a panel maps to (exposed for specs and the
-- dashboard's PNG-vs-native decisions).
function M.renderOptions(panel: any, env: Env, opts: Common.Options): SvgTimeseries.Options
	local cfg = FieldConfig.defaults(panel, env, { color_mode = "palette-classic" })
	local custom = cfg.custom
	local draw: SvgTimeseries.Draw = "line"
	if custom.drawStyle == "bars" then
		draw = "bars"
	elseif custom.drawStyle == "points" then
		draw = "points"
	end
	local stackMode = Json.str(env, Json.path(env, custom.stacking, "mode"))
	local thresholdMode = Json.str(env, Json.path(env, custom.thresholdsStyle, "mode")) or "off"
	local style: SvgTimeseries.ThresholdStyle? = THRESHOLD_STYLES[thresholdMode]
	local thresholdStyle: SvgTimeseries.ThresholdStyle = style or "off"
	local fill = Json.num(env, custom.fillOpacity)
	return {
		width = opts.width or M.WIDTH,
		height = opts.height or M.HEIGHT,
		unit = cfg.unit,
		decimals = cfg.decimals,
		min = cfg.min,
		max = cfg.max,
		thresholds = if style then cfg.thresholds else nil,
		threshold_style = thresholdStyle,
		stack = if stackMode == "normal" or stackMode == "percent" then stackMode else "none",
		draw = draw,
		fill_opacity = fill or 0,
		null_mode = if custom.spanNulls == true then "connect" else "gap",
		from_ms = opts.from_ms,
		to_ms = opts.to_ms,
		offset_min = opts.offset_min,
	}
end

local PLACEMENTS: { [string]: SvgTimeseries.Placement } =
	{ auto = "auto", left = "left", right = "right", hidden = "hidden" }
local DISTRIBUTIONS: { [string]: Axis.Distr } = { linear = "linear", log = "log", symlog = "symlog" }
local DRAWS: { [string]: SvgTimeseries.Draw } = { line = "line", bars = "bars", points = "points" }
local INTERPOLATIONS: { [string]: SvgTimeseries.Interpolation } =
	{ linear = "linear", smooth = "smooth", stepBefore = "stepBefore", stepAfter = "stepAfter" }
local SHOW_POINTS: { [string]: SvgTimeseries.ShowPoints } = { auto = "auto", always = "always", never = "never" }

-- One series' resolved GraphFieldConfig as the renderer's scale, stacking,
-- transform and draw settings (TimeSeries/utils.ts preparePlotConfigBuilder
-- and UPlotSeriesBuilder.ts): drawStyle, lineWidth, lineStyle (dash/dot),
-- lineInterpolation, fillOpacity, gradientMode opacity, showPoints,
-- pointSize, spanNulls (true or a gap in ms) and the bar options.
function M.seriesStyle(item: FieldConfig.Item, env: Env): SvgTimeseries.SeriesStyle
	local cfg = item.config
	local custom = cfg.custom
	local stackMode = Json.str(env, Json.path(env, custom.stacking, "mode"))
	local style: SvgTimeseries.ThresholdStyle? =
		THRESHOLD_STYLES[Json.str(env, Json.path(env, custom.thresholdsStyle, "mode")) or "off"]
	local dist = Json.tbl(env, custom.scaleDistribution)
	local distType: Axis.Distr? = if dist then DISTRIBUTIONS[Json.str(env, dist.type) or ""] else nil
	local transform = Json.str(env, custom.transform)
	local label = Json.str(env, custom.axisLabel)
	local hideFrom = Json.obj(env, custom.hideFrom)
	-- lineStyle: anything but solid dashes ([10, 10] unless given); dot
	-- also rounds the caps.
	local lineStyle = Json.obj(env, custom.lineStyle)
	local lineFill = Json.str(env, lineStyle.fill) or "solid"
	local dash: { number }? = nil
	if lineFill ~= "solid" then
		local list: { number } = {}
		for _, d in Json.list(env, lineStyle.dash) do
			local n = Json.num(env, d)
			if n then
				table.insert(list, n)
			end
		end
		dash = if #list > 0 then list else { 10, 10 }
	end
	local span: (boolean | number)? = Json.bool(env, custom.spanNulls)
	if span == nil then
		span = Json.num(env, custom.spanNulls)
	end
	local gradient = Json.str(env, custom.gradientMode)
	return {
		unit = cfg.unit,
		decimals = cfg.decimals,
		min = cfg.min,
		max = cfg.max,
		soft_min = Json.num(env, custom.axisSoftMin),
		soft_max = Json.num(env, custom.axisSoftMax),
		centered_zero = Json.bool(env, custom.axisCenteredZero) == true,
		placement = PLACEMENTS[Json.str(env, custom.axisPlacement) or ""],
		label = if label ~= "" then label else nil,
		grid = Json.bool(env, custom.axisGridShow),
		distribution = if dist and distType
			then {
				type = distType,
				log = Json.num(env, dist.log),
				linear_threshold = Json.num(env, dist.linearThreshold),
			}
			else nil,
		transform = if transform == "negative-Y" or transform == "constant" then transform else nil,
		stack = if stackMode == "normal" or stackMode == "percent" then stackMode else "none",
		stack_group = Json.str(env, Json.path(env, custom.stacking, "group")),
		thresholds = if style then cfg.thresholds else nil,
		threshold_style = style or "off",
		hide_legend = Json.bool(env, hideFrom.legend) == true,
		hide_tooltip = Json.bool(env, hideFrom.tooltip) == true,
		draw = DRAWS[Json.str(env, custom.drawStyle) or ""] or "line",
		line_width = Json.num(env, custom.lineWidth),
		dash = dash,
		dot = lineFill == "dot",
		interpolation = INTERPOLATIONS[Json.str(env, custom.lineInterpolation) or ""],
		fill_opacity = Json.num(env, custom.fillOpacity) or 0,
		gradient = if gradient == "opacity" then "opacity" else "none",
		show_points = SHOW_POINTS[Json.str(env, custom.showPoints) or ""],
		point_size = Json.num(env, custom.pointSize),
		span_nulls = span or false,
		bar_alignment = Json.num(env, custom.barAlignment),
		bar_width_factor = Json.num(env, custom.barWidthFactor),
		bar_max_width = Json.num(env, custom.barMaxWidth),
	}
end

-- setClassicPaletteIdxs (public/app/plugins/panel/timeseries/utils.ts,
-- run by prepareGraphableFields): palette positions count, over the frames
-- with a time field and a number field, every number and boolean field but
-- each frame's first graphable field, hidden ones included. The classic
-- palette color is colors[seriesIndex % length] (fieldColor.ts).
function M.paletteIndexes(frames: { Frame }): { [Frame.Field]: number }
	local out: { [Frame.Field]: number } = {}
	local idx = 0
	for _, frame in frames do
		local hasTime, hasValue = false, false
		for _, f in frame.fields do
			hasTime = hasTime or f.type == "time"
			hasValue = hasValue or f.type == "number"
		end
		if not (hasTime and hasValue) then
			continue
		end
		local pos = 0
		for _, f in frame.fields do
			if f.type == "time" or f.type == "number" or f.type == "boolean" then
				pos += 1
				if pos > 1 and f.type ~= "time" then
					idx += 1
					out[f] = idx
				end
			end
		end
	end
	return out
end

-- custom.fillBelowTo names another series by field name, datasource
-- display name or display name (TimeSeries/utils.ts).
local function fillBelowIndex(name: string, visible: { FieldConfig.Item }): number?
	for j, other in visible do
		local f = other.field
		if name == f.name or name == other.name or (f.config ~= nil and f.config.displayName == name) then
			return j
		end
	end
	return nil
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets)
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "palette-classic" })
	local render = M.renderOptions(panel, env, opts)
	-- Frames with their time field and the visible number fields, baked.
	local baked: { Frame } = {}
	local visible: { FieldConfig.Item } = {}
	local byFrame: { [Frame]: Frame } = {}
	for _, item in items do
		local tf = Frame.timeField(item.frame)
		if tf == nil or item.field.type ~= "number" or FieldConfig.hidden(item) then
			continue
		end
		local out = byFrame[item.frame]
		if out == nil then
			out = { name = item.frame.name, refId = item.frame.refId, meta = item.frame.meta, fields = { tf } }
			byFrame[item.frame] = out
			table.insert(baked, out :: Frame)
		end
		table.insert((out :: Frame).fields, FieldConfig.bake(item))
		table.insert(visible, item)
	end
	if #visible == 0 then
		-- TimeSeriesPanel without graphable fields: PanelDataErrorView.
		if not Common.hasData(frames) then
			return Common.noData(panel, env, opts.key), {}
		end
		local hasNumber, hasTime = false, false
		for _, f in frames do
			for _, field in f.fields do
				hasNumber = hasNumber or field.type == "number"
				hasTime = hasTime or field.type == "time"
			end
		end
		local why = if not hasNumber
			then "Data is missing a number field"
			elseif not hasTime then "Data is missing a time field"
			else "Cannot visualize data"
		return ui.muted(why, { key = opts.key }), {}
	end
	if opts.exemplars and #opts.exemplars > 0 then
		render.exemplars = opts.exemplars
	end
	local palette = M.paletteIndexes(frames)
	local styles: { SvgTimeseries.SeriesStyle } = table.create(#visible)
	for i, item in visible do
		item.series_index = palette[item.field] or item.series_index
		local st = M.seriesStyle(item, env)
		local color = FieldConfig.seriesColor(item, { theme = opts.theme })
		st.class = color.class
			or (FieldConfig.paletteClass(item.series_index) .. " tgp-fx " .. Common.toneClass(color.tone))
		local below = Json.str(env, item.config.custom.fillBelowTo)
		if below and below ~= "" then
			st.fill_below = fillBelowIndex(below, visible)
			if st.fill_below == nil then
				-- No such series: Grafana drops the fill.
				st.fill_opacity = 0
			end
		end
		styles[i] = st
	end
	render.series = styles
	local result = SvgTimeseries.render(baked, render)
	local drawn: { Drawn } = {}
	for i, s in result.layout.series do
		drawn[i] = { item = visible[i], class = s.class }
	end
	local legendOpts = Json.obj(env, Json.path(env, panel, "options", "legend"))
	local mode = Json.str(env, legendOpts.displayMode) or "list"
	local showLegend = Json.bool(env, legendOpts.showLegend) ~= false and mode ~= "hidden"
	local title = Json.str(env, Json.path(env, panel, "title"))
	local chart, assets = ChartView.view(result, {
		key = opts.key,
		alt = if title and title ~= "" then title else "Time series chart",
		cursor = opts.cursor,
		exemplar = opts.exemplar,
		show_legend = showLegend and opts.cursor ~= nil,
		legend = { mode = if mode == "table" then "table" else "list", offset_min = opts.offset_min },
	})
	if not showLegend or opts.cursor ~= nil then
		return chart, assets
	end
	local legend = legendView(opts.key .. ".legend", drawn, legendCalcs(panel, env), mode, result.dropped, opts, env)
	return { k = "col", p = { key = opts.key .. ".panel", gap = "xs" }, c = { chart, legend } }, assets
end

return M
