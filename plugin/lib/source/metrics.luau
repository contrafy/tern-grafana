--!strict
-- The metrics signal for a routed context. route.via "direct" talks to the
-- Prometheus-compatible server; "datasource" goes through Grafana: queries
-- by /api/ds/query (so Grafana applies its datasource settings, auth and
-- step rules) and labels, values, metadata and buildinfo by the datasource
-- proxy, which relays the Prometheus API unchanged.

local Env = require("../env")
local Frame = require("../frame/types")
local Grafana = require("./grafana")
local Prom = require("./prom")
local Route = require("../config/route")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response

export type Format = "time_series" | "table"
export type RangeQuery = {
	expr: string,
	from_ms: number,
	to_ms: number,
	step_ms: number,
	max_points: number?,
	ref_id: string?,
	format: Format?,
	legend: string?,
}
export type InstantQuery = { expr: string, time_ms: number, ref_id: string?, format: Format?, legend: string? }
export type ListOptions = Prom.ListOptions
export type ListResult = Prom.ListResult
export type MetadataResult = Prom.MetadataResult
export type HealthResult = Prom.HealthResult

local M = {}

M.DEFAULT_REF = "A"
-- Grafana's default maxDataPoints when a panel has no width.
M.DEFAULT_MAX_POINTS = 1000
-- Instant queries through Grafana still need a range; the step it derives
-- from it does not affect an instant result.
M.INSTANT_LOOKBACK_MS = 5 * 60 * 1000
M.INSTANT_INTERVAL_MS = 15000

local function viaGrafana(route: Route): boolean
	if route.via == "direct" then
		return false
	end
	if route.via ~= "datasource" or route.datasource_uid == nil then
		error("metrics: route has no prometheus endpoint or datasource uid", 2)
	end
	return true
end

-- The Prometheus API prefix: "" direct, the datasource proxy via Grafana.
local function base(route: Route): string
	if viaGrafana(route) then
		return Grafana.proxyBase(route.datasource_uid :: string)
	end
	return ""
end

function M.rangeRequest(route: Route, q: RangeQuery): Request
	if not viaGrafana(route) then
		return Prom.rangeRequest("", q)
	end
	return Grafana.promQueryRequest({
		{
			ref_id = q.ref_id or M.DEFAULT_REF,
			uid = route.datasource_uid :: string,
			expr = q.expr,
			instant = false,
			interval_ms = q.step_ms,
			max_points = q.max_points or M.DEFAULT_MAX_POINTS,
			format = q.format,
			legend = q.legend,
		},
	}, q.from_ms, q.to_ms)
end

function M.instantRequest(route: Route, q: InstantQuery): Request
	if not viaGrafana(route) then
		return Prom.instantRequest("", q)
	end
	return Grafana.promQueryRequest({
		{
			ref_id = q.ref_id or M.DEFAULT_REF,
			uid = route.datasource_uid :: string,
			expr = q.expr,
			instant = true,
			interval_ms = M.INSTANT_INTERVAL_MS,
			max_points = M.DEFAULT_MAX_POINTS,
			format = q.format,
			legend = q.legend,
		},
	}, q.time_ms - M.INSTANT_LOOKBACK_MS, q.time_ms)
end

-- The query's result. `kind` is informational: the body says what it holds.
function M.parse(route: Route, response: Response, env: Env, _kind: "range" | "instant"): Frame.QueryResult
	if not viaGrafana(route) then
		return Prom.parseQuery(response, env)
	end
	local parsed = Grafana.parseDsQuery(response, env)
	if not parsed.ok then
		return { ok = false, error = parsed.error }
	end
	local results = parsed.results
	local result: Frame.QueryResult? = results[M.DEFAULT_REF]
	if result == nil then
		local refs: { string } = {}
		for ref in results do
			table.insert(refs, ref)
		end
		table.sort(refs)
		result = if refs[1] then results[refs[1]] else nil
	end
	return result or { ok = true, frames = {}, warnings = {} }
end

function M.labelsRequest(route: Route, opts: ListOptions?): Request
	return Prom.labelsRequest(base(route), opts)
end

function M.labelValuesRequest(route: Route, label: string, opts: ListOptions?): Request
	return Prom.labelValuesRequest(base(route), label, opts)
end

function M.metadataRequest(route: Route, metric: string?): Request
	return Prom.metadataRequest(base(route), metric)
end

function M.healthRequest(route: Route): Request
	return Prom.healthRequest(base(route))
end

function M.parseList(_route: Route, response: Response, env: Env): ListResult
	return Prom.parseList(response, env)
end

function M.parseMetadata(_route: Route, response: Response, env: Env): MetadataResult
	return Prom.parseMetadata(response, env)
end

function M.parseHealth(_route: Route, response: Response, env: Env): HealthResult
	return Prom.parseHealth(response, env)
end

return M
