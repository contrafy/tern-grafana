--!strict
-- The keyboard cursor over a chart: Tern strips SVG tooltips and has no hover
-- callback, so inspection is a cursor time stepped through the drawn samples,
-- drawn as an overlay at a fraction of the image width, with each series'
-- value at that time read out in the legend.

local Frame = require("../frame/types")
local Layout = require("./layout")

type Layout = Layout.Layout

export type Reading = {
	name: string,
	class: string,
	-- Time of the sample read (nearest to the cursor), nil when the series
	-- has no samples.
	time: number?,
	-- nil when that sample is missing (a gap).
	value: number?,
}

local M = {}

function M.fraction(layout: Layout, t: number): number
	return Layout.fractionOfTime(layout, t)
end

-- Index of the time in sorted `times` nearest to `t` (earlier on a tie).
local function nearest(times: { number }, t: number): number?
	local n = #times
	if n == 0 then
		return nil
	end
	local lo, hi = 1, n
	while lo < hi do
		local mid = (lo + hi) // 2
		if times[mid] < t then
			lo = mid + 1
		else
			hi = mid
		end
	end
	-- lo is the first time >= t, or n when every time is before t.
	if times[lo] < t then
		return lo
	elseif lo > 1 and t - times[lo - 1] <= times[lo] - t then
		return lo - 1
	end
	return lo
end

-- Each series' sample nearest to `t`, in legend order. A missing sample is
-- reported as a gap rather than replaced by a farther value.
function M.read(layout: Layout, t: number): { Reading }
	local out: { Reading } = table.create(#layout.series)
	for i, s in layout.series do
		local idx = nearest(s.times, t)
		out[i] = {
			name = s.name,
			class = s.class,
			time = if idx then s.times[idx] else nil,
			value = if idx then Frame.finite(s.values[idx]) else nil,
		}
	end
	return out
end

-- The cursor time after moving `count` (default 1) drawn sample times in
-- `dir` (-1 left, +1 right), clamped to the first and last sample. Without a
-- cursor, left starts at the newest sample and right at the oldest.
function M.step(layout: Layout, t: number?, dir: number, count: number?): number?
	local times = layout.times
	local n = #times
	if n == 0 then
		return nil
	end
	if t == nil then
		return if dir < 0 then times[n] else times[1]
	end
	local i = nearest(times, t) :: number
	-- Off-grid cursor (after a re-render): the first step lands on the
	-- neighbouring sample in that direction.
	if times[i] ~= t then
		if dir > 0 and times[i] > t then
			i -= 1
		elseif dir < 0 and times[i] < t then
			i += 1
		end
	end
	local k = math.clamp(i + (if dir < 0 then -1 else 1) * (count or 1), 1, n)
	return times[k]
end

return M
