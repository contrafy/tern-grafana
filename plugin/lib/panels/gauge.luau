--!strict
-- Gauge and bar gauge panels (public/app/plugins/panel/gauge,
-- public/app/plugins/panel/bargauge; packages/grafana-ui/src/components/
-- Gauge, RadialGauge, BarGauge).
--
-- Gauge: one SVG radial gauge (lib/render/svg_gauge) per field display
-- value (lib/panels/values), laid out like VizRepeater's autoGrid. Grafana
-- 12 with the newGauge feature toggle, and every Grafana 13, draws gauge/v2
-- (RadialGauge: shape, barWidthFactor, barShape, segmentCount/Spacing,
-- neutral, sparkline, effects.gradient for thresholds and continuous
-- schemes, endpointMarker on rounded bars, textMode, text sizes); otherwise
-- gauge/v1 (the flot gauge). Both scale the value over the field's
-- min..max, put threshold markers in an outer ring and threshold labels at
-- min, each step and max (getFormattedThresholds).
--
-- Bar gauge: one SVG (lib/render/svg_bargauge) of every value's bar in
-- the panel's size: displayMode basic|gradient|lcd, orientation (auto:
-- vertical when wider than tall), valueMode color|text|hidden, textMode,
-- namePlacement, showUnfilled, text sizes and the manual sizing limits.
-- Every color is the exact color Grafana paints (Charts.valueClass): a
-- fixed color per row, each threshold step's own color.

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local Shared = require("./transforms/shared")
local SvgBarGauge = require("../render/svg_bargauge")
local SvgGauge = require("../render/svg_gauge")
local Thresholds = require("../units/thresholds")
local TsGradient = require("../render/ts_gradient")
local Values = require("./values")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

export type Part = { value: number, token: string }

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

local clamp01 = SvgGauge.clamp01

-- LCD cells from 0 up to `fill`, each run in its threshold band's tone; the
-- run holding the value takes the value's own tone, so a value sitting
-- exactly on a step reads in that step's color as in Grafana (table gauge
-- cells).
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

M.bandParts = bandParts

-- Bar gauge ---------------------------------------------------------------------

-- getBarGradient for thresholds: the first step's color, then each step the
-- value reaches blending in halfway from the previous step; the last color
-- reached ends the bar. Stops are fractions of the full bar length.
local function thresholdGradient(item: FieldConfig.Item, numeric: number, fill: number, opts: Common.Options)
	local th = item.config.thresholds
	local lo, hi = item.range_min or 0, item.range_max or 100
	local stops: { SvgBarGauge.Stop } = {}
	local last = 0
	local lastClass = ""
	for i, s in th.steps do
		local class = TsGradient.stopClass(Thresholds.color(s.color, opts.theme), opts.theme)
		if i == 1 then
			table.insert(stops, { at = 0, class = class })
		else
			local value = if type(s.value) == "number" then s.value else -math.huge
			local pos = if th.mode == "percentage" then value / 100 else math.min((value - lo) / (hi - lo), 1)
			local thresholdValue = if th.mode == "percentage" then lo + (hi - lo) * pos else value
			if numeric < thresholdValue then
				break
			end
			table.insert(stops, { at = pos - (pos - last) / 2, class = lastClass })
			last = pos
		end
		lastClass = class
	end
	table.insert(stops, { at = fill, class = lastClass })
	return stops
end

-- getBarGradient for continuous schemes: the scheme's colors spread evenly
-- over the full bar length.
local function schemeGradient(mode: string, opts: Common.Options): { SvgBarGauge.Stop }?
	local stops: { SvgBarGauge.Stop } = {}
	for i = 0, 8 do
		local c = TsGradient.schemeColor(mode, i / 8, opts.theme)
		if c == nil then
			return nil
		end
		table.insert(stops, { at = i / 8, class = TsGradient.stopClass(c, opts.theme) })
	end
	return stops
end

-- BarGaugePanel getOrientation.
local function vertical(orientation: string, w: number, h: number): boolean
	if orientation == "auto" then
		return w > h
	end
	return orientation == "vertical"
end

-- panelcfg.cue defaults; calcBarSize applies the panel's limits only with
-- manual sizing.
local DEFAULT_MIN_VIZ_WIDTH = 8
local DEFAULT_MIN_VIZ_HEIGHT = 16
local DEFAULT_MAX_VIZ_HEIGHT = 300

M.BAR_SIZE = { w = 480, h = 240 }

-- The bars and the renderer options for a panel `w` x `h` px.
function M.barSpecs(
	panel: any,
	frames: { Frame },
	env: Env,
	opts: Common.Options,
	w: number,
	h: number
): ({ SvgBarGauge.Bar }, SvgBarGauge.Options)
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "thresholds" })
	local values = Values.values(panel, items, env, { theme = opts.theme, offset_min = opts.offset_min })
	local o = Json.obj(env, Json.path(env, panel, "options"))
	local mode = Json.str(env, o.displayMode) or "gradient"
	if mode ~= "basic" and mode ~= "lcd" then
		mode = "gradient"
	end
	local textMode = Json.str(env, o.textMode) or "auto"
	local isVertical = vertical(Json.str(env, o.orientation) or "auto", w, h)
	local manual = Json.str(env, o.sizing) == "manual"
	local valueMode = Json.str(env, o.valueMode) or "color"
	if textMode == "name" or textMode == "none" then
		valueMode = "hidden"
	end
	local text = Json.obj(env, o.text)
	-- shouldShowName: auto names one bar only when the defaults set a
	-- display name.
	local showName = if textMode == "auto"
		then #values ~= 1 or (Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "displayName")) or "") ~= ""
		else textMode == "name" or textMode == "value_and_name"
	local bars: { SvgBarGauge.Bar } = {}
	for _, v in values do
		local d = v.display
		local item = v.item
		local fill = d.percent
		local bar: SvgBarGauge.Bar = {
			-- The no-values placeholder has no display title.
			title = if showName and not v.placeholder then v.title else nil,
			prefix = d.prefix,
			text = d.text,
			suffix = d.suffix,
			fill = fill,
			class = if item then Charts.valueClass(item, d, opts) else Charts.toneClass(d.tone),
		}
		if item then
			local it = item :: FieldConfig.Item
			local cfgMode = it.config.color_mode
			if mode == "gradient" then
				if cfgMode == "thresholds" then
					bar.gradient = thresholdGradient(it, d.numeric or -math.huge, clamp01(fill), opts)
				elseif string.sub(cfgMode, 1, 11) == "continuous-" then
					bar.gradient = schemeGradient(cfgMode, opts)
				end
			elseif mode == "lcd" then
				local lo, hi = it.range_min or 0, it.range_max or 100
				bar.cell_class = function(at: number): string
					return Charts.valueClass(
						it,
						FieldConfig.display(it, lo + at * (hi - lo), { theme = opts.theme }),
						opts
					)
				end
			end
		end
		table.insert(bars, bar)
	end
	return bars,
		{
			width = w,
			height = h,
			vertical = isVertical,
			mode = mode :: SvgBarGauge.Mode,
			value_mode = valueMode,
			show_unfilled = Json.bool(env, o.showUnfilled) ~= false,
			name_placement = Json.str(env, o.namePlacement) or "auto",
			title_size = Json.num(env, text.titleSize),
			value_size = Json.num(env, text.valueSize),
			min_viz_width = if manual and isVertical
				then Json.num(env, o.minVizWidth) or DEFAULT_MIN_VIZ_WIDTH
				else DEFAULT_MIN_VIZ_WIDTH,
			min_viz_height = if manual and not isVertical
				then Json.num(env, o.minVizHeight) or DEFAULT_MIN_VIZ_HEIGHT
				else DEFAULT_MIN_VIZ_HEIGHT,
			max_viz_height = if manual and not isVertical
				then Json.num(env, o.maxVizHeight) or DEFAULT_MAX_VIZ_HEIGHT
				else DEFAULT_MAX_VIZ_HEIGHT,
		}
end

-- PanelChrome's border and padding around the viz, px across.
local CHROME_PX = 2 + 2 * 8

-- The viz box Grafana gives a gauge: the panel less its border and
-- padding; its height the card body in a height-capped card
-- (opts.card_height), else the panel's less its header too.
local function vizSize(opts: Common.Options, size: { w: number, h: number }, least: number): (number, number)
	local w = math.max(size.w - CHROME_PX, 60)
	return w, math.max(opts.card_height or (size.h - Common.headerPx(opts) - CHROME_PX), least)
end

function M.barView(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets)
	local size = opts.size or M.BAR_SIZE
	local w, h = vizSize(opts, size, 40)
	local bars, o = M.barSpecs(panel, frames, env, opts, w, h)
	local svg, iw, ih = SvgBarGauge.render(bars, o)
	local alt: { string } = {}
	for _, b in bars do
		table.insert(alt, (if b.title then b.title .. ": " else "") .. b.prefix .. b.text .. b.suffix)
	end
	return Charts.image(opts.key, svg, iw, ih, table.concat(alt, ", "), "tern-grafana.bargauge")
end

-- Radial gauge ----------------------------------------------------------------

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
-- by the old gauge, parseFloat(pluginVersion ?? "8") below 13 and no
-- shape, gets no gradient, no sparkline, and markers only in thresholds
-- color mode; a version parseFloat cannot read, "v13.0.0", is not migrated).
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
	look.endpoint = look.rounded and (Json.str(env, o.endpointMarker) or "point") == "point"
	look.text_mode = Json.str(env, o.textMode) or "auto"
	local pluginVersion = Env.value(env, panel.pluginVersion)
	local version = if pluginVersion == nil then 8 else Shared.jsParseFloat(pluginVersion)
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
-- are min, every step strictly inside, max; each band takes the color of
-- the step active in it, later steps winning ties.
function M.bands(item: FieldConfig.Item, lo: number, hi: number, theme: Thresholds.Theme?): { SvgGauge.Band }
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
			local class = TsGradient.stopClass(Thresholds.active(mid, th, lo, hi, theme).color, theme)
			local prev = out[#out]
			if prev and prev.class == class then
				prev.to = b
			else
				table.insert(out, { from = a, to = b, class = class })
			end
		end
	end
	return out
end

-- buildGradientColors (RadialGauge/colors.ts) on the scale lo..hi:
-- thresholds put each step's color at its value (getFormattedThresholds
-- without the offset color: from the base step at min to the step active
-- at max, that color again at max; a stop never before an earlier one, as
-- in a CSS gradient), a continuous scheme spreads its colors evenly. Nil
-- for the other modes: their gradient is shades of the value's color that
-- have no exact class, so the bar keeps the value's color.
function M.gradient(item: FieldConfig.Item, lo: number, hi: number, opts: Common.Options): { SvgGauge.Stop }?
	local mode = item.config.color_mode
	if mode ~= "thresholds" then
		return if string.sub(mode, 1, 11) == "continuous-" then schemeGradient(mode, opts) else nil
	end
	local th = item.config.thresholds
	local pct = th.mode == "percentage"
	local min, max = item.range_min or 0, item.range_max or 100
	if pct then
		min, max = 0, 100
	end
	local out: { SvgGauge.Stop } = {}
	local function add(value: number, color: string)
		local at = if pct then value / 100 elseif hi ~= lo then (value - lo) / (hi - lo) else 0
		local prev = out[#out]
		table.insert(out, {
			at = if prev then math.max(at, prev.at) else at,
			class = TsGradient.stopClass(Thresholds.color(color, opts.theme), opts.theme),
		})
	end
	local function valueOf(s: any): number
		return if s and type(s.value) == "number" then s.value else -math.huge
	end
	local list = th.steps
	for i, s in list do
		local value = valueOf(s)
		add(if value == -math.huge then min else value, s.color)
		if list[i + 1] == nil or valueOf(list[i + 1]) > max then
			if max > value then
				add(max, s.color)
			end
			break
		end
	end
	return if #out > 0 then out else nil
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

-- The sparkline's values as fractions of its y range: Sparkline's
-- getYRange, the field's configured min and max, else the data's.
local function sparkOf(spark: Values.Spark?, min: number?, max: number?): { number? }?
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
	lo, hi = min or lo, max or hi
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
		local valueClass = Charts.valueClass(item, d, opts)
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
			bands = { { from = 0, to = 1, class = valueClass } },
			gradient = if look.gradient then M.gradient(item, lo, hi, opts) else nil,
			endpoint = look.endpoint,
			text_class = if v2 then nil else valueClass,
			value_size = look.value_size,
			name_size = look.name_size,
		}
		if look.segments > 1 then
			-- RadialBarSegmented colors a segment with the field's display
			-- processor; the no-values placeholder has none, so Grafana's
			-- fallback gray.
			local placeholder = v.placeholder == true
			spec.segment_class = function(at: number): string
				if placeholder then
					return Charts.toneClass("neutral")
				end
				return Charts.valueClass(
					item,
					FieldConfig.display(item, lo + at * (hi - lo), { theme = opts.theme }),
					opts
				)
			end
		end
		-- gauge/v1 drew markers and labels only from thresholds; gauge/v2's
		-- ThresholdsBar and RadialScaleLabels draw the thresholds in any color
		-- mode (the ring only when min and max differ).
		local ringOn = look.markers and (if v2 then lo ~= hi else thresholdsMode)
		if ringOn then
			spec.ring = M.bands(item, lo, hi, opts.theme)
		end
		if look.labels and (v2 or thresholdsMode) then
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
		-- The no-values placeholder has no name (createNoValuesFieldDisplay).
		if (mode == "name" or mode == "value_and_name") and v.title ~= "" then
			spec.name = v.title
		end
		if look.sparkline and v.spark then
			spec.spark = sparkOf(v.spark, item.config.min, item.config.max)
			spec.spark_class = valueClass
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
	local w, h = vizSize(opts, size, 60)
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
