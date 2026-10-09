--!strict
-- Series pulled out of frames for charting: one per number field, aligned
-- with its frame's time field; reduction calcs for legends; an outer join on
-- time and stacking (Grafana's normal and percent modes).

local Frame = require("../frame/types")

type Frame = Frame.Frame

export type Calcs = {
	-- Last non-missing value (Grafana's "Last *").
	last: number?,
	min: number?,
	max: number?,
	mean: number?,
	-- Number of finite samples behind the calcs.
	count: number,
}

export type Series = {
	name: string,
	labels: { [string]: string },
	times: { number },
	values: { any },
	unit: string?,
	decimals: number?,
}

export type StackMode = "none" | "normal" | "percent"

local M = {}

local NULL = Frame.NULL
local finite = Frame.finite

-- Nulls, NaN and +-Inf are not values: Grafana's reducers skip them, and one
-- NaN must not turn a mean or a max into NaN.
function M.calcs(values: { any }): Calcs
	local count, sum = 0, 0
	local lo: number?, hi: number?, last: number? = nil, nil, nil
	for _, raw in values do
		local v = finite(raw)
		if v then
			count += 1
			sum += v
			last = v
			if lo == nil or v < lo then
				lo = v
			end
			if hi == nil or v > hi then
				hi = v
			end
		end
	end
	return { last = last, min = lo, max = hi, mean = if count > 0 then sum / count else nil, count = count }
end

-- Every number field of every frame with a time field, in order. Values
-- that are not numbers become NULL.
function M.extract(frames: { Frame }, legend: string?): { Series }
	local out: { Series } = {}
	for _, frame in frames do
		local timeField = Frame.timeField(frame)
		if timeField == nil then
			continue
		end
		local times = timeField.values :: { number }
		for _, field in Frame.numberFields(frame) do
			local values: { any } = table.create(#times)
			for i = 1, #times do
				local v = field.values[i]
				values[i] = if type(v) == "number" then v else NULL
			end
			local config = field.config
			table.insert(out, {
				name = Frame.displayName(field, frame, legend),
				labels = field.labels or {},
				times = times,
				values = values,
				unit = if config then config.unit else nil,
				decimals = if config then config.decimals else nil,
			})
		end
	end
	return out
end

-- Outer join on time: the sorted union of all times and, per series, its
-- values on that grid (NULL where the series has no sample).
function M.join(list: { Series }): ({ number }, { { any } })
	local seen: { [number]: boolean } = {}
	local times: { number } = {}
	for _, s in list do
		for _, t in s.times do
			if not seen[t] then
				seen[t] = true
				table.insert(times, t)
			end
		end
	end
	table.sort(times)
	local index: { [number]: number } = {}
	for i, t in times do
		index[t] = i
	end
	local columns: { { any } } = table.create(#list)
	for c, s in list do
		local col: { any } = table.create(#times, NULL)
		for i, t in s.times do
			col[index[t]] = s.values[i]
		end
		columns[c] = col
	end
	return times, columns
end

-- Stacks joined columns in order. `tops[i][j]` is series i's stacked value
-- (NULL where it has no sample, so its line still breaks there) and
-- `bottoms[i][j]` the stack below it. Missing samples add nothing. Percent
-- mode stacks each value's share of the total at that time (0..1).
function M.stack(columns: { { any } }, mode: StackMode): ({ { any } }, { { number } })
	local n = if #columns > 0 then #columns[1] else 0
	local tops: { { any } } = table.create(#columns)
	local bottoms: { { number } } = table.create(#columns)
	for i = 1, #columns do
		tops[i] = table.create(n)
		bottoms[i] = table.create(n)
	end
	for j = 1, n do
		local scale = 1
		if mode == "percent" then
			local total = 0
			for i = 1, #columns do
				total += finite(columns[i][j]) or 0
			end
			scale = if total ~= 0 then 1 / total else 0
		end
		local acc = 0
		for i = 1, #columns do
			bottoms[i][j] = acc
			local v = finite(columns[i][j])
			if v then
				acc += v * scale
				tops[i][j] = acc
			else
				tops[i][j] = NULL
			end
		end
	end
	return tops, bottoms
end

return M
