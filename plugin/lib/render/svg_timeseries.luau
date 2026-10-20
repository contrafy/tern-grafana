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
-- Tern refuses SVGs over 256 KiB, so the renderer downsamples each series
-- (LTTB) to a point budget derived from a byte budget, drops series beyond
-- the cap (reported as `dropped`), and shrinks the budget until the document
-- fits.
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
-- Exemplars are diamonds in one `tg-exemplar` path over the series, at most
-- EXEMPLAR_CAP of them (thinned evenly over time); layout.exemplars lists
-- the ones drawn so a block can select one by index. They share the first
-- series' scale.

local Axis = require("./axis")
local Format = require("../units/format")
local Frame = require("../frame/types")
local FrameProm = require("../frame/prom")
local Layout = require("./layout")
local Lttb = require("../time/lttb")
local Series = require("./series")
local Thresholds = require("../units/thresholds")
local Tbl = require("../tbl")

type Frame = Frame.Frame
type Layout = Layout.Layout
type DrawnSeries = Layout.DrawnSeries
type YAxis = Layout.YAxis

export type ThresholdStyle = "off" | "line" | "area" | "line+area"
export type Draw = "line" | "bars" | "points"
export type Placement = "auto" | "left" | "right" | "hidden"
export type Transform = "negative-Y" | "constant"
-- Grafana custom.scaleDistribution: type linear|log|symlog, log base 2|10,
-- linearThreshold for symlog.
export type Distribution = { type: Axis.Distr, log: number?, linear_threshold: number? }

export type Interpolation = "linear" | "smooth" | "stepBefore" | "stepAfter"
export type ShowPoints = "auto" | "always" | "never"
export type Gradient = "none" | "opacity"

-- One series' GraphFieldConfig: its scale, stacking and how it is drawn
-- (packages/grafana-ui/src/components/uPlot/config/UPlotSeriesBuilder.ts).
-- Draw fields left nil fall back to the shared Options (draw,
-- fill_opacity, null_mode) and Grafana's defaults.
export type SeriesStyle = {
	unit: string?,
	decimals: number?,
	-- Hard bounds (fieldConfig min/max).
	min: number?,
	max: number?,
	-- custom.axisSoftMin/Max: the scale reaches at least this far.
	soft_min: number?,
	soft_max: number?,
	-- custom.axisCenteredZero.
	centered_zero: boolean?,
	placement: Placement?,
	-- custom.axisLabel.
	label: string?,
	-- custom.axisGridShow (default true).
	grid: boolean?,
	distribution: Distribution?,
	transform: Transform?,
	stack: Series.StackMode?,
	-- custom.stacking.group (default "A").
	stack_group: string?,
	thresholds: Thresholds.Thresholds?,
	threshold_style: ThresholdStyle?,
	hide_legend: boolean?,
	hide_tooltip: boolean?,
	-- Class list the series is painted with (default the palette class of
	-- its position, M.seriesClass).
	class: string?,
	-- custom.drawStyle.
	draw: Draw?,
	-- custom.lineWidth in px (default 1; 0 draws no line).
	line_width: number?,
	-- custom.lineStyle: dash lengths (nil solid) and whether it is dotted
	-- (round caps).
	dash: { number }?,
	dot: boolean?,
	interpolation: Interpolation?,
	-- custom.fillOpacity 0..100 and custom.gradientMode.
	fill_opacity: number?,
	gradient: Gradient?,
	-- custom.showPoints and custom.pointSize (diameter px, default 5).
	show_points: ShowPoints?,
	point_size: number?,
	-- custom.spanNulls: true joins across missing samples, a number joins
	-- only gaps up to that many ms.
	span_nulls: (boolean | number)?,
	-- custom.fillBelowTo: index (in extraction order) of the series the
	-- fill runs down to.
	fill_below: number?,
	-- custom.barAlignment (-1 before, 0 center, 1 after), barWidthFactor,
	-- barMaxWidth (px).
	bar_alignment: number?,
	bar_width_factor: number?,
	bar_max_width: number?,
}

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
	series_cap: number?,
	-- Most samples drawn per series (default: one per plot pixel).
	point_budget: number?,
	-- Visible time range (default: the data's extent).
	from_ms: number?,
	to_ms: number?,
	-- Tick labels' fixed offset, minutes east of UTC.
	offset_min: number?,
	-- Grafana legendFormat for series names.
	legend: string?,
	-- Exemplar markers (any order); those in the time range are drawn, at
	-- most EXEMPLAR_CAP of them.
	exemplars: { FrameProm.Exemplar }?,
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

local NULL = Frame.NULL
local finite = Frame.finite
local fmt = string.format

local PAD_TOP = 8
local PAD_RIGHT = 12
local X_AXIS_H = 24
-- Narrowest y axis band, and the extra band an axis label takes.
local AXIS_MIN_W = 36
local AXIS_LABEL_W = 18
-- Bytes per drawn sample, measured on this generator's output.
local BYTES_LINE = 12
local BYTES_BAR = 30
local FIXED_BYTES = 8 * 1024
-- "M123.4 56.7l4 4l-4 4l-4 -4Z" per exemplar marker.
local BYTES_EXEMPLAR = 32
-- Beyond this, tick labels use automatic decimals.
local MAX_TICK_DECIMALS = 4

local function escape(s: string): string
	return (string.gsub(s, '[&<>"]', { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

function M.seriesClass(i: number): string
	return "tg-s" .. tostring((i - 1) % M.PALETTE + 1)
end

-- Values at chosen indices of a column.
local function pick(col: { any }, idx: { number }): { any }
	local out: { any } = table.create(#idx)
	for k, i in idx do
		out[k] = col[i]
	end
	return out
end

local function presentOnly(times: { number }, values: { any }): ({ number }, { any })
	local t2: { number }, v2: { any } = {}, {}
	for i, t in times do
		if finite(values[i]) then
			table.insert(t2, t)
			table.insert(v2, values[i])
		end
	end
	return t2, v2
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

local function distr(st: SeriesStyle): Axis.Distr
	local d = st.distribution
	return if d then d.type else "linear"
end

-- The series as drawn: negated (negative-Y), flattened to its first value
-- across the time range (constant), non-positive values dropped on a log
-- scale (uPlot cannot place them).
local function transformed(
	list: { Series.Series },
	styles: { SeriesStyle },
	tFrom: number,
	tTo: number
): { Series.Series }
	local out: { Series.Series } = table.create(#list)
	for i, s in list do
		local st = styles[i]
		local log = distr(st) == "log"
		if st.transform == "constant" then
			local first: number? = nil
			for _, v in s.values do
				first = finite(v)
				if first then
					break
				end
			end
			local copy = Tbl.copy(s)
			copy.times = { tFrom, tTo }
			local v: any = if first == nil or (log and first <= 0) then NULL else first
			copy.values = { v, v }
			out[i] = copy
		elseif st.transform == "negative-Y" or log then
			local neg = st.transform == "negative-Y"
			local values: { any } = table.create(#s.values)
			for j, raw in s.values do
				local v = finite(raw)
				if v and neg then
					v = -v
				end
				values[j] = if v == nil or (log and v <= 0) then NULL else v
			end
			local copy = Tbl.copy(s)
			copy.values = values
			out[i] = copy
		else
			out[i] = s
		end
	end
	return out
end

type StackGroup = { mode: Series.StackMode, neg: boolean, members: { number } }

-- getStackingGroups: one group per direction (a series with a negative
-- sample after its transform stacks down), mode, group and scale.
local function stackGroups(shown: { Series.Series }, styles: { SeriesStyle }, scaleOf: { number }): { StackGroup }
	local groups: { StackGroup } = {}
	local byKey: { [string]: StackGroup } = {}
	for i = 1, #shown do
		local st = styles[i]
		local mode: Series.StackMode = st.stack or "none"
		if mode == "none" or st.transform == "constant" then
			continue
		end
		local neg = false
		for _, v in shown[i].values do
			local n = finite(v)
			if n and n < 0 then
				neg = true
				break
			end
		end
		local key = fmt("%s|%s|%s|%d", if neg then "neg" else "pos", mode, st.stack_group or "A", scaleOf[i])
		local g = byKey[key]
		if g == nil then
			g = { mode = mode, neg = neg, members = {} }
			byKey[key] = g
			table.insert(groups, g :: StackGroup)
		end
		table.insert((g :: StackGroup).members, i)
	end
	return groups
end

type Plot = {
	-- Per series: times, values as drawn (transformed, not stacked), values
	-- to plot (stacked tops), and the base each fill or bar starts from
	-- (nil: the axis baseline).
	times: { { number } },
	raw: { { any } },
	tops: { { any } },
	bottoms: { { number }? },
	stacked: { [number]: boolean },
}

-- spanNulls: true drops the missing samples (the line joins across them);
-- a number joins only where the present samples around a gap are at most
-- that many ms apart, a longer gap keeps its first missing sample.
local function spanned(times: { number }, values: { any }, span: boolean | number): ({ number }, { any })
	if span == true then
		return presentOnly(times, values)
	end
	local limit = span :: number
	local t2: { number }, v2: { any } = {}, {}
	local lastT: number? = nil
	local gapAt: number? = nil
	for i, t in times do
		if finite(values[i]) then
			if gapAt and lastT and t - lastT > limit then
				table.insert(t2, gapAt)
				table.insert(v2, NULL)
			end
			table.insert(t2, t)
			table.insert(v2, values[i])
			lastT, gapAt = t, nil
		elseif gapAt == nil then
			gapAt = t
		end
	end
	return t2, v2
end

local function downsample(
	shown: { Series.Series },
	groups: { StackGroup },
	spans: { boolean | number },
	perSeries: number
): Plot
	local plot: Plot = { times = {}, raw = {}, tops = {}, bottoms = {}, stacked = {} }
	for _, g in groups do
		local sub: { Series.Series } = table.create(#g.members)
		for k, i in g.members do
			sub[k] = shown[i]
			plot.stacked[i] = true
		end
		local times, columns = Series.join(sub)
		local tops, bottoms = Series.stack(columns, g.mode)
		-- One index set for the whole group keeps the stack aligned: LTTB on
		-- the stack's outer envelope.
		local envelope: { any } = table.create(#times)
		for j = 1, #times do
			local edge: number? = nil
			for k = 1, #tops do
				local v = finite(tops[k][j])
				if v and (edge == nil or (if g.neg then v < edge else v > edge)) then
					edge = v
				end
			end
			envelope[j] = if edge == nil then NULL else edge
		end
		local keptT = Lttb.downsample(times, envelope, perSeries, NULL)
		local idx: { number }
		if keptT == times then
			idx = table.create(#times)
			for j = 1, #times do
				idx[j] = j
			end
		else
			local at: { [number]: number } = {}
			for j, t in times do
				at[t] = j
			end
			idx = table.create(#keptT)
			for k, t in keptT do
				idx[k] = at[t]
			end
		end
		local drawnT = pick(times, idx) :: { number }
		for k, i in g.members do
			plot.times[i] = drawnT
			plot.raw[i] = pick(columns[k], idx)
			plot.tops[i] = pick(tops[k], idx)
			plot.bottoms[i] = pick(bottoms[k], idx) :: { number }
		end
	end
	for i, s in shown do
		if plot.stacked[i] then
			continue
		end
		local t, v = s.times, s.values
		if spans[i] ~= false then
			t, v = spanned(t, v, spans[i])
		end
		local dt, dv = Lttb.downsample(t, v, perSeries, NULL)
		plot.times[i] = dt
		plot.raw[i] = dv
		plot.tops[i] = dv
	end
	return plot
end

-- The data extent of each scale: stacked tops and bases, or the full-
-- resolution values (so downsampling never moves an axis).
local function scaleRange(shown: { Series.Series }, plot: Plot, members: { number }): (number?, number?)
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
		if plot.stacked[i] then
			for _, v in plot.tops[i] do
				see(v)
			end
			local b = plot.bottoms[i]
			if b then
				for _, v in b do
					see(v)
				end
			end
		else
			local c = Series.calcs(shown[i].values)
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
	local kind = distr(st)
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
	return Axis.rangeScale(a, b, plotPx)
end

-- The fewest decimals (up to MAX_TICK_DECIMALS) that print `v` exactly in
-- its display unit, or nil when none does.
local function exactDecimals(v: number, unit: string?): number?
	local function trimmed(s: string): string
		if string.find(s, ".", 1, true) then
			s = string.gsub(string.gsub(s, "0+$", ""), "%.$", "")
		end
		return s
	end
	local exact = trimmed(Format.format(v, unit, 10).text)
	for d = 0, MAX_TICK_DECIMALS do
		if trimmed(Format.format(v, unit, d).text) == exact then
			return d
		end
	end
	return nil
end

local function yLabels(scale: Axis.Scale, unit: string?, decimals: number?): { string }
	local function render(d: number?): { string }
		local out: { string } = table.create(#scale.ticks)
		for i, v in scale.ticks do
			out[i] = Format.text(v, unit, d)
		end
		return out
	end
	if decimals ~= nil then
		return render(decimals)
	end
	if (scale.distr or "linear") ~= "linear" then
		-- Ticks a magnitude apart: each prints with its own decimals.
		local out: { string } = table.create(#scale.ticks)
		for i, v in scale.ticks do
			out[i] = Format.text(v, unit, exactDecimals(v, unit))
		end
		return out
	end
	-- One decimals count for every tick, the fewest that print each tick
	-- exactly in its display unit: a 0.25 step reads 0.25/0.50 (not 0.3),
	-- a 0.2 percentunit step reads 20% (not 20.0%), 1.5 MiB keeps its .5.
	local common = 0
	for _, v in scale.ticks do
		local d = exactDecimals(v, unit)
		if d == nil then
			-- Not a short decimal in this unit (1500 B = 1.46484375 KiB):
			-- Grafana's automatic three significant digits.
			return render(nil)
		end
		common = math.max(common, d)
	end
	local labels = render(common)
	for i = 2, #labels do
		if labels[i] == labels[i - 1] then
			return render(nil)
		end
	end
	return labels
end

local function num(v: number): string
	return fmt("%.1f", v)
end

type Geometry = {
	layout: Layout,
	xOf: (number) -> number,
	yOf: (number) -> number,
}

-- Runs of present samples as pixel points {x1, y1, x2, y2, ...}, split at
-- missing samples.
local function runs(g: Geometry, times: { number }, values: { any }): { { number } }
	local out: { { number } } = {}
	local cur: { number }? = nil
	for i, t in times do
		local v = finite(values[i])
		if v then
			if cur == nil then
				cur = {}
				table.insert(out, cur :: { number })
			end
			local c = cur :: { number }
			table.insert(c, g.xOf(t))
			table.insert(c, g.yOf(v))
		else
			cur = nil
		end
	end
	return out
end

-- Monotone cubic tangents (Steffen; uPlot's spline path builder uses a
-- monotone cubic), so a smoothed line never overshoots its samples.
local function tangents(p: { number }): { number }
	local n = #p // 2
	local m: { number } = table.create(n, 0)
	local function slope(k: number): number
		local h = p[2 * k + 1] - p[2 * k - 1]
		return if h ~= 0 then (p[2 * k + 2] - p[2 * k]) / h else 0
	end
	for k = 2, n - 1 do
		local h0 = p[2 * k - 1] - p[2 * k - 3]
		local h1 = p[2 * k + 1] - p[2 * k - 1]
		local s0, s1 = slope(k - 1), slope(k)
		local q = if h0 + h1 ~= 0 then (s0 * h1 + s1 * h0) / (h0 + h1) else 0
		local sign = (if s0 > 0 then 1 elseif s0 < 0 then -1 else 0) + (if s1 > 0 then 1 elseif s1 < 0 then -1 else 0)
		m[k] = sign * math.min(math.abs(s0), math.abs(s1), 0.5 * math.abs(q))
	end
	if n >= 2 then
		local s = slope(1)
		m[1] = if n > 2 then (3 * s - m[2]) / 2 else s
		local e = slope(n - 1)
		m[n] = if n > 2 then (3 * e - m[n - 1]) / 2 else e
	end
	return m
end

-- One edge through pixel points `p` in order, starting with `first` ("M" or
-- "L") at its first point: straight, stepped (stepAfter holds a value until
-- the next sample, stepBefore takes the next value at once) or smoothed.
local function edge(buf: { string }, p: { number }, interp: Interpolation, first: string)
	table.insert(buf, fmt("%s%.1f %.1f", first, p[1], p[2]))
	local n = #p // 2
	if n == 1 then
		return
	end
	if interp == "stepAfter" or interp == "stepBefore" then
		-- Walking right to left swaps which end of a step comes first.
		local after = (interp == "stepAfter") == (p[3] >= p[1])
		for k = 2, n do
			local x, y = p[2 * k - 1], p[2 * k]
			if after then
				table.insert(buf, fmt("H%.1fV%.1f", x, y))
			else
				table.insert(buf, fmt("V%.1fH%.1f", y, x))
			end
		end
	elseif interp == "smooth" and n > 2 then
		local m = tangents(p)
		for k = 1, n - 1 do
			local x0, y0, x1, y1 = p[2 * k - 1], p[2 * k], p[2 * k + 1], p[2 * k + 2]
			local h = (x1 - x0) / 3
			table.insert(
				buf,
				fmt("C%.1f %.1f %.1f %.1f %.1f %.1f", x0 + h, y0 + h * m[k], x1 - h, y1 - h * m[k + 1], x1, y1)
			)
		end
	else
		table.insert(buf, "L")
		for k = 2, n do
			table.insert(buf, fmt(if k == 2 then "%.1f %.1f" else " %.1f %.1f", p[2 * k - 1], p[2 * k]))
		end
	end
end

-- The line through each run. A lone sample becomes a zero-length segment,
-- which a round cap still draws as a dot.
local function pathLine(buf: { string }, g: Geometry, times: { number }, values: { any }, interp: Interpolation)
	for _, p in runs(g, times, values) do
		edge(buf, p, interp, "M")
		if #p == 2 then
			table.insert(buf, "h0")
		end
	end
end

-- Dots (zero-length round-capped segments) at the samples; `lone` keeps
-- only samples with no present neighbor (uPlot's points filter for gaps).
local function pathDots(buf: { string }, g: Geometry, times: { number }, values: { any }, lone: boolean)
	for _, p in runs(g, times, values) do
		if not lone or #p == 2 then
			for k = 1, #p, 2 do
				table.insert(buf, fmt("M%.1f %.1fh0", p[k], p[k + 1]))
			end
		end
	end
end

-- Closed areas between each run of present values and its base: the
-- stacked bottoms, the values of the fillBelowTo series (`below`, by
-- time), or the axis baseline.
local function pathArea(
	buf: { string },
	g: Geometry,
	times: { number },
	tops: { any },
	bottoms: { number }?,
	below: { [number]: number }?,
	base: number,
	interp: Interpolation
)
	local n = #times
	local runStart: number? = nil
	for i = 1, n + 1 do
		local v = if i <= n then finite(tops[i]) else nil
		if v and below and below[times[i]] == nil then
			v = nil
		end
		if v and runStart == nil then
			runStart = i
		elseif v == nil and runStart ~= nil then
			local s, e = runStart, i - 1
			local top: { number } = {}
			for j = s, e do
				table.insert(top, g.xOf(times[j]))
				table.insert(top, g.yOf(finite(tops[j]) :: number))
			end
			edge(buf, top, interp, "M")
			if bottoms or below then
				local bot: { number } = {}
				for j = e, s, -1 do
					table.insert(bot, g.xOf(times[j]))
					local b = if bottoms then bottoms[j] else (below :: { [number]: number })[times[j]]
					table.insert(bot, g.yOf(b))
				end
				edge(buf, bot, interp, "L")
			else
				local yb = num(g.yOf(base))
				table.insert(buf, fmt("L%.1f %s %.1f %s", g.xOf(times[e]), yb, g.xOf(times[s]), yb))
			end
			table.insert(buf, "Z")
			runStart = nil
		end
	end
end

-- Bars `barW` wide, centered on their time (align 0), ending at it (-1) or
-- starting at it (1), as uPlot's bars path builder places them.
local function pathBars(
	buf: { string },
	g: Geometry,
	times: { number },
	tops: { any },
	bottoms: { number }?,
	base: number,
	barW: number,
	align: number
)
	local shift = if align == 1 then 0 elseif align == -1 then -barW else -barW / 2
	for i, t in times do
		local v = finite(tops[i])
		if v then
			-- uPlot clips the plot; bars at its edges are cut to it.
			local layout = g.layout
			local x = math.max(layout.plot_left, g.xOf(t) + shift)
			local w = math.min(layout.plot_right, g.xOf(t) + shift + barW) - x
			if w > 0 then
				local y0 = g.yOf(if bottoms then bottoms[i] else base)
				table.insert(buf, fmt("M%.1f %.1fV%.1fh%.1fV%.1fZ", x, y0, g.yOf(v), w, y0))
			end
		end
	end
end

local function thresholdShapes(out: { string }, g: Geometry, scale: Axis.Scale, st: SeriesStyle)
	local style = st.threshold_style or "off"
	local spec = st.thresholds
	if style == "off" or spec == nil or #spec.steps == 0 then
		return
	end
	local layout = g.layout
	local percent = spec.mode == "percentage"
	local steps = Tbl.copy(spec.steps)
	local function at(step: Thresholds.Step): number
		local v = step.value
		if type(v) ~= "number" then
			return -math.huge
		end
		return if percent then scale.min + (scale.max - scale.min) * v / 100 else v
	end
	table.sort(steps, function(a, b)
		return at(a) < at(b)
	end)
	local l, r = layout.plot_left, layout.plot_right
	if style == "area" or style == "line+area" then
		for k, step in steps do
			local lo = math.max(at(step), scale.min)
			local hi = if k < #steps then math.min(at(steps[k + 1]), scale.max) else scale.max
			if hi > lo then
				local yTop, yBot = g.yOf(hi), g.yOf(lo)
				table.insert(
					out,
					fmt(
						'<rect class="tg-tharea tg-th-%s" x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill-opacity="0.12"/>',
						Thresholds.tone(step.color),
						l,
						yTop,
						r - l,
						yBot - yTop
					)
				)
			end
		end
	end
	if style == "line" or style == "line+area" then
		for _, step in steps do
			local v = at(step)
			if v > scale.min and v <= scale.max then
				table.insert(
					out,
					fmt(
						'<path class="tg-th tg-th-%s" d="M%.1f %.1fH%.1f" fill="none" stroke-width="1" stroke-dasharray="10 10"/>',
						Thresholds.tone(step.color),
						l,
						g.yOf(v),
						r
					)
				)
			end
		end
	end
end

-- How one series is drawn, its SeriesStyle resolved against the shared
-- options and Grafana's GraphFieldConfig defaults.
type Look = {
	class: string,
	draw: Draw,
	-- 0..1.
	fill: number,
	gradient: Gradient,
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
	table.insert(
		out,
		fmt(
			'<text class="tg-label" x="%.1f" y="%.1f" font-size="12" text-anchor="middle" transform="rotate(%d %.1f %.1f)">%s</text>',
			x,
			cy,
			if a.side == "left" then -90 else 90,
			x,
			cy,
			escape(label)
		)
	)
end

local function build(ctx: Ctx): string
	local layout, plot, opts = ctx.layout, ctx.plot, ctx.opts
	local out: { string } = {}
	local W, H = layout.width, layout.height
	local top, bottom = layout.plot_top, layout.plot_bottom
	local axes = layout.axes :: { YAxis }
	local function xOf(t: number): number
		return math.clamp(Layout.xOfTime(layout, t), layout.plot_left, layout.plot_right)
	end
	local geo: { Geometry } = table.create(#axes)
	for k in axes do
		geo[k] = {
			layout = layout,
			xOf = xOf,
			yOf = function(v: number): number
				return math.clamp(Layout.yOfValue(layout, v, k), top, bottom)
			end,
		}
	end
	table.insert(
		out,
		fmt(
			'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" class="tg-chart">',
			W,
			H,
			W,
			H
		)
	)

	-- Grid and axis labels.
	local ticks = Axis.timeTicks(layout.t_from, layout.t_to, layout.plot_right - layout.plot_left, opts.offset_min)
	local grid: { string } = {}
	for k, a in axes do
		local scale = ctx.scales[k]
		if a.side ~= "hidden" and ctx.specs[k].style.grid ~= false then
			for _, v in scale.ticks do
				if v >= scale.min and v <= scale.max then
					table.insert(grid, fmt("M%.1f %.1fH%.1f", layout.plot_left, geo[k].yOf(v), layout.plot_right))
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
			if v >= scale.min and v <= scale.max then
				table.insert(
					out,
					fmt(
						'<text class="tg-label" x="%.1f" y="%.1f" font-size="12" text-anchor="%s">%s</text>',
						if left then a.x1 - 6 else a.x0 + 6,
						geo[k].yOf(v) + 4,
						if left then "end" else "start",
						escape(labels[i])
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
			table.insert(
				out,
				fmt(
					'<text class="tg-label" x="%.1f" y="%.1f" font-size="12" text-anchor="middle">%s</text>',
					x,
					H - 6,
					escape(ticks.labels[i])
				)
			)
		end
	end

	-- Thresholds: per scale, from its first series that shows them
	-- (UPlotConfigBuilder addThresholds keeps the first per scale key).
	for k, spec in ctx.specs do
		for _, i in spec.members do
			local st = ctx.styles[i]
			if (st.threshold_style or "off") ~= "off" and st.thresholds then
				thresholdShapes(out, geo[k], ctx.scales[k], st)
				break
			end
		end
	end

	-- Series: fills and bars first, lines and points on top
	-- (UPlotSeriesBuilder: each series' own draw style, line, fill, points).
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
	local slots = 1
	for i = 1, #list do
		if looks[i].draw == "bars" then
			slots = math.max(slots, #plot.times[i])
		end
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
	for i = 1, #list do
		local look = looks[i]
		if look.fill <= 0 or look.draw == "points" then
			continue
		end
		local g = geo[ctx.scaleOf[i]]
		local buf: { string } = {}
		local role = "tg-area"
		if look.draw == "bars" then
			role = "tg-bar"
			local barW = math.max(1, math.min(look.bar_max_width, plotW / slots * look.bar_width_factor))
			pathBars(buf, g, plot.times[i], plot.tops[i], plot.bottoms[i], baseOf(i), barW, look.bar_alignment)
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
			pathArea(buf, g, plot.times[i], plot.tops[i], plot.bottoms[i], below, baseOf(i), look.interpolation)
		end
		if #buf > 0 then
			local mask = if fade and look.gradient == "opacity" then fmt(' mask="url(#%s)"', fade) else ""
			table.insert(
				out,
				fmt(
					'<path class="%s %s" fill-opacity="%.2f"%s d="%s"/>',
					look.class,
					role,
					look.fill,
					mask,
					table.concat(buf)
				)
			)
		end
	end
	for i = 1, #list do
		local look = looks[i]
		local g = geo[ctx.scaleOf[i]]
		local stroke = look.line_width * M.LINE_SCALE
		if look.draw ~= "points" and stroke > 0 then
			local buf: { string } = {}
			if look.draw == "bars" then
				local barW = math.max(1, math.min(look.bar_max_width, plotW / slots * look.bar_width_factor))
				pathBars(buf, g, plot.times[i], plot.tops[i], plot.bottoms[i], baseOf(i), barW, look.bar_alignment)
			else
				pathLine(buf, g, plot.times[i], plot.tops[i], look.interpolation)
			end
			if #buf > 0 then
				local dash = ""
				if look.dash then
					local parts: { string } = table.create(#look.dash)
					for k, d in look.dash do
						parts[k] = fmt("%g", d * M.LINE_SCALE)
					end
					dash = ' stroke-dasharray="' .. table.concat(parts, " ") .. '"'
				end
				-- uPlot strokes with butt caps; dotted lines get round ones.
				-- Solid lines keep round caps so a lone sample shows as a dot.
				local cap = if look.dash and not look.dot then "butt" else "round"
				table.insert(
					out,
					fmt(
						'<path class="%s tg-line" fill="none" stroke-width="%s" stroke-linecap="%s" stroke-linejoin="round"%s d="%s"/>',
						look.class,
						fmt("%g", stroke),
						cap,
						dash,
						table.concat(buf)
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
			for _, v in plot.tops[i] do
				if finite(v) then
					n += 1
				end
			end
			all = n <= plotW / (2 * look.point_size)
		end
		if not all and look.span == true then
			continue
		end
		local buf: { string } = {}
		pathDots(buf, g, plot.times[i], plot.tops[i], not all)
		if #buf > 0 then
			table.insert(
				out,
				fmt(
					'<path class="%s tg-dots" fill="none" stroke-width="%s" stroke-linecap="round" d="%s"/>',
					look.class,
					fmt("%g", look.point_size * M.LINE_SCALE),
					table.concat(buf)
				)
			)
		end
	end

	-- Exemplars: one path of diamonds over the lines, on the first scale.
	local exemplars = layout.exemplars
	if exemplars and #exemplars > 0 and #geo > 0 then
		local r = M.EXEMPLAR_R
		local yOf = geo[1].yOf
		local buf: { string } = table.create(#exemplars)
		for i, e in exemplars do
			buf[i] = fmt("M%.1f %.1fl%d %dl%d %dl%d %dZ", xOf(e.time_ms), yOf(e.value) - r, r, r, -r, r, -r, -r)
		end
		table.insert(out, '<path class="tg-exemplar" stroke-width="1" d="' .. table.concat(buf) .. '"/>')
	end

	if #list == 0 then
		table.insert(
			out,
			fmt(
				'<text class="tg-label" x="%.1f" y="%.1f" font-size="14" text-anchor="middle">No data</text>',
				(layout.plot_left + layout.plot_right) / 2,
				(top + bottom) / 2
			)
		)
	end
	table.insert(out, "</svg>")
	return table.concat(out)
end

-- Narrowest slot a bar gets, in viewBox px. Thinner bars blend into their
-- neighbors once the image is scaled down, so sparse series stacked over many
-- samples (Loki counts over a short step) read as fewer colors than the legend.
M.MIN_BAR_PX = 3

-- Bars over more distinct times than the plot has slots: each series' samples
-- are grouped into equal time buckets (the bucket's largest value, at the
-- bucket's center), so every stacked series lands in the same slots.
local function bucketBars(list: { Series.Series }, tFrom: number, tTo: number, slots: number): { Series.Series }
	local distinct: { [number]: boolean } = {}
	local n = 0
	for _, s in list do
		for _, t in s.times do
			if not distinct[t] then
				distinct[t] = true
				n += 1
			end
		end
	end
	if n <= slots or slots < 1 or tTo <= tFrom then
		return list
	end
	local width = (tTo - tFrom) / slots
	local out: { Series.Series } = table.create(#list)
	for i, s in list do
		local best: { [number]: number } = {}
		for j, t in s.times do
			local v = finite(s.values[j])
			if v then
				local b = math.clamp(math.floor((t - tFrom) / width), 0, slots - 1)
				if best[b] == nil or v > best[b] then
					best[b] = v
				end
			end
		end
		local times, values = {}, {}
		for b = 0, slots - 1 do
			local v = best[b]
			if v ~= nil then
				table.insert(times, math.floor(tFrom + (b + 0.5) * width))
				table.insert(values, v)
			end
		end
		local copy = Tbl.copy(s)
		copy.times, copy.values = times, values
		out[i] = copy
	end
	return out
end

local function unionTimes(plot: Plot): { number }
	local seen: { [number]: boolean } = {}
	local out: { number } = {}
	for _, times in plot.times do
		for _, t in times do
			if not seen[t] then
				seen[t] = true
				table.insert(out, t)
			end
		end
	end
	table.sort(out)
	return out
end

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

-- The series' own value at each drawn time: the source sample when the time
-- is one of its samples, else the drawn value with its transform undone.
local function ownValues(source: Series.Series, st: SeriesStyle, times: { number }, drawn: { any }): { any }
	local at: { [number]: any } = {}
	for j, t in source.times do
		at[t] = source.values[j]
	end
	local out: { any } = table.create(#times)
	for k, t in times do
		local v = at[t]
		if v == nil then
			v = drawn[k]
			local n = finite(v)
			if n and st.transform == "negative-Y" then
				v = -n
			end
		end
		out[k] = v
	end
	return out
end

function M.render(frames: { Frame }, options: Options?): Result
	local opts: Options = options or {}
	local W = opts.width or 960
	local H = opts.height or 300
	local all = Series.extract(frames, opts.legend)
	local cap = opts.series_cap or M.PALETTE
	local list: { Series.Series } = table.move(all, 1, math.min(cap, #all), 1, {})
	local dropped = #all - #list

	-- Time domain.
	local tFrom, tTo = opts.from_ms, opts.to_ms
	if tFrom == nil or tTo == nil then
		local lo, hi = math.huge, -math.huge
		for _, s in list do
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

	local styles = stylesFor(list, opts)
	local specs, scaleOf = scaleSpecs(styles)
	-- An empty chart still has its (empty) first scale.
	for _, spec in specs do
		table.clear(spec.members)
	end
	for i = 1, #list do
		table.insert(specs[scaleOf[i]].members, i)
	end
	local shown = transformed(list, styles, tFrom_, tTo_)
	local looks: { Look } = table.create(#list)
	local spans: { boolean | number } = table.create(#list)
	for i = 1, #list do
		looks[i] = lookOf(i, styles[i], opts, #list)
		spans[i] = looks[i].span
	end

	local plotTop, plotBottom = PAD_TOP, H - X_AXIS_H
	local plotH = plotBottom - plotTop
	-- Bytes per drawn sample over all series, by how each is drawn.
	local estimate = 0
	for _, look in looks do
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
		estimate += e
	end
	local marks: { FrameProm.Exemplar }?, marksDropped = nil, 0
	if opts.exemplars then
		marks, marksDropped = M.drawnExemplars(opts.exemplars, tFrom_, tTo_)
	end
	local fixed = FIXED_BYTES + (if marks then #marks * BYTES_EXEMPLAR else 0)

	local perSeries = opts.point_budget or math.floor(W - PAD_RIGHT)
	if #list > 0 then
		perSeries = math.min(perSeries, math.floor((M.TARGET - fixed) / estimate))
	end
	perSeries = math.max(3, perSeries)

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
		for k, s in bucketBars(barList, tFrom_, tTo_, slots) do
			shown[barAt[k]] = s
		end
	end
	local groups = stackGroups(shown, styles, scaleOf)

	-- Scales and axis bands depend on the plot height only.
	local plot = downsample(shown, groups, spans, perSeries)
	local scales: { Axis.Scale } = table.create(#specs)
	local labels: { { string } } = table.create(#specs)
	local widths: { number } = table.create(#specs)
	local leftW, rightW = 0, 0
	for k, spec in specs do
		local lo, hi = scaleRange(shown, plot, spec.members)
		-- Exemplars share the first scale (as in Grafana): a marker pinned
		-- to the plot edge would misstate its value. Percent stacks keep 0..1.
		if k == 1 and marks and not spec.percent then
			for _, e in marks do
				lo = if lo == nil then e.value else math.min(lo :: number, e.value)
				hi = if hi == nil then e.value else math.max(hi :: number, e.value)
			end
		end
		scales[k] = buildScale(spec, lo, hi, plotH)
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

	local svg, layout, points = "", (nil :: any) :: Layout, 0
	for attempt = 1, 8 do
		if attempt > 1 then
			plot = downsample(shown, groups, spans, perSeries)
		end
		local drawn: { DrawnSeries } = table.create(#list)
		points = 0
		for i, s in list do
			local st = styles[i]
			drawn[i] = {
				name = s.name,
				class = looks[i].class,
				labels = s.labels,
				times = plot.times[i],
				values = ownValues(s, st, plot.times[i], plot.raw[i]),
				calcs = Series.calcs(s.values),
				axis = scaleOf[i],
				unit = st.unit,
				decimals = st.decimals,
				hide_legend = st.hide_legend,
				hide_tooltip = st.hide_tooltip,
			}
			points += #plot.times[i]
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
			times = unionTimes(plot),
			series = drawn,
			dropped = dropped,
			exemplars = marks,
			exemplars_dropped = if marks then marksDropped else nil,
		}
		svg = build({
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
		if #svg <= M.TARGET or perSeries <= 3 then
			break
		end
		perSeries = math.max(3, math.floor(perSeries * M.TARGET / #svg * 0.9))
	end
	assert(#svg <= M.CAP, "svg_timeseries: chart exceeds the 256 KiB SVG cap")
	return { svg = svg, layout = layout, dropped = dropped, points = points }
end

return M
