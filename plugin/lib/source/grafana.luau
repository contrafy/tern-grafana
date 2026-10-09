--!strict
-- Grafana HTTP API request builders and parsers: health, the signed-in user,
-- frontend settings (image renderer availability), datasources, and
-- /api/ds/query. Every function takes a Route whose endpoint is the Grafana
-- endpoint.

local Env = require("../env")
local Frame = require("../frame/types")
local FrameGrafana = require("../frame/grafana")
local Http = require("../transport/http")
local Response = require("./response")
local Route = require("../config/route")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type QueryError = TransportTypes.QueryError

export type Failure = { ok: false, error: QueryError }
export type HealthResult = { ok: true, version: string, database: string?, commit: string? } | Failure
export type User = { login: string, name: string, uid: string?, org_id: number?, is_grafana_admin: boolean }
export type UserResult = { ok: true, user: User } | Failure
export type FrontendSettings = { renderer_available: boolean, renderer_version: string?, version: string? }
export type FrontendResult = { ok: true, settings: FrontendSettings } | Failure
export type Datasource = { uid: string, type: string, name: string, is_default: boolean }
export type DatasourcesResult = { ok: true, datasources: { Datasource } } | Failure
export type DsQueryResult = { ok: true, results: { [string]: Frame.QueryResult } } | Failure

-- One Prometheus target of /api/ds/query, as Grafana's query editor sends it.
export type PromTarget = {
	ref_id: string,
	uid: string,
	expr: string,
	instant: boolean,
	interval_ms: number,
	max_points: number,
	format: ("time_series" | "table")?,
	legend: string?,
}

local M = {}

M.DS_QUERY_PATH = "/api/ds/query"

local function get(path: string): Request
	return { method = "GET", path = path }
end

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

-- The datasource proxy prefix: Prometheus API paths are appended to it.
function M.proxyBase(uid: string): string
	return "/api/datasources/proxy/uid/" .. Http.escape(uid)
end

function M.healthRequest(_route: Route): Request
	return get("/api/health")
end

function M.userRequest(_route: Route): Request
	return get("/api/user")
end

function M.frontendSettingsRequest(_route: Route): Request
	return get("/api/frontend/settings")
end

function M.datasourcesRequest(_route: Route): Request
	return get("/api/datasources")
end

-- Grafana's error body is `{message}`; classify already folds it in.
local function object(response: Response, env: Env, what: string): (any, QueryError?)
	local doc, err = Response.json(response, env, what)
	if err then
		return nil, err
	end
	return doc, nil
end

function M.parseHealth(_route: Route, response: Response, env: Env): HealthResult
	local doc, err = object(response, env, "health")
	if err then
		return { ok = false, error = err }
	end
	local version = str(env, doc.version)
	if version == nil or version == "" then
		return {
			ok = false,
			error = { kind = "parse", message = "/api/health has no version; is this a Grafana server?" },
		}
	end
	return { ok = true, version = version, database = str(env, doc.database), commit = str(env, doc.commit) }
end

function M.parseUser(_route: Route, response: Response, env: Env): UserResult
	local doc, err = object(response, env, "user")
	if err then
		return { ok = false, error = err }
	end
	local orgId = Env.value(env, doc.orgId)
	return {
		ok = true,
		user = {
			login = str(env, doc.login) or "",
			name = str(env, doc.name) or "",
			uid = str(env, doc.uid),
			org_id = if type(orgId) == "number" then orgId else nil,
			is_grafana_admin = Env.value(env, doc.isGrafanaAdmin) == true,
		},
	}
end

function M.parseFrontendSettings(_route: Route, response: Response, env: Env): FrontendResult
	local doc, err = object(response, env, "frontend settings")
	if err then
		return { ok = false, error = err }
	end
	local build = Env.value(env, doc.buildInfo)
	local rendererVersion = str(env, doc.rendererVersion)
	return {
		ok = true,
		settings = {
			renderer_available = Env.value(env, doc.rendererAvailable) == true,
			renderer_version = if rendererVersion ~= "" then rendererVersion else nil,
			version = if type(build) == "table" then str(env, build.version) else nil,
		},
	}
end

function M.parseDatasources(_route: Route, response: Response, env: Env): DatasourcesResult
	local doc, err = object(response, env, "datasources")
	if err then
		return { ok = false, error = err }
	end
	local out: { Datasource } = {}
	for _, ds in doc do
		if type(ds) == "table" then
			local uid = str(env, ds.uid)
			if uid and uid ~= "" then
				table.insert(out, {
					uid = uid,
					type = str(env, ds.type) or "",
					name = str(env, ds.name) or uid,
					is_default = Env.value(env, ds.isDefault) == true,
				})
			end
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return { ok = true, datasources = out }
end

-- Minimal JSON for the fixed shapes this module builds (no env here):
-- strings, finite numbers, booleans, sequences and string-keyed objects.
local ESCAPES: { [string]: string } = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode(v: any): string
	local kind = type(v)
	if kind == "string" then
		return '"'
			.. string.gsub(v, '[%c"\\]', function(c: string): string
				return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
			end)
			.. '"'
	elseif kind == "number" then
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v)
		end
		return string.format("%.17g", v)
	elseif kind == "boolean" then
		return if v then "true" else "false"
	elseif kind == "table" then
		if #v > 0 then
			local parts = table.create(#v)
			for i, item in v do
				parts[i] = encode(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys: { string } = {}
		for k in v do
			table.insert(keys, k)
		end
		table.sort(keys)
		local parts = table.create(#keys)
		for i, k in keys do
			parts[i] = encode(k) .. ":" .. encode(v[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("grafana: cannot encode a " .. kind)
end

M.encode = encode

-- The query object Grafana's Prometheus editor sends.
function M.promTarget(t: PromTarget): { [string]: any }
	local q: { [string]: any } = {
		refId = t.ref_id,
		datasource = { type = "prometheus", uid = t.uid },
		expr = t.expr,
		range = not t.instant,
		instant = t.instant,
		intervalMs = t.interval_ms,
		maxDataPoints = t.max_points,
		format = t.format or "time_series",
		utcOffsetSec = 0,
	}
	if t.legend and t.legend ~= "" then
		q.legendFormat = t.legend
	end
	return q
end

local function dsQuery(body: string): Request
	return {
		method = "POST",
		path = M.DS_QUERY_PATH,
		headers = { ["Content-Type"] = "application/json" },
		body = body,
	}
end

-- /api/ds/query for Prometheus targets; `from`/`to` are strings of epoch ms.
function M.promQueryRequest(targets: { PromTarget }, from_ms: number, to_ms: number): Request
	local queries = table.create(#targets)
	for i, t in targets do
		queries[i] = M.promTarget(t)
	end
	return dsQuery(encode({
		queries = queries,
		from = string.format("%d", from_ms),
		to = string.format("%d", to_ms),
	}))
end

-- /api/ds/query for fully formed query objects (refId, datasource, ...) of
-- any datasource type; encoded with the host's codec.
function M.dsQueryRequest(
	_route: Route,
	queries: { { [string]: any } },
	range: { from_ms: number, to_ms: number },
	env: Env
): Request
	return dsQuery(env.encode({
		queries = queries,
		from = string.format("%d", range.from_ms),
		to = string.format("%d", range.to_ms),
	}))
end

-- Per-refId results. A failed query answers HTTP 400 with its error inside
-- `results`, so the body is read before the status.
function M.parseDsQuery(response: Response, env: Env): DsQueryResult
	local doc, err = Response.json(response, env, "/api/ds/query")
	if doc and type(Env.value(env, doc.results)) == "table" then
		return { ok = true, results = FrameGrafana.parseResults(doc, env) }
	end
	if err then
		return { ok = false, error = err }
	end
	return { ok = false, error = { kind = "parse", status = response.status, message = "/api/ds/query: no results" } }
end

return M
