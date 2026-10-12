--!strict
-- The bar chart panel (public/app/plugins/panel/barchart: utils.ts
-- prepSeries/prepConfig, bars.ts, BarChartPanel.tsx, panelcfg.cue) drawn by
-- lib/render/svg_bars:
-- - data: the first frame, or all frames outer-joined on time when they
--   have a time field; x is options.xField (display or field name), else
--   the first string field, else the time field; every other number field
--   not hidden from the viz is a bar series;
-- - orientation auto (horizontal when the panel is taller than wide),
--   horizontal, vertical; stacking none|normal|percent; groupWidth,
--   barWidth (a single series uses barWidth as its group width; stacking
--   swaps them, bars.ts);
-- - showValue auto|always|never with text.valueSize; xTickLabelRotation,
--   xTickLabelMaxLength (auto when rotated: half the height over the
--   rotation), xTickLabelSpacing;
-- - colors: palette-classic per series (re-indexed over the bars), fixed
--   as tones, by-value modes (thresholds, continuous) per bar, and
--   colorByField: each bar in the color field's color for its row;
-- - fieldConfig unit, decimals, min, max, mappings (value labels),
--   custom.fillOpacity, lineWidth, thresholdsStyle, axisPlacement hidden,
--   axisGridShow; legend with calcs.
-- Grafana's warnings show in place of the chart ("Bar charts require a
-- string or time field", "No numeric fields found").

local Assets = require("../render/assets")
local Axis = require("../render/axis")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local SvgBars = require("../render/svg_bars")
local SvgKit = require("../render/svg_kit")
local Tbl = require("../tbl")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

M.types = { "barchart" }

M.WIDTH = 960
M.HEIGHT = 300

function M.supports(panel: any, env: Env): (boolean, string?)
	local why = Charts.unsupportedLegend(panel, env)
	if why then
		return false, why
	end
	return true, nil
end

export type Prepared = {
	x: Item,
	series: { Item },
	color: Item?,
	-- Number fields hidden from the viz count toward Grafana's totalSeries.
	total: number,
	items: { Item },
}

-- prepSeries: the x field, the bar series and the color field, or Grafana's
-- warning.
function M.prepare(panel: any, frames: { Frame }, env: Env): (Prepared?, string?)
	if not Common.hasData(frames) then
		return nil, nil
	end
	local frame = frames[1]
	if Frame.timeField(frame) and #frames > 1 then
		frame = Charts.joinByTime(frames)
	end
	local items = FieldConfig.resolve(panel, { frame }, env, { color_mode = "palette-classic" })
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local x = Charts.findItem(items, Json.str(env, options.xField))
	if x == nil then
		for _, item in items do
			if item.field.type == "string" then
				x = item
				break
			end
		end
	end
	if x == nil then
		for _, item in items do
			if item.field.type == "time" then
				x = item
				break
			end
		end
	end
	if x == nil then
		return nil, "Bar charts require a string or time field"
	end
	local color = Charts.findItem(items, Json.str(env, options.colorByField))
	local series: { Item } = {}
	local total = 0
	for _, item in items do
		if item == x or item.field.type ~= "number" then
			continue
		end
		total += 1
		local hideFrom = item.config.custom.hideFrom
		if not (type(hideFrom) == "table" and hideFrom.viz == true) then
			table.insert(series, item)
		end
	end
	if #series == 0 then
		return nil, "No numeric fields found"
	end
	return { x = x :: Item, series = series, color = color, total = total, items = items }, nil
end

-- Category labels: strings as they are, times in Grafana's auto format for
-- their spacing, anything else through the field's display processor.
local function categories(x: Item, opts: Common.Options): { string }
	local values = x.field.values
	local out: { string } = table.create(#values)
	if x.field.type == "time" and not (x.config.unit and string.sub(x.config.unit :: string, 1, 5) == "time:") then
		local step, lo, hi = math.huge, math.huge, -math.huge
		for i, t in values do
			if type(t) == "number" then
				lo, hi = math.min(lo, t), math.max(hi, t)
				local prev = values[i - 1]
				if type(prev) == "number" and t ~= prev then
					step = math.min(step, math.abs(t - prev))
				end
			end
		end
		local format = Axis.timeFormat(if step == math.huge then 1000 else step, math.max(hi - lo, 1))
		for i, t in values do
			out[i] = if type(t) == "number" then Axis.formatTime(t, format, opts.offset_min) else ""
		end
		return out
	end
	for i, v in values do
		if type(v) == "string" then
			out[i] = v
		elseif Frame.isNull(v) then
			out[i] = ""
		else
			out[i] = FieldConfig.joined(FieldConfig.display(x, v, { theme = opts.theme, offset_min = opts.offset_min }))
		end
	end
	return out
end

-- The renderer options a panel maps to (exposed for specs).
function M.renderOptions(panel: any, prep: Prepared, env: Env, opts: Common.Options): (SvgBars.Options, { string })
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local orientation = Json.str(env, options.orientation) or "auto"
	local horizontal = if orientation == "auto" then W < H else orientation == "horizontal"
	local stacking = Json.str(env, options.stacking) or "none"
	if stacking ~= "normal" and stacking ~= "percent" then
		stacking = "none"
	end
	local groupWidth = Json.num(env, options.groupWidth) or 0.7
	local barWidth = Json.num(env, options.barWidth) or 0.97
	if #prep.series == 1 and stacking == "none" then
		if prep.total == 1 then
			groupWidth = barWidth
		end
		barWidth = 1
	end
	if stacking ~= "none" then
		groupWidth, barWidth = barWidth, groupWidth
	end
	local rotation = Json.num(env, options.xTickLabelRotation) or 0
	local maxLen = Json.num(env, options.xTickLabelMaxLength)
	if rotation == 0 then
		maxLen = nil
	elseif maxLen == nil or maxLen <= 0 then
		maxLen = math.floor(H / 2 / math.sin(math.abs(math.rad(rotation))) / SvgKit.CHAR_PX - 3)
	end
	local first = prep.series[1]
	local cfg = first.config
	local custom = cfg.custom
	local thresholdMode = Json.str(env, Json.path(env, custom.thresholdsStyle, "mode"))
	local display = { theme = opts.theme, offset_min = opts.offset_min }
	local percentItems: { [number]: Item } = {}
	local series: { SvgBars.Series } = table.create(#prep.series)
	local notes: { string } = {}
	for k, item in prep.series do
		local s: SvgBars.Series = { class = Charts.seriesClass(item, k, opts), values = item.field.values }
		if prep.color then
			local colorItem = prep.color :: Item
			local classes: { string? } = table.create(#item.field.values)
			for r = 1, #item.field.values do
				local v = colorItem.field.values[r]
				classes[r] = if Frame.isNull(v)
					then nil
					else Charts.displayClass(FieldConfig.display(colorItem, v, display))
			end
			s.classes = classes
		elseif Charts.byValue(item) then
			local classes: { string? } = table.create(#item.field.values)
			for r, v in item.field.values do
				classes[r] = if Frame.finite(v) then Charts.displayClass(FieldConfig.display(item, v, display)) else nil
			end
			s.classes = classes
		end
		series[k] = s
	end
	local function format(si: number, v: number): string
		local item = prep.series[si]
		if stacking == "percent" then
			local p = percentItems[si]
			if p == nil then
				p = Tbl.copy(item)
				local c = Tbl.copy(item.config)
				c.unit = "percentunit"
				p.config = c
				percentItems[si] = p
			end
			item = p :: Item
		end
		return FieldConfig.joined(FieldConfig.display(item, v, display))
	end
	local textSize = Json.num(env, Json.path(env, options, "text", "valueSize"))
	local fill = Json.num(env, custom.fillOpacity)
	local lineWidth = Json.num(env, custom.lineWidth)
	local showValue = Json.str(env, options.showValue) or "auto"
	return {
		width = W,
		height = H,
		horizontal = horizontal,
		categories = categories(prep.x, opts),
		series = series,
		stacking = stacking :: SvgBars.Stacking,
		group_width = groupWidth,
		bar_width = barWidth,
		fill_opacity = (fill or 80) / 100,
		line_width = lineWidth or 1,
		show_value = if showValue == "always" or showValue == "never" then showValue else "auto",
		value_size = textSize,
		format = format,
		unit = cfg.unit,
		decimals = cfg.decimals,
		min = cfg.min,
		max = cfg.max,
		thresholds = cfg.thresholds,
		threshold_style = SvgKit.thresholdStyle(thresholdMode),
		label_rotation = rotation,
		label_max = maxLen,
		label_spacing = Json.num(env, options.xTickLabelSpacing),
		value_axis = Json.str(env, custom.axisPlacement) ~= "hidden",
		grid = Json.bool(env, custom.axisGridShow) ~= false,
	},
		notes
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local prep, warn = M.prepare(panel, frames, env)
	if prep == nil then
		if warn then
			return Charts.message(opts.key, warn), {}
		end
		return Common.noData(panel, env, opts.key), {}
	end
	local p = prep :: Prepared
	local render, notes = M.renderOptions(panel, p, env, opts)
	local result = SvgBars.render(render)
	if result.dropped > 0 then
		table.insert(notes, string.format("%d more categories not shown (chart size limit)", result.dropped))
	end
	local chart, assets = Charts.image(
		opts.key,
		result.svg,
		render.width,
		render.height,
		Charts.alt(panel, env, "Bar chart"),
		"tern-grafana.barchart"
	)
	local legend = Charts.legendOptions(panel, env)
	local legendNode: Node? = nil
	if legend.show then
		local rows: { Charts.Row } = {}
		for k, item in p.series do
			if not Charts.hiddenFromLegend(item) then
				table.insert(rows, Charts.calcRow(item, render.series[k].class, legend.calcs, opts))
			end
		end
		legendNode = Charts.calcLegend(opts.key .. ".legend", rows, legend)
	end
	return Charts.compose(opts.key, chart, legendNode, legend.placement, notes), assets
end

return M
