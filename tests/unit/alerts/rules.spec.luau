--!strict
-- The rules view must show every rule source a context has (Grafana-managed
-- rules and its Prometheus' rules, direct or through Grafana) the same way on
-- every server version, single out rules whose evaluation fails, keep showing
-- what loaded when one source fails, and lead from a rule to its query and
-- to its alerts.
local Fixtures = require("../../lib/fixtures")
local Rules = require("../../../plugin/lib/alerts/rules")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/alerts/state")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577860000

local CFG = (function(): any
	local cfg, problems = Validate.parseFile(
		[[{"default_context": "lab", "contexts": {
		"lab": {"grafana": {"url": "http://g"}, "prometheus": {"url": "http://p:9090"}},
		"viaG": {"grafana": {"url": "http://g", "datasources": {"prometheus": "prom3"}}},
		"prom": {"prometheus": {"url": "http://p:9090"}},
		"am": {"alertmanager": {"url": "http://am:9093"}}}}]],
		json.decode
	)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end)()

local env: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null, config = CFG }

local function ok(path: string): any
	return { status = 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

local function paths(plan: any): { string }
	local out = {}
	for _, f in plan.fetches do
		table.insert(out, f.tag .. " " .. f.route.endpoint.url .. f.request.path)
	end
	return out
end

local function byName(rules: { any }): { [string]: any }
	local out = {}
	for _, r in rules do
		out[r.name] = r
	end
	return out
end

describe("rules plan", function()
	it("reads Grafana-managed rules and the context's Prometheus rules", function()
		expect(paths((assert(Rules.plan(CFG, "lab"))))).toEqual({
			"grafana http://g/api/prometheus/grafana/api/v1/rules",
			"prometheus http://p:9090/api/v1/rules",
		})
		expect(paths((assert(Rules.plan(CFG, "viaG"))))).toEqual({
			"grafana http://g/api/prometheus/grafana/api/v1/rules",
			"prometheus http://g/api/prometheus/prom3/api/v1/rules",
		})
		expect(paths((assert(Rules.plan(CFG, "prom"))))).toEqual({ "prometheus http://p:9090/api/v1/rules" })
		local none, err = Rules.plan(CFG, "am")
		expect(none).toBeNil()
		expect(string.find(err :: string, "no grafana or prometheus", 1, true) ~= nil).toBe(true)
	end)
end)

describe("rules normalization", function()
	local versions = {
		{ grafana = "11.6.16", prometheus = "2.53.5" },
		{ grafana = "12.4.12", prometheus = "3.15.0" },
	}
	for _, v in versions do
		it(string.format("Grafana %s and Prometheus %s read the same way", v.grafana, v.prometheus), function()
			local plan = assert(Rules.plan(CFG, "lab"))
			local result = Rules.combine(env, plan, {
				grafana = ok("grafana/" .. v.grafana .. "/alerting_prom_rules.json"),
				prometheus = ok("prometheus/" .. v.prometheus .. "/rules.json"),
			})
			expect(result.failed).toBe(false)
			expect(result.errors).toEqual({})
			local r = byName(result.rules)
			expect(Rules.status(r.TernGrafanaAlwaysFiring)).toBe("firing")
			expect(Rules.status(r.TernGrafanaPending)).toBe("pending")
			expect(Rules.status(r.TernGrafanaNormal)).toBe("inactive")
			expect(r.TernGrafanaAlwaysFiring.source).toBe("grafana")
			expect(r.TernGrafanaAlwaysFiring.interval_s).toBe(10)
			expect(r.TernGrafanaAlwaysFiring.paused).toBe(false)
			expect(Rules.status(r["job:up:sum"])).toBe("recording")
			expect(Rules.unhealthy(r["job:up:sum"])).toBe(false)
			local broken = r["tern:broken:many_to_many"]
			expect(Rules.unhealthy(broken)).toBe(true)
			expect(broken.source).toBe("prometheus")
			local problems = Rules.select(result.rules, { matchers = {}, words = {} }, true)
			expect(#problems).toBe(1)
			expect(problems[1].name).toBe("tern:broken:many_to_many")
		end)
	end

	it("names the datasources a Grafana 12 rule queries (Grafana 11 does not say)", function()
		local plan = assert(Rules.plan(CFG, "lab"))
		local g12 = byName(Rules.combine(env, plan, {
			grafana = ok("grafana/12.4.12/alerting_prom_rules.json"),
			prometheus = ok("prometheus/3.15.0/rules.json"),
		}).rules)
		expect(g12.TernGrafanaAlwaysFiring.datasource_uids).toEqual({ "prom3" })
		local link = assert(Scheme.decode(Rules.queryLink(g12.TernGrafanaAlwaysFiring) :: string))
		expect(link.params).toEqual({ context = "lab", expr = "vector(1)", ds = "prom3" })
		local g11 = byName(Rules.combine(env, plan, {
			grafana = ok("grafana/11.6.16/alerting_prom_rules.json"),
			prometheus = ok("prometheus/2.53.5/rules.json"),
		}).rules)
		expect(g11.TernGrafanaAlwaysFiring.datasource_uids).toEqual({})
		expect(assert(Scheme.decode(Rules.queryLink(g11.TernGrafanaAlwaysFiring) :: string)).params.ds).toBeNil()
	end)

	it("reads Prometheus rules through Grafana's datasource API", function()
		local plan = assert(Rules.plan(CFG, "viaG"))
		local result = Rules.combine(env, plan, {
			grafana = ok("grafana/12.4.12/alerting_prom_rules.json"),
			prometheus = ok("grafana/12.4.12/alerting_ds_prom_rules.json"),
		})
		local r = byName(result.rules)
		expect(r.TernAlwaysFiring.source).toBe("prometheus")
		expect(Rules.unhealthy(r["tern:broken:many_to_many"])).toBe(true)
	end)

	it("keeps the rules of a source that answered when the other fails", function()
		local plan = assert(Rules.plan(CFG, "lab"))
		local result = Rules.combine(env, plan, {
			grafana = { status = 403, headers = {}, body = '{"message":"Permission denied"}', timed_out = false },
			prometheus = ok("prometheus/3.15.0/rules.json"),
		})
		expect(result.failed).toBe(false)
		expect(#result.errors).toBe(1)
		expect(string.find(result.errors[1], "Grafana-managed", 1, true) ~= nil).toBe(true)
		expect(byName(result.rules).TernAlwaysFiring ~= nil).toBe(true)
	end)

	it("filters rules with the inbox filter syntax", function()
		local plan = assert(Rules.plan(CFG, "prom"))
		local result = Rules.combine(env, plan, { prometheus = ok("prometheus/3.15.0/rules.json") })
		local f = { matchers = { { name = "alertname", op = "=", value = "TernPending" } }, words = {} }
		local only = Rules.select(result.rules, f :: any, false)
		expect(#only).toBe(1)
		expect(Rules.alertsFilter(only[1])).toBe('alertname="TernPending"')
	end)
end)

local function key(text: string, name: string?): any
	return {
		name = name or text,
		text = if name then nil else text,
		ctrl = false,
		alt = false,
		shift = false,
		meta = false,
	}
end

-- Answers rules requests (tags `r<gen>:<source>`) and inbox requests.
local function answer(s: any, effects: { any }, bodies: { [string]: any }): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "http" then
			local tag = string.match(e.tag, ":(.+)$") :: string
			local _, more = State.update(s, { kind = "http_done", tag = e.tag, response = bodies[tag] }, env)
			for _, m in more do
				table.insert(out, m)
			end
		end
	end
	return out
end

describe("rules view", function()
	local BODIES = {
		am = ok("grafana/12.4.12/alerting_am_alerts.json"),
		rules = ok("grafana/12.4.12/alerting_prom_alerts.json"),
		grafana = ok("grafana/12.4.12/alerting_prom_rules.json"),
		prometheus = ok("prometheus/3.15.0/rules.json"),
	}

	it("opens on the rules view from a link and leads to a rule's query and alerts", function()
		local s: any, effects = State.init({ "tern-grafana://alerts?context=lab&view=rules" }, nil, env)
		expect(s.view).toBe("rules")
		answer(s, effects, BODIES)
		expect(#s.rule_rows).toBe(12)
		expect(s.rule_rows[1].name).toBe("TernGrafanaAlwaysFiring")
		local _, moved = State.key(s, key("j"), env)
		expect(moved[1]).toEqual({ kind = "reveal", id = "main.rules.u2" })
		State.key(s, key("k"), env)
		local _, q = State.key(s, key("q"), env)
		expect((assert(Scheme.decode((q[1] :: any).target))).action).toBe("query")
		State.key(s, key("a"), env)
		expect(s.view).toBe("inbox")
		expect(s.filter_text).toBe('__alert_rule_uid__="tern-g-firing"')
		expect(#s.rows).toBe(2)
		expect(State.title(s)).toBe("Alerts: lab (2 firing)")
	end)

	it("toggles views with v and shows only unhealthy rules with p", function()
		local s: any, effects = State.init({ "tern-grafana://alerts?context=lab" }, nil, env)
		answer(s, effects, BODIES)
		local _, loads = State.key(s, key("v"), env)
		expect(#loads).toBe(2)
		answer(s, loads, BODIES)
		State.key(s, key("p"), env)
		expect(#s.rule_rows).toBe(1)
		expect(State.save(s).view).toBe("rules")
		expect(State.save(s).problems_only).toBe(true)
	end)
end)

return nil
