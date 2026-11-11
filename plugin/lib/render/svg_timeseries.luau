--!strict
-- Time series frames -> one SVG document for an `image` node.
--
-- Tern draws the SVG as DOM but resolves no `var()` in attributes and drops
-- `style` attributes, so every color is a class bound to theme variables in
-- tern-grafana.css: series `tg-s1`..`tg-s10` (stroke and fill), `tg-grid`,
-- `tg-axis`, `tg-label`, thresholds `tg-th-<tone>`. Role classes after them
-- (`tg-line`, `tg-area`, `tg-bar`, `tg-tharea`) switch off the half a shape
-- does not paint. A theme switch then recolors without a new blob.
--
-- Tern refuses SVGs over 256 KiB. Every series is drawn, as Grafana does:
-- the renderer downsamples each one (LTTB) to a point budget derived from a
-- byte budget shared by all of them, and shrinks the budget until the
-- document fits. Only series that would not fit even at MIN_POINTS samples
-- each are left out (reported as `dropped`).
--
-- Y scales follow Grafana's time series config (public/app/core/components/
-- TimeSeries/utils.ts preparePlotConfigBuilder): series share a scale when
-- their scale key matches (packages/grafana-ui/src/components/uPlot/
-- internal.ts buildScaleKey: unit, min/max, soft min/max, placement,
-- distribution, label), each scale gets an axis unless its placement is
-- hidden, and auto placement puts the first axis left and later ones right
-- (UPlotConfigBuilder addAxis). Stacking groups are per direction, mode,
-- group and scale (uPlot/utils.ts getStackingGroups). custom.transform
-- negative-Y draws a series negated and constant draws its first value
-- across the time range (preparePlotData2, the Constant path builder); the
-- legend and cursor keep reading the series' own values.
--
-- Like uPlot, y scales range over the samples in view only (setScales
-- i0..i1), and each series is drawn through the nearest sample beyond each
-- end of the range (getOuterIdxs), cut at the plot's edges (Tern drops
-- clipPath, so svg_paths cuts the path data itself).
--
-- Exemplars are diamonds in one `tg-exemplar` path over the series, at most
-- EXEMPLAR_CAP of them (thinned evenly over time); layout.exemplars lists
-- the ones drawn so a block can select one by index. They share the first
-- series' scale.
--
-- Series preparation (transforms, stacking, downsampling) lives in
-- lib/render/ts_data, the series path data in lib/render/svg_paths.

local Annotations = require("./svg_annotations")
local Axis = require("./axis")
local Data = require("./ts_data")
local Frame = require("../frame/types")
local FrameProm = require("../frame/prom")
local Kit = require("./svg_kit")
local Layout = require("./layout")
local Paths = require("./svg_paths")
local Series = require("./series")
local Thresholds = require("../units/thresholds")

type Frame = Frame.Frame
type Layout = Layout.Layout
type DrawnSeries = Layout.DrawnSeries
type YAxis = Layout.YAxis
type Geometry = Paths.Geometry
type Plot = Data.Plot

export type ThresholdStyle = Data.ThresholdStyle
export type Draw = Data.Draw
export type Placement = Data.Placement
export type Transform = Data.Transform
export type Distribution = Data.Distribution
export type Interpolation = Data.Interpolation
export type ShowPoints = Data.ShowPoints
export type Gradient = Data.Gradient
export type SeriesStyle = Data.SeriesStyle

export type Options = {
	-- Design size in px (the image scales down to the pane).
	width: number?,
	height: number?,
	-- One shared scale (used when `series` is nil): unit, decimals, hard
	-- y-axis bounds, stacking and thresholds for every series.
	unit: string?,
	decimals: number?,
	min: number?,
	max: number?,
	thresholds: Thresholds.Thresholds?,
	threshold_style: ThresholdStyle?,
	stack: Series.StackMode?,
	-- Per series (extraction order): replaces the shared scale settings.
	series: { SeriesStyle }?,
	draw: Draw?,
	-- 0..100, Grafana's fillOpacity.
	fill_opacity: number?,
	null_mode: ("gap" | "connect")?,
	-- Most samples drawn per series (default: one per plot pixel).
	point_budget: number?,
	-- Visible time range (default: the data's extent).
	from_ms: number?,
	to_ms: number?,
	-- Tick labels' timezone (Range.Offset).
	offset_min: Axis.Offset?,
	-- The plot height Grafana gives this chart, in px: uPlot picks the y
	-- tick spacing (15 px up to 150 px, else 30) and increments from it, so
	-- the axis keeps Grafana's tick count (default: the SVG's plot height).
	tick_height: number?,
	-- Grafana legendFormat for series names.
	legend: string?,
	-- Exemplar markers (any order); those in the time range are drawn, at
	-- most EXEMPLAR_CAP of them.
	exemplars: { FrameProm.Exemplar }?,
	-- Dashboard annotations (lib/render/svg_annotations): over the series,
	-- under the exemplars, markers under the plot; at most
	-- svg_annotations.CAP of them.
	annotations: Annotations.Layer?,
}

export type Result = { svg: string, layout: Layout, dropped: number, points: number }

local M = {}

M.CAP = 262144
-- Aim below the cap: estimates are rough and the next refresh may grow.
M.TARGET = 240 * 1024
M.PALETTE = 10
-- Most exemplar markers drawn: a dense histogram keeps one per bucket per
-- scrape, which would bury the lines.
M.EXEMPLAR_CAP = 200
-- Half the width of an exemplar diamond, in viewBox px.
M.EXEMPLAR_R = 4
-- Stroke widths and point sizes in viewBox px per Grafana px: the image is
-- scaled down to its pane, so a 1 px Grafana line is drawn 1.5 wide.
M.LINE_SCALE = 1.5

local finite = Frame.finite
local fmt = string.format

local PAD_TOP = 8
local PAD_RIGHT = 12
local X_AXIS_H = 24
-- Narrowest y axis band, and the extra band an axis label takes.
local AXIS_MIN_W = 36
local AXIS_LABEL_W = 18
-- Bytes per drawn sample, measured on absolute "%.1f" path data. The size
-- checks below count series paths that way too (svg_paths reports it), so
-- the shorter relative path data keeps the same samples drawn.
local BYTES_LINE = 12
local BYTES_BAR = 30
local FIXED_BYTES = 8 * 1024
-- "M123.4 56.7l4 4l-4 4l-4 -4Z" per exemplar marker.
local BYTES_EXEMPLAR = 32
-- A gradient definition without its stops, and one `<stop>`.
local BYTES_GRADIENT = 140
local BYTES_STOP = 40
-- One series `<path>` without its data (classes and stroke attributes).
local BYTES_PATH = 160
-- Fewest samples a series is drawn with.
local MIN_POINTS = 3

function M.seriesClass(i: number): string
	return "tg-s" .. tostring((i - 1) % M.PALETTE + 1)
end

-- Scales -----------------------------------------------------------------------

local function keyPart(v: any): string
	return if v == nil then "na" else tostring(v)
end

-- buildScaleKey (uPlot/internal.ts); every series here is a number field.
function M.scaleKey(s: SeriesStyle): string
	local d = s.distribution
	local dist = if d == nil then "linear" elseif d.type == "log" then "log" .. keyPart(d.log) else d.type
	local label = if s.label ~= nil and s.label ~= "" then s.label else "na"
	return fmt(
		"%s/%s-%s/%s-%s/%s/%s/%s/number",
		s.unit or "__fixed",
		keyPart(s.min),
		keyPart(s.max),
		keyPart(s.soft_min),
		keyPart(s.soft_max),
		s.placement or "auto",
		dist,
		label
	)
end

-- A scale and the series on it; the first series' style configures it
-- (UPlotConfigBuilder keeps the first scale and axis of a key).
type ScaleSpec = {
	key: string,
	style: SeriesStyle,
	members: { number },
	side: "left" | "right" | "hidden",
	percent: boolean,
}

local function scaleSpecs(styles: { SeriesStyle }): ({ ScaleSpec }, { number })
	local specs: { ScaleSpec } = {}
	local byKey: { [string]: number } = {}
	local scaleOf: { number } = table.create(#styles)
	local hasLeft = false
	for i, st in styles do
		local key = M.scaleKey(st)
		local at = byKey[key]
		if at == nil then
			local placement = st.placement or "auto"
			local side: "left" | "right" | "hidden"
			if placement == "hidden" then
				side = "hidden"
			elseif placement == "right" or (placement ~= "left" and hasLeft) then
				side = "right"
			else
				side = "left"
				hasLeft = true
			end
			table.insert(specs, { key = key, style = st, members = {}, side = side, percent = st.stack == "percent" })
			at = #specs
			byKey[key] = at
		end
		local a = at :: number
		table.insert(specs[a].members, i)
		scaleOf[i] = a
	end
	return specs, scaleOf
end

-- The data extent of each scale: stacked tops (the accumulated values
-- uPlot ranges over; the base a stack fills down to is not data, so a
-- stack of 3..4 ranges 2.9..4.1 as in Grafana), or the full-resolution
-- values (so downsampling never moves an axis), of the samples in view
-- (uPlot ranges its y scales over i0..i1 only). `calcs` holds the calcs of
-- `list`, which a series drawn untransformed and wholly in view shares;
-- `view[i]` bounds the times in view of a series that has samples outside
-- them.
local function scaleRange(
	shown: { Series.Series },
	list: { Series.Series },
	calcs: { Series.Calcs },
	plot: Plot,
	members: { number },
	view: { [number]: { number } }
): (number?, number?)
	local lo: number?, hi: number? = nil, nil
	local function see(v: any)
		local n = finite(v)
		if n then
			if lo == nil or n < lo then
				lo = n
			end
			if hi == nil or n > hi then
				hi = n
			end
		end
	end
	for _, i in members do
		local bounds = view[i]
		local t0, t1 = -math.huge, math.huge
		if bounds then
			t0, t1 = bounds[1], bounds[2]
		end
		if plot.stacked[i] then
			local times = plot.times[i]
			for j, v in plot.tops[i] do
				local t = times[j]
				if t >= t0 and t <= t1 then
					see(v)
				end
			end
		elseif bounds then
			local times = shown[i].times
			for j, v in shown[i].values do
				local t = times[j]
				if t >= t0 and t <= t1 then
					see(v)
				end
			end
		else
			local c = if shown[i] == list[i] then calcs[i] else Series.calcs(shown[i].values)
			see(c.min)
			see(c.max)
		end
	end
	return lo, hi
end

-- UPlotScaleBuilder range: hard bounds kept, centered zero, soft bounds the
-- scale reaches at least, percent stacks 0..1. Linear scales get uPlot's
-- padded range (Axis.linearRange: headroom above the data, a flat 0 series
-- on the floor of 0..100) with ticks at nice steps inside it.
local function buildScale(spec: ScaleSpec, lo: number?, hi: number?, plotPx: number): Axis.Scale
	local st = spec.style
	local d = st.distribution
	local kind = Data.distr(st)
	local hardMin, hardMax = st.min, st.max
	if kind == "log" then
		if spec.percent then
			hardMin, hardMax = hardMin or 0, hardMax or 1
		end
		local base = Axis.logBase(if d then d.log else nil)
		local softLo = if st.soft_min and st.soft_min > 0 then st.soft_min else nil
		local softHi = if st.soft_max and st.soft_max > 0 then st.soft_max else nil
		local a, b = lo, hi
		if softLo and (a == nil or softLo < a) then
			a = softLo
		end
		if softHi and (b == nil or softHi > b) then
			b = softHi
		end
		return Axis.logScale(a, b, plotPx, base, hardMin, hardMax)
	end
	if kind == "symlog" then
		if spec.percent then
			hardMin, hardMax = hardMin or 0, hardMax or 1
		end
		local a, b = lo or 0, hi or 1
		if st.centered_zero then
			local m = math.max(math.abs(a), math.abs(b))
			if m == 0 then
				m = 80
			end
			a, b = -m, m
		end
		if hardMin == nil and st.soft_min ~= nil and st.soft_min < a then
			hardMin = st.soft_min
		end
		if hardMax == nil and st.soft_max ~= nil and st.soft_max > b then
			hardMax = st.soft_max
		end
		local base = Axis.logBase(if d then d.log else nil)
		local lt = if d and d.linear_threshold and d.linear_threshold > 0 then d.linear_threshold else 1
		return Axis.symlogScale(a, b, plotPx, base, lt, hardMin, hardMax)
	end
	local a, b = Axis.linearRange(lo, hi, {
		hard_min = hardMin,
		hard_max = hardMax,
		soft_min = st.soft_min,
		soft_max = st.soft_max,
		centered_zero = st.centered_zero,
		percent = spec.percent,
		decimals = st.decimals,
	})
	return Axis.rangeScale(a, b, plotPx, st.unit)
end

-- One decimals count for every tick, the fewest that print each tick
-- exactly in its display unit: a 0.25 step reads 0.25/0.50 (not 0.3), a 0.2
-- percentunit step reads 20% (not 20.0%), 1.5 MiB keeps its .5. Log and
-- symlog ticks are a magnitude apart: each prints with its own decimals.
local function yLabels(scale: Axis.Scale, unit: string?, decimals: number?): { string }
	return Kit.tickLabels(scale.ticks, unit, decimals, (scale.distr or "linear") ~= "linear")
end

-- How one series is drawn, its SeriesStyle resolved against the shared
-- options and Grafana's GraphFieldConfig defaults.
type Look = {
	class: string,
	draw: Draw,
	-- 0..1.
	fill: number,
	gradient: Gradient,
	hue: { string }?,
	scheme: Data.Scheme?,
	line_width: number,
	dash: { number }?,
	dot: boolean,
	interpolation: Interpolation,
	points: ShowPoints,
	point_size: number,
	span: boolean | number,
	fill_below: number?,
	bar_alignment: number,
	bar_width_factor: number,
	bar_max_width: number,
}

local function lookOf(i: number, st: SeriesStyle, opts: Options, count: number): Look
	local constant = st.transform == "constant"
	local draw: Draw = if constant then "line" else st.draw or opts.draw or "line"
	local fillPct = st.fill_opacity or opts.fill_opacity or 0
	-- Bars without per-series styles (Logs volume, Query block) stay solid
	-- and unoutlined, as they were before per-series styles.
	local plainBars = draw == "bars" and st.draw == nil
	if plainBars and fillPct == 0 then
		fillPct = 80
	end
	local below = st.fill_below
	if below and (below < 1 or below > count or below == i) then
		below = nil
	end
	if below and fillPct == 0 then
		-- TimeSeries/utils.ts: a fillBelowTo band defaults to 35% ("from flot").
		fillPct = 35
	end
	local span: boolean | number = if st.span_nulls ~= nil
		then st.span_nulls :: boolean | number
		else opts.null_mode == "connect"
	local pts: ShowPoints = if draw == "points" then "always" elseif constant then "never" else st.show_points or "auto"
	return {
		class = st.class or M.seriesClass(i),
		draw = draw,
		fill = math.clamp(fillPct :: number, 0, 100) / 100,
		gradient = st.gradient or "none",
		hue = if st.gradient == "hue" then st.hue else nil,
		scheme = if st.gradient == "scheme" then st.scheme else nil,
		line_width = if plainBars then 0 else math.max(0, st.line_width or 1),
		dash = st.dash,
		dot = st.dot == true,
		interpolation = if constant then "linear" else st.interpolation or "linear",
		points = pts,
		point_size = math.max(1, st.point_size or 5),
		span = span,
		fill_below = below,
		bar_alignment = st.bar_alignment or 0,
		bar_width_factor = st.bar_width_factor or 0.6,
		bar_max_width = st.bar_max_width or 200,
	}
end

-- Bytes per drawn sample of one series, by how it is drawn.
local function sampleBytes(look: Look): number
	local e = if look.draw == "bars" then BYTES_BAR else BYTES_LINE
	if look.interpolation == "smooth" then
		e *= 3
	end
	if look.fill > 0 then
		e *= 2
	end
	if look.points ~= "never" then
		e += BYTES_LINE
	end
	return e
end

-- The bytes of one series' paths besides their data: line, area, points.
local function seriesBytes(look: Look): number
	return BYTES_PATH * (1 + (if look.fill > 0 then 1 else 0) + (if look.points ~= "never" then 1 else 0))
end

type Ctx = {
	shown: { Series.Series },
	plot: Plot,
	layout: Layout,
	opts: Options,
	styles: { SeriesStyle },
	looks: { Look },
	specs: { ScaleSpec },
	scales: { Axis.Scale },
	labels: { { string } },
	scaleOf: { number },
}

local function axisLabel(out: { string }, a: YAxis, cy: number)
	local label = a.label
	if label == nil or label == "" then
		return
	end
	local x = if a.side == "left" then a.x0 + 14 else a.x1 - 14
	table.insert(out, Kit.text(x, cy, label, { rotate = if a.side == "left" then -90 else 90 }))
end

-- The class list of a stroked series shape: its color class, or none when
-- a gradient paints it through the stroke attribute (a class color would
-- win over the attribute).
local function strokeClass(class: string, role: string, gradient: string?): string
	if gradient then
		return fmt('%s" stroke="url(#%s)', role, gradient)
	end
	return class .. " " .. role
end

-- Gradient ids from their content (a 32-bit polynomial hash).
local function hash(s: string): number
	local h = 0
	for k = 1, #s do
		h = (h * 31 + string.byte(s, k)) % 4294967296
	end
	return h
end

local function stopTag(offset: number, class: string): string
	return fmt('<stop offset="%.4g" class="%s"/>', math.clamp(offset, 0, 1), class)
end

local function verticalGradient(y1: number, y2: number, stops: string): string
	return fmt(' gradientUnits="userSpaceOnUse" x1="0" y1="%.1f" x2="0" y2="%.1f">%s', y1, y2, stops)
end

-- getGradientRange: hard min/max, else soft min/max, else the range of the
-- data drawn on the series' scale (its scale's range when flat).
local function gradientRange(ctx: Ctx, i: number, scale: Axis.Scale): (number, number)
	local st = ctx.styles[i]
	local lo, hi = st.min or st.soft_min, st.max or st.soft_max
	if lo == nil or hi == nil then
		local dlo, dhi = math.huge, -math.huge
		for _, j in ctx.specs[ctx.scaleOf[i]].members do
			for _, v in ctx.plot.tops[j] do
				local n = finite(v)
				if n then
					dlo, dhi = math.min(dlo, n), math.max(dhi, n)
				end
			end
		end
		if dlo >= dhi then
			dlo, dhi = scale.min, scale.max
		end
		lo, hi = lo or dlo, hi or dhi
	end
	return lo :: number, hi :: number
end

-- The attributes and stops (after the id) of series i's hue or scheme
-- gradient, or nil when it has none. Hue runs down the plot
-- (getHueGradientFn); scheme follows scaleGradient: the stops between the
-- one at or below the scale's min and the first at or above its max, placed
-- at their values' pixels.
local function gradientDef(ctx: Ctx, i: number, geo: { Geometry }, top: number, bottom: number): string?
	local look = ctx.looks[i]
	local hue = look.hue
	if hue then
		return verticalGradient(top, bottom, stopTag(0, hue[1]) .. stopTag(1, hue[2]))
	end
	local scheme = look.scheme
	if scheme == nil or #scheme.stops == 0 then
		return nil
	end
	local k = ctx.scaleOf[i]
	local scale, g = ctx.scales[k], geo[k]
	local stops = scheme.stops
	local values: { number } = table.create(#stops)
	local lo, span = 0, 1
	if scheme.relative then
		local a, b = gradientRange(ctx, i, scale)
		lo, span = a, b - a
	end
	for n, s in stops do
		values[n] = if math.abs(s.at) == math.huge or not scheme.relative then s.at else lo + span * s.at
	end
	local minIdx, maxIdx = 1, 1
	for n, v in values do
		if v <= scale.min or n == 1 then
			minIdx = n
		end
		maxIdx = n
		if v >= scale.max then
			break
		end
	end
	local function solid(class: string): string
		return verticalGradient(top, bottom, stopTag(0, class))
	end
	if minIdx == maxIdx then
		return solid(stops[minIdx].class)
	end
	local minV, maxV = values[minIdx], values[maxIdx]
	if minV == -math.huge then
		minV = scale.min
	end
	if maxV == math.huge then
		maxV = scale.max
	end
	local minPos = math.floor(Paths.y(g, minV) + 0.5)
	local maxPos = math.floor(Paths.y(g, maxV) + 0.5)
	local range = minPos - maxPos
	if range == 0 then
		return solid(stops[maxIdx].class)
	end
	local buf: { string } = {}
	local prev = ""
	for n = minIdx, maxIdx do
		local pos = if n == minIdx
			then minPos
			elseif n == maxIdx then maxPos
			else math.floor(Paths.y(g, values[n]) + 0.5)
		local pct = (minPos - pos) / range
		if scheme.discrete and n > minIdx then
			table.insert(buf, stopTag(pct, prev))
		end
		prev = stops[n].class
		table.insert(buf, stopTag(pct, prev))
	end
	return verticalGradient(minPos, maxPos, table.concat(buf))
end

-- The document, and how many bytes longer it would be with absolute "%.1f"
-- series path data (the size the point budget is measured against).
local function build(ctx: Ctx): (string, number)
	local layout, plot, opts = ctx.layout, ctx.plot, ctx.opts
	local out: { string } = {}
	local W, H = layout.width, layout.height
	local top, bottom = layout.plot_top, layout.plot_bottom
	local axes = layout.axes :: { YAxis }
	local geo: { Geometry } = table.create(#axes)
	for k in axes do
		geo[k] = Paths.geometry(layout, k)
	end
	local g1 = geo[1]
	local function xOf(t: number): number
		return Paths.x(g1, t)
	end
	-- "%d" of the size, as the viewBox always printed it.
	table.insert(out, Kit.open(math.floor(W), math.floor(H)))
	local extra = 0
	local function seriesPath(d: string, legacy: number): string
		extra += legacy - #d
		return d
	end

	-- Grid and axis labels.
	local ticks = Axis.timeTicks(layout.t_from, layout.t_to, layout.plot_right - layout.plot_left, opts.offset_min)
	local grid: { string } = {}
	for k, a in axes do
		local scale = ctx.scales[k]
		if a.side ~= "hidden" and ctx.specs[k].style.grid ~= false then
			for _, v in scale.ticks do
				if v >= scale.min and v <= scale.max then
					table.insert(grid, fmt("M%.1f %.1fH%.1f", layout.plot_left, Paths.y(geo[k], v), layout.plot_right))
				end
			end
		end
	end
	for _, t in ticks.ticks do
		table.insert(grid, fmt("M%.1f %.1fV%.1f", xOf(t), top, bottom))
	end
	if #grid > 0 then
		table.insert(out, '<path class="tg-grid" fill="none" stroke-width="1" d="' .. table.concat(grid) .. '"/>')
	end
	table.insert(
		out,
		fmt(
			'<path class="tg-axis" fill="none" stroke-width="1" d="M%.1f %.1fH%.1f"/>',
			layout.plot_left,
			bottom,
			layout.plot_right
		)
	)
	for k, a in axes do
		if a.side == "hidden" then
			continue
		end
		local scale = ctx.scales[k]
		local labels = ctx.labels[k]
		local left = a.side == "left"
		for i, v in scale.ticks do
			if v >= scale.min and v <= scale.max and labels[i] ~= "" then
				table.insert(
					out,
					Kit.text(
						if left then a.x1 - 6 else a.x0 + 6,
						Paths.y(geo[k], v) + 4,
						labels[i],
						{ anchor = if left then "end" else "start" }
					)
				)
			end
		end
		axisLabel(out, a, (top + bottom) / 2)
	end
	for i, t in ticks.ticks do
		local x = xOf(t)
		local half = #ticks.labels[i] * Axis.CHAR_PX / 2
		if x - half >= 0 and x + half <= W then
			table.insert(out, Kit.text(x, H - 6, ticks.labels[i]))
		end
	end

	-- Thresholds: per scale, from its first series that shows them
	-- (UPlotConfigBuilder addThresholds keeps the first per scale key).
	for k, spec in ctx.specs do
		for _, i in spec.members do
			local st = ctx.styles[i]
			if (st.threshold_style or "off") ~= "off" and st.thresholds then
				local g, scale = geo[k], ctx.scales[k]
				Kit.thresholds(out, {
					min = scale.min,
					max = scale.max,
					toPx = function(v: number): number
						return Paths.y(g, v)
					end,
					from = layout.plot_left,
					to = layout.plot_right,
				}, st.thresholds, st.threshold_style or "off")
				break
			end
		end
	end

	-- Series: fills and bars first, lines and points on top
	-- (UPlotSeriesBuilder: each series' own draw style, line, fill, points).
	-- Samples just beyond the range are cut at the plot's edges (svg_paths).
	local list = ctx.shown
	local looks = ctx.looks
	local function baseOf(i: number): number
		local s = ctx.scales[ctx.scaleOf[i]]
		if (s.distr or "linear") == "log" then
			return s.min
		end
		return math.clamp(0, s.min, s.max)
	end
	local plotW = layout.plot_right - layout.plot_left
	-- uPlot's bars path builder (findColWidth, bars): a series' column is
	-- the smallest distance between two of its adjacent samples (the whole
	-- plot for one sample); barWidthFactor of it is the bar and the rest the
	-- gap, dropped below 1 px. The outline (lineWidth) is inset into the
	-- column, and not drawn at all once it would take half the bar; the bar
	-- is clamped to 1 px .. barMaxWidth and snapped to whole pixels once the
	-- gap reaches 5 px. Grafana's renderer and Tern's viewBox both count
	-- Grafana px (pxRatio 1); the drawn outline is LINE_SCALE wider, so it is
	-- inset by that width.
	local barPaths: { [number]: string } = {}
	local barLegacy: { [number]: number } = {}
	local barStroke: { [number]: number } = {}
	local function bars(i: number): string
		if barPaths[i] == nil then
			local look = looks[i]
			local g = geo[ctx.scaleOf[i]]
			local times = list[i].times
			local col = g.width
			local minDelta = math.huge
			for j = 2, #times do
				local delta = math.abs(times[j] - times[j - 1])
				if delta < minDelta then
					minDelta = delta
					col = math.abs(Paths.x(g, times[j]) - Paths.x(g, times[j - 1]))
				end
			end
			local gap = col * (1 - look.bar_width_factor)
			if gap < 1 then
				gap = 0
			end
			local stroke = math.floor(look.line_width + 0.5)
			if stroke >= (col - gap) / 2 then
				stroke = 0
			end
			local drawn = stroke * M.LINE_SCALE
			local inset = if gap > 0 then drawn else 0
			local raw = col - gap - inset
			local barW = if raw < 1 then 1 elseif raw > look.bar_max_width then look.bar_max_width else raw
			if gap >= 5 then
				barW = math.floor(barW + 0.5)
			end
			local align = look.bar_alignment
			local shift = if align == 1 then inset / 2 elseif align == -1 then -barW - inset / 2 else -barW / 2
			barStroke[i] = drawn
			barPaths[i], barLegacy[i] =
				Paths.bars(g, plot.times[i], plot.tops[i], plot.bottoms[i], baseOf(i), barW, shift)
		end
		return seriesPath(barPaths[i], barLegacy[i])
	end
	local fade: string? = nil
	for i = 1, #list do
		local look = looks[i]
		if look.fill > 0 and look.gradient == "opacity" and look.draw ~= "points" then
			-- getOpacityGradientFn: the fill fades from its opacity at the
			-- plot's top to nothing at its bottom. One luminance mask over
			-- the plot (ids are per geometry, so equal charts share it).
			local id = fmt("tgfade-%d-%d", top, bottom)
			table.insert(
				out,
				fmt(
					'<defs><linearGradient id="%s-g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="white"/><stop offset="1" stop-color="white" stop-opacity="0"/></linearGradient><mask id="%s"><rect x="0" y="%.1f" width="%d" height="%.1f" fill="url(#%s-g)"/></mask></defs>',
					id,
					id,
					top,
					W,
					bottom - top,
					id
				)
			)
			fade = id
			break
		end
	end
	-- gradientMode hue and scheme: one userSpaceOnUse gradient per series
	-- strokes its line and points and fills its area at the fill opacity
	-- (UPlotSeriesBuilder getLineColor/getFill). Ids hash the gradient, so
	-- equal gradients share one.
	local paint: { [number]: string } = {}
	local defined: { [string]: boolean } = {}
	for i = 1, #list do
		local def = gradientDef(ctx, i, geo, top, bottom)
		if def then
			local id = fmt("tgg%08x", hash(def))
			if not defined[id] then
				defined[id] = true
				table.insert(out, fmt('<defs><linearGradient id="%s"%s</linearGradient></defs>', id, def))
			end
			paint[i] = id
		end
	end
	for i = 1, #list do
		local look = looks[i]
		if look.fill <= 0 or look.draw == "points" then
			continue
		end
		local d: string
		local role = "tg-area"
		if look.draw == "bars" then
			role = "tg-bar"
			d = bars(i)
		else
			local below: { [number]: number }? = nil
			local j = look.fill_below
			if j and plot.bottoms[i] == nil and plot.times[j] then
				local map: { [number]: number } = {}
				for k, t in plot.times[j] do
					local v = finite(plot.tops[j][k])
					if v then
						map[t] = v
					end
				end
				below = map
			end
			d = seriesPath(
				Paths.area(
					geo[ctx.scaleOf[i]],
					plot.times[i],
					plot.tops[i],
					plot.bottoms[i],
					below,
					baseOf(i),
					look.interpolation
				)
			)
		end
		if d ~= "" then
			local mask = if fade and look.gradient == "opacity" then fmt(' mask="url(#%s)"', fade) else ""
			local id = paint[i]
			local color = if id then fmt('%s" fill="url(#%s)', role, id) else look.class .. " " .. role
			table.insert(out, fmt('<path class="%s" fill-opacity="%.2f"%s d="%s"/>', color, look.fill, mask, d))
		end
	end
	for i = 1, #list do
		local look = looks[i]
		local g = geo[ctx.scaleOf[i]]
		local d = ""
		local stroke = look.line_width * M.LINE_SCALE
		if look.draw == "bars" then
			d = bars(i)
			stroke = barStroke[i]
		elseif look.draw ~= "points" and stroke > 0 then
			d = seriesPath(Paths.line(g, plot.times[i], plot.tops[i], look.interpolation))
		end
		if stroke > 0 then
			if d ~= "" then
				local dash = ""
				if look.dash then
					local parts: { string } = table.create(#look.dash)
					for k, v in look.dash do
						parts[k] = fmt("%g", v * M.LINE_SCALE)
					end
					dash = ' stroke-dasharray="' .. table.concat(parts, " ") .. '"'
				end
				-- uPlot strokes with butt caps; dotted lines get round ones.
				-- Solid lines keep round caps so a lone sample shows as a dot.
				local cap = if look.dash and not look.dot then "butt" else "round"
				table.insert(
					out,
					fmt(
						'<path class="%s" fill="none" stroke-width="%s" stroke-linecap="%s" stroke-linejoin="round"%s d="%s"/>',
						strokeClass(look.class, "tg-line", paint[i]),
						fmt("%g", stroke),
						cap,
						dash,
						d
					)
				)
			end
		end
		-- Points: always, or (auto) when the samples are at least two point
		-- sizes apart (uPlot seriesPointsShow), else only lone samples
		-- between gaps unless nulls are spanned (Grafana's points filter).
		local pts = look.points
		if pts == "never" or look.draw == "bars" then
			continue
		end
		local all = pts == "always"
		if pts == "auto" then
			local n = 0
			local times = plot.times[i]
			for j, v in plot.tops[i] do
				local t = times[j]
				if finite(v) and t >= layout.t_from and t <= layout.t_to then
					n += 1
				end
			end
			all = n <= plotW / (2 * look.point_size)
		end
		if not all and look.span == true then
			continue
		end
		local dots = seriesPath(Paths.dots(g, plot.times[i], plot.tops[i], not all))
		if dots ~= "" then
			table.insert(
				out,
				fmt(
					'<path class="%s" fill="none" stroke-width="%s" stroke-linecap="round" d="%s"/>',
					strokeClass(look.class, "tg-dots", paint[i]),
					fmt("%g", look.point_size * M.LINE_SCALE),
					dots
				)
			)
		end
	end

	-- Annotations: drawn after the series (AnnotationsPlugin's draw hook),
	-- under the exemplar markers.
	if opts.annotations then
		Annotations.draw(out, opts.annotations, {
			t_from = layout.t_from,
			t_to = layout.t_to,
			left = layout.plot_left,
			right = layout.plot_right,
			top = top,
			bottom = bottom,
			scale = M.LINE_SCALE,
		})
	end

	-- Exemplars: one path of diamonds over the lines, on the first scale.
	local exemplars = layout.exemplars
	if exemplars and #exemplars > 0 and #geo > 0 then
		local r = M.EXEMPLAR_R
		local buf: { string } = table.create(#exemplars)
		for i, e in exemplars do
			buf[i] = fmt("M%.1f %.1fl%d %dl%d %dl%d %dZ", xOf(e.time_ms), Paths.y(g1, e.value) - r, r, r, -r, r, -r, -r)
		end
		table.insert(out, '<path class="tg-exemplar" stroke-width="1" d="' .. table.concat(buf) .. '"/>')
	end

	if #list == 0 then
		Kit.noData(out, (layout.plot_left + layout.plot_right) / 2, (top + bottom) / 2)
	end
	table.insert(out, Kit.CLOSE)
	return table.concat(out), extra
end

-- Narrowest slot a bar gets, in viewBox px. Thinner bars blend into their
-- neighbors once the image is scaled down, so sparse series stacked over many
-- samples (Loki counts over a short step) read as fewer colors than the legend.
M.MIN_BAR_PX = 3

-- The exemplars a chart over [from_ms, to_ms] draws, sorted by time and
-- thinned evenly to EXEMPLAR_CAP, and how many in range were left out.
-- layout.exemplars holds the same list, so a block can pick one by index.
function M.drawnExemplars(
	list: { FrameProm.Exemplar },
	from_ms: number,
	to_ms: number
): ({ FrameProm.Exemplar }, number)
	local inRange: { FrameProm.Exemplar } = {}
	for _, e in list do
		if e.time_ms >= from_ms and e.time_ms <= to_ms then
			table.insert(inRange, e)
		end
	end
	FrameProm.sortExemplars(inRange)
	local n = #inRange
	if n <= M.EXEMPLAR_CAP then
		return inRange, 0
	end
	local kept: { FrameProm.Exemplar } = table.create(M.EXEMPLAR_CAP)
	for k = 1, M.EXEMPLAR_CAP do
		kept[k] = inRange[math.floor((k - 1) * n / M.EXEMPLAR_CAP) + 1]
	end
	return kept, n - M.EXEMPLAR_CAP
end

-- Per-series styles: the given ones, or the shared scale settings for all.
local function stylesFor(list: { Series.Series }, opts: Options): { SeriesStyle }
	local out: { SeriesStyle } = table.create(#list)
	if opts.series then
		for i = 1, math.max(1, #list) do
			out[i] = opts.series[i] or {}
		end
		return out
	end
	local shared: SeriesStyle = {
		unit = opts.unit or (if list[1] then list[1].unit else nil),
		decimals = if opts.decimals ~= nil then opts.decimals elseif list[1] then list[1].decimals else nil,
		min = opts.min,
		max = opts.max,
		stack = opts.stack,
		thresholds = opts.thresholds,
		threshold_style = opts.threshold_style,
	}
	for i = 1, math.max(1, #list) do
		out[i] = shared
	end
	return out
end

function M.render(frames: { Frame }, options: Options?): Result
	local opts: Options = options or {}
	local W = opts.width or 960
	local H = opts.height or 300
	local all = Series.extract(frames, opts.legend)

	-- Time domain.
	local tFrom, tTo = opts.from_ms, opts.to_ms
	if tFrom == nil or tTo == nil then
		local lo, hi = math.huge, -math.huge
		for _, s in all do
			if #s.times > 0 then
				lo = math.min(lo, s.times[1])
				hi = math.max(hi, s.times[#s.times])
			end
		end
		if lo > hi then
			lo, hi = 0, 1
		end
		tFrom = tFrom or lo
		tTo = tTo or hi
	end
	local tFrom_ = tFrom :: number
	local tTo_ = tTo :: number
	if tTo_ <= tFrom_ then
		tFrom_, tTo_ = tFrom_ - 30000, tTo_ + 30000
	end

	local marks: { FrameProm.Exemplar }?, marksDropped = nil, 0
	if opts.exemplars then
		marks, marksDropped = M.drawnExemplars(opts.exemplars, tFrom_, tTo_)
	end
	local fixed = FIXED_BYTES + (if marks then #marks * BYTES_EXEMPLAR else 0)
	if opts.annotations then
		fixed += math.min(#opts.annotations.marks, Annotations.CAP) * Annotations.BYTES
	end

	-- Every series is drawn, as in Grafana: the point budget shrinks with
	-- their number. Only series that would not fit the size cap even at
	-- MIN_POINTS samples each are left out (reported as `dropped`).
	local allStyles = stylesFor(all, opts)
	local keep, minBytes = #all, 0
	for i = 1, #all do
		local look = lookOf(i, allStyles[i], opts, #all)
		local cost = seriesBytes(look) + MIN_POINTS * sampleBytes(look)
		if minBytes + cost > M.TARGET - fixed then
			keep = i - 1
			break
		end
		minBytes += cost
	end
	local list = all
	local styles = allStyles
	if keep < #all then
		list = table.move(all, 1, keep, 1, {})
		styles = table.move(allStyles, 1, math.max(1, keep), 1, {})
	end
	local dropped = #all - #list

	local specs, scaleOf = scaleSpecs(styles)
	-- An empty chart still has its (empty) first scale.
	for _, spec in specs do
		table.clear(spec.members)
	end
	for i = 1, #list do
		table.insert(specs[scaleOf[i]].members, i)
	end
	local shown = Data.transformed(list, styles, tFrom_, tTo_)
	-- The samples in view plus the nearest one beyond each end (Data.window):
	-- `view` bounds the samples in view of a series with others outside
	-- them, `outside` is set when a drawn sample lies outside the time range.
	-- `plain`: a series drawn from its own samples (Data.ownValues).
	local view: { [number]: { number } } = {}
	local plain: { boolean } = table.create(#list)
	local outside = false
	for i, s in shown do
		local cut, t0, t1, asc = Data.window(s, tFrom_, tTo_)
		plain[i] = asc and s == list[i]
		local times = cut.times
		local n = #times
		if t0 and t1 and (t0 > s.times[1] or t1 < s.times[#s.times]) then
			view[i] = { t0, t1 }
		end
		if n > 0 and (times[1] < tFrom_ or times[n] > tTo_) then
			outside = true
		end
		shown[i] = cut
	end
	local looks: { Look } = table.create(#list)
	local spans: { boolean | number } = table.create(#list)
	for i = 1, #list do
		looks[i] = lookOf(i, styles[i], opts, #list)
		spans[i] = looks[i].span
	end

	local plotTop, plotBottom = PAD_TOP, H - X_AXIS_H
	local plotH = plotBottom - plotTop
	-- Bytes per drawn sample over all series, and the series' own elements.
	local estimate = 0
	for _, look in looks do
		estimate += sampleBytes(look)
		fixed += seriesBytes(look)
	end
	-- Gradient definitions: their stops, doubled for discrete edges.
	for _, look in looks do
		if look.hue then
			fixed += BYTES_GRADIENT + 2 * BYTES_STOP
		elseif look.scheme then
			fixed += BYTES_GRADIENT + 2 * #look.scheme.stops * BYTES_STOP
		end
	end

	local perSeries = opts.point_budget or math.floor(W - PAD_RIGHT)
	if #list > 0 then
		perSeries = math.min(perSeries, math.floor((M.TARGET - fixed) / estimate))
	end
	perSeries = math.max(MIN_POINTS, perSeries)

	-- What is drawn; `list` keeps the samples the legend calcs read.
	local barList: { Series.Series } = {}
	local barAt: { number } = {}
	for i, look in looks do
		if look.draw == "bars" then
			table.insert(barList, shown[i])
			table.insert(barAt, i)
		end
	end
	if #barList > 0 then
		local slots = math.floor((W - PAD_RIGHT - 36) / M.MIN_BAR_PX)
		for k, s in Data.bucketBars(barList, tFrom_, tTo_, slots) do
			if s ~= barList[k] then
				-- Buckets hold only the samples in the range.
				view[barAt[k]] = nil
				plain[barAt[k]] = false
			end
			shown[barAt[k]] = s
		end
	end
	local groups = Data.stackGroups(shown, styles, scaleOf)
	-- The legend calcs over each full-resolution series; they also bound
	-- the scale of a series drawn as extracted.
	local calcs: { Series.Calcs } = table.create(#list)
	for i, s in list do
		calcs[i] = Series.calcs(s.values)
	end

	-- Scales and axis bands depend on the plot height only.
	local plot = Data.downsample(shown, groups, spans, perSeries)
	local scales: { Axis.Scale } = table.create(#specs)
	local labels: { { string } } = table.create(#specs)
	local widths: { number } = table.create(#specs)
	local leftW, rightW = 0, 0
	for k, spec in specs do
		local lo, hi = scaleRange(shown, list, calcs, plot, spec.members, view)
		-- Exemplars share the first scale (as in Grafana): a marker pinned
		-- to the plot edge would misstate its value. Percent stacks keep 0..1.
		if k == 1 and marks and not spec.percent then
			for _, e in marks do
				lo = if lo == nil then e.value else math.min(lo :: number, e.value)
				hi = if hi == nil then e.value else math.max(hi :: number, e.value)
			end
		end
		scales[k] = buildScale(spec, lo, hi, opts.tick_height or plotH)
		local st = spec.style
		local unit = if spec.percent then "percentunit" else st.unit
		labels[k] = yLabels(scales[k], unit, st.decimals)
		if spec.side ~= "hidden" then
			local chars = 0
			for _, label in labels[k] do
				chars = math.max(chars, utf8.len(label) or #label)
			end
			local w = math.max(AXIS_MIN_W, chars * Axis.CHAR_PX + 12)
			if st.label ~= nil and st.label ~= "" then
				w += AXIS_LABEL_W
			end
			widths[k] = w
			if spec.side == "left" then
				leftW += w
			else
				rightW += w
			end
		end
	end
	local plotLeft = if leftW > 0 then leftW else PAD_RIGHT
	local plotRight = W - (if rightW > 0 then rightW else PAD_RIGHT)
	local axes: { YAxis } = table.create(#specs)
	local nextLeft, nextRight = plotLeft, plotRight
	for k, spec in specs do
		local s = scales[k]
		local x0, x1 = 0, 0
		if spec.side == "left" then
			x1 = nextLeft
			x0 = x1 - widths[k]
			nextLeft = x0
		elseif spec.side == "right" then
			x0 = nextRight
			x1 = x0 + widths[k]
			nextRight = x1
		end
		axes[k] = {
			key = spec.key,
			side = spec.side,
			min = s.min,
			max = s.max,
			distr = s.distr,
			log = s.log,
			linear_threshold = s.linear_threshold,
			unit = if spec.percent then "percentunit" else spec.style.unit,
			decimals = spec.style.decimals,
			label = spec.style.label,
			x0 = x0,
			x1 = x1,
		}
	end

	local svg, layout = "", (nil :: any) :: Layout
	for attempt = 1, 8 do
		if attempt > 1 then
			plot = Data.downsample(shown, groups, spans, perSeries)
		end
		local first = axes[1]
		layout = {
			width = W,
			height = H,
			plot_left = plotLeft,
			plot_right = plotRight,
			plot_top = plotTop,
			plot_bottom = plotBottom,
			t_from = tFrom_,
			t_to = tTo_,
			y_min = first.min,
			y_max = first.max,
			unit = first.unit,
			decimals = first.decimals,
			axes = axes,
			times = {},
			series = {},
			dropped = dropped,
			exemplars = marks,
			exemplars_dropped = if marks then marksDropped else nil,
		}
		local extra: number
		svg, extra = build({
			shown = shown,
			plot = plot,
			layout = layout,
			opts = opts,
			styles = styles,
			looks = looks,
			specs = specs,
			scales = scales,
			labels = labels,
			scaleOf = scaleOf,
		})
		local size = #svg + extra
		if size <= M.TARGET or perSeries <= MIN_POINTS then
			break
		end
		perSeries = math.max(MIN_POINTS, math.floor(perSeries * M.TARGET / size * 0.9))
	end
	assert(#svg <= M.CAP, "svg_timeseries: chart exceeds the 256 KiB SVG cap")
	local drawn: { DrawnSeries } = table.create(#list)
	local points = 0
	for i, s in list do
		local st = styles[i]
		drawn[i] = {
			name = s.name,
			class = looks[i].class,
			labels = s.labels,
			times = plot.times[i],
			values = Data.ownValues(s, plain[i], st, plot, i, spans),
			calcs = calcs[i],
			axis = scaleOf[i],
			unit = st.unit,
			decimals = st.decimals,
			hide_legend = st.hide_legend,
			hide_tooltip = st.hide_tooltip,
		}
		points += #plot.times[i]
	end
	layout.series = drawn
	local stops = Data.unionTimes(plot)
	if outside then
		local inRange: { number } = {}
		for _, t in stops do
			if t >= tFrom_ and t <= tTo_ then
				table.insert(inRange, t)
			end
		end
		stops = inRange
	end
	layout.times = stops
	return { svg = svg, layout = layout, dropped = dropped, points = points }
end

return M
