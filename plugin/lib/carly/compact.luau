--!strict
-- Compact, bounded summaries of query results for Carly's exports and the
-- Investigate prompt: one statistics row per series instead of the raw
-- matrix, and a byte budget that every answer is cut to before it crosses
-- into Carly's VM (values over 16 KiB are refused there).

local Frame = require("../frame/types")

type Frame = Frame.Frame

export type Series = {
	name: string,
	labels: { [string]: string },
	-- Finite samples in the range (NaN, +-Inf and gaps are not counted).
	points: number,
	first: number?,
	last: number?,
	-- Time of the last finite sample, "YYYY-MM-DDTHH:MM:SSZ".
	last_at: string?,
	min: number?,
	max: number?,
	avg: number?,
	-- Up to SPARK samples spread over the range, oldest first.
	trend: { number }?,
}

export type Options = {
	-- Series kept (the largest last values first); the rest are counted.
	max_series: number?,
	-- Trend samples per series; 0 leaves the trend out.
	spark: number?,
}

local M = {}

M.MAX_SERIES = 20
M.SPARK = 12
-- What one answer may encode to: under Carly's 16 KiB cap with headroom.
M.MAX_BYTES = 12 * 1024
-- Raw response bodies above this are refused before parsing: the window
-- half runs under a 50 ms budget and a huge matrix would blow it.
M.MAX_BODY_BYTES = 2 * 1024 * 1024

local SECOND = 1000
local MINUTE = 60 * SECOND
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR

-- Four significant digits: enough to reason about, small to encode.
function M.round(v: number): number
	return tonumber(string.format("%.4g", v)) :: number
end

-- civil_from_days (Howard Hinnant), for UTC timestamps.
local function civil(days: number): (number, number, number)
	local z = days + 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return (if m <= 2 then y + 1 else y), m, d
end

-- Epoch ms as an RFC 3339 UTC time ("2026-10-09T14:58:00Z").
function M.iso(ms: number): string
	local t = math.floor(ms)
	local days = t // DAY
	local rem = t - days * DAY
	local y, m, d = civil(days)
	return string.format(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		y,
		m,
		d,
		rem // HOUR,
		rem % HOUR // MINUTE,
		rem % MINUTE // SECOND
	)
end

local function summarize(frame: Frame, field: Frame.Field, spark: number): Series
	local times = Frame.timeField(frame)
	local s: Series = {
		name = Frame.displayName(field, frame),
		labels = field.labels or {},
		points = 0,
	}
	local sum = 0
	local finite: { number } = {}
	for i, raw in field.values do
		local v = Frame.finite(raw)
		if v == nil then
			continue
		end
		s.points += 1
		sum += v
		table.insert(finite, v)
		if s.first == nil then
			s.first = v
		end
		s.last = v
		if times and type(times.values[i]) == "number" then
			s.last_at = M.iso(times.values[i])
		end
		s.min = if s.min == nil then v else math.min(s.min :: number, v)
		s.max = if s.max == nil then v else math.max(s.max :: number, v)
	end
	if s.points > 0 then
		s.avg = M.round(sum / s.points)
		s.first = M.round(s.first :: number)
		s.last = M.round(s.last :: number)
		s.min = M.round(s.min :: number)
		s.max = M.round(s.max :: number)
	end
	if spark > 0 and #finite > 1 then
		local n = math.min(spark, #finite)
		local trend: { number } = table.create(n)
		for k = 1, n do
			local at = 1 + math.floor((k - 1) * (#finite - 1) / math.max(1, n - 1) + 0.5)
			trend[k] = M.round(finite[at])
		end
		s.trend = trend
	end
	return s
end

-- (series, omitted): one summary per number field of the frames, the
-- largest last values first (series without samples last), at most
-- `max_series`.
function M.series(frames: { Frame }, opts: Options?): ({ Series }, number)
	local o: Options = opts or {}
	local maxSeries = o.max_series or M.MAX_SERIES
	local spark = o.spark or M.SPARK
	local all: { Series } = {}
	for _, frame in frames do
		for _, field in Frame.numberFields(frame) do
			table.insert(all, summarize(frame, field, spark))
		end
	end
	table.sort(all, function(a: Series, b: Series): boolean
		local la, lb = a.last, b.last
		if la ~= nil and lb ~= nil and la ~= lb then
			return la > lb
		elseif (la == nil) ~= (lb == nil) then
			return la ~= nil
		end
		return a.name < b.name
	end)
	local kept: { Series } = {}
	for i = 1, math.min(#all, maxSeries) do
		kept[i] = all[i]
	end
	return kept, #all - #kept
end

-- `s` cut to `max` characters, marking the cut.
function M.clip(s: string, max: number): string
	if #s <= max then
		return s
	end
	return string.sub(s, 1, math.max(0, max - 3)) .. "..."
end

export type Codec = {
	encode: (any) -> string,
	-- tern.json.array in Tern: tags a list so an empty one still encodes as `[]`.
	array: (<T>(T) -> T)?,
}

-- An untagged list (getmetatable nil) tagged as a JSON array; tagged or foreign tables pass through.
local function asArray(codec: Codec, list: any): any
	if codec.array and type(list) == "table" and getmetatable(list) == nil then
		return codec.array(list)
	end
	return list
end

-- Drops items from the end of `result[list]` until `encode(result)` fits
-- `max_bytes` (default MAX_BYTES), adding the number dropped to
-- `result.omitted`. The list is tagged as a JSON array so an empty answer
-- reads `[]`. Returns the result (changed in place).
function M.fit(result: { [string]: any }, list: string, codec: Codec, max_bytes: number?): { [string]: any }
	local encode = codec.encode
	local limit = max_bytes or M.MAX_BYTES
	local items = result[list]
	if type(items) ~= "table" then
		return result
	end
	result[list] = asArray(codec, items)
	if #encode(result) <= limit then
		return result
	end
	-- Size each item once, then cut where the running total crosses the
	-- budget; a final check covers separators and the omitted counter.
	local sizes: { number } = table.create(#items)
	for i, item in items do
		sizes[i] = #encode(item) + 1
	end
	result[list] = asArray(codec, {})
	local base = #encode(result) + 32
	local keep = 0
	local total = base
	for i, size in sizes do
		if total + size > limit then
			break
		end
		total += size
		keep = i
	end
	local dropped = #items - keep
	local kept = asArray(codec, table.create(keep))
	for i = 1, keep do
		kept[i] = items[i]
	end
	result[list] = kept
	result.omitted = (if type(result.omitted) == "number" then result.omitted else 0) + dropped
	while #encode(result) > limit and #kept > 0 do
		table.remove(kept)
		result.omitted += 1
	end
	return result
end

return M
