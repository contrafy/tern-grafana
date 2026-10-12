--!strict
-- OTLP traces in JSON as Tempo serves them: `/api/traces/<id>` answers
-- `{batches: [ResourceSpans]}`, `/api/v2/traces/<id>` answers
-- `{trace: {resourceSpans: [...]}}`, and an OTLP export is
-- `{resourceSpans: [...]}`. Older writers name the scope level
-- `instrumentationLibrarySpans`. Ids may be base64 (protobuf JSON) or hex
-- (OTLP JSON); kinds and status codes may be enum names or numbers.

local Env = require("../env")
local Ids = require("./ids")
local Nanos = require("./nanos")
local Types = require("./types")

type Env = Env.Env
type Attr = Types.Attr
type RawSpan = Types.RawSpan
type Kind = Types.Kind
type Status = Types.Status

local M = {}

local KIND_NAMES: { [string]: Kind } = {
	SPAN_KIND_SERVER = "server",
	SPAN_KIND_CLIENT = "client",
	SPAN_KIND_PRODUCER = "producer",
	SPAN_KIND_CONSUMER = "consumer",
	SPAN_KIND_INTERNAL = "internal",
	SPAN_KIND_UNSPECIFIED = "unspecified",
}
local KIND_NUMBERS: { Kind } = { "internal", "server", "client", "producer", "consumer" }

local STATUS_NAMES: { [string]: Status } = {
	STATUS_CODE_UNSET = "unset",
	STATUS_CODE_OK = "ok",
	STATUS_CODE_ERROR = "error",
}
local STATUS_NUMBERS: { [number]: Status } = { [0] = "unset", [1] = "ok", [2] = "error" }

local function list(env: Env, v: any): { any }
	local x = Env.value(env, v)
	return if type(x) == "table" then x else {}
end

local function str(env: Env, v: any): string?
	local x = Env.value(env, v)
	return if type(x) == "string" then x else nil
end

local function number(n: number): string
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return string.format("%.15g", n)
end

local valueText: (env: Env, v: any) -> (string, "string" | "number" | "boolean" | "other")

-- An OTLP AnyValue as display text.
function valueText(env: Env, v: any): (string, "string" | "number" | "boolean" | "other")
	local any = Env.value(env, v)
	if type(any) ~= "table" then
		return "", "other"
	end
	local s = Env.value(env, any.stringValue)
	if s ~= nil then
		return tostring(s), "string"
	end
	local b = Env.value(env, any.boolValue)
	if b ~= nil then
		return if b == true then "true" else "false", "boolean"
	end
	local i = Env.value(env, any.intValue)
	if i ~= nil then
		return if type(i) == "number" then number(i) else tostring(i), "number"
	end
	local d = Env.value(env, any.doubleValue)
	if d ~= nil then
		return if type(d) == "number" then number(d) else tostring(d), "number"
	end
	local bytes = Env.value(env, any.bytesValue)
	if bytes ~= nil then
		return tostring(bytes), "other"
	end
	local arr = Env.value(env, any.arrayValue)
	if type(arr) == "table" then
		local parts: { string } = {}
		for _, item in list(env, arr.values) do
			local text, kind = valueText(env, item)
			table.insert(parts, if kind == "string" then string.format("%q", text) else text)
		end
		return "[" .. table.concat(parts, ", ") .. "]", "other"
	end
	local kvl = Env.value(env, any.kvlistValue)
	if type(kvl) == "table" then
		local parts: { string } = {}
		for _, kv in list(env, kvl.values) do
			if type(kv) == "table" then
				local text = valueText(env, kv.value)
				table.insert(parts, tostring(str(env, kv.key) or "") .. ": " .. text)
			end
		end
		return "{" .. table.concat(parts, ", ") .. "}", "other"
	end
	return "", "other"
end

M.valueText = valueText

-- OTLP `[{key, value: AnyValue}]` in the order sent.
function M.attributes(env: Env, raw: any): { Attr }
	local out: { Attr } = {}
	for _, kv in list(env, raw) do
		if type(kv) == "table" then
			local key = str(env, kv.key)
			if key then
				local text, kind = valueText(env, kv.value)
				table.insert(out, { key = key, value = text, kind = kind } :: Attr)
			end
		end
	end
	return out
end

function M.attr(attrs: { Attr }, key: string): string?
	for _, a in attrs do
		if a.key == key then
			return a.value
		end
	end
	return nil
end

local function kind(env: Env, v: any): Kind
	local x = Env.value(env, v)
	if type(x) == "string" then
		return KIND_NAMES[x] or KIND_NAMES["SPAN_KIND_" .. string.upper(x)] or "unspecified"
	elseif type(x) == "number" then
		return KIND_NUMBERS[x] or "unspecified"
	end
	return "unspecified"
end

local function status(env: Env, raw: any): (Status, string?)
	local st = Env.value(env, raw)
	if type(st) ~= "table" then
		return "unset", nil
	end
	local code = Env.value(env, st.code)
	local out: Status = "unset"
	if type(code) == "string" then
		out = STATUS_NAMES[code] or "unset"
	elseif type(code) == "number" then
		out = STATUS_NUMBERS[code] or "unset"
	end
	local message = str(env, st.message)
	return out, if message and message ~= "" then message else nil
end

local function span(
	env: Env,
	raw: any,
	resource: { Attr },
	service: string,
	scope: string?,
	scopeVersion: string?
): RawSpan?
	if type(raw) ~= "table" then
		return nil
	end
	local traceId = Ids.trace(Env.value(env, raw.traceId))
	local spanId = Ids.span(Env.value(env, raw.spanId))
	local start = Nanos.parse(Env.value(env, raw.startTimeUnixNano))
	local stop = Nanos.parse(Env.value(env, raw.endTimeUnixNano))
	if traceId == nil or spanId == nil or start == nil then
		return nil
	end
	local st: Status, message = status(env, raw.status)
	local events = {}
	for _, ev in list(env, raw.events) do
		if type(ev) == "table" then
			table.insert(events, {
				time = Nanos.parse(Env.value(env, ev.timeUnixNano)),
				name = str(env, ev.name) or "",
				attributes = M.attributes(env, ev.attributes),
			})
		end
	end
	local links = {}
	for _, l in list(env, raw.links) do
		if type(l) == "table" then
			local lt, ls = Ids.trace(Env.value(env, l.traceId)), Ids.span(Env.value(env, l.spanId))
			if lt and ls then
				table.insert(links, { trace_id = lt, span_id = ls, attributes = M.attributes(env, l.attributes) })
			end
		end
	end
	return {
		trace_id = traceId,
		span_id = spanId,
		parent_id = Ids.span(Env.value(env, raw.parentSpanId)),
		name = str(env, raw.name) or "",
		service = service,
		kind = kind(env, raw.kind),
		status = st,
		status_message = message,
		start = start,
		-- A span still open (no end) reads as instantaneous.
		stop = stop or start,
		attributes = M.attributes(env, raw.attributes),
		resource = resource,
		scope = scope,
		scope_version = scopeVersion,
		events = events,
		links = links,
	}
end

-- The ResourceSpans list of any of the accepted documents; nil when `doc`
-- is none of them.
local function resourceSpans(env: Env, doc: any): { any }?
	if type(doc) ~= "table" then
		return nil
	end
	local inner = Env.value(env, doc.trace)
	if type(inner) == "table" then
		doc = inner
	end
	local batches = Env.value(env, doc.batches)
	if type(batches) == "table" then
		return batches
	end
	local rs = Env.value(env, doc.resourceSpans)
	if type(rs) == "table" then
		return rs
	end
	-- `{trace: {}}` / `{}`: a known shape with no spans.
	if inner ~= nil or next(doc) == nil then
		return {}
	end
	return nil
end

-- Every span of the document, or nil and why it is not an OTLP trace.
function M.parse(doc: any, env: Env): ({ RawSpan }?, string?)
	local batches = resourceSpans(env, doc)
	if batches == nil then
		return nil, "the answer is not an OTLP trace (no batches or resourceSpans)"
	end
	local out: { RawSpan } = {}
	for _, rs in batches do
		if type(rs) ~= "table" then
			continue
		end
		local res = Env.value(env, rs.resource)
		local resource = M.attributes(env, if type(res) == "table" then res.attributes else nil)
		local service = M.attr(resource, "service.name") or "unknown"
		local scopes = Env.value(env, rs.scopeSpans)
		if type(scopes) ~= "table" then
			scopes = Env.value(env, rs.instrumentationLibrarySpans)
		end
		for _, ss in (if type(scopes) == "table" then scopes else {}) :: { any } do
			if type(ss) ~= "table" then
				continue
			end
			local sc = Env.value(env, ss.scope)
			if type(sc) ~= "table" then
				sc = Env.value(env, ss.instrumentationLibrary)
			end
			local scopeName = if type(sc) == "table" then str(env, sc.name) else nil
			local scopeVersion = if type(sc) == "table" then str(env, sc.version) else nil
			for _, raw in list(env, ss.spans) do
				local s = span(
					env,
					raw,
					resource,
					service,
					if scopeName ~= "" then scopeName else nil,
					if scopeVersion ~= "" then scopeVersion else nil
				)
				if s then
					table.insert(out, s)
				end
			end
		end
	end
	return out, nil
end

return M
