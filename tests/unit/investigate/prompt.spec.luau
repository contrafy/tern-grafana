--!strict
-- The prompt is what an agent sees and acts on: it must carry what the user
-- was looking at (the alert's labels, annotations and runbook, the query and
-- its time range, a summary of the recent values, links back to Grafana),
-- ask for a read-only investigation, stay bounded, and never contain a
-- context's credentials, credential sources or tenant headers.
local Normalize = require("../../../plugin/lib/alerts/normalize")
local Fixtures = require("../../lib/fixtures")
local Frame = require("../../../plugin/lib/frame/types")
local Prom = require("../../../plugin/lib/source/prom")
local Prompt = require("../../../plugin/lib/investigate/prompt")
local Subject = require("../../../plugin/lib/investigate/subject")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577898000

local CFG = (function(): any
	local cfg, problems = Validate.parseFile(
		[[{"default_context": "lab", "contexts": {"lab": {
		"prometheus": {"url": "http://p:9090", "headers": {"X-Scope-OrgID": "TENANTMARK"},
			"auth": {"type": "bearer", "token_cmd": ["op", "read", "op://vault/CMDMARK"]}},
		"alertmanager": {"url": "http://am:9093",
			"auth": {"type": "basic", "username": "USERMARK", "password_file": "/secrets/PWFILEMARK"}},
		"grafana": {"url": "http://g:3000", "auth": {"type": "bearer", "token_env": "TOKENENVMARK"},
			"headers": {"X-Grafana-Org-Id": "ORGHEADERMARK"},
			"datasources": {"prometheus": "prom3"}}}}}]],
		json.decode
	)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end)()

local MARKS = { "TENANTMARK", "CMDMARK", "USERMARK", "PWFILEMARK", "TOKENENVMARK", "ORGHEADERMARK" }

local env: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null, config = CFG }

local function assertNoSecrets(text: string)
	for _, mark in MARKS do
		if string.find(text, mark, 1, true) then
			error("prompt contains credential marker " .. mark)
		end
	end
end

local function alerts(path: string, prometheus: boolean): { any }
	local body = Fixtures.read(path)
	local parsed: any = if prometheus
		then Normalize.parsePrometheusAlerts(env, body, "lab", "prometheus")
		else Normalize.parseAlertmanager(env, body, "lab", "alertmanager")
	assert(parsed.ok, parsed.error)
	return parsed.items
end

local function named(list: { any }, name: string): any
	for _, a in list do
		if a.labels.alertname == name then
			return a
		end
	end
	error("no alert " .. name)
end

local function frames(path: string): { any }
	local r: any = Prom.parseQuery({ status = 200, headers = {}, body = Fixtures.read(path), timed_out = false }, env)
	assert(r.ok, path)
	return r.frames
end

local RANGE = { from = "now-15m", to = "now", from_ms = NOW - 900000, to_ms = NOW }

describe("alert prompt", function()
	it("carries the alert's labels, annotations, runbook and links, and asks for read-only work", function()
		local a = named(alerts("prometheus/3.15.0/alerts.json", true), "TernAlwaysFiring")
		local s = Subject.fromAlert(a, CFG, json.encode)
		local p = Prompt.build(s, NOW)
		expect(p).toContain("Investigate this firing Grafana alert")
		expect(p).toContain("Do not change anything without asking me first.")
		expect(p).toContain("Alert: TernAlwaysFiring (severity critical, firing since ")
		expect(p).toContain("Summary: Always firing fixture alert")
		expect(p).toContain("Description: Fires on every evaluation")
		expect(p).toContain("  team: platform")
		expect(p).toContain("  Runbook: https://example.com/runbooks/tern-always-firing")
		expect(p).toContain("  Dashboard: http://127.0.0.1:3000/d/tern-panels/tern-panels")
		-- The runbook is a link, not repeated as an annotation.
		expect((string.find(p, "runbook_url:", 1, true))).toBeNil()
		assertNoSecrets(p)
	end)

	it("hides Grafana's internal labels and annotations", function()
		local list = alerts("alertmanager/0.34.1/alerts.json", false)
		for _, a in list do
			local p = Prompt.build(Subject.fromAlert(a, CFG, json.encode), NOW)
			expect((string.find(p, "__alert_rule_uid__", 1, true))).toBeNil()
			expect((string.find(p, "__values__", 1, true))).toBeNil()
			assertNoSecrets(p)
		end
	end)

	it("takes a Prometheus alert's query from its generator URL so the preview can fetch recent values", function()
		local exprs: { string } = {}
		for _, a in alerts("alertmanager/0.34.1/alerts.json", false) do
			local s = Subject.fromAlert(a, CFG, json.encode)
			if s.fetch then
				table.insert(exprs, s.queries[1].expr)
				expect(Prompt.build(s, NOW)).toContain("Query (PromQL): " .. s.queries[1].expr)
			end
		end
		expect(table.find(exprs, "vector(1)") ~= nil).toBe(true)
	end)
end)

describe("query prompt", function()
	it("carries the query, its time range, a values summary and the Explore link", function()
		local s = Subject.fromQuery({
			context = "lab",
			expr = 'rate(node_cpu_seconds_total{mode=~"user|system|idle"}[1m])',
			range = RANGE,
			frames = frames("prometheus/3.15.0/query_range_multi.json"),
		}, CFG, json.encode)
		local p = Prompt.build(s, NOW)
		expect(p).toContain("Investigate this Prometheus query result")
		expect(p).toContain('Query (PromQL): rate(node_cpu_seconds_total{mode=~"user|system|idle"}[1m])')
		expect(p).toContain("Time range: now-15m to now (")
		expect(p).toContain("Recent values (")
		expect(p).toContain("node_cpu_seconds_total{")
		expect(p).toContain("  Grafana Explore: http://g:3000/explore?")
		expect(#(s.values :: any).series <= Subject.MAX_SERIES).toBe(true)
		assertNoSecrets(p)
		assertNoSecrets(json.encode(s))
	end)

	it("says when the range had no data", function()
		local s =
			Subject.fromQuery({ context = "lab", expr = "absent_metric", range = RANGE, frames = {} }, CFG, json.encode)
		expect(Prompt.build(s, NOW)).toContain("(no data in this range)")
	end)
end)

describe("panel prompt", function()
	it("names the dashboard and panel and lists every query by ref", function()
		local s = Subject.fromPanel({
			context = "lab",
			dashboard = "Tern Panels",
			uid = "tern-panels",
			panel_id = 2,
			title = "CPU",
			type = "timeseries",
			queries = { { ref = "A", expr = "rate(a[5m])" }, { ref = "B", expr = "rate(b[5m])" } },
			range = RANGE,
			frames = { Frame.timeSeries({ __name__ = "a" }, { NOW - 1000, NOW }, { 1, 2 }) },
		}, CFG, json.encode)
		local p = Prompt.build(s, NOW)
		expect(p).toContain("Investigate this Grafana dashboard panel")
		expect(p).toContain("Dashboard: Tern Panels (uid tern-panels)")
		expect(p).toContain("Panel: CPU (timeseries)")
		expect(p).toContain("  A: rate(a[5m])\n  B: rate(b[5m])")
		expect(p).toContain("  a: last 2, min 1, max 2, avg 1.5 (2 points)")
		expect(p).toContain("  Grafana panel: http://g:3000/d/tern-panels")
		assertNoSecrets(p)
	end)
end)

describe("bounds", function()
	it("cuts an oversized prompt and says so", function()
		local s = Subject.fromQuery({ context = "lab", expr = string.rep("x", 3000), range = RANGE }, CFG, json.encode)
		local big: any = Subject.read(json.decode(json.encode(s)))
		for i = 1, 8 do
			big.queries[i] = { ref = tostring(i), expr = string.rep("y", 3000) }
		end
		local p = Prompt.build(big, NOW)
		expect(#p <= Prompt.MAX_CHARS).toBe(true)
		expect(string.sub(p, -11)).toBe("[truncated]")
	end)

	it("refuses a subject that does not have the expected shape", function()
		expect(Subject.read(nil)).toBeNil()
		expect(Subject.read({ kind = "shell", title = "x", queries = {}, links = {} })).toBeNil()
		expect(
			Subject.read({ kind = "query", title = "x", queries = {}, links = { { label = "x", url = "file:///etc" } } })
		).toBeNil()
	end)
end)

return nil
