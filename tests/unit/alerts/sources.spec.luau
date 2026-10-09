--!strict
-- Alerts must be read from the server the user configured for them (a
-- direct Alertmanager wins over Grafana), Grafana-managed alerting must show
-- pending alerts its Alertmanager never sees, and a Prometheus-only context
-- still gets an inbox. Links from an alert must land on the native block when
-- one exists.
local Fixtures = require("../../lib/fixtures")
local Scheme = require("../../../plugin/lib/links/scheme")
local Sources = require("../../../plugin/lib/alerts/sources")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env: any = { now_ms = 1791577860000, decode = json.decode, encode = json.encode, null = json.null }

local function config(text: string): any
	local cfg, problems = Validate.parseFile(text, json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

local CFG = config([[{"default_context": "am", "contexts": {
	"am": {"alertmanager": {"url": "http://am:9093"}, "grafana": {"url": "http://g"}},
	"ext": {"grafana": {"url": "http://g", "datasources": {"alertmanager": "alertmanager"}}},
	"graf": {"grafana": {"url": "http://g/sub", "org_id": 2}},
	"prom": {"prometheus": {"url": "http://p:9090"}},
	"logs": {"loki": {"url": "http://l"}}}}]])

local function ok(body: string): any
	return { status = 200, headers = {}, body = body, timed_out = false }
end

local function paths(plan: any): { string }
	local out = {}
	for _, f in plan.fetches do
		table.insert(out, f.tag .. " " .. f.request.path)
	end
	return out
end

local function byName(list: { any }): { [string]: any }
	local out = {}
	for _, a in list do
		out[a.labels.alertname] = a
	end
	return out
end

describe("plan", function()
	it("reads a direct Alertmanager even when Grafana is configured", function()
		local plan = assert(Sources.plan(CFG, nil))
		expect(plan.kind).toBe("alertmanager")
		expect(paths(plan)).toEqual({ "am /api/v2/alerts" })
	end)

	it("reads Grafana's proxy to the Alertmanager datasource the user named", function()
		local plan = assert(Sources.plan(CFG, "ext"))
		expect(paths(plan)).toEqual({ "am /api/alertmanager/alertmanager/api/v2/alerts" })
	end)

	it("reads Grafana-managed alerting from its Alertmanager and its rule evaluator", function()
		local plan = assert(Sources.plan(CFG, "graf"))
		expect(plan.kind).toBe("grafana")
		expect(paths(plan)).toEqual({
			"am /api/alertmanager/grafana/api/v2/alerts",
			"rules /api/prometheus/grafana/api/v1/alerts",
		})
	end)

	it("falls back to Prometheus' own alerts for a Prometheus-only context", function()
		local plan = assert(Sources.plan(CFG, "prom"))
		expect(plan.kind).toBe("prometheus")
		expect(plan.route.endpoint_name).toBe("prometheus")
		expect(paths(plan)).toEqual({ "prom /api/v1/alerts" })
	end)

	it("says what to configure when nothing serves alerts", function()
		local plan, err = Sources.plan(CFG, "logs")
		expect(plan).toBeNil()
		expect(err).toBe('context "logs" has no alertmanager, grafana or prometheus endpoint')
		plan, err = Sources.plan(CFG, "nope")
		expect(plan).toBeNil()
		expect(string.find(err :: string, "no context named", 1, true) ~= nil).toBe(true)
	end)
end)

describe("combine", function()
	for _, v in { "11.6.16", "12.4.12" } do
		it(v .. ": Grafana's firing and silenced alerts plus its pending ones", function()
			local plan = assert(Sources.plan(CFG, "graf"))
			local r = Sources.combine(env, plan, {
				am = ok(Fixtures.read("grafana/" .. v .. "/alerting_am_alerts_silenced.json")),
				rules = ok(Fixtures.read("grafana/" .. v .. "/alerting_prom_alerts.json")),
			})
			expect(r.ok).toBe(true)
			local a = byName(r.alerts)
			expect(a.TernGrafanaAlwaysFiring.state).toBe("silenced")
			expect(a.TernGrafanaTargetDown.state).toBe("firing")
			expect(a.TernGrafanaPending.state).toBe("pending")
			expect(a.TernGrafanaPending.context).toBe("graf")
		end)

		it(v .. ": a failing rule evaluator only loses pending alerts, with a warning", function()
			local plan = assert(Sources.plan(CFG, "graf"))
			local r = Sources.combine(env, plan, {
				am = ok(Fixtures.read("grafana/" .. v .. "/alerting_am_alerts.json")),
				rules = { status = 500, headers = {}, body = '{"message":"boom"}', timed_out = false },
			})
			expect(r.ok).toBe(true)
			expect(#r.alerts).toBe(2)
			expect(r.warnings).toEqual({ "/api/prometheus/grafana/api/v1/alerts: HTTP 500: boom" })
		end)
	end

	it("fails the context when its Alertmanager fails, with the error kind", function()
		local plan = assert(Sources.plan(CFG, "graf"))
		local r = Sources.combine(env, plan, {
			am = { status = 0, headers = {}, body = "", error = "timeout", timed_out = true },
			rules = ok(Fixtures.read("grafana/12.4.12/alerting_prom_alerts.json")),
		})
		expect(r.ok).toBe(false)
		expect(r.error_kind).toBe("timeout")
	end)

	for _, v in { "2.53.5", "3.15.0" } do
		it(v .. ": Prometheus-only contexts show firing and pending alerts", function()
			local plan = assert(Sources.plan(CFG, "prom"))
			local r = Sources.combine(env, plan, { prom = ok(Fixtures.read("prometheus/" .. v .. "/alerts.json")) })
			local a = byName(r.alerts)
			expect(a.TernPending.state).toBe("pending")
			expect(a.TernAlwaysFiring.state).toBe("firing")
		end)
	end

	it("leaves resolved alerts out of the inbox", function()
		local doc = json.decode(Fixtures.read("alertmanager/0.34.1/alerts.json"))
		doc[1].endsAt = doc[1].updatedAt
		local r = Sources.combine(env, assert(Sources.plan(CFG, "am")), { am = ok(json.encode(doc)) })
		expect(#r.alerts).toBe(3)
	end)
end)

describe("links", function()
	local function alerts(path: string, context: string): { [string]: any }
		local plan = assert(Sources.plan(CFG, context))
		local r = Sources.combine(env, plan, { am = ok(Fixtures.read(path)) })
		return byName(r.alerts)
	end

	it("opens a Prometheus generator URL as the query block on the same context", function()
		local a = alerts("alertmanager/0.34.1/alerts.json", "am").TernTargetDown
		local link = assert(Scheme.decode(Sources.generatorTarget(a) :: string))
		expect(link.action).toBe("query")
		expect(link.params).toEqual({ context = "am", expr = "up == 0" })
	end)

	it("opens Grafana's rule page as is", function()
		local a = alerts("alertmanager/0.34.1/alerts.json", "am").TernGrafanaAlwaysFiring
		expect(Sources.generatorTarget(a)).toBe("http://127.0.0.1:3011/alerting/grafana/tern-g-firing/view")
	end)

	it("opens the native dashboard on the alert's panel from Grafana's annotations", function()
		local a = alerts("alertmanager/0.34.1/alerts.json", "am").TernGrafanaAlwaysFiring
		local link = assert(Scheme.decode(Sources.dashboardTarget(a) :: string))
		expect(link.action).toBe("dashboard")
		expect(link.params).toEqual({ context = "am", uid = "tern-panels", panel = "2" })
		local prom = alerts("alertmanager/0.34.1/alerts.json", "am").TernAlwaysFiring
		expect(Sources.dashboardTarget(prom)).toBe("http://127.0.0.1:3000/d/tern-panels/tern-panels")
		expect(Sources.runbookTarget(prom)).toBe("https://example.com/runbooks/tern-always-firing")
		expect(Sources.dashboardTarget(alerts("alertmanager/0.34.1/alerts.json", "am").TernTargetDown)).toBeNil()
	end)
end)

return nil
