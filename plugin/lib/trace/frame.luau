--!strict
-- Grafana's Trace data frame (/api/ds/query with a Tempo `traceId` query,
-- Grafana 11 and 12 alike) to raw spans. One row per span: hex ids,
-- startTime and duration in fractional milliseconds, statusCode 0/1/2 (unset,
-- ok, error), kind in lower case, and JSON columns serviceTags (resource
-- attributes), tags (span attributes), logs (events) and references (links).

local Env = require("../env")
local FrameTypes = require("../frame/types")
local Ids = require("./ids")
local Nanos = require("./nanos")
local Types = require("./types")

type Env = Env.Env
type Frame = FrameTypes.Frame
type Attr = Types.Attr
type RawSpan = Types.RawSpan
type Kind = Types.Kind
type Status = Types.Status

local M = {}

local KINDS: { [string]: Kind } = {
	server = "server",
	client = "client",
	producer = "producer",
	consumer = "consumer",
	internal = "internal",
}
local STATUS: { [number]: Status } = { [0] = "unset", [1] = "ok", [2] = "error" }

local function column(frame: Frame, name: string): { any }
	for _, f in frame.fields do
		if f.name == name then
			return f.values
		end
	end
	return {}
end

local function value(v: any): any
	return if FrameTypes.isNull(v) then nil else v
end

local function str(v: any): string?
	local x = value(v)
	return if type(x) == "string" and x ~= "" then x else nil
end

local function text(env: Env, v: any): (string, "string" | "number" | "boolean" | "other")
	local x = Env.value(env, v)
	if type(x) == "string" then
		return x, "string"
	elseif type(x) == "number" then
		if x == math.floor(x) and math.abs(x) < 2 ^ 53 then
			return string.format("%d", x), "number"
		end
		return string.format("%.15g", x), "number"
	elseif type(x) == "boolean" then
		return if x then "true" else "false", "boolean"
	elseif x == nil then
		return "", "other"
	end
	local ok, encoded = pcall(env.encode, x)
	return if ok then encoded else "", "other"
end

-- `[{key, value}]` (TraceKeyValuePair).
local function pairsOf(env: Env, raw: any): { Attr }
	local out: { Attr } = {}
	local list = value(Env.value(env, raw))
	if type(list) ~= "table" then
		return out
	end
	for _, kv in list do
		if type(kv) == "table" and type(Env.value(env, kv.key)) == "string" then
			local t, kind = text(env, kv.value)
			table.insert(out, { key = kv.key, value = t, kind = kind } :: Attr)
		end
	end
	return out
end

local function attr(attrs: { Attr }, key: string): string?
	for _, a in attrs do
		if a.key == key then
			return a.value
		end
	end
	return nil
end

-- The spans of a Trace frame; nil when the frame is not one.
function M.spans(frame: Frame, env: Env): { RawSpan }?
	local traceIds, spanIds, starts = column(frame, "traceID"), column(frame, "spanID"), column(frame, "startTime")
	if #spanIds == 0 and #traceIds == 0 then
		return if frame.name == "Trace" then {} else nil
	end
	local parents, names, services =
		column(frame, "parentSpanID"), column(frame, "operationName"), column(frame, "serviceName")
	local kinds, codes, messages = column(frame, "kind"), column(frame, "statusCode"), column(frame, "statusMessage")
	local scopes, versions = column(frame, "instrumentationLibraryName"), column(frame, "instrumentationLibraryVersion")
	local serviceTags, tags = column(frame, "serviceTags"), column(frame, "tags")
	local durations, logs, refs = column(frame, "duration"), column(frame, "logs"), column(frame, "references")
	local out: { RawSpan } = {}
	for i = 1, #spanIds do
		local traceId, spanId = Ids.trace(value(traceIds[i])), Ids.span(value(spanIds[i]))
		local startMs = value(starts[i])
		if traceId == nil or spanId == nil or type(startMs) ~= "number" then
			continue
		end
		local durMs = value(durations[i])
		local start = Nanos.fromMs(startMs)
		local resource = pairsOf(env, serviceTags[i])
		local events = {}
		local rawLogs = value(Env.value(env, logs[i]))
		if type(rawLogs) == "table" then
			for _, ev in rawLogs do
				if type(ev) == "table" then
					local ts = Env.value(env, ev.timestamp)
					local name = Env.value(env, ev.name)
					table.insert(events, {
						time = if type(ts) == "number" then Nanos.fromMs(ts) else nil,
						name = if type(name) == "string" then name else "",
						attributes = pairsOf(env, ev.fields),
					})
				end
			end
		end
		local links = {}
		local rawRefs = value(Env.value(env, refs[i]))
		if type(rawRefs) == "table" then
			for _, ref in rawRefs do
				if type(ref) == "table" then
					local lt, ls = Ids.trace(Env.value(env, ref.traceID)), Ids.span(Env.value(env, ref.spanID))
					if lt and ls then
						table.insert(links, { trace_id = lt, span_id = ls, attributes = pairsOf(env, ref.tags) })
					end
				end
			end
		end
		local code = value(codes[i])
		out[#out + 1] = {
			trace_id = traceId,
			span_id = spanId,
			parent_id = Ids.span(value(parents[i])),
			name = str(names[i]) or "",
			service = str(services[i]) or attr(resource, "service.name") or "unknown",
			kind = KINDS[string.lower(str(kinds[i]) or "")] or "unspecified",
			status = if type(code) == "number" then STATUS[code] or "unset" else "unset",
			status_message = str(messages[i]),
			start = start,
			stop = if type(durMs) == "number" and durMs > 0
				then Nanos.add(start, math.floor(durMs * 1e6 + 0.5))
				else start,
			attributes = pairsOf(env, tags[i]),
			resource = resource,
			scope = str(scopes[i]),
			scope_version = str(versions[i]),
			events = events,
			links = links,
		}
	end
	return out
end

return M
