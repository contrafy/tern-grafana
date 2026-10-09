--!strict
-- Prometheus HTTP API query results (`data` of /api/v1/query and
-- /api/v1/query_range) to Frames, shaped like Grafana's own Prometheus
-- frames: one frame per series with a "Time" field and a "Value" number
-- field carrying the labels, meta.type "timeseries-multi" for a matrix and
-- "numeric-multi" for an instant vector, so both data planes reach the same
-- renderers.
--
-- Native histogram samples (`histogram`/`histograms`) have no single value to
-- plot; they are skipped with a warning instead of failing the whole query.

local Env = require("../env")
local Frame = require("./types")

type Env = Env.Env
type Frame = Frame.Frame

local M = {}

M.HISTOGRAM_WARNING = "native histogram samples are not shown (%d series); "
	.. "query them with histogram_quantile(), histogram_count() or histogram_sum()"

local SPECIAL: { [string]: number } = {
	NaN = 0 / 0,
	["+Inf"] = math.huge,
	["-Inf"] = -math.huge,
	Inf = math.huge,
}

-- A sample value string ("1.5", "NaN", "+Inf", "-Inf") as a number; NULL when
-- it is not a number at all.
function M.sample(s: any): any
	if type(s) == "number" then
		return s
	end
	if type(s) ~= "string" then
		return Frame.NULL
	end
	local special = SPECIAL[s]
	if special then
		return special
	end
	return tonumber(s) or Frame.NULL
end

-- Prometheus timestamps are float seconds; frames hold integer epoch ms.
function M.ms(t: any): number
	local n = tonumber(t) or 0
	return math.floor(n * 1000 + 0.5)
end

local function labels(env: Env, metric: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(metric) == "table" then
		for k, v in metric do
			if type(k) == "string" and not Env.isNull(env, v) then
				out[k] = tostring(v)
			end
		end
	end
	return out
end

local function meta(frameType: string, resultType: string): Frame.FrameMeta
	return { type = frameType, custom = { resultType = resultType } }
end

local function series(lbls: { [string]: string }, times: { number }, values: { any }, m: Frame.FrameMeta): Frame
	local frame = Frame.timeSeries(lbls, times, values)
	frame.meta = m
	return frame
end

-- (frames, number of series that held native histograms)
function M.matrix(result: any, env: Env): ({ Frame }, number)
	local frames: { Frame } = {}
	local histograms = 0
	if type(result) ~= "table" then
		return frames, 0
	end
	for _, s in result do
		if type(s) ~= "table" then
			continue
		end
		if type(s.histograms) == "table" and #s.histograms > 0 then
			histograms += 1
		end
		local samples = if type(s.values) == "table" then s.values else nil
		if samples == nil or #samples == 0 then
			continue
		end
		local n = #samples
		local times: { number } = table.create(n)
		local values: { any } = table.create(n)
		for i, pair in samples do
			times[i] = M.ms(pair[1])
			values[i] = M.sample(pair[2])
		end
		table.insert(frames, series(labels(env, s.metric), times, values, meta("timeseries-multi", "matrix")))
	end
	return frames, histograms
end

function M.vector(result: any, env: Env): ({ Frame }, number)
	local frames: { Frame } = {}
	local histograms = 0
	if type(result) ~= "table" then
		return frames, 0
	end
	for _, s in result do
		if type(s) ~= "table" then
			continue
		end
		local pair = s.value
		if type(pair) ~= "table" then
			if type(s.histogram) == "table" then
				histograms += 1
			end
			continue
		end
		table.insert(
			frames,
			series(labels(env, s.metric), { M.ms(pair[1]) }, { M.sample(pair[2]) }, meta("numeric-multi", "vector"))
		)
	end
	return frames, histograms
end

function M.scalar(result: any): { Frame }
	if type(result) ~= "table" then
		return {}
	end
	return { series({}, { M.ms(result[1]) }, { M.sample(result[2]) }, meta("numeric-multi", "scalar")) }
end

-- A string result: one row with a string "Value" field.
function M.string(result: any): { Frame }
	if type(result) ~= "table" then
		return {}
	end
	return {
		{
			fields = {
				Frame.field("Time", "time", { M.ms(result[1]) }),
				Frame.field("Value", "string", { tostring(result[2]) }),
			},
			meta = meta("numeric-multi", "string"),
		},
	}
end

-- Prometheus 3 reports PromQL annotations as `warnings` and `infos`; 2.53
-- puts both under `warnings`.
function M.annotations(doc: any): { string }
	local out: { string } = {}
	for _, key in { "warnings", "infos" } do
		local list = doc[key]
		if type(list) == "table" then
			for _, w in list do
				if type(w) == "string" and w ~= "" then
					table.insert(out, w)
				end
			end
		end
	end
	return out
end

-- A decoded success body `{status, data = {resultType, result}, warnings?,
-- infos?}` to a QueryResult. Error bodies are the caller's (source/prom).
function M.result(doc: any, env: Env): Frame.QueryResult
	local data = if type(doc) == "table" then doc.data else nil
	if type(data) ~= "table" then
		return { ok = false, error = { kind = "parse", message = "the response has no data object" } }
	end
	local resultType = data.resultType
	local frames: { Frame }
	local histograms = 0
	if resultType == "matrix" then
		frames, histograms = M.matrix(data.result, env)
	elseif resultType == "vector" then
		frames, histograms = M.vector(data.result, env)
	elseif resultType == "scalar" then
		frames = M.scalar(data.result)
	elseif resultType == "string" then
		frames = M.string(data.result)
	else
		return {
			ok = false,
			error = { kind = "unsupported", message = "unknown result type " .. tostring(resultType) },
		}
	end
	local warnings = M.annotations(doc)
	if histograms > 0 then
		table.insert(warnings, string.format(M.HISTOGRAM_WARNING, histograms))
	end
	return { ok = true, frames = frames, warnings = warnings }
end

return M
