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

local Axis = require("./axis")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Layout = require("./layout")
local Lttb = require("../time/lttb")
local Series = require("./series")
local Thresholds = require("../units/thresholds")

type Frame = Frame.Frame
type Layout = Layout.Layout
type DrawnSeries = Layout.DrawnSeries

export type ThresholdStyle = "off" | "line" | "area" | "line+area"
export type Draw = "line" | "bars" | "points"

export type Options = {
	-- Design size in px (the image scales down to the pane).
	width: number?,
	height: number?,
	unit: string?,
	decimals: number?,
	-- Hard y-axis bounds.
	min: number?,
	max: number?,
	thresholds: Thresholds.Thresholds?,
	threshold_style: ThresholdStyle?,
	stack: Series.StackMode?,
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
}

export type Result = { svg: string, layout: Layout, dropped: number, points: number }

local M = {}

M.CAP = 262144
-- Aim below the cap: estimates are rough and the next refresh may grow.
M.TARGET = 240 * 1024
M.PALETTE = 10

local NULL = Frame.NULL
local finite = Frame.finite
local fmt = string.format

local PAD_TOP = 8
local PAD_RIGHT = 12
local X_AXIS_H = 24
-- Bytes per drawn sample, measured on this generator's output.
local BYTES_LINE = 12
local BYTES_BAR = 30
local FIXED_BYTES = 8 * 1024
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

type Plot = {
	-- Per series: times, raw values, values to plot (stacked tops), and the
	-- base each fill or bar starts from (nil: the axis baseline).
	times: { { number } },
	raw: { { any } },
	tops: { { any } },
	bottoms: { { number }? },
}

local function downsample(list: { Series.Series }, opts: Options, perSeries: number): Plot
	local stack: Series.StackMode = opts.stack or "none"
	local plot: Plot = { times = {}, raw = {}, tops = {}, bottoms = {} }
	if stack ~= "none" and #list > 0 then
		local times, columns = Series.join(list)
		local tops, bottoms = Series.stack(columns, stack)
		-- One index set for all series keeps the stack aligned: LTTB on the
		-- stack's upper envelope.
		local envelope: { any } = table.create(#times)
		for j = 1, #times do
			local hi: number? = nil
			for i = 1, #tops do
				local v = finite(tops[i][j])
				if v and (hi == nil or v > hi) then
					hi = v
				end
			end
			envelope[j] = if hi == nil then NULL else hi
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
		for i = 1, #list do
			plot.times[i] = drawnT
			plot.raw[i] = pick(columns[i], idx)
			plot.tops[i] = pick(tops[i], idx)
			plot.bottoms[i] = pick(bottoms[i], idx) :: { number }
		end
		return plot
	end
	for i, s in list do
		local t, v = s.times, s.values
		if opts.null_mode == "connect" then
			t, v = presentOnly(t, v)
		end
		local dt, dv = Lttb.downsample(t, v, perSeries, NULL)
		plot.times[i] = dt
		plot.raw[i] = dv
		plot.tops[i] = dv
	end
	return plot
end

local function valueRange(list: { Series.Series }, plot: Plot, opts: Options): (number?, number?)
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
	if (opts.stack or "none") ~= "none" then
		for i = 1, #plot.tops do
			for _, v in plot.tops[i] do
				see(v)
			end
			local b = plot.bottoms[i]
			if b then
				for _, v in b do
					see(v)
				end
			end
		end
	else
		-- Full resolution, so downsampling never moves the axis.
		for _, s in list do
			local c = Series.calcs(s.values)
			see(c.min)
			see(c.max)
		end
	end
	if lo ~= nil and ((opts.draw or "line") == "bars" or (opts.fill_opacity or 0) > 0) then
		see(0)
	end
	return lo, hi
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
	-- One decimals count for every tick, the fewest that print each tick
	-- exactly in its display unit: a 0.25 step reads 0.25/0.50 (not 0.3),
	-- a 0.2 percentunit step reads 20% (not 20.0%), 1.5 MiB keeps its .5.
	local function trimmed(s: string): string
		if string.find(s, ".", 1, true) then
			s = string.gsub(string.gsub(s, "0+$", ""), "%.$", "")
		end
		return s
	end
	local common = 0
	for _, v in scale.ticks do
		local exact = trimmed(Format.format(v, unit, 10).text)
		local d = 0
		while d <= MAX_TICK_DECIMALS and trimmed(Format.format(v, unit, d).text) ~= exact do
			d += 1
		end
		if d > MAX_TICK_DECIMALS then
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

-- Polyline runs between missing samples. A lone sample becomes a zero-length
-- segment, which the round line cap still draws as a dot.
local function pathLine(buf: { string }, g: Geometry, times: { number }, values: { any }, dots: boolean)
	local run = 0
	for i, t in times do
		local v = finite(values[i])
		if v then
			local x, y = g.xOf(t), g.yOf(v)
			if dots then
				table.insert(buf, fmt("M%.1f %.1fh0", x, y))
			elseif run == 0 then
				table.insert(buf, fmt("M%.1f %.1f", x, y))
			elseif run == 1 then
				table.insert(buf, fmt("L%.1f %.1f", x, y))
			else
				table.insert(buf, fmt(" %.1f %.1f", x, y))
			end
			run += 1
		else
			if run == 1 and not dots then
				table.insert(buf, "h0")
			end
			run = 0
		end
	end
	if run == 1 and not dots then
		table.insert(buf, "h0")
	end
end

-- Closed areas between each run of present values and its base.
local function pathArea(
	buf: { string },
	g: Geometry,
	times: { number },
	tops: { any },
	bottoms: { number }?,
	base: number
)
	local runStart: number? = nil
	local n = #times
	for i = 1, n + 1 do
		local v = if i <= n then finite(tops[i]) else nil
		if v and runStart == nil then
			runStart = i
		elseif v == nil and runStart ~= nil then
			local s, e = runStart, i - 1
			table.insert(buf, fmt("M%.1f %.1f", g.xOf(times[s]), g.yOf(finite(tops[s]) :: number)))
			for j = s + 1, e do
				table.insert(buf, fmt(" %.1f %.1f", g.xOf(times[j]), g.yOf(finite(tops[j]) :: number)))
			end
			if bottoms then
				for j = e, s, -1 do
					table.insert(buf, fmt(" %.1f %.1f", g.xOf(times[j]), g.yOf(bottoms[j])))
				end
			else
				local yb = num(g.yOf(base))
				table.insert(buf, fmt(" %.1f %s %.1f %s", g.xOf(times[e]), yb, g.xOf(times[s]), yb))
			end
			table.insert(buf, "Z")
			runStart = nil
		end
	end
end

local function pathBars(
	buf: { string },
	g: Geometry,
	times: { number },
	tops: { any },
	bottoms: { number }?,
	base: number,
	barW: number
)
	local half = barW / 2
	for i, t in times do
		local v = finite(tops[i])
		if v then
			local x = g.xOf(t) - half
			local y0 = g.yOf(if bottoms then bottoms[i] else base)
			table.insert(buf, fmt("M%.1f %.1fV%.1fh%.1fV%.1fZ", x, y0, g.yOf(v), barW, y0))
		end
	end
end

local function thresholdShapes(out: { string }, g: Geometry, opts: Options)
	local style = opts.threshold_style or "off"
	local spec = opts.thresholds
	if style == "off" or spec == nil or #spec.steps == 0 then
		return
	end
	local layout = g.layout
	local percent = spec.mode == "percentage"
	local steps = table.clone(spec.steps)
	local function at(step: Thresholds.Step): number
		local v = step.value
		if type(v) ~= "number" then
			return -math.huge
		end
		return if percent then layout.y_min + (layout.y_max - layout.y_min) * v / 100 else v
	end
	table.sort(steps, function(a, b)
		return at(a) < at(b)
	end)
	local l, r = layout.plot_left, layout.plot_right
	if style == "area" or style == "line+area" then
		for k, step in steps do
			local lo = math.max(at(step), layout.y_min)
			local hi = if k < #steps then math.min(at(steps[k + 1]), layout.y_max) else layout.y_max
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
			if v > layout.y_min and v <= layout.y_max then
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

local function build(list: { Series.Series }, plot: Plot, layout: Layout, opts: Options, yScale: Axis.Scale): string
	local out: { string } = {}
	local W, H = layout.width, layout.height
	local yMin, yMax = layout.y_min, layout.y_max
	local top, bottom = layout.plot_top, layout.plot_bottom
	local g: Geometry = {
		layout = layout,
		xOf = function(t: number): number
			return math.clamp(Layout.xOfTime(layout, t), layout.plot_left, layout.plot_right)
		end,
		yOf = function(v: number): number
			return math.clamp(Layout.yOfValue(layout, v), top, bottom)
		end,
	}
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
	for _, v in yScale.ticks do
		if v >= yMin and v <= yMax then
			table.insert(grid, fmt("M%.1f %.1fH%.1f", layout.plot_left, g.yOf(v), layout.plot_right))
		end
	end
	for _, t in ticks.ticks do
		table.insert(grid, fmt("M%.1f %.1fV%.1f", g.xOf(t), top, bottom))
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
	local unit = layout.unit
	local labels = yLabels(yScale, unit, layout.decimals)
	for i, v in yScale.ticks do
		if v >= yMin and v <= yMax then
			table.insert(
				out,
				fmt(
					'<text class="tg-label" x="%.1f" y="%.1f" font-size="12" text-anchor="end">%s</text>',
					layout.plot_left - 6,
					g.yOf(v) + 4,
					escape(labels[i])
				)
			)
		end
	end
	for i, t in ticks.ticks do
		local x = g.xOf(t)
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

	thresholdShapes(out, g, opts)

	-- Series: fills and bars first, lines on top.
	local draw = opts.draw or "line"
	local fill = math.clamp(opts.fill_opacity or 0, 0, 100) / 100
	local base = math.clamp(0, yMin, yMax)
	if draw == "bars" then
		local n = 1
		for i = 1, #plot.times do
			n = math.max(n, #plot.times[i])
		end
		local barW = math.max(1, (layout.plot_right - layout.plot_left) / n * 0.6)
		for i = 1, #list do
			local buf: { string } = {}
			pathBars(buf, g, plot.times[i], plot.tops[i], plot.bottoms[i], base, barW)
			if #buf > 0 then
				table.insert(
					out,
					fmt(
						'<path class="%s tg-bar" fill-opacity="%s" d="%s"/>',
						M.seriesClass(i),
						if fill > 0 then fmt("%.2f", fill) else "0.8",
						table.concat(buf)
					)
				)
			end
		end
	else
		if fill > 0 and draw == "line" then
			for i = 1, #list do
				local buf: { string } = {}
				pathArea(buf, g, plot.times[i], plot.tops[i], plot.bottoms[i], base)
				if #buf > 0 then
					table.insert(
						out,
						fmt(
							'<path class="%s tg-area" fill-opacity="%.2f" d="%s"/>',
							M.seriesClass(i),
							fill,
							table.concat(buf)
						)
					)
				end
			end
		end
		local width = if draw == "points" then 4 else 1.5
		for i = 1, #list do
			local buf: { string } = {}
			pathLine(buf, g, plot.times[i], plot.tops[i], draw == "points")
			if #buf > 0 then
				table.insert(
					out,
					fmt(
						'<path class="%s tg-line" fill="none" stroke-width="%s" stroke-linecap="round" stroke-linejoin="round" d="%s"/>',
						M.seriesClass(i),
						tostring(width),
						table.concat(buf)
					)
				)
			end
		end
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
		local copy = table.clone(s)
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

function M.render(frames: { Frame }, options: Options?): Result
	local opts: Options = options or {}
	local W = opts.width or 960
	local H = opts.height or 300
	local all = Series.extract(frames, opts.legend)
	local cap = opts.series_cap or M.PALETTE
	local list: { Series.Series } = table.move(all, 1, math.min(cap, #all), 1, {})
	local dropped = #all - #list
	local stack = opts.stack or "none"

	local unit = opts.unit or (if list[1] then list[1].unit else nil)
	local decimals = if opts.decimals ~= nil then opts.decimals elseif list[1] then list[1].decimals else nil
	if stack == "percent" then
		unit = "percentunit"
	end

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

	local plotTop, plotBottom = PAD_TOP, H - X_AXIS_H
	local plotRight = W - PAD_RIGHT
	local estimate = if (opts.draw or "line") == "bars" then BYTES_BAR else BYTES_LINE
	if (opts.fill_opacity or 0) > 0 and (opts.draw or "line") == "line" then
		estimate *= 2
	end
	local perSeries = opts.point_budget or math.floor(plotRight)
	if #list > 0 then
		perSeries = math.min(perSeries, math.floor((M.TARGET - FIXED_BYTES) / (#list * estimate)))
	end
	perSeries = math.max(3, perSeries)

	-- What is drawn; `list` keeps the samples the legend calcs read.
	local shown = list
	if (opts.draw or "line") == "bars" then
		local slots = math.floor((plotRight - 36) / M.MIN_BAR_PX)
		shown = bucketBars(list, tFrom_, tTo_, slots)
	end

	local svg, layout, points = "", (nil :: any) :: Layout, 0
	for _ = 1, 8 do
		local plot = downsample(shown, opts, perSeries)
		local lo, hi = valueRange(shown, plot, opts)
		local hardMin, hardMax = opts.min, opts.max
		if stack == "percent" then
			hardMin, hardMax = hardMin or 0, hardMax or 1
		end
		local yScale = Axis.niceScale(lo or 0, hi or 1, plotBottom - plotTop, hardMin, hardMax)
		local labelW = 0
		for _, label in yLabels(yScale, unit, decimals) do
			labelW = math.max(labelW, utf8.len(label) or #label)
		end
		local drawn: { DrawnSeries } = table.create(#list)
		points = 0
		for i, s in list do
			drawn[i] = {
				name = s.name,
				class = M.seriesClass(i),
				labels = s.labels,
				times = plot.times[i],
				values = plot.raw[i],
				calcs = Series.calcs(s.values),
			}
			points += #plot.times[i]
		end
		layout = {
			width = W,
			height = H,
			plot_left = math.max(36, labelW * Axis.CHAR_PX + 12),
			plot_right = plotRight,
			plot_top = plotTop,
			plot_bottom = plotBottom,
			t_from = tFrom_,
			t_to = tTo_,
			y_min = yScale.min,
			y_max = yScale.max,
			unit = unit,
			decimals = decimals,
			times = unionTimes(plot),
			series = drawn,
			dropped = dropped,
		}
		svg = build(shown, plot, layout, opts, yScale)
		if #svg <= M.TARGET or perSeries <= 3 then
			break
		end
		perSeries = math.max(3, math.floor(perSeries * M.TARGET / #svg * 0.9))
	end
	assert(#svg <= M.CAP, "svg_timeseries: chart exceeds the 256 KiB SVG cap")
	return { svg = svg, layout = layout, dropped = dropped, points = points }
end

return M
