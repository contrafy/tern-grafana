--!strict
-- Before/after math of an impact watch. The before window is the `window_ms`
-- that ended when the command started; the after window starts when it
-- finished and lasts as long. Each side is the mean of its finite samples;
-- the delta is after minus before, in percent of |before| when before is not
-- zero. A change under FLAT_PCT is flat; otherwise the tone says whether it
-- moved the bad way (signal.bad) and how far.

local Frame = require("../frame/types")

type Frame = Frame.Frame

export type Direction = "up" | "down" | "flat"
export type Tone = "success" | "warning" | "error" | "info" | "muted"

export type Side = { mean: number?, n: number }

export type Comparison = {
	before: Side,
	after: Side,
	delta: number?,
	-- nil when before is 0 (or either side has no samples).
	pct: number?,
	direction: Direction?,
	tone: Tone,
}

export type Series = { name: string, labels: { [string]: string }, times: { number }, values: { number? } }

export type Window = { start_ms: number, finish_ms: number, window_ms: number }

local M = {}

M.FLAT_PCT = 5
M.BAD_PCT = 25
-- A difference this small (absolute) counts as flat when before is zero.
M.EPSILON = 1e-9

-- One series per number field of each frame, values aligned to the time field.
function M.series(frames: { Frame }): { Series }
	local out: { Series } = {}
	for _, frame in frames do
		local tf = Frame.timeField(frame)
		if tf == nil then
			continue
		end
		for _, f in Frame.numberFields(frame) do
			local values: { number? } = table.create(#tf.values)
			local times: { number } = table.create(#tf.values)
			for i, t in tf.values do
				if type(t) == "number" then
					table.insert(times, t)
					values[#times] = Frame.finite(f.values[i])
				end
			end
			local name = Frame.formatLabels(f.labels)
			table.insert(out, { name = name, labels = f.labels or {}, times = times, values = values })
		end
	end
	return out
end

local function mean(s: Series, from: number, to: number): Side
	local sum, n = 0, 0
	for i, t in s.times do
		local v = s.values[i]
		if t >= from and t <= to and v ~= nil then
			sum += v
			n += 1
		end
	end
	return { mean = if n > 0 then sum / n else nil, n = n }
end

-- Before is [start - window, start); after is [finish, finish + window].
function M.sides(s: Series, w: Window): (Side, Side)
	local before = mean(s, w.start_ms - w.window_ms, w.start_ms - 1)
	local after = mean(s, w.finish_ms, w.finish_ms + w.window_ms)
	return before, after
end

function M.compare(before: Side, after: Side, bad: "up" | "down" | "none"): Comparison
	local out: Comparison = { before = before, after = after, delta = nil, pct = nil, direction = nil, tone = "muted" }
	if before.mean == nil or after.mean == nil then
		return out
	end
	local b, a = before.mean :: number, after.mean :: number
	local delta = a - b
	out.delta = delta
	local direction: Direction
	if b ~= 0 then
		local pct = delta / math.abs(b) * 100
		out.pct = pct
		direction = if math.abs(pct) < M.FLAT_PCT then "flat" elseif pct > 0 then "up" else "down"
	else
		direction = if math.abs(delta) <= M.EPSILON then "flat" elseif delta > 0 then "up" else "down"
	end
	out.direction = direction
	if direction == "flat" or (bad ~= "none" and direction ~= bad) then
		out.tone = "success"
	elseif bad == "none" then
		out.tone = "info"
	elseif out.pct == nil or math.abs(out.pct :: number) >= M.BAD_PCT then
		-- From zero to anything the bad way (errors appearing) is the worst case.
		out.tone = "error"
	else
		out.tone = "warning"
	end
	return out
end

-- "+12.5%", "-3.0%", "new" (before was 0), "" (no comparison).
function M.formatPct(c: Comparison): string
	if c.delta == nil then
		return ""
	elseif c.pct then
		return string.format("%+.1f%%", c.pct :: number)
	elseif c.direction == "flat" then
		return "+0.0%"
	end
	return if (c.delta :: number) > 0 then "up from 0" else "down to <0"
end

-- Up to `max` points of the series inside [from, to], bucketed by time
-- (mean per bucket; empty buckets nil) for a spark.
function M.buckets(s: Series, from: number, to: number, max: number): { number? }
	local out: { number? } = {}
	if to <= from or max < 1 then
		return out
	end
	local sums: { number } = table.create(max, 0)
	local counts: { number } = table.create(max, 0)
	local span = to - from
	for i, t in s.times do
		local v = s.values[i]
		if v ~= nil and t >= from and t <= to then
			local b = math.min(max, math.floor((t - from) / span * max) + 1)
			sums[b] += v
			counts[b] += 1
		end
	end
	for b = 1, max do
		out[b] = if counts[b] > 0 then sums[b] / counts[b] else nil
	end
	return out
end

return M
