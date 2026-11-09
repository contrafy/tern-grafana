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
-- that are not numbers become NULL. A field whose values are already dense
-- (numbers or NULL, one per time) is shared, not copied: series are read
-- only.
function M.extract(frames: { Frame }, legend: string?): { Series }
	local out: { Series } = {}
	for _, frame in frames do
		local timeField = Frame.timeField(frame)
		if timeField == nil then
			continue
		end
		local times = timeField.values :: { number }
		local n = #times
		for _, field in Frame.numberFields(frame) do
			local src = field.values
			local values: { any } = src
			if #src ~= n then
				values = table.create(n)
				for i = 1, n do
					local v = src[i]
					values[i] = if type(v) == "number" then v else NULL
				end
			else
				for i = 1, n do
					local v = src[i]
					if type(v) ~= "number" and v ~= NULL then
						values = table.create(n)
						table.move(src, 1, i - 1, 1, values)
						for j = i, n do
							local w = src[j]
							values[j] = if type(w) == "number" then w else NULL
						end
						break
					end
				end
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

-- Strictly increasing times shared (or repeated element for element) by
-- every series: the join is that array as is.
local function aligned(list: { Series }): { number }?
	local first = list[1].times
	local n = #first
	for i = 2, n do
		if first[i] <= first[i - 1] then
			return nil
		end
	end
	for k = 2, #list do
		local times = list[k].times
		if times ~= first then
			if #times ~= n then
				return nil
			end
			for i = 1, n do
				if times[i] ~= first[i] then
					return nil
				end
			end
		end
	end
	return first
end

-- Outer join on time: the sorted union of all times and, per series, its
-- values on that grid (NULL where the series has no sample).
function M.join(list: { Series }): ({ number }, { { any } })
	if #list > 0 then
		local shared = aligned(list)
		if shared then
			local n = #shared
			local columns: { { any } } = table.create(#list)
			for c, s in list do
				local col: { any } = table.create(n)
				table.move(s.values, 1, n, 1, col)
				columns[c] = col
			end
			return shared, columns
		end
	end
	local seen: { [number]: boolean } = {}
	local times: { number } = {}
	local count = 0
	for _, s in list do
		for _, t in s.times do
			if not seen[t] then
				seen[t] = true
				count += 1
				times[count] = t
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
