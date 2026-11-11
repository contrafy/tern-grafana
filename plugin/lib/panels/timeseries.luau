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
-- - custom.drawStyle line|bars|points, fillOpacity, insertNulls (a gap
--   longer than it, else than the time field's interval, gets nulls: the
--   line breaks), spanNulls (true connects; false or a gap threshold keeps
--   gaps), stacking.mode
--   none|normal|percent and stacking.group per series (stacks per scale),
--   custom.transform negative-Y|constant, thresholdsStyle.mode (off, line,
--   dashed, area, line+area, dashed+area; "series" colors by value, drawn
--   as off);
-- - overrides (lib/panels/fieldconfig) for display names, colors and
--   hidden series (custom.hideFrom.viz, .legend, .tooltip);
-- - series colors: palette-classic keeps the chart palette; a fixed color
--   and a continuous scheme paint the series (and its swatch) in Grafana's
--   color at the series' `seriesBy` value, thresholds in its step's tone
--   (getFieldSeriesColor); gradientMode hue and scheme paint line and fill
--   through a gradient (lib/render/ts_gradient);
-- - options.legend: showLegend, displayMode list|table|hidden, placement
--   bottom|right, calcs (any lib/panels/reduce reducer, formatted with the
--   series' own config);
-- - exemplars (opts.exemplars) as markers, the selected one (opts.exemplar)
--   read out under the legend;
-- - dashboard annotations (opts.annotations) as dashed lines, regions and
--   markers, styled by the panel's options.annotations.

local Assets = require("../render/assets")
local Axis = require("../render/axis")
local ChartView = require("../render/chart_view")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Legend = require("../render/legend")
local Json = require("./json")
local Reduce = require("./reduce")
local SvgAnnotations = require("../render/svg_annotations")
local SvgTimeseries = require("../render/svg_timeseries")
local Tbl = require("../tbl")
local TsData = require("../render/ts_data")
local TsGradient = require("../render/ts_gradient")
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

function M.unsupported(panel: any, env: Env): string?
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

local function legendView(
	key: string,
	drawn: { Drawn },
	calcs: { string },
	mode: string,
	dropped: number,
	opts: Common.Options,
	env: Env
): Node
	local rows: { Legend.Row } = {}
	local disp = { theme = opts.theme, offset_min = opts.offset_min }
	for _, d in drawn do
		local item = d.item
		if Json.bool(env, Json.path(env, item.config.custom.hideFrom, "legend")) == true then
			continue
		end
		local results = Reduce.calcs(item.field.values, calcs, item.field.type, item.config.null_mode)
		local values: { string } = {}
		for k, c in calcs do
			local v = results[c]
			values[k] = if v == nil then "-" else FieldConfig.joined(FieldConfig.display(item, v, disp))
		end
		table.insert(rows, { class = d.class, name = item.name, values = values })
	end
	local children: { Node } = {}
	local heads = Charts.calcHeads(calcs)
	if mode == "table" then
		table.insert(children, Legend.rowsNode(key .. ".t", rows, heads, "table"))
	else
		table.insert(children, Legend.rowsNode(key .. ".l", rows, heads, "list"))
	end
	if dropped > 0 then
		table.insert(
			children,
			ui.muted(string.format("%d more series not shown (chart size limit)", dropped), { key = "dropped" })
		)
	end
	return { k = "col", p = { key = key, gap = "xs" }, c = children }
end

-- Grafana's px around a time series plot: PanelChrome's 1 px border, the
-- 32 px header of a titled panel and 8 px padding; VizLayout's bottom
-- legend (list lines 23 px apart plus 7, a table's 26 px head and 23 px
-- rows) at most 35% of the viz; the x axis (tick 4 + gap 5 + 12 px font)
-- and uPlot's top padding (a third of its 50 px default axis size).
-- Measured on Grafana 12.4 renders: a titled 7-row panel with a one-line
-- legend plots 140 px.
M.GRAFANA_PX = table.freeze({
	border = 1,
	header = 32,
	padding = 8,
	legend_line = 23,
	legend_pad = 7,
	table_head = 26,
	table_row = 23,
	x_axis = 21,
	top = 17,
})

-- The plot height Grafana gives a time series panel of w x h px whose
-- legend shows `rows` (the y tick density follows it).
function M.grafanaPlotHeight(w: number, h: number, titled: boolean, rows: { Legend.Row }, legend: Charts.Legend): number
	local g = M.GRAFANA_PX
	local viz = h - 2 * g.border - (if titled then g.header else 0) - 2 * g.padding
	local legendPx = 0
	if legend.show and #rows > 0 and legend.placement == "bottom" then
		if legend.mode == "table" then
			legendPx = g.table_head + #rows * g.table_row
		else
			local width = w - 2 * g.border - 2 * g.padding
			local px = Legend.height(rows, "list", width, Charts.calcHeads(legend.calcs))
			local lines = math.floor((px + Legend.LINE_GAP_PX) / (Legend.LINE_PX + Legend.LINE_GAP_PX) + 0.5)
			legendPx = lines * g.legend_line + g.legend_pad
		end
		legendPx = math.min(legendPx, viz * Charts.LEGEND_MAX)
	end
	return math.max(viz - legendPx - g.x_axis - g.top, 1)
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
	-- Grafana's panel width and, in a height-capped card, the card body.
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	return {
		width = W,
		height = H,
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
local GRADIENTS: { [string]: SvgTimeseries.Gradient } = { opacity = "opacity", hue = "hue", scheme = "scheme" }

-- One series' resolved GraphFieldConfig as the renderer's scale, stacking,
-- transform and draw settings (TimeSeries/utils.ts preparePlotConfigBuilder
-- and UPlotSeriesBuilder.ts): drawStyle, lineWidth, lineStyle (dash/dot),
-- lineInterpolation, fillOpacity, gradientMode (hue and scheme get their
-- stops in M.view), showPoints, pointSize, spanNulls (true or a gap in ms)
-- and the bar options.
function M.seriesStyle(item: FieldConfig.Item, env: Env): SvgTimeseries.SeriesStyle
	local cfg = item.config
	local custom = cfg.custom
	local stackMode = Json.str(env, Json.path(env, custom.stacking, "mode"))
	-- getStackingGroups keys the group by its template string: an override
	-- {group: false} stacks the series alone, in group "false".
	local rawGroup = Json.path(env, custom.stacking, "group")
	local stackGroup = if type(rawGroup) == "string"
		then rawGroup
		elseif type(rawGroup) == "boolean" or type(rawGroup) == "number" then tostring(rawGroup)
		else nil
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
	local gradient: SvgTimeseries.Gradient = GRADIENTS[Json.str(env, custom.gradientMode) or ""] or "none"
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
		stack_group = stackGroup,
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
		gradient = gradient,
		show_points = SHOW_POINTS[Json.str(env, custom.showPoints) or ""],
		point_size = Json.num(env, custom.pointSize),
		span_nulls = span or false,
		bar_alignment = Json.num(env, custom.barAlignment),
		bar_width_factor = Json.num(env, custom.barWidthFactor),
		bar_max_width = Json.num(env, custom.barMaxWidth),
	}
end

-- The class a series and its legend swatch are painted with
-- (getFieldSeriesColor): the palette class; a fixed color (or shades) and
-- a continuous scheme's color at the series' `seriesBy` value as the
-- nearest Grafana color class; thresholds in their step's tone, as
-- threshold lines and areas are drawn.
local function seriesClass(item: FieldConfig.Item, color: FieldConfig.Scale, opts: Common.Options): string
	local mode = item.config.color_mode
	if mode == "fixed" or mode == "shades" then
		return TsGradient.fixedClass(item.config.fixed_color or "", opts.theme)
	elseif string.sub(mode, 1, 11) == "continuous-" then
		local c = TsGradient.schemeColor(mode, color.percent, opts.theme)
		if c then
			return TsGradient.stopClass(c, opts.theme)
		end
	end
	return color.class or (FieldConfig.paletteClass(item.series_index) .. " tgp-fx " .. Common.toneClass(color.tone))
end

-- gradientMode hue and scheme stops for one series (UPlotSeriesBuilder
-- getLineColor/getFill). Hue shifts the series color; scheme runs through
-- the color mode's thresholds or scheme colors, and with a fixed color (or
-- shades, or another palette) draws plainly.
local function gradientStops(
	st: SvgTimeseries.SeriesStyle,
	item: FieldConfig.Item,
	color: FieldConfig.Scale,
	opts: Common.Options
)
	local cfg = item.config
	local mode = cfg.color_mode
	if st.gradient == "hue" then
		local base: string
		if mode == "palette-classic" or mode == "palette-classic-by-name" then
			base = TsGradient.paletteHex(item.series_index)
		elseif mode == "fixed" or mode == "shades" then
			base = cfg.fixed_color or ""
		else
			base = TsGradient.schemeColor(mode, color.percent, opts.theme) or color.color
		end
		st.hue = TsGradient.hue(base, opts.theme)
	elseif st.gradient == "scheme" then
		st.scheme = TsGradient.scheme(mode, cfg.thresholds, opts.theme)
	end
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

-- applyNullInsertThreshold's threshold for one frame: each field's
-- custom.insertNulls (ms; 0, false or absent fall back), else the time
-- field's interval (the datasource's step). Grafana inserts only when every
-- field agrees (an override on some fields of a frame inserts nothing) and
-- the threshold is positive. `true`, which the editor never writes, falls
-- back to the interval too.
local function nullThreshold(fields: { FieldConfig.Item }, interval: number?, env: Env): number?
	local threshold: number? = nil
	for _, item in fields do
		local own = Json.num(env, item.config.custom.insertNulls)
		local t = if own and own ~= 0 and own == own then own else interval
		if t == nil then
			continue
		elseif threshold ~= nil and threshold ~= t then
			return nil
		end
		threshold = t
	end
	return if threshold and threshold > 0 then threshold else nil
end

-- Inserted nulls by time column: a cursor move redraws with the same
-- frames, and the render memo compares value columns by identity. `times`
-- is nil when nothing was inserted: the entry must not hold its own key,
-- since a weak-keyed table is no ephemeron and would keep it alive.
type Nulled = {
	threshold: number,
	from: number?,
	to: number?,
	columns: { { any } },
	times: { number }?,
	filled: { { any } },
}
local nulled: { [{ number }]: Nulled } = setmetatable({} :: any, { __mode = "k" })

local function insertNulls(frame: Frame, threshold: number, from: number?, to: number?)
	local fields = frame.fields
	local times = fields[1].values :: { number }
	local columns: { { any } } = table.create(#fields - 1)
	for i = 2, #fields do
		columns[i - 1] = fields[i].values
	end
	local hit = nulled[times]
	local fresh = hit ~= nil and hit.threshold == threshold and hit.from == from and hit.to == to
	if hit and fresh then
		for i, c in columns do
			if hit.columns[i] ~= c then
				fresh = false
				break
			end
		end
	end
	if hit == nil or not fresh then
		local t, filled = TsData.insertNulls(times, columns, threshold, from, to)
		hit = {
			threshold = threshold,
			from = from,
			to = to,
			columns = columns,
			times = if t == times then nil else t,
			filled = filled,
		}
		nulled[times] = hit
	end
	local h = hit :: Nulled
	local inserted = h.times
	if inserted == nil then
		return
	end
	for i, f in fields do
		local copy = Tbl.copy(f)
		copy.values = if i == 1 then inserted else h.filled[i - 1]
		fields[i] = copy
	end
end

-- The last renders by panel key. A cursor move in an expanded panel redraws
-- the same chart with only the overlay changed; SvgTimeseries.render is a
-- pure function of (frames, options), so equal arguments reuse its result.
-- Value columns compare by identity (frames are never mutated), everything
-- else structurally. A handful of keys: one expanded panel is the case.
type RenderMemo = { baked: { Frame }, render: SvgTimeseries.Options, result: SvgTimeseries.Result }

local renders: { [string]: RenderMemo } = {}
local renderCount = 0
local RENDER_MEMO_MAX = 4
local BY_IDENTITY: { [any]: boolean } = { values = true, exemplars = true }

local function same(a: any, b: any, key: any): boolean
	if a == b then
		return true
	elseif type(a) ~= "table" or type(b) ~= "table" or BY_IDENTITY[key] then
		return false
	end
	for k, v in a do
		if not same(v, b[k], k) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function renderMemo(key: string, baked: { Frame }, render: SvgTimeseries.Options): SvgTimeseries.Result
	local hit = renders[key]
	if hit and same(hit.render, render, nil) and same(hit.baked, baked, nil) then
		return hit.result
	end
	local result = SvgTimeseries.render(baked, render)
	if hit == nil then
		if renderCount >= RENDER_MEMO_MAX then
			table.clear(renders)
			renderCount = 0
		end
		renderCount += 1
	end
	renders[key] = { baked = baked, render = render, result = result }
	return result
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets)
	-- preparePlotFrame joins on time, which sorts a frame whose times run
	-- backwards (a newest-first table from Grafana Incident).
	local sorted: { Frame } = table.create(#frames)
	for i, f in frames do
		sorted[i] = Charts.sortByTime(f)
	end
	frames = sorted
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "palette-classic" })
	local render = M.renderOptions(panel, env, opts)
	-- Frames with their time field and the visible number fields, baked.
	local baked: { Frame } = {}
	local visible: { FieldConfig.Item } = {}
	local byFrame: { [Frame]: Frame } = {}
	local frameItems: { [Frame]: { FieldConfig.Item } } = {}
	for _, item in items do
		local list = frameItems[item.frame]
		if list == nil then
			list = {}
			frameItems[item.frame] = list
		end
		table.insert(list :: { FieldConfig.Item }, item)
	end
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
	for src, out in byFrame do
		local tf = out.fields[1]
		local threshold = nullThreshold(frameItems[src], if tf.config then tf.config.interval else nil, env)
		if threshold then
			insertNulls(out, threshold, opts.from_ms, opts.to_ms)
		end
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
	if opts.annotations and #opts.annotations > 0 then
		render.annotations = SvgAnnotations.layer(opts.annotations, Json.path(env, panel, "options", "annotations"))
	end
	local palette = M.paletteIndexes(frames)
	local styles: { SvgTimeseries.SeriesStyle } = table.create(#visible)
	for i, item in visible do
		item.series_index = palette[item.field] or item.series_index
		local st = M.seriesStyle(item, env)
		local color = FieldConfig.seriesColor(item, { theme = opts.theme })
		st.class = seriesClass(item, color, opts)
		gradientStops(st, item, color, opts)
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
	-- In a height-capped card the chart leaves a bottom legend room; calc
	-- values are estimated at 7 characters.
	local legendLook = Charts.legendOptions(panel, env)
	local legendRows: { Legend.Row } = {}
	if legendLook.show then
		local guess = table.create(#legendLook.calcs, "0000.00")
		for _, item in visible do
			if not Charts.hiddenFromLegend(item) then
				table.insert(legendRows, { class = "", name = item.name, values = guess })
			end
		end
	end
	local rh, rw = render.height, render.width
	assert(rh and rw, "timeseries: render size unset")
	if opts.card_height and legendLook.show then
		render.height = Charts.chartHeight(opts, rh, rw, legendRows, legendLook)
	end
	-- The x axis follows the time field's own config (TimeSeries/utils.ts
	-- xField axisPlacement): defaults hiding every axis hide it too.
	for _, item in items do
		if item.field.type == "time" then
			render.x_axis_hidden = Json.str(env, item.config.custom.axisPlacement) == "hidden"
			break
		end
	end
	if opts.size then
		local titled = (Json.str(env, Json.path(env, panel, "title")) or "") ~= ""
		render.tick_height = M.grafanaPlotHeight(opts.size.w, opts.size.h, titled, legendRows, legendLook)
			+ (if render.x_axis_hidden then M.GRAFANA_PX.x_axis else 0)
	end
	local result = renderMemo(opts.key, baked, render)
	local drawn: { Drawn } = {}
	for i, s in result.layout.series do
		drawn[i] = { item = visible[i], class = s.class }
	end
	local legendOpts = Json.obj(env, Json.path(env, panel, "options", "legend"))
	local mode = Json.str(env, legendOpts.displayMode) or "list"
	-- TimeSeries.renderLegend: no legend unless a drawn series shows in it
	-- (hasVisibleLegendSeries), as when hideZero/hideEmpty hide them all.
	local legendSeries = false
	for _, d in drawn do
		if not Charts.hiddenFromLegend(d.item) then
			legendSeries = true
			break
		end
	end
	local showLegend = Json.bool(env, legendOpts.showLegend) ~= false and mode ~= "hidden" and legendSeries
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
	if legendLook.placement == "right" then
		-- VizLayout: the legend beside the plot, from its top.
		return { k = "row", p = { key = opts.key .. ".panel", gap = "sm", align = "start" }, c = { chart, legend } },
			assets
	end
	if opts.card_height then
		local cap = Legend.capClass(
			legendRows,
			legendLook.mode,
			rw,
			math.floor(rh * Charts.LEGEND_MAX) - Charts.LEGEND_GAP_PX,
			Charts.calcHeads(legendLook.calcs)
		)
		if cap then
			legend = { k = "el", p = { tag = "div", key = opts.key .. ".lgcap", class = cap }, c = { legend } }
		end
	end
	return { k = "col", p = { key = opts.key .. ".panel", gap = "xs" }, c = { chart, legend } }, assets
end

return M
