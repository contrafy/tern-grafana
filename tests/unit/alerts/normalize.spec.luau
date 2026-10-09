--!strict
-- Every alert API must land in one model, or the inbox and the status
-- segment disagree with the server: states (firing, pending, silenced,
-- inhibited) decide what demands attention, fingerprints keep one alert's
-- identity across sources and polls, and Grafana's annotations are the only
-- way back to the dashboard panel an alert came from.
local Fixtures = require("../../lib/fixtures")
local Normalize = require("../../../plugin/lib/alerts/normalize")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local GRAFANA = { "11.6.16", "12.4.12" }
local PROMETHEUS = { "2.53.5", "3.15.0" }
-- Shortly after the alerting fixtures were captured (2026-10-09T20:31Z).
local NOW = 1791577860000

local env: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null }

local function items(parsed: any): { any }
	assert(parsed.ok, parsed.error)
	return parsed.items
end

local function byName(list: { any }): { [string]: any }
	local out = {}
	for _, a in list do
		out[a.labels.alertname] = a
	end
	return out
end

local function am(path: string, source: any?): { any }
	return items(Normalize.parseAlertmanager(env, Fixtures.read(path), "lab", source or "alertmanager"))
end

local function promAlerts(path: string, source: any): { any }
	return items(Normalize.parsePrometheusAlerts(env, Fixtures.read(path), "lab", source))
end

-- A real capture with one alert's status rewritten: the dev stack has no
-- inhibition rule, so Alertmanager never reports one.
local function withStatus(path: string, name: string, edit: (any) -> ()): string
	local doc = json.decode(Fixtures.read(path))
	for _, raw in doc do
		if raw.labels.alertname == name then
			edit(raw)
		end
	end
	return json.encode(doc)
end

describe("Alertmanager v2 alerts", function()
	it("reads active alerts as firing and suppressed-by-silence as silenced, keeping the silence id", function()
		local a = byName(am("alertmanager/0.34.1/alerts_with_silenced.json"))
		expect(a.TernAlwaysFiring.state).toBe("silenced")
		expect(a.TernAlwaysFiring.silenced_by).toEqual({ "892a1c9d-e05b-4e32-8dad-b5b3860bc8c3" })
		expect(a.TernTargetDown.state).toBe("firing")
		expect(a.TernGrafanaAlwaysFiring.state).toBe("firing")
		expect(a.TernGrafanaTargetDown.state).toBe("firing")
	end)

	it("reads an alert suppressed by an inhibition as inhibited, and a silence wins over both", function()
		local path = "alertmanager/0.34.1/alerts.json"
		local inhibited = withStatus(path, "TernTargetDown", function(raw)
			raw.status.state = "suppressed"
			raw.status.inhibitedBy = { "8719efdbe93398cf" }
		end)
		local a = byName(items(Normalize.parseAlertmanager(env, inhibited, "lab", "alertmanager")))
		expect(a.TernTargetDown.state).toBe("inhibited")
		expect(a.TernTargetDown.inhibited_by).toEqual({ "8719efdbe93398cf" })

		local both = withStatus(path, "TernTargetDown", function(raw)
			raw.status.state = "suppressed"
			raw.status.inhibitedBy = { "8719efdbe93398cf" }
			raw.status.silencedBy = { "s1" }
		end)
		a = byName(items(Normalize.parseAlertmanager(env, both, "lab", "alertmanager")))
		expect(a.TernTargetDown.state).toBe("silenced")
	end)

	it("reads an alert whose end is not after its last update as resolved", function()
		local body = withStatus("alertmanager/0.34.1/alerts.json", "TernTargetDown", function(raw)
			raw.endsAt = raw.updatedAt
		end)
		local a = byName(items(Normalize.parseAlertmanager(env, body, "lab", "alertmanager")))
		expect(a.TernTargetDown.state).toBe("resolved")
		expect(a.TernAlwaysFiring.state).toBe("firing")
	end)

	it("keeps Alertmanager's fingerprint, times, receivers and the Prometheus annotations", function()
		local a = byName(am("alertmanager/0.34.1/alerts.json")).TernAlwaysFiring
		expect(a.fingerprint).toBe("8719efdbe93398cf")
		expect(a.starts_at_ms).toBe(1791576954628)
		expect(a.ends_at_ms).toBe(1791578114628)
		expect(a.generator_url).toBe("http://5d64f183d71f:9090/graph?g0.expr=vector%281%29&g0.tab=1")
		expect(a.receivers).toEqual({ "platform" })
		expect(a.severity).toBe("critical")
		expect(a.summary).toBe("Always firing fixture alert")
		expect(a.runbook_url).toBe("https://example.com/runbooks/tern-always-firing")
		expect(a.dashboard_url).toBe("http://127.0.0.1:3000/d/tern-panels/tern-panels")
		expect(a.dashboard_uid).toBeNil()
		expect(a.context).toBe("lab")
	end)

	it("reads each alert of /alerts/groups once", function()
		local list = items(
			Normalize.parseAlertmanagerGroups(
				env,
				Fixtures.read("alertmanager/0.34.1/alert_groups.json"),
				"lab",
				"alertmanager"
			)
		)
		local fps = {}
		for _, a in list do
			table.insert(fps, a.fingerprint)
		end
		table.sort(fps)
		expect(fps).toEqual({ "60e501da44260207", "8719efdbe93398cf", "c07ddd495f2853cf", "e465b94738ecf983" })
	end)

	it("reports a body that is not JSON instead of an empty inbox", function()
		local parsed: any = Normalize.parseAlertmanager(env, "<html>", "lab", "alertmanager")
		expect(parsed.ok).toBe(false)
	end)
end)

describe("Grafana-managed alerts", function()
	for _, v in GRAFANA do
		it(v .. ": silenced alerts from Grafana's Alertmanager are silenced", function()
			local a = byName(am("grafana/" .. v .. "/alerting_am_alerts_silenced.json", "grafana"))
			expect(a.TernGrafanaAlwaysFiring.state).toBe("silenced")
			expect(#a.TernGrafanaAlwaysFiring.silenced_by).toBe(1)
			expect(a.TernGrafanaTargetDown.state).toBe("firing")
			expect(a.TernGrafanaTargetDown.source).toBe("grafana")
		end)

		it(v .. ": dashboard, panel, runbook, summary and description come from the annotations", function()
			local a = byName(am("grafana/" .. v .. "/alerting_am_alerts.json", "grafana")).TernGrafanaAlwaysFiring
			expect(a.dashboard_uid).toBe("tern-panels")
			expect(a.panel_id).toBe(2)
			expect(a.runbook_url).toBe("https://example.com/runbooks/tern-grafana-always-firing")
			expect(a.summary).toBe("TernGrafanaAlwaysFiring")
			expect(a.description).toBe("Fires on every evaluation so Grafana alert views always have data.")
			expect(a.rule_uid).toBe("tern-g-firing")
			expect(a.severity).toBe("critical")
			expect(Normalize.isInternal("__dashboardUid__")).toBe(true)
			expect(Normalize.isInternal("__value_string__")).toBe(true)
			expect(Normalize.isInternal("__alert_rule_uid__")).toBe(true)
			expect(Normalize.isInternal("runbook_url")).toBe(false)
		end)

		it(v .. ": the rule evaluator reports pending alerts and drops Normal ones", function()
			local a = byName(promAlerts("grafana/" .. v .. "/alerting_prom_alerts.json", "grafana"))
			expect(a.TernGrafanaNormal).toBeNil()
			expect(a.TernGrafanaPending.state).toBe("pending")
			expect(a.TernGrafanaPending.severity).toBe("info")
			expect(a.TernGrafanaPending.value).toBe("1e+00")
			expect(a.TernGrafanaAlwaysFiring.state).toBe("firing")
			expect(a.TernGrafanaAlwaysFiring.panel_id).toBe(2)
			expect(a.TernGrafanaAlwaysFiring.starts_at_ms).toBe(1791576960000)
		end)

		it(v .. ": merging adds pending alerts to the Alertmanager view without duplicating firing ones", function()
			local merged = Normalize.merge(
				am("grafana/" .. v .. "/alerting_am_alerts_silenced.json", "grafana"),
				promAlerts("grafana/" .. v .. "/alerting_prom_alerts.json", "grafana")
			)
			local states = {}
			for _, a in merged do
				states[a.labels.alertname] = (states[a.labels.alertname] or "") .. a.state
			end
			expect(states).toEqual({
				TernGrafanaAlwaysFiring = "silenced",
				TernGrafanaTargetDown = "firing",
				TernGrafanaPending = "pending",
			})
		end)

		it(v .. ": an external Alertmanager proxied by Grafana reads like a direct one", function()
			local a = byName(am("grafana/" .. v .. "/alerting_ext_am_alerts.json"))
			expect(a.TernAlwaysFiring.fingerprint).toBe("8719efdbe93398cf")
			expect(a.TernAlwaysFiring.state).toBe("firing")
		end)
	end
end)

describe("Prometheus alerts", function()
	for _, v in PROMETHEUS do
		it(v .. ": firing and pending alerts with Alertmanager-compatible fingerprints", function()
			local a = byName(promAlerts("prometheus/" .. v .. "/alerts.json", "prometheus"))
			expect(a.TernAlwaysFiring.state).toBe("firing")
			expect(a.TernPending.state).toBe("pending")
			expect(a.TernTargetDown.state).toBe("firing")
			-- The same alert as Alertmanager reports it, so a pending alert that
			-- starts firing keeps its identity.
			expect(a.TernAlwaysFiring.fingerprint).toBe("8719efdbe93398cf")
			expect(a.TernTargetDown.fingerprint).toBe("e465b94738ecf983")
			expect(a.TernAlwaysFiring.starts_at_ms).toBe(1791576954628)
			expect(a.TernAlwaysFiring.source).toBe("prometheus")
		end)
	end

	it("fingerprints every captured Alertmanager alert exactly as Alertmanager does", function()
		for _, path in
			{
				"alertmanager/0.34.1/alerts.json",
				"grafana/11.6.16/alerting_am_alerts.json",
				"grafana/12.4.12/alerting_am_alerts.json",
			}
		do
			for _, raw in json.decode(Fixtures.read(path)) do
				expect(Normalize.fingerprint(raw.labels)).toBe(raw.fingerprint)
			end
		end
	end)

	it("reports Prometheus' own error instead of an empty list", function()
		local parsed: any = Normalize.parsePrometheusAlerts(
			env,
			'{"status":"error","errorType":"bad_data","error":"boom"}',
			"lab",
			"prometheus"
		)
		expect(parsed.ok).toBe(false)
		expect(parsed.error).toBe("boom")
	end)
end)

describe("rules", function()
	for _, v in PROMETHEUS do
		it(v .. ": alerting and recording rules with health, last error and last evaluation", function()
			local rules = items(
				Normalize.parseRules(env, Fixtures.read("prometheus/" .. v .. "/rules.json"), "lab", "prometheus")
			)
			local r = {}
			for _, rule in rules do
				r[rule.name] = rule
			end
			expect(r.TernPending.type).toBe("alerting")
			expect(r.TernPending.state).toBe("pending")
			expect(r.TernPending.alerts[1].state).toBe("pending")
			expect(r.TernInactive.state).toBe("inactive")
			expect(#r.TernInactive.alerts).toBe(0)
			local broken = r["tern:broken:many_to_many"]
			expect(broken.type).toBe("recording")
			expect(broken.state).toBeNil()
			expect(broken.health).toBe("err")
			expect(string.find(broken.last_error, "many-to-many matching not allowed", 1, true) ~= nil).toBe(true)
			expect(broken.query).toBe("up * on () up")
			expect(r["job:up:sum"].health).toBe("ok")
			expect(r["job:up:sum"].last_error).toBeNil()
			expect(type(r.TernAlwaysFiring.last_evaluation_ms)).toBe("number")
			expect(r.TernAlwaysFiring.group).toBe("tern-alerts")
		end)
	end

	for _, v in GRAFANA do
		it(v .. ": Grafana rules carry their uid and Grafana's alert states", function()
			local rules = items(
				Normalize.parseRules(
					env,
					Fixtures.read("grafana/" .. v .. "/alerting_prom_rules.json"),
					"lab",
					"grafana"
				)
			)
			local r = {}
			for _, rule in rules do
				r[rule.name] = rule
			end
			expect(r.TernGrafanaAlwaysFiring.uid).toBe("tern-g-firing")
			expect(r.TernGrafanaAlwaysFiring.alerts[1].state).toBe("firing")
			expect(r.TernGrafanaPending.alerts[1].state).toBe("pending")
			expect(#r.TernGrafanaNormal.alerts).toBe(0)
			expect(r.TernGrafanaAlwaysFiring.last_evaluation_ms).toBe(1791577900000)
		end)
	end
end)

describe("severity", function()
	it("maps severity labels onto the five ranks, unknown values to none", function()
		expect(Normalize.severity({ severity = "Critical" })).toBe("critical")
		expect(Normalize.severity({ severity = "error" })).toBe("error")
		expect(Normalize.severity({ severity = "warn" })).toBe("warning")
		expect(Normalize.severity({ severity = "info" })).toBe("info")
		expect(Normalize.severity({ severity = "p3" })).toBe("none")
		expect(Normalize.severity({})).toBe("none")
	end)
end)

return nil
