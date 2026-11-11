--!strict
-- Data preparation for lib/render/svg_timeseries: per-series styles, the
-- series as drawn (transforms, stacking, null spanning, bar buckets), LTTB
-- downsampling to the point budget, and the values the layout keeps for the
-- legend and cursor.

local Axis = require("./axis")
local Frame = require("../frame/types")
local Lttb = require("../time/lttb")
local Series = require("./series")
local Thresholds = require("../units/thresholds")
local Tbl = require("../tbl")

export type ThresholdStyle = "off" | "line" | "area" | "line+area"
export type Draw = "line" | "bars" | "points"
export type Placement = "auto" | "left" | "right" | "hidden"
export type Transform = "negative-Y" | "constant"
-- Grafana custom.scaleDistribution: type linear|log|symlog, log base 2|10,
-- linearThreshold for symlog.
export type Distribution = { type: Axis.Distr, log: number?, linear_threshold: number? }

export type Interpolation = "linear" | "smooth" | "stepBefore" | "stepAfter"
export type ShowPoints = "auto" | "always" | "never"
export type Gradient = "none" | "opacity" | "hue" | "scheme"
-- gradientMode scheme stops: `at` is a value on the series' scale, or with
-- `relative` a fraction of the gradient range (hard min/max, soft min/max,
-- else the data range: gradientFills.ts getGradientRange). `discrete`
-- makes hard edges between stops (threshold steps).
export type SchemeStop = { at: number, class: string }
export type Scheme = { stops: { SchemeStop }, relative: boolean, discrete: boolean }

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
	-- custom.fillOpacity 0..100 and custom.gradientMode. Hue and scheme
	-- also color the line: `hue` holds the top and bottom stop classes,
	-- `scheme` the value stops (lib/render/ts_gradient); without them the
	-- mode draws plainly.
	fill_opacity: number?,
	gradient: Gradient?,
	hue: { string }?,
	scheme: Scheme?,
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

local M = {}

local NULL = Frame.NULL
local finite = Frame.finite

function M.distr(st: SeriesStyle): Axis.Distr
	local d = st.distribution
	return if d then d.type else "linear"
end

-- Strictly increasing times (no duplicates): a time then names one sample.
local function ascending(times: { number }): boolean
	for i = 2, #times do
		if times[i] <= times[i - 1] then
			return false
		end
	end
	return true
end

-- Same length and elements.
local function sameTimes(a: { number }, b: { number }): boolean
	if a == b then
		return true
	end
	local n = #a
	if #b ~= n then
		return false
	end
	for i = 1, n do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
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
	local n = 0
	for i, t in times do
		if finite(values[i]) then
			n += 1
			t2[n] = t
			v2[n] = values[i]
		end
	end
	return t2, v2
end

-- The series as drawn: negated (negative-Y), flattened to its first value
-- across the time range (constant), non-positive values dropped on a log
-- scale (uPlot cannot place them).
function M.transformed(list: { Series.Series }, styles: { SeriesStyle }, tFrom: number, tTo: number): { Series.Series }
	local out: { Series.Series } = table.create(#list)
	for i, s in list do
		local st = styles[i]
		local log = M.distr(st) == "log"
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

-- uPlot closestIdx: the index (1-based) of the time nearest `t` in the
-- ascending `times`, the earlier one on a tie.
local function closestIdx(t: number, times: { number }): number
	local lo, hi = 1, #times
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if times[mid] < t then
			lo = mid
		else
			hi = mid
		end
	end
	return if t - times[lo] <= times[hi] - t then lo else hi
end

-- The samples in view, as uPlot's setScales finds them (i0..i1: the
-- samples nearest the range's ends, moved inside it unless that leaves at
-- most two), and the series as drawn: getOuterIdxs adds the nearest
-- present sample beyond each end, so a line enters the plot at its slope
-- and the plot clips it. Returns the series (itself when nothing is cut),
-- the times of its first and last sample in view (nil bounds for an empty
-- series) and whether its times ascend; other series are kept whole.
function M.window(s: Series.Series, tFrom: number, tTo: number): (Series.Series, number?, number?, boolean)
	local times = s.times
	local n = #times
	if n == 0 then
		return s, nil, nil, true
	elseif not ascending(times) then
		return s, tFrom, tTo, false
	end
	local i0, i1 = closestIdx(tFrom, times), closestIdx(tTo, times)
	if i1 - i0 > 1 then
		if times[i0] < tFrom then
			i0 += 1
		end
		if times[i1] > tTo then
			i1 -= 1
		end
	end
	local values = s.values
	local o0, o1 = math.max(i0 - 1, 1), math.min(i1 + 1, n)
	while o0 > 1 and finite(values[o0]) == nil do
		o0 -= 1
	end
	while o1 < n and finite(values[o1]) == nil do
		o1 += 1
	end
	if o0 == 1 and o1 == n then
		return s, times[i0], times[i1], true
	end
	local copy = Tbl.copy(s)
	copy.times = table.move(times, o0, o1, 1, table.create(o1 - o0 + 1))
	copy.values = table.move(values, o0, o1, 1, table.create(o1 - o0 + 1))
	return copy, times[i0], times[i1], true
end

export type StackGroup = { mode: Series.StackMode, neg: boolean, members: { number } }

-- getStackingGroups: one group per direction (a series with a negative
-- sample after its transform stacks down), mode, group and scale.
function M.stackGroups(shown: { Series.Series }, styles: { SeriesStyle }, scaleOf: { number }): { StackGroup }
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
		local key = string.format("%s|%s|%s|%d", if neg then "neg" else "pos", mode, st.stack_group or "A", scaleOf[i])
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

export type Plot = {
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
	local n = 0
	local lastT: number? = nil
	local gapAt: number? = nil
	for i, t in times do
		if finite(values[i]) then
			if gapAt and lastT and t - lastT > limit then
				n += 1
				t2[n] = gapAt
				v2[n] = NULL
			end
			n += 1
			t2[n] = t
			v2[n] = values[i]
			lastT, gapAt = t, nil
		elseif gapAt == nil then
			gapAt = t
		end
	end
	return t2, v2
end

-- A series over more threshold steps than this (range edges included)
-- gets one null per gap and none at the edges instead, which draws the
-- same.
M.INSERT_MAX = 100000

-- applyNullInsertThreshold (grafana-data nullInsertThreshold.ts, run by
-- the time series panel's prepareGraphableFields): where the time column
-- (ascending ms) jumps by more than `threshold`, a null at every threshold
-- step from the earlier sample, so the line breaks; likewise from
-- `pseudo_min` up to the first sample and from the last up to `pseudo_max`
-- (the panel's range). Returns the inputs themselves when nothing is
-- inserted.
function M.insertNulls(
	times: { number },
	columns: { { any } },
	threshold: number,
	pseudoMin: number?,
	pseudoMax: number?
): ({ number }, { { any } })
	local n = #times
	if n == 0 or not (threshold > 0) then
		return times, columns
	end
	local first, last = times[1], times[n]
	local needs = (pseudoMin ~= nil and pseudoMin < first - threshold)
		or (pseudoMax ~= nil and pseudoMax > last + threshold)
	if not needs then
		for i = 2, n do
			if times[i] - times[i - 1] > threshold then
				needs = true
				break
			end
		end
	end
	if not needs then
		return times, columns
	end
	local lo = if pseudoMin then math.min(pseudoMin, first) else first
	local hi = if pseudoMax then math.max(pseudoMax, last) else last
	local thorough = (hi - lo) / threshold <= M.INSERT_MAX
	local out: { number } = {}
	local k = 0
	if thorough and pseudoMin ~= nil and pseudoMin < first then
		local slot = first - math.ceil((first - pseudoMin) / threshold) * threshold
		while slot < first do
			k += 1
			out[k] = slot
			slot += threshold
		end
	end
	k += 1
	out[k] = first
	local prev = first
	for i = 2, n do
		local cur = times[i]
		while cur - prev > threshold do
			k += 1
			out[k] = prev + threshold
			prev += threshold
			if not thorough then
				break
			end
		end
		k += 1
		out[k] = cur
		prev = cur
	end
	if thorough and pseudoMax ~= nil and pseudoMax > prev then
		while prev + threshold < pseudoMax do
			k += 1
			out[k] = prev + threshold
			prev += threshold
		end
	end
	if k == n then
		return times, columns
	end
	local filled: { { any } } = table.create(#columns)
	for c, col in columns do
		local values: { any } = table.create(k)
		local j = 1
		for i = 1, k do
			if times[j] == out[i] then
				values[i] = col[j]
				j += 1
			else
				values[i] = NULL
			end
		end
		filled[c] = values
	end
	return out, filled
end

function M.downsample(
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
		local neg = g.neg
		for j = 1, #times do
			local edge: number? = nil
			for k = 1, #tops do
				local v = tops[k][j]
				if
					type(v) == "number"
					and v == v
					and v ~= math.huge
					and v ~= -math.huge
					and (edge == nil or (if neg then v < edge else v > edge))
				then
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

-- Bars over more distinct times than the plot has slots: each series' samples
-- in the time range are grouped into equal time buckets (the bucket's largest
-- value, at the bucket's center), so every stacked series lands in the same
-- slots.
function M.bucketBars(list: { Series.Series }, tFrom: number, tTo: number, slots: number): { Series.Series }
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
			if v and t >= tFrom and t <= tTo then
				local b = math.min(math.floor((t - tFrom) / width), slots - 1)
				if best[b] == nil or v > best[b] then
					best[b] = v
				end
			end
		end
		local times, values = {}, {}
		local k = 0
		for b = 0, slots - 1 do
			local v = best[b]
			if v ~= nil then
				k += 1
				times[k] = math.floor(tFrom + (b + 0.5) * width)
				values[k] = v
			end
		end
		local copy = Tbl.copy(s)
		copy.times, copy.values = times, values
		out[i] = copy
	end
	return out
end

-- Sorted union of every series' drawn times (the cursor stops). Series of
-- one aligned query share their times: that array is the union already.
function M.unionTimes(plot: Plot): { number }
	local all = plot.times
	local first = all[1]
	if first and ascending(first) then
		local shared = true
		for i = 2, #all do
			if not sameTimes(first, all[i]) then
				shared = false
				break
			end
		end
		if shared then
			return first
		end
	end
	local seen: { [number]: boolean } = {}
	local out: { number } = {}
	local n = 0
	for _, times in all do
		for _, t in times do
			if not seen[t] then
				seen[t] = true
				n += 1
				out[n] = t
			end
		end
	end
	table.sort(out)
	return out
end

-- The series' own value at each drawn time: the source sample when the time
-- is one of its samples, else the drawn value with its transform undone.
-- An unstacked series drawn from its own samples (`plain`: ascending, no
-- transform, at most cut to the range by M.window, not bucketed) without
-- null spanning draws its own samples: those values are already the answer.
function M.ownValues(
	source: Series.Series,
	plain: boolean,
	st: SeriesStyle,
	plot: Plot,
	i: number,
	spans: { boolean | number }
): { any }
	local times, drawn = plot.times[i], plot.raw[i]
	if plain and not plot.stacked[i] and spans[i] == false then
		return drawn
	end
	local neg = st.transform == "negative-Y"
	local stimes, svalues = source.times, source.values
	local m = #stimes
	-- Ascending source times (`plain`) are walked alongside the drawn times
	-- (a drawn time before the previous one restarts the walk); others are
	-- looked up by time.
	local at: { [number]: any }? = nil
	if not plain then
		local map: { [number]: any } = {}
		for j, t in stimes do
			map[t] = svalues[j]
		end
		at = map
	end
	local out: { any } = table.create(#times)
	local j, prev = 1, -math.huge
	for k, t in times do
		local v: any
		if at then
			v = at[t]
		else
			if t < prev then
				j = 1
			end
			prev = t
			while j <= m and stimes[j] < t do
				j += 1
			end
			v = if j <= m and stimes[j] == t then svalues[j] else nil
		end
		if v == nil then
			v = drawn[k]
			local n = finite(v)
			if n and neg then
				v = -n
			end
		end
		out[k] = v
	end
	return out
end

return M
