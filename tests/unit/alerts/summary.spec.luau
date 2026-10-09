--!strict
-- The summary feeds the status segment through kv, a plain 0644 file every
-- window re-reads: it must count what the inbox counts, stay small enough to
-- read inside a 4 ms formatter, and never carry labels, annotations, server
-- messages or credentials. `diff` is what later announces newly firing
-- alerts, so the first poll must not announce everything already firing.
local Fixtures = require("../../lib/fixtures")
local Normalize = require("../../../plugin/lib/alerts/normalize")
local Settings = require("../../../plugin/lib/alerts/settings")
local Sources = require("../../../plugin/lib/alerts/sources")
local Summary = require("../../../plugin/lib/alerts/summary")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577860000
local env: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null }

local function grafanaAlerts(v: string): { any }
	local am: any = Normalize.parseAlertmanager(
		env,
		Fixtures.read("grafana/" .. v .. "/alerting_am_alerts_silenced.json"),
		"lab",
		"grafana"
	)
	local rules: any = Normalize.parsePrometheusAlerts(
		env,
		Fixtures.read("grafana/" .. v .. "/alerting_prom_alerts.json"),
		"lab",
		"grafana"
	)
	return Normalize.merge(am.items, rules.items)
end

local function amAlerts(path: string): { any }
	local parsed: any = Normalize.parseAlertmanager(env, Fixtures.read(path), "lab", "alertmanager")
	return parsed.items
end

-- `n` firing alerts with distinct label sets, from a captured alert.
local function many(n: number): { any }
	local base = amAlerts("alertmanager/0.34.1/alerts.json")[1]
	local out = {}
	for i = 1, n do
		local a = table.clone(base)
		a.labels = table.clone(base.labels)
		a.labels.instance = "host-" .. i
		a.fingerprint = Normalize.fingerprint(a.labels)
		a.severity = if i % 3 == 0 then "critical" else "warning"
		table.insert(out, a)
	end
	return out
end

describe("summarize", function()
	for _, v in { "11.6.16", "12.4.12" } do
		it(v .. ": counts Grafana-managed alerts by state, firing ones by severity", function()
			local s = Summary.summarize(grafanaAlerts(v), NOW)
			expect(s.firing).toBe(1)
			expect(s.pending).toBe(1)
			expect(s.silenced).toBe(1)
			expect(s.inhibited).toBe(0)
			expect(s.by_severity).toEqual({ warning = 1 })
			-- The silenced critical does not make the context critical.
			expect(s.worst).toBe("warning")
			expect(s.fingerprints).toEqual({ "60e501da44260207" })
			expect(s.updated_ms).toBe(NOW)
		end)
	end

	it("takes the worst firing severity for an Alertmanager", function()
		local s = Summary.summarize(amAlerts("alertmanager/0.34.1/alerts.json"), NOW)
		expect(s.firing).toBe(4)
		expect(s.worst).toBe("critical")
		expect(s.by_severity).toEqual({ critical = 2, warning = 2 })
	end)

	it("maps severities onto the status tones", function()
		expect(Summary.tone("critical")).toBe("error")
		expect(Summary.tone("error")).toBe("error")
		expect(Summary.tone("warning")).toBe("warning")
		expect(Summary.tone("info")).toBe("info")
		expect(Summary.tone("none")).toBe("muted")
	end)

	it("keeps the last counts when a poll fails, so an outage never reads as all clear", function()
		local good = Summary.summarize(amAlerts("alertmanager/0.34.1/alerts.json"), NOW)
		local bad = Summary.failed(good, "network", NOW + 60000)
		expect(bad.firing).toBe(4)
		expect(bad.error).toBe("network")
		expect(bad.updated_ms).toBe(NOW + 60000)
		expect(good.error).toBeNil()
	end)
end)

describe("diff", function()
	it("announces nothing on the first poll", function()
		local next = Summary.summarize(amAlerts("alertmanager/0.34.1/alerts.json"), NOW)
		expect(Summary.diff(nil, next)).toEqual({})
	end)

	it("returns alerts that started firing, including a silence that ended", function()
		local prev = Summary.summarize(amAlerts("alertmanager/0.34.1/alerts_with_silenced.json"), NOW)
		local next = Summary.summarize(amAlerts("alertmanager/0.34.1/alerts.json"), NOW + 60000)
		expect(Summary.diff(prev, next)).toEqual({ "8719efdbe93398cf" })
		expect(Summary.diff(next, next)).toEqual({})
		expect(Summary.diff(next, prev)).toEqual({})
	end)
end)

describe("kv payload", function()
	it("stays small with every polled context full of firing alerts", function()
		local contexts = {}
		for i = 1, Settings.MAX_CONTEXTS do
			contexts["context-" .. i] = Summary.summarize(many(2000), NOW)
		end
		local encoded = json.encode(Summary.payload(contexts, NOW, 60))
		expect(#contexts["context-1"].fingerprints).toBe(Summary.MAX_FINGERPRINTS)
		-- The critical alerts are the ones kept.
		expect(contexts["context-1"].by_severity.critical).toBe(666)
		expect(#encoded < 32 * 1024).toBe(true)
		expect(#json.encode(contexts["context-1"]) < 1700).toBe(true)
	end)

	it("never carries labels, annotations, URLs, server messages or credentials", function()
		local cfg = Validate.parseFile(
			[[{"default_context": "lab", "contexts": {"lab": {"alertmanager": {"url": "http://am.example:9093",
			"auth": {"type": "bearer", "token_env": "AM_TOKEN"}}}}}]],
			json.decode
		)
		assert(cfg, "config")
		local plan = assert(Sources.plan(cfg, "lab"))
		local body = Fixtures.read("alertmanager/0.34.1/alerts.json")
		local ok = Sources.combine(env, plan, { am = { status = 200, headers = {}, body = body, timed_out = false } })
		local good = Summary.summarize(ok.alerts, NOW)
		local failed = Sources.combine(env, plan, {
			am = {
				status = 401,
				headers = {},
				body = '{"message":"invalid token s3cr3t-T0KEN-value"}',
				timed_out = false,
			},
		})
		expect(failed.ok).toBe(false)
		local payload = Summary.payload({
			lab = good,
			other = Summary.failed(nil, failed.error_kind :: any, NOW),
		}, NOW, 60)
		local encoded = json.encode(payload)
		for _, needle in
			{
				"s3cr3t",
				"AM_TOKEN",
				"invalid token",
				"http",
				"runbook",
				"TernAlwaysFiring",
				"platform",
				"node-exporter",
				'summary":"',
			}
		do
			expect({ needle = needle, found = string.find(encoded, needle, 1, true) ~= nil }).toEqual({
				needle = needle,
				found = false,
			})
		end
		expect(payload.contexts.other.error).toBe("auth")
	end)

	it("replaces one context's summary and keeps the others", function()
		local a = Summary.summarize({}, NOW)
		local prev = Summary.payload({ one = a, two = a }, NOW, 60)
		local next = Summary.withContext(prev, "two", Summary.failed(a, "timeout", NOW + 1), NOW + 1, 30)
		expect(next.contexts.one).toBe(a)
		expect(next.contexts.two.error).toBe("timeout")
		expect(next.poll_s).toBe(60)
		expect(Summary.readPayload({ v = 0, contexts = {}, updated_ms = 1 })).toBeNil()
		expect(Summary.readPayload(json.decode(json.encode(next)))).toEqual(json.decode(json.encode(next)))
	end)
end)

return nil
