--!strict
-- Which requests read a context's alerts, how their answers combine, and
-- where an alert's links lead.
--
-- Routing follows lib/config/route's `alerts` signal: a direct Alertmanager
-- wins; else Grafana's proxy to the Alertmanager datasource the user named;
-- else Grafana-managed alerting (its Alertmanager for firing, silenced and
-- inhibited alerts, its rule evaluator for pending ones). A context with only
-- a Prometheus endpoint reads Prometheus' own `/api/v1/alerts` (firing and
-- pending; Prometheus knows nothing of silences).

local Classify = require("../transport/classify")
local ConfigTypes = require("../config/types")
local Env = require("../env")
local Http = require("../transport/http")
local Normalize = require("./normalize")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Summary = require("./summary")
local TransportTypes = require("../transport/types")

type Config = ConfigTypes.Config
type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type Alert = Normalize.Alert
type Env = Env.Env

export type Kind = "alertmanager" | "grafana" | "grafana_external" | "prometheus"
export type Parser = "alertmanager" | "prometheus_alerts"

export type Fetch = {
	tag: string,
	route: Route,
	request: Request,
	parser: Parser,
	source: Normalize.Source,
	-- Without it the context's alerts are unknown; optional fetches only add.
	required: boolean,
}

export type Plan = {
	context: string,
	kind: Kind,
	route: Route,
	fetches: { Fetch },
}

export type Result = {
	ok: boolean,
	alerts: { Alert },
	-- Set when ok is false.
	error: string?,
	error_kind: Summary.ErrorKind?,
	-- Optional fetches that failed (ok stays true).
	warnings: { string },
}

local M = {}

local function get(path: string): Request
	return { method = "GET", path = path }
end

-- The route for alerts, with the Prometheus-only fallback; nil and a message
-- that says what to configure otherwise.
function M.route(config: Config, context: string?): (Route?, Kind?, string?)
	local r, err = Route.route(config, context, "alerts")
	if r then
		local kind: Kind = if r.via == "direct"
			then "alertmanager"
			elseif r.via == "datasource" then "grafana_external"
			else "grafana"
		return r, kind, nil
	end
	local e = err :: Route.RouteError
	if e.kind == "unroutable" then
		local name = (context or config.default_context) :: string
		local ctx = config.contexts[name]
		if ctx and ctx.prometheus then
			return {
				context = name,
				signal = "alerts",
				via = "direct",
				endpoint_name = "prometheus",
				endpoint = ctx.prometheus,
			},
				"prometheus",
				nil
		end
		return nil, nil, string.format("context %q has no alertmanager, grafana or prometheus endpoint", name)
	end
	return nil, nil, e.message
end

function M.plan(config: Config, context: string?): (Plan?, string?)
	local r, kind, err = M.route(config, context)
	if r == nil or kind == nil then
		return nil, err
	end
	local fetches: { Fetch } = {}
	if kind == "alertmanager" then
		table.insert(fetches, {
			tag = "am",
			route = r,
			request = get("/api/v2/alerts"),
			parser = "alertmanager",
			source = "alertmanager",
			required = true,
		})
	elseif kind == "grafana_external" then
		local uid = Http.escape(r.datasource_uid :: string)
		table.insert(fetches, {
			tag = "am",
			route = r,
			request = get("/api/alertmanager/" .. uid .. "/api/v2/alerts"),
			parser = "alertmanager",
			source = "alertmanager",
			required = true,
		})
	elseif kind == "grafana" then
		table.insert(fetches, {
			tag = "am",
			route = r,
			request = get("/api/alertmanager/grafana/api/v2/alerts"),
			parser = "alertmanager",
			source = "grafana",
			required = true,
		})
		table.insert(fetches, {
			tag = "rules",
			route = r,
			request = get("/api/prometheus/grafana/api/v1/alerts"),
			parser = "prometheus_alerts",
			source = "grafana",
			required = false,
		})
	else
		table.insert(fetches, {
			tag = "prom",
			route = r,
			request = get("/api/v1/alerts"),
			parser = "prometheus_alerts",
			source = "prometheus",
			required = true,
		})
	end
	local plan: Plan = { context = r.context, kind = kind :: Kind, route = r, fetches = fetches }
	return plan, nil
end

local function errorKind(kind: string): Summary.ErrorKind
	if
		kind == "auth"
		or kind == "network"
		or kind == "timeout"
		or kind == "http"
		or kind == "parse"
		or kind == "query"
		or kind == "unsupported"
	then
		return kind :: Summary.ErrorKind
	end
	return "http"
end

-- (alerts, nil) or (nil, message, kind) for one fetch's response.
local function parseOne(env: Env, plan: Plan, f: Fetch, response: Response?): ({ Alert }?, string?, Summary.ErrorKind?)
	if response == nil then
		return nil, "no response", "network"
	end
	local qe = Classify.classify(response, env.decode)
	if qe then
		return nil, qe.message, errorKind(qe.kind)
	end
	local parsed = if f.parser == "alertmanager"
		then Normalize.parseAlertmanager(env, response.body, plan.context, f.source)
		else Normalize.parsePrometheusAlerts(env, response.body, plan.context, f.source)
	if parsed.ok then
		return (parsed :: any).items, nil, nil
	end
	return nil, (parsed :: any).error, "parse"
end

-- Combines the answers to a plan's fetches, keyed by fetch tag.
function M.combine(env: Env, plan: Plan, responses: { [string]: Response }): Result
	local result: Result = { ok = true, alerts = {}, warnings = {} }
	local primary: { Alert } = {}
	local extra: { Alert } = {}
	for _, f in plan.fetches do
		local alerts, message, kind = parseOne(env, plan, f, responses[f.tag])
		if alerts == nil then
			local text = string.format("%s: %s", f.request.path, message or "failed")
			if f.required then
				result.ok = false
				result.error = text
				result.error_kind = kind :: Summary.ErrorKind?
				return result
			end
			table.insert(result.warnings, text)
		elseif f.required then
			for _, a in alerts do
				table.insert(primary, a)
			end
		else
			for _, a in alerts do
				table.insert(extra, a)
			end
		end
	end
	result.alerts = if #extra > 0 then Normalize.merge(primary, extra) else primary
	-- Resolved alerts linger in an Alertmanager until garbage collection;
	-- they are history, not the inbox.
	local live: { Alert } = {}
	for _, a in result.alerts do
		if a.state ~= "resolved" then
			table.insert(live, a)
		end
	end
	result.alerts = live
	return result
end

-- Labels a silence for this alert matches on: every label except Grafana's
-- and Prometheus' internal ones, but keeping Grafana's rule uid, which is
-- how Grafana itself scopes silences created from an alert.
function M.silenceMatchers(alert: Alert): { { string } }
	local names: { string } = {}
	for name in alert.labels do
		if name == "__alert_rule_uid__" or not Normalize.isInternal(name) then
			table.insert(names, name)
		end
	end
	table.sort(names)
	local out: { { string } } = {}
	for _, name in names do
		table.insert(out, { name, alert.labels[name] })
	end
	return out
end

local function quote(s: string): string
	return '"' .. string.gsub(string.gsub(s, "\\", "\\\\"), '"', '\\"') .. '"'
end

local function grafanaBase(plan: Plan): string
	local e = plan.route.endpoint
	return string.gsub(e.browser_url or (e.url .. e.path_prefix), "/+$", "")
end

-- The page that creates a silence for `alert` (until silences are native):
-- Alertmanager's UI or Grafana's. nil when the server has no silences.
function M.silenceUrl(plan: Plan, alert: Alert): string?
	local matchers = M.silenceMatchers(alert)
	if plan.kind == "alertmanager" then
		local parts: { string } = {}
		for _, m in matchers do
			table.insert(parts, m[1] .. "=" .. quote(m[2]))
		end
		local e = plan.route.endpoint
		local base = string.gsub(e.url .. e.path_prefix, "/+$", "")
		return base .. "/#/silences/new?filter=" .. Http.escape("{" .. table.concat(parts, ",") .. "}")
	elseif plan.kind == "grafana" or plan.kind == "grafana_external" then
		local am = if plan.kind == "grafana" then "grafana" else plan.route.datasource_uid :: string
		local query = { "alertmanager=" .. Http.escape(am) }
		for _, m in matchers do
			table.insert(query, "matcher=" .. Http.escape(m[1] .. "=" .. m[2]))
		end
		local org = plan.route.endpoint.org_id
		if org then
			table.insert(query, "orgId=" .. tostring(org))
		end
		return grafanaBase(plan) .. "/alerting/silence/new?" .. table.concat(query, "&")
	end
	return nil
end

local function isHttp(url: string?): boolean
	return url ~= nil and string.match(string.lower(url), "^https?://[^/@%s]+") ~= nil
end

-- Prometheus' generator URL (`/graph?g0.expr=...`) opens the query block on
-- the same context; anything else (Grafana's rule page) opens as is.
function M.generatorTarget(alert: Alert): string?
	local url = alert.generator_url
	if url == nil or not isHttp(url) then
		return nil
	end
	local query = string.match(url, "^[^?#]*/graph%?([^#]*)")
	if query then
		local pairs_ = Scheme.parseQuery(query)
		if pairs_ then
			for _, p in pairs_ do
				if p.name == "g0.expr" and p.value ~= "" then
					local ok, link = pcall(Scheme.encode, {
						action = "query",
						params = { context = alert.context, expr = p.value },
						vars = {},
					})
					if ok then
						return link
					end
				end
			end
		end
	end
	return url
end

-- Grafana's dashboard annotations open the native dashboard (on the alert's
-- panel); a `dashboard_url` annotation opens through link routing.
function M.dashboardTarget(alert: Alert): string?
	if alert.dashboard_uid then
		local params: { [string]: string } = { context = alert.context, uid = alert.dashboard_uid }
		if alert.panel_id then
			params.panel = tostring(alert.panel_id)
		end
		local ok, link = pcall(Scheme.encode, { action = "dashboard", params = params, vars = {} })
		if ok then
			return link
		end
	end
	if isHttp(alert.dashboard_url) then
		return alert.dashboard_url
	end
	return nil
end

function M.runbookTarget(alert: Alert): string?
	return if isHttp(alert.runbook_url) then alert.runbook_url else nil
end

return M
