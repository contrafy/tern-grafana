--!strict
-- TSDB head cardinality from /api/v1/status/tsdb: head stats and the four
-- top-N lists Prometheus computes over the head block.

local Env = require("../env")

type Env = Env.Env

export type Entry = { name: string, value: number }

export type Head = {
	series: number?,
	label_pairs: number?,
	chunks: number?,
	min_time_ms: number?,
	max_time_ms: number?,
}

export type Tsdb = {
	head: Head,
	-- Series per metric name.
	series_by_metric: { Entry },
	-- Distinct values per label name.
	values_by_label: { Entry },
	-- Series per `name=value` pair.
	series_by_pair: { Entry },
	-- Bytes of label index memory per label name.
	memory_by_label: { Entry },
}

export type ListName = "series_by_metric" | "values_by_label" | "series_by_pair" | "memory_by_label"

local M = {}

-- The order the block shows the lists in, with their server field names.
M.LISTS = table.freeze({
	{ name = "series_by_metric" :: ListName, field = "seriesCountByMetricName" },
	{ name = "values_by_label" :: ListName, field = "labelValueCountByLabelName" },
	{ name = "series_by_pair" :: ListName, field = "seriesCountByLabelValuePair" },
	{ name = "memory_by_label" :: ListName, field = "memoryInBytesByLabelName" },
})

-- The limits the block cycles through (the server's default is 10).
M.LIMITS = table.freeze({ 5, 10, 20, 50, 100 })
M.DEFAULT_LIMIT = 10

local function num(env: Env, v: any): number?
	v = Env.value(env, v)
	return if type(v) == "number" then v else nil
end

local function entries(env: Env, v: any): { Entry }
	local out: { Entry } = {}
	v = Env.value(env, v)
	if type(v) ~= "table" then
		return out
	end
	for _, e in v do
		if type(e) == "table" and type(e.name) == "string" and type(e.value) == "number" then
			table.insert(out, { name = e.name, value = e.value })
		end
	end
	-- The server sorts already; keep that order stable for equal values.
	table.sort(out, function(a: Entry, b: Entry): boolean
		if a.value ~= b.value then
			return a.value > b.value
		end
		return a.name < b.name
	end)
	return out
end

function M.normalize(data: any, env: Env): Tsdb
	local d = if type(data) == "table" then data else {}
	local head = Env.value(env, d.headStats)
	local h: Head = {}
	if type(head) == "table" then
		h.series = num(env, head.numSeries)
		h.label_pairs = num(env, head.numLabelPairs)
		h.chunks = num(env, head.chunkCount)
		h.min_time_ms = num(env, head.minTime)
		h.max_time_ms = num(env, head.maxTime)
	end
	return {
		head = h,
		series_by_metric = entries(env, d.seriesCountByMetricName),
		values_by_label = entries(env, d.labelValueCountByLabelName),
		series_by_pair = entries(env, d.seriesCountByLabelValuePair),
		memory_by_label = entries(env, d.memoryInBytesByLabelName),
	}
end

function M.list(t: Tsdb, name: ListName): { Entry }
	if name == "series_by_metric" then
		return t.series_by_metric
	elseif name == "values_by_label" then
		return t.values_by_label
	elseif name == "series_by_pair" then
		return t.series_by_pair
	end
	return t.memory_by_label
end

-- `entry`'s share of the head's series (series lists only); nil without a
-- series total.
function M.share(t: Tsdb, value: number): number?
	local total = t.head.series
	if total == nil or total <= 0 then
		return nil
	end
	return value / total
end

-- The next limit up (`step` 1) or down (-1), clamped to LIMITS.
function M.stepLimit(limit: number, step: number): number
	local i = table.find(M.LIMITS, limit)
	if i == nil then
		i = table.find(M.LIMITS, M.DEFAULT_LIMIT) :: number
	end
	local j = math.clamp((i :: number) + step, 1, #M.LIMITS)
	return M.LIMITS[j]
end

local function quote(s: string): string
	return '"' .. (string.gsub(s, '(["\\])', "\\%1")) .. '"'
end

-- Classic label names stay bare (Prometheus 2.x rejects quoted names); only
-- UTF-8 names, which exist only on 3.x, are quoted.
local function labelName(s: string): string
	return if string.match(s, "^[%a_][%w_]*$") then s else quote(s)
end

-- A PromQL query that breaks an entry down one level further: a metric's
-- series by job, a label's values by metric, a pair's series by metric.
-- Memory entries are label names, like values_by_label.
function M.drillQuery(name: ListName, entry: string): string?
	if name == "series_by_metric" then
		return string.format("count by (job) ({__name__=%s})", quote(entry))
	elseif name == "values_by_label" or name == "memory_by_label" then
		return string.format('count by (__name__) ({%s=~".+"})', labelName(entry))
	end
	local label, value = string.match(entry, "^([^=]+)=(.*)$")
	if label == nil or value == nil then
		return nil
	end
	return string.format("count by (__name__) ({%s=%s})", labelName(label), quote(value))
end

return M
