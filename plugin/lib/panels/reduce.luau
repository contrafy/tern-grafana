--!strict
-- Grafana's field reducers (packages/grafana-data/src/transformations/
-- fieldReducer.ts): doStandardCalcs plus the non-standard reducers panels can
-- pick (median, stdDev/variance, changeCount, distinctCount, p1..p99).
--
-- Values are a field's column: numbers (NaN and +-Inf included), strings,
-- booleans, or missing samples (nil or Frame.NULL). The quirks are Grafana's
-- and deliberate, so a stat reads the same number in Tern as in Grafana:
-- - nulls are skipped by default (nullValueMode "connected"); NaN is not
--   null, so it counts toward `count` but not toward sums, min or max;
-- - `delta` is the counter-reset-aware increase, `diff` is last minus first;
-- - `first`/`last` return the raw first/last value, null included.

local Frame = require("../frame/types")

export type NullMode = "connected" | "null" | "null as zero"

-- Reducer id -> value (number, string, boolean or nil).
export type Calcs = { [string]: any }

local M = {}

local NAMES: { [string]: string } = {
	lastNotNull = "Last *",
	last = "Last",
	firstNotNull = "First *",
	first = "First",
	min = "Min",
	max = "Max",
	mean = "Mean",
	median = "Median",
	variance = "Variance",
	stdDev = "StdDev",
	sum = "Total",
	count = "Count",
	countAll = "Count all",
	range = "Range",
	delta = "Delta",
	step = "Step",
	diff = "Difference",
	diffperc = "Difference percent",
	logmin = "Min (above zero)",
	allIsZero = "All Zeros",
	allIsNull = "All Nulls",
	changeCount = "Change Count",
	distinctCount = "Distinct Count",
}

local function percentileOf(id: string): number?
	local p = string.match(id, "^p(%d%d?)$")
	local n = if p then tonumber(p) else nil
	if n and n >= 1 and n <= 99 then
		return n
	end
	return nil
end

function M.supports(id: string): boolean
	return NAMES[id] ~= nil or percentileOf(id) ~= nil
end

-- The reducer's label in Grafana's UI ("Last *", "Mean", "95th %").
function M.name(id: string): string
	local named = NAMES[id]
	if named then
		return named
	end
	local p = percentileOf(id)
	if p then
		local suffix = if p > 3 and p < 21
			then "th"
			elseif p % 10 == 1 then "st"
			elseif p % 10 == 2 then "nd"
			elseif p % 10 == 3 then "rd"
			else "th"
		return tostring(p) .. suffix .. " %"
	end
	return id
end

local function isNull(v: any): boolean
	return v == nil or v == Frame.NULL
end

local function isNaN(v: any): boolean
	return type(v) == "number" and v ~= v
end

-- doStandardCalcs.
local function standard(values: { any }, numeric: boolean, ignoreNulls: boolean, nullAsZero: boolean): Calcs
	local c: Calcs = {
		sum = 0,
		count = 0,
		nonNullCount = 0,
		allIsNull = true,
		allIsZero = true,
		delta = 0,
		diffperc = 0,
	}
	local max, min, logmin, step = -math.huge, math.huge, math.huge, math.huge
	local previousDeltaUp = true
	local lastNotNull: any = nil
	local firstNotNull: any = nil
	local n = #values
	for i = 1, n do
		local v = values[i]
		if isNull(v) then
			v = nil
		end
		if i == 1 then
			c.first = v
		end
		c.last = v
		if v == nil then
			if ignoreNulls then
				continue
			end
			if nullAsZero then
				v = 0
			end
		end
		c.count += 1
		if v ~= nil and not isNaN(v) then
			local isFirst = firstNotNull == nil
			if isFirst then
				firstNotNull = v
			end
			if numeric and type(v) == "number" then
				c.sum += v
				c.allIsNull = false
				c.nonNullCount += 1
				if not isFirst and type(lastNotNull) == "number" then
					local d = v - lastNotNull
					if step > d then
						step = d
					end
					if lastNotNull > v then
						-- Counter reset.
						previousDeltaUp = false
					else
						if previousDeltaUp then
							c.delta += d
						end
						previousDeltaUp = true
					end
				end
				if v > max then
					max = v
				end
				if v < min then
					min = v
				end
				if v < logmin and v > 0 then
					logmin = v
				end
			end
			if v ~= 0 then
				c.allIsZero = false
			end
			lastNotNull = v
		end
	end
	c.firstNotNull = firstNotNull
	c.lastNotNull = lastNotNull
	c.max = if max == -math.huge and c.nonNullCount == 0 then nil else max
	c.min = if min == math.huge and c.nonNullCount == 0 then nil else min
	c.logmin = if logmin == math.huge then nil else logmin
	c.step = if step == math.huge then nil else step
	if c.nonNullCount > 0 then
		c.mean = c.sum / c.nonNullCount
	end
	if c.allIsNull then
		c.allIsZero = false
	end
	if c.max ~= nil and c.min ~= nil then
		c.range = c.max - c.min
	end
	if type(firstNotNull) == "number" and type(lastNotNull) == "number" then
		c.diff = lastNotNull - firstNotNull
		c.diffperc = c.diff / firstNotNull * 100
	end
	c.countAll = n
	if not numeric then
		c.sum = nil
	end
	return c
end

local function numbersOf(values: { any }, ignoreNulls: boolean, nullAsZero: boolean): { number }
	local out: { number } = {}
	for _, v in values do
		if isNull(v) then
			if ignoreNulls or not nullAsZero then
				continue
			end
			v = 0
		end
		if type(v) == "number" then
			table.insert(out, v)
		end
	end
	return out
end

local function sortNumbers(list: { number })
	-- NaN sorts last so it never breaks the comparator's ordering.
	table.sort(list, function(a: number, b: number): boolean
		if a ~= a then
			return false
		elseif b ~= b then
			return true
		end
		return a < b
	end)
end

local function jsRound(x: number): number
	return math.floor(x + 0.5)
end

local function extra(id: string, values: { any }, numeric: boolean, ignoreNulls: boolean, nullAsZero: boolean): any
	if id == "median" then
		local list = numbersOf(values, ignoreNulls, nullAsZero)
		if #list == 0 then
			return nil
		end
		sortNumbers(list)
		local mid = #list // 2
		if #list % 2 == 0 then
			return (list[mid] + list[mid + 1]) / 2
		end
		return list[mid + 1]
	elseif id == "variance" or id == "stdDev" then
		if not numeric then
			return 0
		end
		local squareSum, mean, count = 0, 0, 0
		for _, v in values do
			if not isNull(v) and type(v) == "number" then
				count += 1
				local old = mean
				mean += (v - old) / count
				squareSum += (v - old) * (v - mean)
			end
		end
		local variance = if count > 0 then squareSum / count else 0
		return if id == "variance" then variance else math.sqrt(variance)
	elseif id == "changeCount" then
		local count, first, last = 0, true, nil :: any
		for _, v in values do
			local cur: any = if isNull(v) then nil else v
			if cur == nil then
				if ignoreNulls then
					continue
				end
				if nullAsZero then
					cur = 0
				end
			end
			if not first and last ~= cur then
				count += 1
			end
			first = false
			last = cur
		end
		return count
	elseif id == "distinctCount" then
		local seen: { [any]: boolean } = {}
		local count = 0
		local sawNull = false
		for _, v in values do
			local cur: any = if isNull(v) then nil else v
			if cur == nil then
				if ignoreNulls then
					continue
				end
				if nullAsZero then
					cur = 0
				end
			end
			if cur == nil then
				if not sawNull then
					sawNull = true
					count += 1
				end
			elseif not seen[cur] then
				seen[cur] = true
				count += 1
			end
		end
		return count
	end
	local p = percentileOf(id)
	if p then
		local list = numbersOf(values, ignoreNulls, nullAsZero)
		if #list == 0 then
			return nil
		end
		sortNumbers(list)
		return list[jsRound((#list - 1) * p / 100) + 1]
	end
	return nil
end

local EXTRA: { [string]: boolean } =
	{ median = true, variance = true, stdDev = true, changeCount = true, distinctCount = true }

-- Every requested reducer over one column. `fieldType` decides whether
-- numeric calcs apply ("number" and "time" fields only, as in Grafana).
function M.calcs(values: { any }, ids: { string }, fieldType: string?, nullMode: NullMode?): Calcs
	local mode = nullMode or "connected"
	local ignoreNulls = mode == "connected"
	local nullAsZero = mode == "null as zero"
	local numeric = fieldType == nil or fieldType == "number" or fieldType == "time"
	local c = standard(values, numeric, ignoreNulls, nullAsZero)
	for _, id in ids do
		if EXTRA[id] or percentileOf(id) then
			c[id] = extra(id, values, numeric, ignoreNulls, nullAsZero)
		end
	end
	return c
end

-- One reducer's value.
function M.reduce(values: { any }, id: string, fieldType: string?, nullMode: NullMode?): any
	return M.calcs(values, { id }, fieldType, nullMode)[id]
end

return M
