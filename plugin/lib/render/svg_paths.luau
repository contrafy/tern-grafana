--!strict
-- Series path data for lib/render/svg_timeseries: lines, dots, fill areas
-- and bars as SVG path `d` strings.
--
-- Every vertex is placed on the 0.1 px grid exactly as "%.1f" rounds its
-- absolute position. A subpath starts with an absolute `M`; further
-- vertices are relative (`l`, `h`, `v`, `c`, `m`) by the difference of those
-- rounded positions, kept as whole tenths, so accumulating the deltas lands
-- on the very same vertices. Every ANCHOR-th vertex is absolute again: Tern
-- sums relative segments in single precision, and a long relative run
-- drifts far enough to change antialiased edge pixels. Numbers drop a
-- trailing ".0" and a leading "0" (".5"), and no space precedes a minus.
--
-- Each builder also returns how many bytes the same path took as absolute
-- "%.1f" coordinates (the format the point budget was tuned on), so the
-- renderer keeps choosing the same number of samples.

local Axis = require("./axis")
local Layout = require("./layout")

type Layout = Layout.Layout
type YAxis = Layout.YAxis

local M = {}

local HUGE = math.huge
local floor = math.floor

-- Where values land on one y scale, with the plot's x mapping: the
-- constants of Layout.xOfTime/yOfValue, evaluated in the same order so
-- every coordinate is bit-identical to theirs.
export type Geometry = {
	layout: Layout,
	left: number,
	right: number,
	top: number,
	bottom: number,
	t_from: number,
	span: number,
	width: number,
	height: number,
	-- Linear scale: its min, max and max - min (max <= min: every value at
	-- the middle). Other scales go through Axis.position.
	linear: boolean,
	y_min: number,
	y_max: number,
	y_span: number,
	axis: YAxis,
}

function M.geometry(layout: Layout, k: number): Geometry
	local axis = (layout.axes :: { YAxis })[k]
	return {
		layout = layout,
		left = layout.plot_left,
		right = layout.plot_right,
		top = layout.plot_top,
		bottom = layout.plot_bottom,
		t_from = layout.t_from,
		span = layout.t_to - layout.t_from,
		width = layout.plot_right - layout.plot_left,
		height = layout.plot_bottom - layout.plot_top,
		linear = (axis.distr or "linear") ~= "log" and (axis.distr or "linear") ~= "symlog",
		y_min = axis.min,
		y_max = axis.max,
		y_span = axis.max - axis.min,
		axis = axis,
	}
end

-- Layout.xOfTime clamped to the plot.
function M.x(g: Geometry, t: number): number
	local f = if g.span > 0 then (t - g.t_from) / g.span else 0.5
	local x = g.left + f * g.width
	return if x < g.left then g.left elseif x > g.right then g.right else x
end

-- Layout.yOfValue on the geometry's scale, clamped to the plot.
function M.y(g: Geometry, v: number): number
	local f: number?
	if g.linear then
		f = if g.y_max <= g.y_min then 0.5 else (v - g.y_min) / g.y_span
	else
		f = Axis.position(g.axis, v)
	end
	local y = g.bottom - (f or 0) * g.height
	return if y < g.top then g.top elseif y > g.bottom then g.bottom else y
end

-- `v` in whole tenths, rounded as "%.1f" rounds it. Halfway cases (within
-- float error of x.x5) ask string.format itself.
local function tenths(v: number): number
	local s = v * 10
	local n = floor(s + 0.5)
	local d = s - n
	if d < -0.4999999 or d > 0.4999999 then
		n = floor((tonumber(string.format("%.1f", v)) :: number) * 10 + 0.5)
	end
	return n
end

-- Number strings by tenths, for deltas and positions within +-409.5 px
-- (most of them; at most 2 x 8191 short strings stay cached).
local CACHE_LIMIT = 4096
local plain: { [number]: string } = {}
local spaced: { [number]: string } = {}

local function encode(n: number): string
	if n == 0 then
		return "0"
	end
	local a = if n < 0 then -n else n
	local whole, frac = a // 10, a % 10
	local s = if frac == 0 then tostring(whole) elseif whole == 0 then "." .. frac else whole .. "." .. frac
	return if n < 0 then "-" .. s else s
end

-- Tenths `n` as a path number: "12", "1.5", ".5", "-.5".
local function num(n: number): string
	local s = plain[n]
	if s == nil then
		s = encode(n)
		if n < CACHE_LIMIT and n > -CACHE_LIMIT then
			plain[n] = s
		end
	end
	return s
end

-- num(n) separated from a preceding number: a space, unless it starts with
-- a minus.
local function sep(n: number): string
	local s = spaced[n]
	if s == nil then
		s = if n < 0 then num(n) else " " .. num(n)
		if n < CACHE_LIMIT and n > -CACHE_LIMIT then
			spaced[n] = s
		end
	end
	return s
end

-- Length of tenths `n` printed as "%.1f".
local function legacy(n: number): number
	local len = 3
	if n < 0 then
		n = -n
		len = 4
	end
	if n >= 100 then
		len += 1
		if n >= 1000 then
			len += 1
			if n >= 10000 then
				len += 1
				n //= 100000
				while n >= 1 do
					len += 1
					n //= 10
				end
			end
		end
	end
	return len
end

-- Vertices per absolute anchor (measured on Tern Panels: none moves 74
-- edge pixels by up to 16/255, 8 leaves 3 within 13/255).
local ANCHOR = 8

local function present(v: any): boolean
	return type(v) == "number" and v == v and v ~= HUGE and v ~= -HUGE
end

export type Interpolation = "linear" | "smooth" | "stepBefore" | "stepAfter"

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

-- Path data under construction: the pieces, the current point in tenths,
-- and the absolute-format byte count.
type Buf = { parts: { string }, n: number, x: number, y: number, legacy: number }

local function newBuf(): Buf
	return { parts = {}, n = 0, x = 0, y = 0, legacy = 0 }
end

-- One edge through pixel points `p` (x1, y1, x2, y2, ...) in order: a new
-- subpath at its first point (`join` false) or a line to it from the
-- current point; then straight, stepped (stepAfter holds a value until the
-- next sample, stepBefore takes the next value at once) or smoothed.
local function edge(b: Buf, p: { number }, interp: Interpolation, join: boolean)
	local parts, k = b.parts, b.n
	local X, Y = tenths(p[1]), tenths(p[2])
	local L = legacy(X) + legacy(Y)
	parts[k + 1] = if join then "L" else "M"
	parts[k + 2] = num(X)
	parts[k + 3] = sep(Y)
	k += 3
	L += 2
	local n = #p // 2
	if n > 1 then
		if interp == "stepAfter" or interp == "stepBefore" then
			-- Walking right to left swaps which end of a step comes first.
			local after = (interp == "stepAfter") == (p[3] >= p[1])
			for i = 2, n do
				local x, y = tenths(p[2 * i - 1]), tenths(p[2 * i])
				local abs = (i - 1) % ANCHOR == 0
				local h = if abs then "H" else "h"
				local v = if abs then "V" else "v"
				local hx = if abs then num(x) else num(x - X)
				local vy = if abs then num(y) else num(y - Y)
				if after then
					parts[k + 1] = h
					parts[k + 2] = hx
					parts[k + 3] = v
					parts[k + 4] = vy
				else
					parts[k + 1] = v
					parts[k + 2] = vy
					parts[k + 3] = h
					parts[k + 4] = hx
				end
				k += 4
				L += 2 + legacy(x) + legacy(y)
				X, Y = x, y
			end
		elseif interp == "smooth" and n > 2 then
			local m = tangents(p)
			for i = 1, n - 1 do
				local x0, y0, x1, y1 = p[2 * i - 1], p[2 * i], p[2 * i + 1], p[2 * i + 2]
				local h = (x1 - x0) / 3
				local ax, ay = tenths(x0 + h), tenths(y0 + h * m[i])
				local bx, by = tenths(x1 - h), tenths(y1 - h * m[i + 1])
				local x, y = tenths(x1), tenths(y1)
				local ox, oy = X, Y
				if i % ANCHOR == 0 then
					parts[k + 1] = "C"
					ox, oy = 0, 0
				else
					parts[k + 1] = "c"
				end
				parts[k + 2] = num(ax - ox)
				parts[k + 3] = sep(ay - oy)
				parts[k + 4] = sep(bx - ox)
				parts[k + 5] = sep(by - oy)
				parts[k + 6] = sep(x - ox)
				parts[k + 7] = sep(y - oy)
				k += 7
				L += 6 + legacy(ax) + legacy(ay) + legacy(bx) + legacy(by) + legacy(x) + legacy(y)
				X, Y = x, y
			end
		else
			-- Absolute "%.1f" data spends one "L" on the whole edge.
			L += 1
			local fresh = true
			for i = 2, n do
				local x, y = tenths(p[2 * i - 1]), tenths(p[2 * i])
				if (i - 1) % ANCHOR == 0 then
					parts[k + 1] = "L"
					parts[k + 2] = num(x)
					parts[k + 3] = sep(y)
					k += 3
					fresh = true
				elseif fresh then
					parts[k + 1] = "l"
					parts[k + 2] = num(x - X)
					parts[k + 3] = sep(y - Y)
					k += 3
					fresh = false
				else
					parts[k + 1] = sep(x - X)
					parts[k + 2] = sep(y - Y)
					k += 2
				end
				L += legacy(x) + legacy(y) + (if i == 2 then 1 else 2)
				X, Y = x, y
			end
		end
	end
	b.n, b.x, b.y = k, X, Y
	b.legacy += L
end

local function finish(b: Buf): (string, number)
	return table.concat(b.parts, "", 1, b.n), b.legacy
end

-- The line through each run of present samples. A lone sample becomes a
-- zero-length segment, which a round cap still draws as a dot.
function M.line(g: Geometry, times: { number }, values: { any }, interp: Interpolation): (string, number)
	local b = newBuf()
	if interp ~= "linear" then
		local run: { number } = {}
		local c = 0
		local count = #times
		for i = 1, count + 1 do
			local v = if i <= count then values[i] else nil
			if i <= count and present(v) then
				run[c + 1] = M.x(g, times[i])
				run[c + 2] = M.y(g, v)
				c += 2
			elseif c > 0 then
				-- `run` is reused for the next run once edge has read it.
				edge(b, run, interp, false)
				if c == 2 then
					b.n += 1
					b.parts[b.n] = "h0"
					b.legacy += 2
				end
				table.clear(run)
				c = 0
			end
		end
		return finish(b)
	end
	-- Linear: straight from the samples, no point arrays.
	local parts, k, L = b.parts, 0, 0
	local left, right, top, bottom = g.left, g.right, g.top, g.bottom
	local t0, span, width, height = g.t_from, g.span, g.width, g.height
	local linear, y0, ySpan, flat = g.linear, g.y_min, g.y_span, g.y_max <= g.y_min
	local inRun, X, Y = 0, 0, 0
	for i, t in times do
		local v = values[i]
		if type(v) == "number" and v == v and v ~= HUGE and v ~= -HUGE then
			local x = left + (if span > 0 then (t - t0) / span else 0.5) * width
			if x < left then
				x = left
			elseif x > right then
				x = right
			end
			local f: number?
			if linear then
				f = if flat then 0.5 else (v - y0) / ySpan
			else
				f = Axis.position(g.axis, v)
			end
			local y = bottom - (f or 0) * height
			if y < top then
				y = top
			elseif y > bottom then
				y = bottom
			end
			local s = x * 10
			local nx = floor(s + 0.5)
			local d = s - nx
			if d < -0.4999999 or d > 0.4999999 then
				nx = tenths(x)
			end
			s = y * 10
			local ny = floor(s + 0.5)
			d = s - ny
			if d < -0.4999999 or d > 0.4999999 then
				ny = tenths(y)
			end
			if inRun == 0 then
				parts[k + 1] = "M"
				parts[k + 2] = num(nx)
				parts[k + 3] = sep(ny)
				k += 3
				L += 2 + legacy(nx) + legacy(ny)
			elseif inRun % ANCHOR == 0 then
				parts[k + 1] = "L"
				parts[k + 2] = num(nx)
				parts[k + 3] = sep(ny)
				k += 3
				L += 2 + legacy(nx) + legacy(ny)
			elseif inRun % ANCHOR == 1 then
				parts[k + 1] = "l"
				parts[k + 2] = num(nx - X)
				parts[k + 3] = sep(ny - Y)
				k += 3
				L += 2 + legacy(nx) + legacy(ny)
			else
				parts[k + 1] = sep(nx - X)
				parts[k + 2] = sep(ny - Y)
				k += 2
				L += 2 + legacy(nx) + legacy(ny)
			end
			inRun += 1
			X, Y = nx, ny
		else
			if inRun == 1 then
				k += 1
				parts[k] = "h0"
				L += 2
			end
			inRun = 0
		end
	end
	if inRun == 1 then
		k += 1
		parts[k] = "h0"
		L += 2
	end
	return table.concat(parts, "", 1, k), L
end

-- Dots (zero-length round-capped segments) at the samples; `lone` keeps
-- only samples with no present neighbor (uPlot's points filter for gaps).
function M.dots(g: Geometry, times: { number }, values: { any }, lone: boolean): (string, number)
	local parts, k, L = {}, 0, 0
	local X, Y = 0, 0
	local count = 0
	local n = #times
	for i = 1, n do
		local v = values[i]
		if not present(v) then
			continue
		end
		if lone and ((i > 1 and present(values[i - 1])) or (i < n and present(values[i + 1]))) then
			continue
		end
		local x, y = tenths(M.x(g, times[i])), tenths(M.y(g, v))
		if count % ANCHOR == 0 then
			parts[k + 1] = "M"
			parts[k + 2] = num(x)
			parts[k + 3] = sep(y)
		else
			parts[k + 1] = "m"
			parts[k + 2] = num(x - X)
			parts[k + 3] = sep(y - Y)
		end
		parts[k + 4] = "h0"
		k += 4
		count += 1
		L += 4 + legacy(x) + legacy(y)
		X, Y = x, y
	end
	return table.concat(parts, "", 1, k), L
end

-- Closed areas between each run of present values and its base: the
-- stacked bottoms, the values of the fillBelowTo series (`below`, by
-- time), or the axis baseline.
function M.area(
	g: Geometry,
	times: { number },
	tops: { any },
	bottoms: { number }?,
	below: { [number]: number }?,
	base: number,
	interp: Interpolation
): (string, number)
	local b = newBuf()
	local n = #times
	local runStart: number? = nil
	for i = 1, n + 1 do
		local v = if i <= n and present(tops[i]) then tops[i] else nil
		if v and below and below[times[i]] == nil then
			v = nil
		end
		if v and runStart == nil then
			runStart = i
		elseif v == nil and runStart ~= nil then
			local s, e = runStart, i - 1
			local top: { number } = table.create(2 * (e - s + 1))
			local c = 0
			for j = s, e do
				top[c + 1] = M.x(g, times[j])
				top[c + 2] = M.y(g, tops[j] :: number)
				c += 2
			end
			edge(b, top, interp, false)
			if bottoms or below then
				local bot: { number } = table.create(2 * (e - s + 1))
				c = 0
				for j = e, s, -1 do
					bot[c + 1] = M.x(g, times[j])
					bot[c + 2] = M.y(g, if bottoms then bottoms[j] else (below :: { [number]: number })[times[j]])
					c += 2
				end
				edge(b, bot, interp, true)
			else
				local yb = tenths(M.y(g, base))
				local xe, xs = tenths(M.x(g, times[e])), tenths(M.x(g, times[s]))
				local parts, k = b.parts, b.n
				parts[k + 1] = "L"
				parts[k + 2] = num(xe)
				parts[k + 3] = sep(yb)
				parts[k + 4] = sep(xs)
				parts[k + 5] = sep(yb)
				b.n = k + 5
				b.x, b.y = xs, yb
				b.legacy += 4 + 2 * legacy(yb) + legacy(xe) + legacy(xs)
			end
			b.n += 1
			b.parts[b.n] = "Z"
			b.legacy += 1
			runStart = nil
		end
	end
	return finish(b)
end

-- Bars `barW` wide, centered on their time (align 0), ending at it (-1) or
-- starting at it (1), as uPlot's bars path builder places them.
function M.bars(
	g: Geometry,
	times: { number },
	tops: { any },
	bottoms: { number }?,
	base: number,
	barW: number,
	align: number
): (string, number)
	local parts, k, L = {}, 0, 0
	local X, Y = 0, 0
	local count = 0
	local shift = if align == 1 then 0 elseif align == -1 then -barW else -barW / 2
	local left, right = g.left, g.right
	for i, t in times do
		local v = tops[i]
		if present(v) then
			-- uPlot clips the plot; bars at its edges are cut to it.
			local x = math.max(left, M.x(g, t) + shift)
			local w = math.min(right, M.x(g, t) + shift + barW) - x
			if w > 0 then
				local nx, ny = tenths(x), tenths(M.y(g, if bottoms then bottoms[i] else base))
				local top, nw = tenths(M.y(g, v)), tenths(w)
				if count % ANCHOR == 0 then
					parts[k + 1] = "M"
					parts[k + 2] = num(nx)
					parts[k + 3] = sep(ny)
				else
					parts[k + 1] = "m"
					parts[k + 2] = num(nx - X)
					parts[k + 3] = sep(ny - Y)
				end
				parts[k + 4] = "V"
				parts[k + 5] = num(top)
				parts[k + 6] = "h"
				parts[k + 7] = num(nw)
				parts[k + 8] = "V"
				parts[k + 9] = num(ny)
				parts[k + 10] = "Z"
				k += 10
				count += 1
				L += 6 + 2 * legacy(ny) + legacy(nx) + legacy(top) + legacy(nw)
				X, Y = nx, ny
			end
		end
	end
	return table.concat(parts, "", 1, k), L
end

return M
