--!strict
-- Carly's exports answer a model, not a person: arguments it gets wrong must
-- fail with a message that says how to fix them, answers must be summaries
-- that fit Carly's 16 KiB cap however large the result is, and nothing a
-- context's credentials are made of may ever reach an answer.
local Compact = require("../../../plugin/lib/carly/compact")
local Exports = require("../../../plugin/lib/carly/exports")
local Fixtures = require("../../lib/fixtures")
local Frame = require("../../../plugin/lib/frame/types")
local Specs = require("../../../plugin/lib/carly/specs")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect
local JSON_ENV = { encode = json.encode, array = json.array }

local NOW = 1791577898000

local function config(text: string): any
	local cfg, problems = Validate.parseFile(text, json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

-- Every credential source and header carries a marker no answer may contain.
local CFG = config([[{"default_context": "lab", "contexts": {
	"lab": {
		"prometheus": {"url": "http://p:9090", "headers": {"X-Scope-OrgID": "TENANTMARK"},
			"auth": {"type": "bearer", "token_cmd": ["op", "read", "op://vault/CMDMARK"]}},
		"alertmanager": {"url": "http://am:9093",
			"auth": {"type": "basic", "username": "USERMARK", "password_env": "PWENVMARK"}},
		"loki": {"url": "http://l:3100", "auth": {"type": "bearer", "token_file": "/secrets/FILEMARK"}},
		"grafana": {"url": "http://g:3000", "auth": {"type": "bearer", "token_env": "TOKENENVMARK"}}},
	"graf": {"grafana": {"url": "http://g:3000/sub", "datasources": {"prometheus": "prom3", "loki": "loki"}}},
	"bare": {"tempo": {"url": "http://t:3200"}}}}]])

local MARKS = { "TENANTMARK", "CMDMARK", "USERMARK", "PWENVMARK", "FILEMARK", "TOKENENVMARK" }

local env: any = {
	now_ms = NOW,
	decode = json.decode,
	encode = json.encode,
	null = json.null,
	array = json.array,
	config = CFG,
}

local function ok(path: string): any
	return { status = 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

local function plan(name: string, args: { any }): any
	local p, err = Exports.plan(name, args, env)
	assert(p, err)
	return p
end

local function errorOf(name: string, args: { any }): string
	local p, err = Exports.plan(name, args, env)
	expect(p).toBeNil()
	return err :: string
end

-- Answers a single-fetch plan with `response`.
local function finish(p: any, response: any): (any, string?)
	local responses = {}
	for _, f in p.fetches do
		responses[f.tag] = response
	end
	return p.finish(responses, env)
end

local function assertNoSecrets(value: any)
	local text = json.encode(value)
	for _, mark in MARKS do
		if string.find(text, mark, 1, true) then
			error("answer contains credential marker " .. mark)
		end
	end
end

describe("argument validation", function()
	it("refuses a missing, empty or non-string expression", function()
		expect(errorOf("promql", {})).toBe("expr must be a string")
		expect(errorOf("promql", { "   " })).toBe("expr must not be empty")
		expect(errorOf("promql", { 42 })).toBe("expr must be a string")
		expect(errorOf("logs", { '{a="b"}\0' })).toBe("expr contains control characters")
	end)

	it("names the configured contexts when the context is unknown", function()
		expect(errorOf("promql", { "up", nil, "prod" })).toBe('no context named "prod" (contexts: bare, graf, lab)')
		expect(errorOf("alerts", { 7 })).toBe("context must be a string")
	end)

	it("says what the context lacks instead of guessing another one", function()
		expect(errorOf("promql", { "up", nil, "bare" })).toContain("has no prometheus or grafana endpoint")
		expect(errorOf("find_dashboard", { "x", "bare" })).toContain("no grafana endpoint")
	end)

	it("accepts a duration, a Grafana start or {from, to} as the range", function()
		local d = assert(Exports.range("1h", NOW))
		expect(d.to_ms - d.from_ms).toBe(3600000)
		local g = assert(Exports.range("now-6h", NOW))
		expect(g.to_ms - g.from_ms).toBe(6 * 3600000)
		local ft = assert(Exports.range({ from = "now-2h", to = "now-1h" }, NOW))
		expect(ft.to_ms - ft.from_ms).toBe(3600000)
		expect(select(2, Exports.range("yesterday-ish", NOW))).toContain("range: from:")
		expect(select(2, Exports.range({ from = 1 }, NOW))).toContain("needs string times")
		expect(select(2, Exports.range(5, NOW))).toBe("range must be a string or {from, to}")
		expect(select(2, Exports.range({ from = "now", to = "now-1h" }, NOW))).toContain("range:")
	end)

	it("lists dashboards for an empty search but refuses a non-string one", function()
		expect(#plan("find_dashboard", { "" }).fetches).toBe(1)
		expect(errorOf("find_dashboard", { {} })).toBe("query must be a string")
	end)

	it("documents every export within Tern's limits", function()
		for _, name in Specs.NAMES do
			local spec = (Specs.SPECS :: any)[name]
			expect(string.match(name, "^[a-z][a-z0-9_]*$") ~= nil and #name <= 24).toBe(true)
			expect(#spec.sig > 0 and #spec.sig <= 1024).toBe(true)
			expect(#spec.doc > 0 and #spec.doc <= 1024).toBe(true)
		end
	end)
end)

describe("promql", function()
	it("summarizes a range result per series, largest last value first, without raw samples", function()
		local p = plan("promql", { "rate(node_cpu_seconds_total[$__rate_interval])", "15m" })
		local req = p.fetches[1].request
		expect(req.path).toBe("/api/v1/query_range")
		expect((string.find(req.body, "$__", 1, true))).toBeNil()
		expect((string.find(req.body, "%24__", 1, true))).toBeNil()
		local out = assert(finish(p, ok("prometheus/3.15.0/query_range_multi.json")))
		expect(out.context).toBe("lab")
		expect(out.kind).toBe("range")
		expect(#out.series > 0).toBe(true)
		for i, s in out.series do
			expect(s.points > 0).toBe(true)
			expect(#(s.trend :: any) <= Compact.SPARK).toBe(true)
			if i > 1 then
				expect(out.series[i - 1].last >= s.last).toBe(true)
			end
		end
		expect((string.find(json.encode(out), "1791576998", 1, true))).toBeNil()
		assertNoSecrets(out)
	end)

	it("runs an instant query when no range is given, through Grafana for a datasource context", function()
		local p = plan("promql", { "up", nil, "graf" })
		expect(p.fetches[1].request.path).toBe("/api/ds/query")
		local out = assert(finish(p, ok("grafana/12.4.12/ds_query_prom_instant.json")))
		expect(out.kind).toBe("instant")
		expect(out.step).toBeNil()
		expect(#out.series > 0).toBe(true)
		-- No warnings must still read as a list, matching the declared signature.
		expect((string.find(json.encode(out), '"warnings":[]', 1, true)) ~= nil).toBe(true)
	end)

	it("passes the server's query error through", function()
		local p = plan("promql", { "sum(" })
		local out, err = finish(p, {
			status = 400,
			headers = {},
			body = Fixtures.read("prometheus/3.15.0/query_error_parse.json"),
			timed_out = false,
		})
		expect(out).toBeNil()
		expect(err).toContain("parse error")
	end)

	it("refuses a body too large to parse inside the window budget", function()
		local p = plan("promql", { "up" })
		local out, err = finish(p, {
			status = 200,
			headers = {},
			body = string.rep(" ", Compact.MAX_BODY_BYTES + 1),
			timed_out = false,
		})
		expect(out).toBeNil()
		expect(err).toContain("too large")
	end)
end)

describe("compaction", function()
	local function frames(n: number): { any }
		local out = {}
		for i = 1, n do
			local times, values = {}, {}
			for k = 1, 50 do
				times[k] = NOW - (50 - k) * 15000
				values[k] = i * 1000 + k + 0.123456
			end
			table.insert(
				out,
				Frame.timeSeries({
					__name__ = "http_requests_total",
					pod = string.format("checkout-%04d-%s", i, string.rep("x", 40)),
				}, times, values)
			)
		end
		return out
	end

	it("keeps at most MAX_SERIES series and counts the rest", function()
		local series, omitted = Compact.series(frames(30))
		expect(#series).toBe(Compact.MAX_SERIES)
		expect(omitted).toBe(10)
		expect(series[1].last).toBe(Compact.round(30 * 1000 + 50.123456))
	end)

	it("cuts any answer to the byte budget and says how much was cut", function()
		local series, omitted = Compact.series(frames(200), { max_series = 200 })
		expect(omitted).toBe(0)
		local out = Compact.fit({ omitted = omitted, series = series }, "series", JSON_ENV)
		expect(#json.encode(out) <= Compact.MAX_BYTES).toBe(true)
		expect(out.omitted > 0).toBe(true)
		expect(#out.series + out.omitted).toBe(200)
	end)

	it("leaves an answer that fits unchanged", function()
		local out = Compact.fit({ series = { { name = "a" } } }, "series", JSON_ENV)
		expect(out.omitted).toBeNil()
		expect(#out.series).toBe(1)
	end)

	it("answers an empty list as a JSON array, so Carly reads no results instead of an object", function()
		local out = Compact.fit({ series = {} }, "series", JSON_ENV)
		expect(json.encode(out)).toBe('{"series":[]}')
	end)

	it("skips NaN and infinities: they are not JSON values Carly can take", function()
		local f = Frame.timeSeries({}, { 1, 2, 3 }, { 0 / 0, math.huge, 2 })
		local series = Compact.series({ f })
		expect(series[1].points).toBe(1)
		expect(series[1].max).toBe(2)
		json.encode(series)
	end)
end)

describe("alerts", function()
	it("lists firing alerts worst first with counts, hiding internal labels", function()
		local p = plan("alerts", {})
		expect(p.fetches[1].request.path).toBe("/api/v2/alerts")
		local out = assert(finish(p, ok("alertmanager/0.34.1/alerts.json")))
		expect(out.context).toBe("lab")
		expect(out.counts.firing > 0).toBe(true)
		expect(#out.alerts).toBe(out.counts.firing + out.counts.pending)
		for i, a in out.alerts do
			expect(a.labels.__alert_rule_uid__).toBeNil()
			expect(a.labels.alertname).toBeNil()
			expect(string.match(a.since, "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil).toBe(true)
			if i > 1 and out.alerts[i - 1].state == a.state then
				local rank = { critical = 5, error = 4, warning = 3, info = 2, none = 1 }
				expect(rank[out.alerts[i - 1].severity] >= rank[a.severity]).toBe(true)
			end
		end
		assertNoSecrets(out)
	end)
end)

describe("find_dashboard", function()
	it("answers native links and Grafana pages for each hit", function()
		local p = plan("find_dashboard", { "tern", "graf" })
		local out = assert(finish(p, ok("grafana/12.4.12/search.json")))
		expect(#out.dashboards > 0).toBe(true)
		local d = out.dashboards[1]
		expect(d.link).toBe("tern-grafana://dashboard?context=graf&uid=" .. d.uid)
		expect(string.sub(d.url, 1, #"http://g:3000/sub/d/")).toBe("http://g:3000/sub/d/")
		assertNoSecrets(plan("find_dashboard", { "tern" }).finish({ q = ok("grafana/12.4.12/search.json") }, env))
	end)

	-- Grafana sends `"tags": []` for most dashboards; Carly's signature says
	-- `tags: {string}`, so an empty list must not encode as an object.
	it("answers an untagged dashboard's tags as an empty JSON array", function()
		local body = string.gsub(Fixtures.read("grafana/12.4.12/search.json"), '"tags":%[[^%]]*%]', '"tags":[]')
		local out = assert(finish(plan("find_dashboard", { "tern", "graf" }), {
			status = 200,
			headers = {},
			body = body,
			timed_out = false,
		}))
		expect(#out.dashboards > 0).toBe(true)
		local text = json.encode(out)
		expect((string.find(text, '"tags":{}', 1, true))).toBeNil()
		expect((string.find(text, '"tags":[]', 1, true)) ~= nil).toBe(true)
	end)
end)

describe("logs", function()
	it("answers the newest lines, clipped, with their streams indexed", function()
		local p = plan("logs", { '{job="loggen"}' })
		expect(p.fetches[1].request.path).toBe("/loki/api/v1/query_range")
		local out = assert(finish(p, ok("loki/3.7.8/query_range_streams.json")))
		expect(out.kind).toBe("streams")
		expect(#out.lines > 0).toBe(true)
		expect(#out.streams > 0).toBe(true)
		for _, l in out.lines do
			expect(#l.line <= Exports.LOG_LINE_CHARS).toBe(true)
			expect(l.s >= 0 and l.s <= #out.streams).toBe(true)
		end
		expect(#json.encode(out) <= Compact.MAX_BYTES).toBe(true)
		assertNoSecrets(out)
	end)

	it("summarizes a metric query like promql", function()
		local out = assert(
			finish(
				plan("logs", { 'sum by (level) (count_over_time({job="loggen"}[1m]))', "15m" }),
				ok("loki/3.7.8/query_range_matrix.json")
			)
		)
		expect(out.kind).toBe("matrix")
		expect(#out.series > 0).toBe(true)
		expect(out.lines).toBeNil()
	end)
end)

return nil
