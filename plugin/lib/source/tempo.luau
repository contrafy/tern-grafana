--!strict
-- Tempo HTTP API for the trace block: a trace by id, TraceQL search, and the
-- tag names and values that feed search suggestions. A direct route calls
-- Tempo; a datasource route goes through Grafana, either `/api/ds/query`
-- (Tempo queries `traceId` and `traceql`) or the datasource proxy, which
-- relays Tempo's own paths and answers. Grafana 11.6's Tempo plugin answers
-- every TraceQL search through /api/ds/query with HTTP 500
-- (`plugin.requestFailureError`) while the proxy works, so the block falls
-- back to the proxy on a 5xx from /api/ds/query (`fallback`).

local Env = require("../env")
local FrameTypes = require("../frame/types")
local Grafana = require("./grafana")
local Http = require("../transport/http")
local Ids = require("../trace/ids")
local Nanos = require("../trace/nanos")
local Otlp = require("../trace/otlp")
local Response = require("./response")
local Route = require("../config/route")
local TraceFrame = require("../trace/frame")
local TraceTypes = require("../trace/types")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type QueryError = TransportTypes.QueryError
type RawSpan = TraceTypes.RawSpan
type Frame = FrameTypes.Frame

-- How a request reaches Tempo: direct, Grafana's /api/ds/query, or Grafana's
-- datasource proxy.
export type Mode = "direct" | "dsquery" | "proxy"

export type SearchService = { name: string, spans: number, errors: number }

export type SearchHit = {
	trace_id: string,
	root_service: string?,
	root_name: string?,
	start_ms: number?,
	duration_ms: number?,
	-- Spans the query matched (Tempo's spanSet.matched).
	matched: number?,
	services: { SearchService },
	errors: number,
}

export type Tag = { scope: string, name: string }

export type TraceResult = { ok: true, spans: { RawSpan } } | { ok: false, error: QueryError }
export type SearchResult = { ok: true, hits: { SearchHit } } | { ok: false, error: QueryError }
export type TagsResult = { ok: true, tags: { Tag } } | { ok: false, error: QueryError }
export type ValuesResult = { ok: true, values: { string } } | { ok: false, error: QueryError }

export type Search = { q: string, limit: number, from_ms: number, to_ms: number }

local M = {}

M.REF = "A"

-- The mode a route starts with.
function M.mode(route: Route): Mode
	if route.via == "direct" then
		return "direct"
	end
	if route.via ~= "datasource" or route.datasource_uid == nil then
		error("tempo: route has no tempo endpoint or datasource uid", 2)
	end
	return "dsquery"
end

-- True when a failed /api/ds/query answer should be retried through the
-- datasource proxy: Grafana's plugin failed, not the query.
function M.fallback(mode: Mode, err: QueryError): boolean
	return mode == "dsquery" and err.status ~= nil and (err.status :: number) >= 500
end

local function base(route: Route, mode: Mode): string
	if mode == "direct" then
		return ""
	end
	return Grafana.proxyBase(route.datasource_uid :: string)
end

local function datasource(route: Route): { [string]: any }
	return { type = "tempo", uid = route.datasource_uid }
end

local ACCEPT_JSON = { Accept = "application/json" }

-- `id` is hex (any width up to 32).
function M.traceRequest(route: Route, mode: Mode, id: string, env: Env): Request
	if mode == "dsquery" then
		-- Tempo looks a trace up by id without a time range; Grafana requires one.
		local now = env.now_ms
		return Grafana.dsQueryRequest(route, {
			{ refId = M.REF, datasource = datasource(route), queryType = "traceId", query = id },
		}, { from_ms = now - 3600000, to_ms = now }, env)
	end
	return { method = "GET", path = base(route, mode) .. "/api/traces/" .. Http.escape(id), headers = ACCEPT_JSON }
end

local function seconds(ms: number): string
	return string.format("%d", math.floor(ms / 1000))
end

function M.searchRequest(route: Route, mode: Mode, s: Search, env: Env): Request
	if mode == "dsquery" then
		return Grafana.dsQueryRequest(route, {
			{
				refId = M.REF,
				datasource = datasource(route),
				queryType = "traceql",
				query = s.q,
				limit = s.limit,
				tableType = "traces",
			},
		}, { from_ms = s.from_ms, to_ms = s.to_ms }, env)
	end
	return {
		method = "GET",
		path = base(route, mode) .. "/api/search",
		query = {
			{ "q", s.q },
			{ "limit", string.format("%d", s.limit) },
			{ "start", seconds(s.from_ms) },
			{ "end", seconds(s.to_ms) },
		},
		headers = ACCEPT_JSON,
	}
end

-- Tag names by scope; never through /api/ds/query.
function M.tagsRequest(route: Route, mode: Mode): Request
	local m: Mode = if mode == "dsquery" then "proxy" else mode
	return { method = "GET", path = base(route, m) .. "/api/v2/search/tags", headers = ACCEPT_JSON }
end

-- Values of one tag; `tag` is scoped ("resource.service.name") or intrinsic.
function M.tagValuesRequest(route: Route, mode: Mode, tag: string): Request
	local m: Mode = if mode == "dsquery" then "proxy" else mode
	return {
		method = "GET",
		path = base(route, m) .. "/api/v2/search/tag/" .. Http.escape(tag) .. "/values",
		headers = ACCEPT_JSON,
	}
end

local function fail(kind: any, message: string, status: number?): { ok: false, error: QueryError }
	return { ok = false, error = { kind = kind, message = message, status = status } }
end

-- The decoded body or the error. Tempo answers errors as plain text
-- ("invalid TraceQL query: ..."), kept whole as a query error on 400.
local function tempoJson(response: Response, env: Env, what: string): (any, QueryError?)
	local doc, err = Response.json(response, env, what)
	if err == nil then
		return doc, nil
	end
	local e = err :: QueryError
	if e.status == 400 and doc == nil then
		e.kind = "query"
		local line = string.match(response.body, "^%s*([^\r\n]+)")
		if line then
			e.message = line
		end
	end
	return nil, e
end

local function dsFrames(response: Response, env: Env): ({ Frame }?, QueryError?)
	local parsed = Grafana.parseDsQuery(response, env)
	if not parsed.ok then
		return nil, (parsed :: any).error
	end
	local r = (parsed :: any).results[M.REF]
	if r == nil then
		return {}, nil
	end
	if not r.ok then
		return nil, r.error
	end
	return r.frames, nil
end

function M.parseTrace(mode: Mode, response: Response, env: Env): TraceResult
	-- Tempo's 404 has an empty body; a JSON 404 is Grafana explaining
	-- something else (an unknown datasource) and stays an HTTP error.
	if response.status == 404 and not response.failure and not string.find(response.body, "^%s*{") then
		return fail("query", "trace not found", 404)
	end
	if mode == "dsquery" then
		local frames, err = dsFrames(response, env)
		if err then
			return { ok = false, error = err }
		end
		local spans: { RawSpan } = {}
		for _, f in frames :: { Frame } do
			local list = TraceFrame.spans(f, env)
			if list then
				table.move(list, 1, #list, #spans + 1, spans)
			end
		end
		if #spans == 0 then
			return fail("query", "trace not found", response.status)
		end
		return { ok = true, spans = spans }
	end
	local doc, err = tempoJson(response, env, "/api/traces")
	if err then
		return { ok = false, error = err }
	end
	local spans, why = Otlp.parse(doc, env)
	if spans == nil then
		return fail("parse", why :: string, response.status)
	end
	if #spans == 0 then
		return fail("query", "trace not found", response.status)
	end
	return { ok = true, spans = spans }
end

local function num(env: Env, v: any): number?
	local x = Env.value(env, v)
	if type(x) == "number" then
		return x
	elseif type(x) == "string" then
		return tonumber(x)
	end
	return nil
end

local function str(env: Env, v: any): string?
	local x = Env.value(env, v)
	return if type(x) == "string" and x ~= "" then x else nil
end

local function services(env: Env, raw: any): ({ SearchService }, number)
	local out: { SearchService } = {}
	local errors = 0
	local stats = Env.value(env, raw)
	if type(stats) ~= "table" then
		return out, 0
	end
	for name, st in stats do
		if type(name) == "string" and type(st) == "table" then
			local e = num(env, st.errorCount) or 0
			table.insert(out, { name = name, spans = num(env, st.spanCount) or 0, errors = e })
			errors += e
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out, errors
end

-- Tempo's `{traces: [...]}`.
local function tempoHits(doc: any, env: Env): { SearchHit }?
	local traces = Env.value(env, doc.traces)
	if traces == nil then
		return if type(doc) == "table" and Env.value(env, doc.metrics) ~= nil then {} else nil
	end
	if type(traces) ~= "table" then
		return nil
	end
	local out: { SearchHit } = {}
	for _, t in traces do
		if type(t) ~= "table" then
			continue
		end
		local id = Ids.trace(Env.value(env, t.traceID))
		if id == nil then
			continue
		end
		local start = Nanos.parse(Env.value(env, t.startTimeUnixNano))
		local matched: number? = nil
		local set = Env.value(env, t.spanSet)
		if type(set) == "table" then
			matched = num(env, set.matched)
		end
		local svc, errors = services(env, t.serviceStats)
		table.insert(out, {
			trace_id = id,
			root_service = str(env, t.rootServiceName),
			root_name = str(env, t.rootTraceName),
			start_ms = if start then Nanos.toMs(start) else nil,
			-- Tempo omits durationMs below 1 ms.
			duration_ms = num(env, t.durationMs) or (if start then 0 else nil),
			matched = matched,
			services = svc,
			errors = errors,
		})
	end
	return out
end

local function fieldValues(frame: Frame, name: string): { any }?
	for _, f in frame.fields do
		if f.name == name then
			return f.values
		end
	end
	return nil
end

-- Grafana's "Traces" table frame (traceID, startTime, traceService,
-- traceName, traceDuration, nested span frames).
local function frameHits(frames: { Frame }, env: Env): { SearchHit }
	local out: { SearchHit } = {}
	for _, f in frames do
		local ids = fieldValues(f, "traceID")
		if ids == nil then
			continue
		end
		local starts = fieldValues(f, "startTime") or {}
		local svc = fieldValues(f, "traceService") or {}
		local names = fieldValues(f, "traceName") or {}
		local durations = fieldValues(f, "traceDuration") or {}
		local nested = fieldValues(f, "nested") or {}
		for i, raw in ids do
			local id = Ids.trace(if FrameTypes.isNull(raw) then nil else raw)
			if id == nil then
				continue
			end
			local matched: number? = nil
			local sub = nested[i]
			if type(sub) == "table" then
				matched = 0
				for _, nf in sub do
					local data = if type(nf) == "table" then Env.value(env, nf.data) else nil
					local values = if type(data) == "table" then Env.value(env, data.values) else nil
					local first = if type(values) == "table" then values[1] else nil
					if type(first) == "table" then
						matched = (matched :: number) + #first
					end
				end
			end
			local start = starts[i]
			local dur = durations[i]
			local s, n = svc[i], names[i]
			table.insert(out, {
				trace_id = id,
				root_service = if type(s) == "string" and s ~= "" then s else nil,
				root_name = if type(n) == "string" and n ~= "" then n else nil,
				start_ms = if type(start) == "number" then start else nil,
				duration_ms = if type(dur) == "number" then dur else 0,
				matched = matched,
				services = {},
				errors = 0,
			})
		end
	end
	return out
end

local function byStartDesc(hits: { SearchHit })
	table.sort(hits, function(a, b)
		local sa, sb = a.start_ms or 0, b.start_ms or 0
		if sa ~= sb then
			return sa > sb
		end
		return a.trace_id < b.trace_id
	end)
end

function M.parseSearch(mode: Mode, response: Response, env: Env): SearchResult
	if mode == "dsquery" then
		local frames, err = dsFrames(response, env)
		if err then
			return { ok = false, error = err }
		end
		local hits = frameHits(frames :: { Frame }, env)
		byStartDesc(hits)
		return { ok = true, hits = hits }
	end
	local doc, err = tempoJson(response, env, "/api/search")
	if err then
		return { ok = false, error = err }
	end
	local hits = tempoHits(doc, env)
	if hits == nil then
		return fail("parse", "/api/search: the answer is not a Tempo search result", response.status)
	end
	byStartDesc(hits)
	return { ok = true, hits = hits }
end

-- `/api/v2/search/tags` `{scopes: [{name, tags}]}`, or v1 `{tagNames}`.
function M.parseTags(response: Response, env: Env): TagsResult
	local doc, err = tempoJson(response, env, "/api/v2/search/tags")
	if err then
		return { ok = false, error = err }
	end
	local out: { Tag } = {}
	local scopes = Env.value(env, doc.scopes)
	if type(scopes) == "table" then
		for _, sc in scopes do
			local name = if type(sc) == "table" then str(env, sc.name) else nil
			local tags = if type(sc) == "table" then Env.value(env, sc.tags) else nil
			if name and type(tags) == "table" then
				for _, t in tags do
					if type(t) == "string" and t ~= "" then
						table.insert(out, { scope = name, name = t })
					end
				end
			end
		end
		return { ok = true, tags = out }
	end
	local names = Env.value(env, doc.tagNames)
	if type(names) == "table" then
		for _, t in names do
			if type(t) == "string" and t ~= "" then
				table.insert(out, { scope = "", name = t })
			end
		end
		return { ok = true, tags = out }
	end
	return fail("parse", "/api/v2/search/tags: the answer has no scopes", response.status)
end

-- `/api/v2/search/tag/<tag>/values` `{tagValues: [{type, value}]}`.
function M.parseTagValues(response: Response, env: Env): ValuesResult
	local doc, err = Response.json(response, env, "/api/v2/search/tag/values")
	if err then
		return { ok = false, error = err }
	end
	local list = Env.value(env, doc.tagValues)
	if type(list) ~= "table" then
		return fail("parse", "tag values: the answer has no tagValues", response.status)
	end
	local out: { string } = {}
	for _, v in list do
		local value = if type(v) == "table" then Env.value(env, v.value) else v
		if type(value) == "string" then
			table.insert(out, value)
		elseif type(value) == "number" then
			table.insert(out, tostring(value))
		end
	end
	table.sort(out)
	return { ok = true, values = out }
end

return M
