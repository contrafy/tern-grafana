--!strict
-- The rules view's data: which requests read a context's alerting and
-- recording rules, how their answers combine, and how rules are filtered and
-- ordered. A context can have two rule sources at once: Grafana-managed rules
-- (`/api/prometheus/grafana/api/v1/rules`) and its Prometheus' own rules,
-- read directly (`/api/v1/rules`) or through Grafana
-- (`/api/prometheus/<datasource uid>/api/v1/rules`).

local Classify = require("../transport/classify")
local ConfigTypes = require("../config/types")
local Env = require("../env")
local Group = require("./group")
local Http = require("../transport/http")
local Normalize = require("./normalize")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local TransportTypes = require("../transport/types")

type Config = ConfigTypes.Config
type Env = Env.Env
type Rule = Normalize.Rule
type Response = TransportTypes.Response

export type Fetch = {
	tag: string,
	route: Route.Route,
	request: TransportTypes.Request,
	source: Normalize.Source,
	-- How the source is named in the view.
	label: string,
}

export type Plan = { context: string, fetches: { Fetch } }

export type Result = {
	rules: { Rule },
	-- One line per source that failed.
	errors: { string },
	-- Every source failed.
	failed: boolean,
}

local M = {}

function M.plan(config: Config, context: string?): (Plan?, string?)
	local name = context or config.default_context
	if name == nil then
		return nil, "no context given and default_context is not set"
	end
	local ctx = config.contexts[name :: string]
	if ctx == nil then
		return nil, string.format("no context named %q", name)
	end
	local fetches: { Fetch } = {}
	if ctx.grafana then
		table.insert(fetches, {
			tag = "grafana",
			route = {
				context = name :: string,
				signal = "alerts",
				via = "grafana",
				endpoint_name = "grafana",
				endpoint = ctx.grafana,
			},
			request = { method = "GET", path = "/api/prometheus/grafana/api/v1/rules" },
			source = "grafana",
			label = "Grafana-managed",
		})
	end
	local r = Route.route(config, name, "metrics")
	if r then
		local path = if r.via == "direct"
			then "/api/v1/rules"
			else "/api/prometheus/" .. Http.escape(r.datasource_uid :: string) .. "/api/v1/rules"
		table.insert(fetches, {
			tag = "prometheus",
			route = r,
			request = { method = "GET", path = path },
			source = "prometheus",
			label = if r.via == "direct" then "Prometheus" else "Prometheus (" .. (r.datasource_uid :: string) .. ")",
		})
	end
	if #fetches == 0 then
		return nil, string.format("context %q has no grafana or prometheus endpoint to read rules from", name)
	end
	return { context = name :: string, fetches = fetches }, nil
end

function M.combine(env: Env, plan: Plan, responses: { [string]: Response }): Result
	local result: Result = { rules = {}, errors = {}, failed = false }
	local failures = 0
	for _, f in plan.fetches do
		local response = responses[f.tag]
		local message: string? = nil
		if response == nil then
			message = "no response"
		else
			local qe = Classify.classify(response, env.decode)
			if qe then
				message = qe.message
			else
				local parsed: any = Normalize.parseRules(env, response.body, plan.context, f.source)
				if parsed.ok then
					for _, rule in parsed.items do
						table.insert(result.rules, rule)
					end
				else
					message = parsed.error
				end
			end
		end
		if message then
			failures += 1
			table.insert(result.errors, string.format("%s rules: %s", f.label, message))
		end
	end
	result.failed = failures == #plan.fetches
	return result
end

-- The rule failed its last evaluation (or Grafana reports no data / error).
function M.unhealthy(rule: Rule): boolean
	return rule.last_error ~= nil or (rule.health ~= "ok" and rule.health ~= "unknown")
end

-- What the rule is doing: firing / pending / inactive / paused for alerting
-- rules, "recording" for recording rules.
function M.status(rule: Rule): string
	if rule.paused then
		return "paused"
	elseif rule.type == "recording" then
		return "recording"
	end
	local st = rule.state
	if st == "alerting" then
		return "firing"
	end
	return st or "inactive"
end

local function hasWord(rule: Rule, word: string): boolean
	local function has(s: string?): boolean
		return s ~= nil and string.find(string.lower(s), word, 1, true) ~= nil
	end
	if has(rule.name) or has(rule.group) or has(rule.query) or has(rule.health) or has(M.status(rule)) then
		return true
	end
	for name, value in rule.labels do
		if has(name) or has(value) then
			return true
		end
	end
	return false
end

-- The inbox filter applied to rules: matchers test the rule's labels (plus
-- `alertname`, the rule name), words its name, group, query, health and status.
function M.accept(filter: Group.Filter, rule: Rule): boolean
	if #filter.matchers > 0 then
		local labels = table.clone(rule.labels)
		labels.alertname = labels.alertname or rule.name
		for _, m in filter.matchers do
			if not Group.matches(m, labels) then
				return false
			end
		end
	end
	for _, w in filter.words do
		if not hasWord(rule, w) then
			return false
		end
	end
	return true
end

-- Rules in server order, keeping each source and group together; with
-- `problems`, only unhealthy rules.
function M.select(rules: { Rule }, filter: Group.Filter, problems: boolean): { Rule }
	local out: { Rule } = {}
	for _, r in rules do
		if (not problems or M.unhealthy(r)) and M.accept(filter, r) then
			table.insert(out, r)
		end
	end
	return out
end

-- A stable identity for selection across reloads.
function M.key(rule: Rule): string
	return table.concat({ rule.source, rule.file, rule.group, rule.uid or rule.name }, "\0")
end

-- Opens the query block with the rule's expression. Grafana-managed rules
-- that name exactly one datasource query that datasource.
function M.queryLink(rule: Rule): string?
	if rule.query == "" then
		return nil
	end
	local params: { [string]: string } = { context = rule.context, expr = rule.query }
	if rule.source == "grafana" and #rule.datasource_uids == 1 then
		params.ds = rule.datasource_uids[1]
	end
	local ok, link = pcall(Scheme.encode, { action = "query", params = params, vars = {} })
	return if ok then link else nil
end

-- The inbox filter that shows an alerting rule's alerts.
function M.alertsFilter(rule: Rule): string?
	if rule.type ~= "alerting" then
		return nil
	end
	if rule.uid then
		return string.format('__alert_rule_uid__="%s"', rule.uid)
	end
	return string.format('alertname="%s"', (string.gsub(rule.name, '(["\\])', "\\%1")))
end

return M
