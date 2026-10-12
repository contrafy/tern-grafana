--!strict
-- The logs signal for a routed context: Loki's HTTP API direct, or Grafana's
-- Loki datasource (queries by /api/ds/query, label lists through the
-- datasource proxy, which relays Loki's API unchanged).
--
-- Log queries come back as Lines (lib/frame/loki.luau) and frames; metric
-- queries (`sum by (level) (count_over_time(...))`) as Prometheus-shaped
-- series frames. Direct log queries ask for categorized labels, so indexed
-- labels, structured metadata and parsed fields stay apart as they do through
-- Grafana; a Loki that does not know the header (2.x) ignores it.

local Env = require("../env")
local Frame = require("../frame/types")
local FrameLoki = require("../frame/loki")
local FrameProm = require("../frame/prom")
local Grafana = require("./grafana")
local Http = require("../transport/http")
local Prom = require("./prom")
local Response = require("./response")
local Route = require("../config/route")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type QueryError = TransportTypes.QueryError
type Line = FrameLoki.Line

export type Direction = "backward" | "forward"

export type RangeQuery = {
	expr: string,
	from_ms: number,
	to_ms: number,
	-- Most log lines (Loki's default is 100); ignored by metric queries.
	limit: number?,
	-- Loki's default is backward (newest first).
	direction: Direction?,
	-- Metric query resolution.
	step_ms: number?,
	-- Through Grafana: points per series (sets Grafana's step with step_ms).
	max_points: number?,
	ref_id: string?,
	legend: string?,
}

export type ListOptions = { from_ms: number?, to_ms: number? }

export type Result =
	{
		ok: true,
		kind: "streams" | "matrix" | "vector",
		frames: { Frame.Frame },
		-- Log lines, newest first; empty for metric queries.
		lines: { Line },
		warnings: { string },
	}
	| { ok: false, error: QueryError }

local M = {}

M.CATEGORIZE_HEADER = "X-Loki-Response-Encoding-Flags"
M.CATEGORIZE_VALUE = "categorize-labels"
M.DEFAULT_REF = "A"
M.DEFAULT_MAX_POINTS = 1000

local function viaGrafana(route: Route): boolean
	if route.via == "direct" then
		return false
	end
	if route.via ~= "datasource" or route.datasource_uid == nil then
		error("loki: route has no loki endpoint or datasource uid", 2)
	end
	return true
end

local function base(route: Route): string
	if viaGrafana(route) then
		return Grafana.proxyBase(route.datasource_uid :: string)
	end
	return ""
end

-- Epoch ms as Loki's nanosecond timestamps.
M.ns = FrameLoki.msToNs

-- /loki/api/v1/query_range (direct) or the /api/ds/query target Grafana's
-- Loki editor sends (`maxLines`, `direction`, `queryType = "range"`).
function M.rangeRequest(route: Route, q: RangeQuery, env: Env): Request
	if viaGrafana(route) then
		local target: { [string]: any } = {
			refId = q.ref_id or M.DEFAULT_REF,
			datasource = { type = "loki", uid = route.datasource_uid },
			expr = q.expr,
			queryType = "range",
			direction = q.direction or "backward",
		}
		if q.limit then
			target.maxLines = q.limit
		end
		if q.step_ms then
			target.intervalMs = q.step_ms
			target.maxDataPoints = q.max_points or M.DEFAULT_MAX_POINTS
		end
		if q.legend and q.legend ~= "" then
			target.legendFormat = q.legend
		end
		return Grafana.dsQueryRequest(route, { target }, { from_ms = q.from_ms, to_ms = q.to_ms }, env)
	end
	local query: { { string } } = { { "query", q.expr } }
	if q.limit then
		table.insert(query, { "limit", string.format("%d", q.limit) })
	end
	if q.direction == "forward" then
		table.insert(query, { "direction", "forward" })
	end
	if q.step_ms then
		table.insert(query, { "step", Prom.seconds(q.step_ms) })
	end
	table.insert(query, { "start", M.ns(q.from_ms) })
	table.insert(query, { "end", M.ns(q.to_ms) })
	return {
		method = "GET",
		path = "/loki/api/v1/query_range",
		query = query,
		headers = { [M.CATEGORIZE_HEADER] = M.CATEGORIZE_VALUE },
	}
end

local function listQuery(opts: ListOptions?): { { string } }
	local query: { { string } } = {}
	if opts and opts.from_ms then
		table.insert(query, { "start", M.ns(opts.from_ms) })
	end
	if opts and opts.to_ms then
		table.insert(query, { "end", M.ns(opts.to_ms) })
	end
	return query
end

-- Indexed label names (structured metadata and parsed fields are not listed).
function M.labelsRequest(route: Route, opts: ListOptions?): Request
	return { method = "GET", path = base(route) .. "/loki/api/v1/labels", query = listQuery(opts) }
end

function M.labelValuesRequest(route: Route, label: string, opts: ListOptions?): Request
	return {
		method = "GET",
		path = base(route) .. "/loki/api/v1/label/" .. Http.escape(label) .. "/values",
		query = listQuery(opts),
	}
end

-- Label and value lists answer `{status, data: [..]}` like Prometheus.
function M.parseList(_route: Route, response: Response, env: Env): Prom.ListResult
	return Prom.parseList(response, env)
end

-- Loki answers a bad query with HTTP 400 and the parser's message as plain
-- text; that is the query's error, not a transport one.
local function directError(response: Response, err: QueryError): QueryError
	if err.kind == "http" and response.status == 400 then
		local first = string.match(response.body or "", "^%s*([^\r\n]+)")
		if first and string.sub(first, 1, 1) ~= "{" and string.sub(first, 1, 1) ~= "<" then
			return { kind = "query", status = 400, message = (string.gsub(first, "%s+$", "")) }
		end
		return { kind = "query", status = 400, message = err.message }
	end
	return err
end

local function fromFrames(result: Frame.QueryResult, env: Env): Result
	if not result.ok then
		return { ok = false, error = (result :: any).error }
	end
	local frames: { Frame.Frame } = (result :: any).frames
	local lines = FrameLoki.fromFrames(frames, env)
	local kind: "streams" | "matrix" | "vector" = "matrix"
	for _, f in frames do
		if FrameLoki.isLogsFrame(f) then
			kind = "streams"
		elseif f.meta and f.meta.type == "numeric-multi" then
			kind = "vector"
		end
	end
	return { ok = true, kind = kind, frames = frames, lines = lines, warnings = (result :: any).warnings }
end

-- The query's lines (log queries) or series frames (metric queries).
function M.parse(route: Route, response: Response, env: Env): Result
	if viaGrafana(route) then
		local parsed = Grafana.parseDsQuery(response, env)
		if not parsed.ok then
			return { ok = false, error = (parsed :: any).error }
		end
		local results = (parsed :: any).results :: { [string]: Frame.QueryResult }
		local result: Frame.QueryResult? = results[M.DEFAULT_REF]
		if result == nil then
			local refs: { string } = {}
			for ref in results do
				table.insert(refs, ref)
			end
			table.sort(refs)
			result = if refs[1] then results[refs[1]] else nil
		end
		return fromFrames((result or { ok = true, frames = {}, warnings = {} }) :: any, env)
	end
	local doc, err = Response.json(response, env, "query_range")
	if doc then
		local promErr = Response.promError(doc, env, response.status)
		if promErr then
			return { ok = false, error = promErr }
		end
	end
	if err then
		return { ok = false, error = directError(response, err) }
	end
	local data = Env.value(env, doc.data)
	if Env.value(env, doc.status) ~= "success" or type(data) ~= "table" then
		return {
			ok = false,
			error = { kind = "parse", status = response.status, message = "query_range: the response is not a success" },
		}
	end
	local resultType = Env.value(env, data.resultType)
	if resultType == "streams" then
		local lines = FrameLoki.streams(data, env)
		return {
			ok = true,
			kind = "streams",
			frames = { FrameLoki.toFrame(lines, M.DEFAULT_REF) },
			lines = lines,
			warnings = FrameProm.annotations(doc),
		}
	end
	local result = FrameProm.result(doc, env)
	if not result.ok then
		return { ok = false, error = (result :: any).error }
	end
	return {
		ok = true,
		kind = if resultType == "vector" then "vector" else "matrix",
		frames = (result :: any).frames,
		lines = {},
		warnings = (result :: any).warnings,
	}
end

return M
