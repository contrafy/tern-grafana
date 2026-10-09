--!strict
-- Prometheus operational endpoints for the ops block: scrape targets and the
-- status API (TSDB head cardinality, build, flags, runtime, config). Direct
-- routes call the server; datasource routes go through Grafana's datasource
-- proxy, which relays these paths unchanged.
--
-- Not every Prometheus-compatible server has them (Mimir has no targets,
-- Loki-style gateways answer `404 page not found`, VictoriaMetrics answers
-- `unsupported path requested`), so a missing endpoint is its own error kind:
-- the block shows a note for that tab instead of a failure.

local Env = require("../env")
local Grafana = require("./grafana")
local Response = require("./response")
local Route = require("../config/route")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type QueryError = TransportTypes.QueryError

export type Status = "buildinfo" | "flags" | "runtimeinfo" | "config" | "tsdb"

-- The decoded `data` member of a success document.
export type Result = { ok: true, data: any } | { ok: false, error: QueryError }

local M = {}

M.TARGETS_PATH = "/api/v1/targets"

function M.statusPath(name: Status): string
	return "/api/v1/status/" .. name
end

-- "" for a direct endpoint, the datasource proxy prefix through Grafana.
local function base(route: Route): string
	if route.via == "direct" then
		return ""
	end
	if route.via ~= "datasource" or route.datasource_uid == nil then
		error("ops: route has no prometheus endpoint or datasource uid", 2)
	end
	return Grafana.proxyBase(route.datasource_uid :: string)
end

-- Every target with its discovered labels, active and dropped in one answer
-- (`droppedTargetCounts` gives the per-pool dropped totals).
function M.targetsRequest(route: Route): Request
	return { method = "GET", path = base(route) .. M.TARGETS_PATH }
end

-- `limit` caps each top-N list (the server's default is 10).
function M.tsdbRequest(route: Route, limit: number?): Request
	local query: { { string } }? = if limit then { { "limit", string.format("%d", limit) } } else nil
	return { method = "GET", path = base(route) .. M.statusPath("tsdb"), query = query }
end

function M.statusRequest(route: Route, name: Status): Request
	return { method = "GET", path = base(route) .. M.statusPath(name) }
end

local function unsupported(path: string, status: number, why: string): QueryError
	return {
		kind = "unsupported",
		status = status,
		message = string.format("this server has no %s endpoint (%s)", path, why),
	}
end

local function isJson(response: Response, env: Env): boolean
	local ok, doc = pcall(env.decode, response.body)
	return ok and type(doc) == "table"
end

-- A status that means "no such endpoint here", not "the endpoint failed".
-- A JSON 404 is Grafana or a gateway explaining something else (an unknown
-- datasource uid), which the user must see as is.
local function missingEndpoint(response: Response, env: Env, path: string): QueryError?
	local status = response.status
	if status == 404 or status == 405 or status == 501 then
		if not isJson(response, env) then
			return unsupported(path, status, string.format("HTTP %d", status))
		end
	elseif status == 400 and string.find(response.body, "unsupported path", 1, true) then
		return unsupported(path, status, "HTTP 400 unsupported path")
	end
	return nil
end

-- `path` is the API path (without any proxy prefix), for messages.
function M.parse(response: Response, env: Env, path: string): Result
	if not response.failure and response.status ~= 0 then
		local missing = missingEndpoint(response, env, path)
		if missing then
			return { ok = false, error = missing }
		end
	end
	local doc, err = Response.json(response, env, path)
	if doc then
		local promErr = Response.promError(doc, env, response.status)
		if promErr then
			return { ok = false, error = promErr }
		end
	end
	if err then
		if err.kind == "parse" and response.status >= 200 and response.status < 300 then
			return { ok = false, error = unsupported(path, response.status, "the answer is not JSON") }
		end
		return { ok = false, error = err }
	end
	if doc == nil or doc.status ~= "success" or type(Env.value(env, doc.data)) ~= "table" then
		return {
			ok = false,
			error = unsupported(path, response.status, "the answer is not a Prometheus API document"),
		}
	end
	return { ok = true, data = doc.data }
end

return M
