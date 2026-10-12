--!strict
-- Charts on a numeric (or time) x axis and a linear y axis, for the trend,
-- XY chart, histogram and candlestick panels. Layers, drawn in this order:
-- - rects: boxes in data units (histogram buckets) or centered on an x with
--   a px width (candle bodies and wicks, volume bars), optionally on a
--   hidden second scale 0..y2_max (candlestick volume), filled or outlined;
-- - lines: polylines with gaps at missing values (or spanning them), an
--   optional fill down to a baseline or a stack bottom, optional markers;
-- - scatters: markers (round or square) with a size and class per point.
-- Colors are classes as in lib/render/svg_timeseries. Lines are downsampled
-- (LTTB when x ascends, else evenly) and scatters thinned evenly to a byte
-- budget that keeps the document under Tern's 256 KiB cap.

local Axis = require("./axis")
local Frame = require("../frame/types")
local Kit = require("./svg_kit")
local Lttb = require("../time/lttb")
local Tbl = require("../tbl")
local Thresholds = require("../units/thresholds")

local M = {}

export type Line = {
	class: string,
	xs: { number },
	ys: { any },
	-- Stroke width, px (0 draws no line, e.g. points only).
	width: number?,
	-- stroke-dasharray (LineStyle dash/dots).
	dash: string?,
	-- 0..1 fill down to `bottoms` or the baseline.
	fill_opacity: number?,
	bottoms: { number }?,
	-- Marker diameter, px (nil: none).
	points: number?,
	-- Join across missing values (spanNulls).
	connect: boolean?,
	-- Draw each value as a bar instead of a line (drawStyle bars).
	bars: boolean?,
}

export type Scatter = {
	class: string,
	xs: { number },
	ys: { any },
	-- Per point color classes (color dimension) and diameters, px.
	classes: { string }?,
	sizes: { number }?,
	size: number?,
	square: boolean?,
	-- 0..1 marker fill opacity.
	opacity: number?,
}

export type Rect = {
	x0: number,
	-- Right edge in data units, or `w` px centered on x0.
	x1: number?,
	w: number?,
	-- Px shift of a `w` rect (OHLC bar ticks left and right of the stick).
	dx: number?,
	y0: number,
	y1: number,
}

export type Rects = {
	class: string,
	rects: { Rect },
	-- On the hidden 0..y2_max scale.
	y2: boolean?,
	opacity: number?,
	-- Outline only (hollow candles), this stroke width.
	outline: number?,
	-- Least height in px (OHLC open/close ticks are 1-2 px lines).
	min_h: number?,
}

export type Options = {
	width: number,
	height: number,
	-- Time x axis (epoch ms) with Grafana's time tick labels.
	x_time: boolean?,
	offset_min: number?,
	x_unit: string?,
	x_decimals: number?,
	-- Hard x bounds; free ends use the data extent (uPlot's padded range
	-- with x_padded, as for the XY chart's numeric x).
	x_min: number?,
	x_max: number?,
	x_padded: boolean?,
	-- Data units added on both sides of the data extent (half a candle).
	x_pad: number?,
	y_unit: string?,
	y_decimals: number?,
	y_min: number?,
	y_max: number?,
	-- Keep 0 in the y range (bars, fills).
	y_zero: boolean?,
	-- Soft bounds (axisSoftMin/Max): kept in range, data may exceed them.
	y_soft_min: number?,
	y_soft_max: number?,
	y2_max: number?,
	thresholds: Thresholds.Thresholds?,
	threshold_style: Kit.ThresholdStyle?,
	grid: boolean?,
	-- "left" (default), "right" or "hidden".
	y_side: string?,
	x_axis: boolean?,
	x_label: string?,
	y_label: string?,
	lines: { Line }?,
	scatters: { Scatter }?,
	rects: { Rects }?,
}

export type Plot = {
	left: number,
	right: number,
	top: number,
	bottom: number,
	x_min: number,
	x_max: number,
	y_min: number,
	y_max: number,
}

export type Result = { svg: string, plot: Plot, points: number }

local NULL = Frame.NULL
local finite = Frame.finite
local fmt = string.format

local BYTES_POINT = 13
local BYTES_MARKER = 40
local BYTES_RECT = 36
local FIXED_BYTES = 8 * 1024

local function ascending(xs: { number }): boolean
	for i = 2, #xs do
		if xs[i] < xs[i - 1] then
			return false
		end
	end
	return true
end

-- Every k-th index so at most `n` remain (first and last kept).
local function evenIdx(len: number, n: number): { number }
	if len <= n or n < 2 then
		local all = table.create(len)
		for i = 1, len do
			all[i] = i
		end
		return all
	end
	local out: { number } = table.create(n)
	for k = 1, n do
		out[k] = 1 + math.floor((k - 1) * (len - 1) / (n - 1) + 0.5)
	end
	return out
end

local function pick<T>(col: { T }, idx: { number }): { T }
	local out: { T } = table.create(#idx)
	for k, i in idx do
		out[k] = col[i]
	end
	return out
end

local function thinLine(l: Line, n: number): Line
	if #l.xs <= n then
		return l
	end
	local out: Line = Tbl.copy(l)
	if l.bottoms == nil and ascending(l.xs) then
		local xs, ys = Lttb.downsample(l.xs, l.ys, n, NULL)
		out.xs, out.ys = xs, ys
		return out
	end
	local idx = evenIdx(#l.xs, n)
	out.xs = pick(l.xs, idx)
	out.ys = pick(l.ys, idx)
	if l.bottoms then
		out.bottoms = pick(l.bottoms :: { number }, idx)
	end
	return out
end

local function thinScatter(s: Scatter, n: number): Scatter
	if #s.xs <= n then
		return s
	end
	local idx = evenIdx(#s.xs, n)
	local out: Scatter = Tbl.copy(s)
	out.xs = pick(s.xs, idx)
	out.ys = pick(s.ys, idx)
	if s.classes then
		out.classes = pick(s.classes :: { string }, idx)
	end
	if s.sizes then
		out.sizes = pick(s.sizes :: { number }, idx)
	end
	return out
end

type Extent = { lo: number?, hi: number? }

local function see(e: Extent, v: any)
	local n = finite(v)
	if n then
		if e.lo == nil or n < (e.lo :: number) then
			e.lo = n
		end
		if e.hi == nil or n > (e.hi :: number) then
			e.hi = n
		end
	end
end

local function build(opts: Options, lines: { Line }, scatters: { Scatter }, rects: { Rects }): (string, Plot)
	local W, H = math.max(80, opts.width), math.max(60, opts.height)
	-- Extents over the full data (thinning never moves the axes).
	local ex: Extent, ey: Extent = {}, {}
	for _, l in lines do
		for i, x in l.xs do
			if finite(l.ys[i]) then
				see(ex, x)
				see(ey, l.ys[i])
			end
		end
		if l.bottoms then
			for _, b in l.bottoms :: { number } do
				see(ey, b)
			end
		end
		if l.bars then
			see(ey, 0)
		end
	end
	for _, s in scatters do
		for i, x in s.xs do
			if finite(s.ys[i]) then
				see(ex, x)
				see(ey, s.ys[i])
			end
		end
	end
	for _, r in rects do
		for _, b in r.rects do
			see(ex, b.x0)
			if b.x1 then
				see(ex, b.x1)
			end
			if not r.y2 then
				see(ey, b.y0)
				see(ey, b.y1)
			end
		end
	end
	see(ey, opts.y_soft_min)
	see(ey, opts.y_soft_max)
	if opts.y_zero then
		see(ey, 0)
	end
	local pad = opts.x_pad or 0
	local xlo = opts.x_min or (if ex.lo then (ex.lo :: number) - pad else 0)
	local xhi = opts.x_max or (if ex.hi then (ex.hi :: number) + pad else 1)
	if opts.x_padded and not opts.x_time and ex.lo and ex.hi then
		local a, b = Kit.padRange(ex.lo :: number, ex.hi :: number)
		xlo, xhi = opts.x_min or a, opts.x_max or b
	end
	if xhi <= xlo then
		local d = if opts.x_time then 30000 elseif xlo == 0 then 1 else math.abs(xlo) * 0.1
		xlo, xhi = xlo - d, xhi + d
	end

	local top = 8
	local ySide = opts.y_side or "left"
	local showX = opts.x_axis ~= false
	local bottom = H - (if showX then 24 else 8) - (if opts.x_label then 16 else 0)
	local yScale = Kit.vScalePadded(ey.lo or 0, ey.hi or 1, bottom - top, opts.y_min, opts.y_max)
	local yLabels = Kit.tickLabels(yScale.ticks, opts.y_unit, opts.y_decimals)
	local labelW = 0
	for _, l in yLabels do
		labelW = math.max(labelW, Kit.textWidth(l))
	end
	local axisW = if ySide == "hidden" then 8 else math.max(36, labelW + 12)
	local titleW = if opts.y_label then 18 else 0
	local left = if ySide == "right" then 8 + titleW else axisW + titleW
	local right = if ySide == "right" then W - axisW else W - 12

	-- X ticks.
	local xTicks: { number }, xLabels: { string }
	if opts.x_time then
		local t = Axis.timeTicks(xlo, xhi, right - left, opts.offset_min)
		xTicks, xLabels = t.ticks, t.labels
	else
		local s, labels = Kit.hScale(xlo, xhi, right - left, xlo, xhi, opts.x_unit, opts.x_decimals)
		xlo, xhi = s.min, s.max
		xTicks, xLabels = s.ticks, labels
	end
	local plot: Plot = {
		left = left,
		right = right,
		top = top,
		bottom = bottom,
		x_min = xlo,
		x_max = xhi,
		y_min = yScale.min,
		y_max = yScale.max,
	}
	local xspan, yspan = xhi - xlo, yScale.max - yScale.min
	if yspan <= 0 then
		yspan = 1
	end
	local function xOf(x: number): number
		return math.clamp(left + (x - xlo) / xspan * (right - left), left - 1, right + 1)
	end
	local function yOf(y: number): number
		return math.clamp(bottom - (y - yScale.min) / yspan * (bottom - top), top - 1, bottom + 1)
	end
	local y2max = opts.y2_max or 1
	local function y2Of(y: number): number
		return bottom - math.clamp(y / (if y2max > 0 then y2max else 1), 0, 1) * (bottom - top)
	end

	local out: { string } = { Kit.open(W, H) }
	-- Grid.
	if opts.grid ~= false then
		local grid: { string } = {}
		for _, v in yScale.ticks do
			if v >= yScale.min and v <= yScale.max then
				table.insert(grid, fmt("M%.1f %.1fH%.1f", left, yOf(v), right))
			end
		end
		for _, x in xTicks do
			if x >= xlo and x <= xhi then
				table.insert(grid, fmt("M%.1f %.1fV%.1f", xOf(x), top, bottom))
			end
		end
		if #grid > 0 then
			table.insert(out, '<path class="tg-grid" fill="none" stroke-width="1" d="' .. table.concat(grid) .. '"/>')
		end
	end
	table.insert(
		out,
		fmt('<path class="tg-axis" fill="none" stroke-width="1" d="M%.1f %.1fH%.1f"/>', left, bottom, right)
	)
	Kit.thresholds(out, {
		min = yScale.min,
		max = yScale.max,
		toPx = yOf,
		from = left,
		to = right,
	}, opts.thresholds, opts.threshold_style or "off")

	-- Rects.
	for _, r in rects do
		local buf: { string } = table.create(#r.rects)
		local yf: (number) -> number = if r.y2 then y2Of else yOf
		for _, b in r.rects do
			local x0, w: number
			if b.w then
				w = b.w :: number
				x0 = xOf(b.x0) - w / 2 + (b.dx or 0)
			else
				local a, c = xOf(b.x0), xOf(b.x1 or b.x0)
				x0, w = math.min(a, c), math.abs(c - a)
			end
			local ya, yb = yf(b.y0), yf(b.y1)
			local h = math.max(r.min_h or 1, math.abs(yb - ya))
			table.insert(buf, fmt("M%.1f %.1fh%.1fv%.1fh%.1fZ", x0, math.min(ya, yb), w, h, -w))
		end
		if #buf > 0 then
			if r.outline then
				table.insert(
					out,
					fmt(
						'<path class="%s tg-line" stroke-width="%s" d="%s"/>',
						r.class,
						tostring(r.outline),
						table.concat(buf)
					)
				)
			else
				table.insert(
					out,
					fmt(
						'<path class="%s tg-bar" fill-opacity="%.2f" d="%s"/>',
						r.class,
						r.opacity or 1,
						table.concat(buf)
					)
				)
			end
		end
	end

	-- Lines: fills first, then strokes and markers.
	local base = math.clamp(0, yScale.min, yScale.max)
	for _, l in lines do
		local fill = l.fill_opacity or 0
		if fill <= 0 or l.bars then
			continue
		end
		local buf: { string } = {}
		local runStart: number? = nil
		local n = #l.xs
		for i = 1, n + 1 do
			local v = if i <= n then finite(l.ys[i]) else nil
			if v == nil and i <= n and l.connect then
				continue
			end
			if v and runStart == nil then
				runStart = i
			elseif (v == nil or i > n) and runStart ~= nil then
				local s, e = runStart :: number, i - 1
				local pts: { string } = {}
				local function at(j: number): number?
					return finite(l.ys[j])
				end
				for j = s, e do
					local y = at(j)
					if y then
						table.insert(pts, fmt("%.1f %.1f", xOf(l.xs[j]), yOf(y)))
					end
				end
				local bottoms = l.bottoms
				if bottoms then
					for j = e, s, -1 do
						if at(j) then
							table.insert(pts, fmt("%.1f %.1f", xOf(l.xs[j]), yOf(bottoms[j])))
						end
					end
				else
					table.insert(pts, fmt("%.1f %.1f", xOf(l.xs[e]), yOf(base)))
					table.insert(pts, fmt("%.1f %.1f", xOf(l.xs[s]), yOf(base)))
				end
				table.insert(buf, "M" .. table.concat(pts, " ") .. "Z")
				runStart = if v then i else nil
			end
		end
		if #buf > 0 then
			table.insert(
				out,
				fmt('<path class="%s tg-area" fill-opacity="%.2f" d="%s"/>', l.class, fill, table.concat(buf))
			)
		end
	end
	for _, l in lines do
		local width = l.width or 1
		if l.bars then
			local n = math.max(1, #l.xs)
			local bw = math.max(1, (right - left) / n * 0.6)
			local buf: { string } = {}
			for i, x in l.xs do
				local v = finite(l.ys[i])
				if v then
					local y0 = yOf(if l.bottoms then (l.bottoms :: { number })[i] else base)
					table.insert(buf, fmt("M%.1f %.1fV%.1fh%.1fV%.1fZ", xOf(x) - bw / 2, y0, yOf(v), bw, y0))
				end
			end
			if #buf > 0 then
				local op = l.fill_opacity or 0
				table.insert(
					out,
					fmt(
						'<path class="%s tg-bar" fill-opacity="%.2f" d="%s"/>',
						l.class,
						if op > 0 then op else 0.8,
						table.concat(buf)
					)
				)
			end
		elseif width > 0 then
			local buf: { string } = {}
			local run = 0
			for i, x in l.xs do
				local v = finite(l.ys[i])
				if v then
					local px, py = xOf(x), yOf(v)
					if run == 0 then
						table.insert(buf, fmt("M%.1f %.1f", px, py))
					elseif run == 1 then
						table.insert(buf, fmt("L%.1f %.1f", px, py))
					else
						table.insert(buf, fmt(" %.1f %.1f", px, py))
					end
					run += 1
				elseif not l.connect then
					if run == 1 then
						table.insert(buf, "h0")
					end
					run = 0
				end
			end
			if run == 1 then
				table.insert(buf, "h0")
			end
			if #buf > 0 then
				table.insert(
					out,
					fmt(
						'<path class="%s tg-line" fill="none" stroke-width="%s"%s stroke-linecap="round" stroke-linejoin="round" d="%s"/>',
						l.class,
						tostring(width),
						if l.dash then fmt(' stroke-dasharray="%s"', l.dash :: string) else "",
						table.concat(buf)
					)
				)
			end
		end
		local p = l.points
		if p and p > 0 and not l.bars then
			local buf: { string } = {}
			for i, x in l.xs do
				local v = finite(l.ys[i])
				if v then
					table.insert(buf, fmt("M%.1f %.1fh0", xOf(x), yOf(v)))
				end
			end
			if #buf > 0 then
				table.insert(
					out,
					fmt(
						'<path class="%s tg-line" stroke-width="%s" stroke-linecap="round" d="%s"/>',
						l.class,
						tostring(p),
						table.concat(buf)
					)
				)
			end
		end
	end

	-- Scatters: markers filled at the series' fill opacity with a 1 px
	-- full-color outline (scatter.ts drawBubbles), one group per color class
	-- so the class's fill and stroke reach every marker.
	for _, s in scatters do
		local groups: { [string]: { string } } = {}
		local order: { string } = {}
		for i, x in s.xs do
			local v = finite(s.ys[i])
			if v == nil then
				continue
			end
			local class = if s.classes then s.classes[i] else s.class
			local r = math.max(0.5, (if s.sizes then s.sizes[i] else s.size or 5) / 2)
			local g = groups[class]
			if g == nil then
				g = {}
				groups[class] = g
				table.insert(order, class)
			end
			local px, py = xOf(x), yOf(v)
			table.insert(
				g :: { string },
				if s.square
					then fmt('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>', px - r, py - r, 2 * r, 2 * r)
					else fmt('<circle cx="%.1f" cy="%.1f" r="%.1f"/>', px, py, r)
			)
		end
		for _, class in order do
			table.insert(
				out,
				fmt(
					'<g class="%s" fill-opacity="%.2f" stroke-width="1">%s</g>',
					class,
					s.opacity or 1,
					table.concat(groups[class])
				)
			)
		end
	end

	-- Axis labels.
	if ySide ~= "hidden" then
		for i, v in yScale.ticks do
			if v >= yScale.min and v <= yScale.max then
				if ySide == "right" then
					table.insert(out, Kit.text(right + 6, yOf(v) + 4, yLabels[i], { anchor = "start" }))
				else
					table.insert(out, Kit.text(left - 6, yOf(v) + 4, yLabels[i], { anchor = "end" }))
				end
			end
		end
	end
	if showX then
		local lastEnd = -math.huge
		for i, x in xTicks do
			if x < xlo or x > xhi then
				continue
			end
			local px = xOf(x)
			local half = Kit.textWidth(xLabels[i]) / 2
			if px - half >= 0 and px + half <= W and px - half >= lastEnd then
				table.insert(out, Kit.text(px, bottom + 18, xLabels[i]))
				lastEnd = px + half + 4
			end
		end
	end
	if opts.x_label then
		table.insert(out, Kit.text((left + right) / 2, H - 4, opts.x_label :: string))
	end
	if opts.y_label then
		local x = if ySide == "right" then W - 6 else 12
		local y = (top + bottom) / 2
		table.insert(out, Kit.text(x, y, opts.y_label :: string, { rotate = -90 }))
	end
	local empty = #lines == 0 and #scatters == 0 and #rects == 0
	if empty then
		Kit.noData(out, (left + right) / 2, (top + bottom) / 2)
	end
	table.insert(out, Kit.CLOSE)
	return table.concat(out), plot
end

function M.render(opts: Options): Result
	local lines: { Line } = opts.lines or {}
	local scatters: { Scatter } = opts.scatters or {}
	local rects: { Rects } = opts.rects or {}
	local nrect = 0
	for _, r in rects do
		nrect += #r.rects
	end
	local fixed = FIXED_BYTES + nrect * BYTES_RECT
	local plotW = math.max(40, opts.width)
	local perLine = plotW
	local nLineCost = 0
	for _, l in lines do
		nLineCost += (if (l.fill_opacity or 0) > 0 then 3 else 1) + (if l.points then 1 else 0)
	end
	if nLineCost > 0 then
		perLine = math.min(perLine, math.floor((Kit.TARGET - fixed) / (nLineCost * BYTES_POINT * 2)))
	end
	local perScatter = math.huge
	if #scatters > 0 then
		perScatter = math.floor((Kit.TARGET - fixed) / (#scatters * BYTES_MARKER))
	end
	local svg, plot = "", (nil :: any) :: Plot
	local points = 0
	for _ = 1, 8 do
		local ls: { Line } = table.create(#lines)
		points = 0
		for i, l in lines do
			ls[i] = thinLine(l, math.max(3, perLine))
			points += #ls[i].xs
		end
		local ss: { Scatter } = table.create(#scatters)
		for i, s in scatters do
			ss[i] = thinScatter(s, math.max(3, perScatter))
			points += #ss[i].xs
		end
		svg, plot = build(opts, ls, ss, rects)
		if #svg <= Kit.TARGET or (perLine <= 3 and perScatter <= 3) then
			break
		end
		local shrink = Kit.TARGET / #svg * 0.9
		perLine = math.max(3, math.floor(perLine * shrink))
		if perScatter ~= math.huge then
			perScatter = math.max(3, math.floor(perScatter * shrink))
		end
	end
	assert(#svg <= Kit.CAP, "svg_xy: chart exceeds the 256 KiB SVG cap")
	return { svg = svg, plot = plot, points = points }
end

return M
