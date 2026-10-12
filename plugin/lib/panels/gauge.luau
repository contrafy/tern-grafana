--!strict
-- Gauge and bar gauge panels (public/app/plugins/panel/gauge,
-- public/app/plugins/panel/bargauge; packages/grafana-ui/src/components/
-- Gauge, RadialGauge, BarGauge).
--
-- Gauge: one SVG radial gauge (lib/render/svg_gauge) per field display
-- value (lib/panels/values), laid out like VizRepeater's autoGrid. Grafana
-- 12 with the newGauge feature toggle draws gauge/v2 (RadialGauge: shape,
-- barWidthFactor, barShape, segmentCount/Spacing, neutral, sparkline,
-- effects.gradient, endpointMarker, textMode, text sizes); otherwise
-- gauge/v1 (the flot gauge). Both scale the value over the field's
-- min..max, put threshold markers in an outer ring and threshold labels at
-- min, each step and max (getFormattedThresholds).
--
-- Bar gauge: Tern `meter` nodes. Each value becomes one meter whose fill is
-- the value's percent of the field range in its threshold tone:
-- displayMode basic and gradient fill in the value's tone (a gradient ends
-- in that color); lcd is Tern's block grid with each threshold band's
-- cells in the band's tone; valueMode color|text|hidden and namePlacement
-- hidden decide the label and title. Tern meters take only two threshold
-- levels, so tones are explicit. `meters` also describes gauges as rings
-- (ring marks at the steps), for read-outs that want numbers.

local Assets = require("../render/assets")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local SvgGauge = require("../render/svg_gauge")
local Thresholds = require("../units/thresholds")
local Values = require("./values")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

export type Mark = { at: number, tone: string, title: string }
export type Part = { value: number, token: string }

export type Meter = {
	title: string?,
	label: string?,
	value: number,
	tone: string,
	marks: { Mark }?,
	parts: { Part }?,
	-- Formatted threshold step values (gauge showThresholdLabels).
	threshold_labels: { string }?,
	-- The label's color: the value's tone, or none (bar gauge valueMode text).
	label_tone: string?,
}

local M = {}

-- A threshold step's position on the field's 0..1 scale.
local function stepAt(item: FieldConfig.Item, value: number): number?
	local t = item.config.thresholds
	if t.mode == "percentage" then
		return value / 100
	end
	local lo, hi = item.range_min or 0, item.range_max or 100
	if hi <= lo then
		return nil
	end
	return (value - lo) / (hi - lo)
end

local function steps(item: FieldConfig.Item): { { at: number, value: number, name: string } }
	local out = {}
	for _, s in item.config.thresholds.steps do
		if type(s.value) == "number" then
			local at = stepAt(item, s.value)
			if at and at > 0 and at < 1 then
				table.insert(out, { at = at, value = s.value, name = s.color })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.at < b.at
	end)
	return out
end

local function clamp01(x: number): number
	return if x ~= x then 0 else math.clamp(x, 0, 1)
end

-- LCD cells from 0 up to `fill`, each run in its threshold band's tone; the
-- run holding the value takes the value's own tone, so a value sitting
-- exactly on a step reads in that step's color as in Grafana.
local function bandParts(item: FieldConfig.Item, fill: number, valueTone: Thresholds.Tone): { Part }
	local parts: { Part } = {}
	local name = Thresholds.active(nil, item.config.thresholds).name
	local from = 0
	for _, e in steps(item) do
		if e.at >= fill then
			break
		end
		if e.at > from then
			table.insert(parts, { value = e.at - from, token = Common.token(Thresholds.tone(name)) })
		end
		from = e.at
		name = e.name
	end
	if fill > from then
		table.insert(parts, { value = fill - from, token = "" })
	end
	if #parts > 0 then
		parts[#parts].token = Common.token(valueTone)
	end
	for _, p in parts do
		if p.token == "" then
			p.token = "muted"
		end
	end
	return parts
end

function M.meters(panel: any, frames: { Frame }, env: Env, opts: Common.Options, bar: boolean): { Meter }
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "thresholds" })
	local values = Values.values(panel, items, env, { theme = opts.theme, offset_min = opts.offset_min })
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local displayMode = Json.str(env, options.displayMode) or "gradient"
	local valueMode = Json.str(env, options.valueMode) or "color"
	local namePlacement = Json.str(env, options.namePlacement) or "auto"
	local showMarkers = Json.bool(env, options.showThresholdMarkers) ~= false
	local showLabels = Json.bool(env, options.showThresholdLabels) == true
	local out: { Meter } = {}
	for _, v in values do
		local d = v.display
		local fill = clamp01(d.percent)
		local meter: Meter = {
			-- The no-values placeholder has no display title (BarGauge shows none).
			title = if (bar and namePlacement == "hidden") or v.placeholder then nil else v.title,
			label = FieldConfig.joined(d),
			value = fill,
			tone = d.tone,
			label_tone = if bar and valueMode == "text" then nil else d.tone,
		}
		if bar and valueMode == "hidden" then
			meter.label = nil
		end
		local item = v.item
		if item and item.config.color_mode == "thresholds" then
			if bar and displayMode == "lcd" then
				meter.parts = bandParts(item, fill, d.tone)
			elseif not bar and showMarkers then
				local marks: { Mark } = {}
				for _, e in steps(item) do
					table.insert(marks, {
						at = e.at,
						tone = Thresholds.tone(e.name) :: string,
						title = FieldConfig.joined(FieldConfig.display(item, e.value, { theme = opts.theme })),
					})
				end
				meter.marks = marks
			end
			if not bar and showLabels then
				local labels: { string } = {}
				for _, s in item.config.thresholds.steps do
					if type(s.value) == "number" then
						table.insert(
							labels,
							FieldConfig.joined(FieldConfig.display(item, s.value, { theme = opts.theme }))
						)
					end
				end
				meter.threshold_labels = labels
			end
		end
		table.insert(out, meter)
	end
	return out
end

local function meterNode(m: Meter, key: string, style: string, size: string): Node
	local p: { [string]: any } = { key = "m", style = style, size = size, value = m.value, grow = 1 }
	if m.label then
		local token = Common.token((m.label_tone or "neutral") :: any)
		p.label = { ui.span(m.label :: string, if token ~= "" then "strong " .. token else "strong") }
	end
	if m.parts then
		p.parts = m.parts
	else
		-- `neutral` would yield to the accent default; Grafana's fallback is gray.
		p.tone = if m.tone == "neutral" then "muted" else m.tone
	end
	if m.marks then
		p.marks = m.marks
	end
	local children: { Node } = {}
	if m.title then
		table.insert(children, ui.text({ ui.span(m.title :: string, "muted") }, { key = "t", truncate = "end" }))
	end
	table.insert(children, { k = "meter", p = p })
	if m.threshold_labels and #(m.threshold_labels :: { string }) > 0 then
		table.insert(children, ui.muted(table.concat(m.threshold_labels :: { string }, " · "), { key = "th" }))
	end
	return { k = "col", p = { key = key, gap = "xs", grow = 1 }, c = children }
end

function M.barView(panel: any, frames: { Frame }, env: Env, opts: Common.Options): Node
	local meters = M.meters(panel, frames, env, opts, true)
	local nodes: { Node } = table.create(#meters)
	local displayMode = Json.str(env, Json.path(env, panel, "options", "displayMode")) or "gradient"
	local style = if displayMode == "lcd" then "blocks" else "bar"
	for i, m in meters do
		nodes[i] = meterNode(m, "g" .. i, style, "md")
	end
	local orientation = Json.str(env, Json.path(env, panel, "options", "orientation")) or "auto"
	if orientation ~= "vertical" then
		-- Horizontal bar gauges stack their bars (Grafana's default reading).
		return ui.col(nodes, { key = opts.key, gap = "sm", role = "tern-grafana.bargauge" })
	end
	return ui.row(nodes, { key = opts.key, gap = "md", wrap = true, role = "tern-grafana.bargauge" })
end

-- Radial gauge ----------------------------------------------------------------

-- Grafana panel chrome above the visualization (header row), px.
M.HEADER_PX = 32
M.DEFAULT_SIZE = { w = 480, h = 240 }
-- VizRepeater itemSpacing for gauges.
M.SPACING = 16

export type Look = {
	v2: boolean,
	style: SvgGauge.Style,
	gradient: boolean,
	sparkline: boolean,
	markers: boolean,
	labels: boolean,
	neutral: number?,
	bar_width_factor: number,
	rounded: boolean,
	glow: boolean,
	segments: number,
	segment_spacing: number,
	endpoint: boolean,
	text_mode: string,
	value_size: number?,
	name_size: number?,
}

-- The gauge options Grafana would render with: panelcfg.cue defaults, and
-- for v2 gauge/v2/migrations.ts gaugePanelMigrationHandler (a panel saved
-- by the old gauge gets no gradient, no sparkline, and markers only in
-- thresholds color mode).
function M.look(panel: any, env: Env, v2: boolean): Look
	local o = Json.obj(env, Json.path(env, panel, "options"))
	local text = Json.obj(env, o.text)
	local effects = Json.obj(env, o.effects)
	local look: Look = {
		v2 = v2,
		style = "v1",
		gradient = false,
		sparkline = false,
		markers = Json.bool(env, o.showThresholdMarkers) ~= false,
		labels = Json.bool(env, o.showThresholdLabels) == true,
		neutral = nil,
		bar_width_factor = 0.5,
		rounded = false,
		glow = false,
		segments = 1,
		segment_spacing = 0.3,
		endpoint = false,
		text_mode = "auto",
		value_size = Json.num(env, text.valueSize),
		name_size = Json.num(env, text.titleSize),
	}
	if not v2 then
		look.neutral = Json.num(env, Json.path(env, panel, "fieldConfig", "defaults", "custom", "neutral"))
		return look
	end
	local shape = Json.str(env, o.shape)
	look.style = if shape == "circle" then "circle" else "gauge"
	look.gradient = Json.bool(env, effects.gradient) ~= false
	look.sparkline = Json.bool(env, o.sparkline) ~= false
	look.neutral = Json.num(env, o.neutral)
	look.bar_width_factor = Json.num(env, o.barWidthFactor) or 0.5
	look.rounded = Json.str(env, o.barShape) == "rounded"
	look.glow = Json.bool(env, effects.barGlow) == true
	look.segments = Json.num(env, o.segmentCount) or 1
	look.segment_spacing = Json.num(env, o.segmentSpacing) or 0.3
	look.endpoint = (Json.str(env, o.endpointMarker) or "point") == "point"
	look.text_mode = Json.str(env, o.textMode) or "auto"
	local version = tonumber(string.match(Json.str(env, panel.pluginVersion) or "", "^%d+%.?%d*") or "") or 8
	if shape == nil and version < 13 then
		local colorMode = Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "color", "mode"))
		if colorMode ~= "thresholds" then
			look.markers = false
		end
		look.sparkline = false
		look.gradient = false
		local displayName = Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "displayName"))
		if displayName and displayName ~= "" then
			look.text_mode = "value_and_name"
		end
	end
	return look
end

-- The scale a value is drawn on: v2 getFieldConfigMinMax (min ?? 0,
-- max ?? 100, widened 10% each way when equal), v1 the same without the
-- widening; percentage thresholds put v1 on 0..100.
local function scaleOf(item: FieldConfig.Item, look: Look): (number, number)
	local lo, hi = item.range_min or 0, item.range_max or 100
	if look.v2 and lo == hi then
		lo, hi = lo - lo * 0.1, hi + hi * 0.1
	end
	return lo, hi
end

-- The threshold bands over the scale (getFormattedThresholds): the edges
-- are min, every step strictly inside, max; each band takes the step active
-- in it, later steps winning ties.
function M.bands(item: FieldConfig.Item, lo: number, hi: number): { SvgGauge.Band }
	local th = item.config.thresholds
	local pct = th.mode == "percentage"
	local edges: { number } = { 0 }
	for _, s in th.steps do
		if type(s.value) == "number" then
			local at = if pct then s.value / 100 else (s.value - lo) / (hi - lo)
			if at > 0 and at < 1 then
				table.insert(edges, at)
			end
		end
	end
	table.sort(edges)
	table.insert(edges, 1)
	local out: { SvgGauge.Band } = {}
	for i = 1, #edges - 1 do
		local a, b = edges[i], edges[i + 1]
		if b > a then
			local mid = lo + (a + b) / 2 * (hi - lo)
			local tone = Thresholds.active(mid, th, lo, hi).tone
			local prev = out[#out]
			if prev and prev.tone == tone then
				prev.to = b
			else
				table.insert(out, { from = a, to = b, tone = tone })
			end
		end
	end
	return out
end

-- getFormattedThresholds values: min, each step inside the range, max.
local function labelValues(item: FieldConfig.Item, lo: number, hi: number): { number }
	local th = item.config.thresholds
	local pct = th.mode == "percentage"
	local out: { number } = { lo }
	for _, s in th.steps do
		if type(s.value) == "number" then
			local v = if pct then lo + s.value / 100 * (hi - lo) else s.value
			if v > lo and v < hi then
				table.insert(out, v)
			end
		end
	end
	table.sort(out)
	table.insert(out, hi)
	return out
end

local function frac(v: number, lo: number, hi: number): number
	local f = (v - lo) / (hi - lo)
	return if f ~= f then 0 else f
end

local function sparkOf(spark: Values.Spark?): { number? }?
	if spark == nil then
		return nil
	end
	local lo, hi = math.huge, -math.huge
	for _, v in spark.values do
		local n = Frame.finite(v)
		if n then
			lo, hi = math.min(lo, n), math.max(hi, n)
		end
	end
	if lo > hi then
		return nil
	end
	local out: { number? } = table.create(#spark.values)
	for i, v in spark.values do
		local n = Frame.finite(v)
		out[i] = if n == nil then nil elseif hi > lo then (n - lo) / (hi - lo) else 0.5
	end
	return out
end

-- VizRepeater autoGrid: the column count that gives the largest square-ish
-- cells.
function M.grid(n: number, w: number, h: number): (number, number)
	local best, bestCols = -1, 1
	for cols = 1, math.max(n, 1) do
		local rows = math.ceil(n / cols)
		local size = math.min(w / cols, h / rows)
		if size > best then
			best, bestCols = size, cols
		end
	end
	return bestCols, math.ceil(n / bestCols)
end

-- The SVG spec of each gauge value, before layout sizes.
function M.specs(panel: any, frames: { Frame }, env: Env, opts: Common.Options): ({ SvgGauge.Spec }, Look)
	local v2 = opts.features ~= nil and (opts.features :: { [string]: boolean }).newGauge == true
	local look = M.look(panel, env, v2)
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "thresholds" })
	local values = Values.values(
		panel,
		items,
		env,
		{ sparkline = look.sparkline, theme = opts.theme, offset_min = opts.offset_min }
	)
	local mode = look.text_mode
	if mode == "auto" then
		mode = if not v2
			then (if #values > 1 then "value_and_name" else "value")
			elseif #values == 1 then "value"
			else "value_and_name"
	end
	local out: { SvgGauge.Spec } = {}
	for _, v in values do
		local d = v.display
		local item = v.item :: FieldConfig.Item
		local lo, hi = scaleOf(item, look)
		local numeric = d.numeric or 0
		local thresholdsMode = item.config.color_mode == "thresholds"
		local pct = item.config.thresholds.mode == "percentage"
		local valueAt
		if not v2 and pct then
			valueAt = d.percent
		else
			valueAt = frac(numeric, lo, hi)
		end
		local from, to = 0, valueAt
		if look.neutral then
			local n = frac(math.clamp(look.neutral :: number, math.min(lo, hi), math.max(lo, hi)), lo, hi)
			from, to = math.min(n, valueAt), math.max(n, valueAt)
		end
		local spec: SvgGauge.Spec = {
			width = 0,
			height = 0,
			style = look.style,
			bar_width_factor = look.bar_width_factor,
			rounded = look.rounded,
			glow = look.glow,
			segments = look.segments,
			segment_spacing = look.segment_spacing,
			fill_from = from,
			fill_to = to,
			bands = if look.gradient and thresholdsMode
				then M.bands(item, lo, hi)
				else { { from = 0, to = 1, tone = d.tone } },
			endpoint = look.endpoint,
			text_tone = if v2 then nil else d.tone,
			value_size = look.value_size,
			name_size = look.name_size,
		}
		if look.segments > 1 then
			-- RadialBarSegmented colors a segment with the field's display
			-- processor; the no-values placeholder has none, so Grafana's
			-- fallback gray.
			local placeholder = v.placeholder == true
			spec.segment_tone = function(at: number): string
				if placeholder then
					return "neutral"
				end
				return FieldConfig.display(item, lo + at * (hi - lo), { theme = opts.theme }).tone
			end
		end
		local ringOn = look.markers and thresholdsMode and (not v2 or lo ~= hi)
		if ringOn then
			spec.ring = M.bands(item, lo, hi)
		end
		if look.labels and thresholdsMode then
			local labels: { SvgGauge.Label } = {}
			local values_ = labelValues(item, lo, hi)
			local neutral = look.neutral
			if v2 and neutral and neutral > lo and neutral < hi and table.find(values_, neutral) == nil then
				table.insert(values_, neutral)
			end
			for _, lv in values_ do
				local text = FieldConfig.joined(FieldConfig.display(item, lv, { theme = opts.theme }))
				table.insert(labels, { at = frac(lv, lo, hi), text = text })
			end
			spec.labels = labels
		end
		if mode == "value" or mode == "value_and_name" then
			spec.prefix, spec.text, spec.suffix = d.prefix, d.text, d.suffix
		end
		if mode == "name" or mode == "value_and_name" then
			spec.name = v.title
		end
		if look.sparkline and v.spark then
			spec.spark = sparkOf(v.spark)
			spec.spark_tone = d.tone
		end
		table.insert(out, spec)
	end
	return out, look
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets)
	local specs, look = M.specs(panel, frames, env, opts)
	-- gauge/v2 GaugePanel: a "No data" placeholder is PanelDataErrorView.
	if look.v2 and #specs == 1 and specs[1].text == "No data" then
		return Common.noData(panel, env, opts.key), {}
	end
	local size = opts.size or M.DEFAULT_SIZE
	local w = math.max(size.w, 60)
	local h = math.max(size.h - M.HEADER_PX, 60)
	local cols, rows = M.grid(#specs, w, h)
	local cw = math.floor((w - M.SPACING * (cols - 1)) / cols)
	local ch = math.floor((h - M.SPACING * (rows - 1)) / rows)
	local assets: Assets.Assets = {}
	local nodes: { Node } = table.create(#specs)
	for i, spec in specs do
		spec.width, spec.height = math.max(cw, 40), math.max(ch, 40)
		local key = opts.key .. ".g" .. i
		-- The SVG's viewBox is tight around the gauge, so the image fills the
		-- pane's width (down to narrow splits) and the card bounds its height.
		local svg, iw, ih = SvgGauge.render(spec)
		assets[key] = { mime = Assets.SVG, bytes = svg }
		local alt = (spec.name or "Gauge") .. ": " .. (spec.prefix or "") .. (spec.text or "") .. (spec.suffix or "")
		-- Bounded by the cell's height in Tern lines (16 px), so a wide pane cannot
		-- grow the gauge past the card's Grafana height and clip it.
		local maxLines = math.max(3, math.floor(spec.height / 16))
		nodes[i] = {
			k = "image",
			p = { key = "g" .. i, asset = key, w = iw, h = ih, alt = alt, max = { h = maxLines .. "lines" } },
		}
	end
	return ui.row(nodes, { key = opts.key, gap = "md", wrap = true, role = "tern-grafana.gauge" }), assets
end

return M
