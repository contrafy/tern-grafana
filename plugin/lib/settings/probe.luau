--!strict
-- "Test connection" for one configured endpoint: the requests that prove the
-- server answers and the credentials work, their parsing, and a remediation
-- hint for each failure class. Prometheus and Grafana use the source
-- modules; Alertmanager, Loki and Tempo answer their build info endpoints.

local ConfigTypes = require("../config/types")
local Env = require("../env")
local Grafana = require("../source/grafana")
local Metrics = require("../source/metrics")
local Response = require("../source/response")
local Route = require("../config/route")
local TransportTypes = require("../transport/types")

type Config = ConfigTypes.Config
type Endpoint = ConfigTypes.Endpoint
type Route = Route.Route
type Request = TransportTypes.Request
type QueryError = TransportTypes.QueryError
type Env = Env.Env

local M = {}

export type Step = "health" | "user" | "datasources"

export type StepResult = {
	ok: boolean,
	-- What the step established ("Prometheus 3.15.0", "signed in as admin").
	text: string?,
	error: string?,
	hint: string?,
}

local SIGNAL: { [string]: ConfigTypes.Signal } = {
	grafana = "dashboards",
	prometheus = "metrics",
	alertmanager = "alerts",
	loki = "logs",
	tempo = "traces",
}

-- A direct route to the named endpoint of a validated config; nil when the
-- config has no such endpoint.
function M.route(config: Config, context: string, endpoint: string): Route?
	local ctx = config.contexts[context]
	local ep: Endpoint? = if ctx then (ctx :: any)[endpoint] else nil
	local signal = SIGNAL[endpoint]
	if ep == nil or signal == nil then
		return nil
	end
	local route: Route = {
		context = context,
		signal = signal :: ConfigTypes.Signal,
		via = if endpoint == "grafana" then "grafana" else "direct",
		endpoint_name = endpoint :: ConfigTypes.EndpointName,
		endpoint = ep,
	}
	return route
end

local BUILDINFO: { [string]: string } = {
	alertmanager = "/api/v2/status",
	loki = "/loki/api/v1/status/buildinfo",
	tempo = "/api/status/buildinfo",
}

export type Probe = { step: Step, request: Request }

-- The requests to send, in order. Grafana's /api/health needs no credentials,
-- so /api/user proves the token, and configured datasource uids are checked
-- against /api/datasources.
function M.requests(route: Route): { Probe }
	local name = route.endpoint_name
	if name == "grafana" then
		local out: { Probe } = {
			{ step = "health", request = Grafana.healthRequest(route) },
			{ step = "user", request = Grafana.userRequest(route) },
		}
		local ds = route.endpoint.datasources
		if ds and next(ds :: any) ~= nil then
			table.insert(out, { step = "datasources", request = Grafana.datasourcesRequest(route) })
		end
		return out
	elseif name == "prometheus" then
		return { { step = "health", request = Metrics.healthRequest(route) } }
	end
	return { { step = "health", request = { method = "GET", path = BUILDINFO[name] } } }
end

local function contains(s: string, needle: string): boolean
	return string.find(string.lower(s), needle, 1, true) ~= nil
end

-- What to try next for a failure.
function M.hint(route: Route, err: QueryError): string?
	local message = err.message
	if err.kind == "auth" then
		if route.endpoint.auth.type == "none" then
			return "the server wants credentials: set auth (bearer or basic) for this endpoint"
		end
		if err.status == 401 then
			return "the credential was rejected: check that the token or password the reference yields is current"
		end
		if err.status == 403 then
			return "the credential works but lacks permission for this API; use an account with Viewer (or higher) role"
		end
		return "the credential could not be read: run the token_cmd in a terminal, check the environment of the "
			.. "Tern process or the file path"
	elseif err.kind == "timeout" then
		return "the server did not answer in time: check the url, or raise timeout_ms"
	elseif err.kind == "network" then
		if contains(message, "certificate") or contains(message, "unknownissuer") or contains(message, "ssl") then
			return "set tls.ca_file to the CA bundle that signed the server certificate (or tls.insecure for a lab)"
		elseif contains(message, "refused") then
			return "nothing listens at " .. route.endpoint.url .. ": is the server running and the port right?"
		elseif contains(message, "lookup") or contains(message, "resolve") then
			return "the host name does not resolve: check the url"
		elseif contains(message, "curl") then
			return "TLS options need curl on the PATH of the Tern process"
		end
		return "check the url and that the server is reachable from this machine"
	elseif err.kind == "http" then
		if err.status == 404 then
			return "the API path was not found: check url and path_prefix (Mimir: /prometheus, Grafana Cloud: /api/prom)"
		end
		return "the server answered with an error; check url and path_prefix"
	elseif err.kind == "parse" then
		return "the answer was not what this endpoint type returns: check that url points at the right server"
	end
	return nil
end

local function failed(route: Route, err: QueryError): StepResult
	return { ok = false, error = err.message, hint = M.hint(route, err) }
end

local TITLE: { [string]: string } = {
	alertmanager = "Alertmanager",
	loki = "Loki",
	tempo = "Tempo",
	prometheus = "Prometheus",
	thanos = "Thanos",
	mimir = "Mimir",
	cortex = "Cortex",
	victoriametrics = "VictoriaMetrics",
}

local function buildVersion(name: string, doc: any, env: Env): string?
	if type(doc) ~= "table" then
		return nil
	end
	local info = if name == "alertmanager" then Env.value(env, doc.versionInfo) else doc
	if type(info) ~= "table" then
		return nil
	end
	local v = Env.value(env, info.version)
	return if type(v) == "string" and v ~= "" then v else nil
end

local function datasourceCheck(route: Route, list: { Grafana.Datasource }): StepResult
	local wanted = route.endpoint.datasources or {}
	local have: { [string]: Grafana.Datasource } = {}
	local uids: { string } = {}
	for _, ds in list do
		have[ds.uid] = ds
		table.insert(uids, ds.uid)
	end
	table.sort(uids)
	local found: { string } = {}
	local missing: { string } = {}
	for _, key in { "prometheus", "loki", "tempo", "alertmanager" } do
		local uid = (wanted :: any)[key]
		if uid then
			local ds = have[uid]
			if ds then
				table.insert(found, string.format("%s=%s (%s)", key, uid, ds.type))
			else
				table.insert(missing, string.format("datasources.%s: no datasource with uid %q", key, uid))
			end
		end
	end
	if #missing > 0 then
		return {
			ok = false,
			error = table.concat(missing, "; "),
			hint = "available uids: " .. (if #uids > 0 then table.concat(uids, ", ") else "none"),
		}
	end
	return { ok = true, text = "datasources " .. table.concat(found, ", ") }
end

function M.parse(route: Route, step: Step, response: TransportTypes.Response, env: Env): StepResult
	local name = route.endpoint_name
	if name == "grafana" then
		if step == "health" then
			local r = Grafana.parseHealth(route, response, env)
			if r.ok then
				return { ok = true, text = "Grafana " .. r.version }
			end
			return failed(route, r.error)
		elseif step == "user" then
			local r = Grafana.parseUser(route, response, env)
			if r.ok then
				return { ok = true, text = "signed in as " .. r.user.login }
			end
			return failed(route, r.error)
		end
		local r = Grafana.parseDatasources(route, response, env)
		if r.ok then
			return datasourceCheck(route, r.datasources)
		end
		return failed(route, r.error)
	elseif name == "prometheus" then
		local r = Metrics.parseHealth(route, response, env)
		if r.ok then
			return { ok = true, text = (TITLE[r.flavor] or r.flavor) .. " " .. r.version }
		end
		return failed(route, r.error)
	end
	local doc, err = Response.json(response, env, "build info")
	if err then
		return failed(route, err)
	end
	local version = buildVersion(name, doc, env)
	if version == nil then
		return failed(route, { kind = "parse", message = "the answer carries no version" })
	end
	return { ok = true, text = (TITLE[name] or name) .. " " .. version }
end

return M
