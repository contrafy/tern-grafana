--!strict
-- The impact watch tells the user whether a deploy hurt: configured signals
-- must be used as written (placeholders filled from the command, unfillable
-- ones skipped with a reason, never queried half-filled), guesses must pick
-- real request metrics from the server and say they are guesses, and the
-- before/after numbers and tones must compare the right windows.
local Delta = require("../../../plugin/lib/impact/delta")
local Fixtures = require("../../lib/fixtures")
local Frame = require("../../../plugin/lib/frame/types")
local Render = require("../../../plugin/lib/impact/render")
local Scheme = require("../../../plugin/lib/links/scheme")
local Settings = require("../../../plugin/lib/impact/settings")
local Signals = require("../../../plugin/lib/impact/signals")
local State = require("../../../plugin/lib/impact/state")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local VERSIONS = { "3.15.0", "2.53.5" }

local function list(...: any): { any }
	return { ... }
end

local function config(extra: string): any
	local cfg, problems = Validate.parseFile([[{"default_context": "lab", "contexts": {
		"lab": {"prometheus": {"url": "http://localhost:9090"}},
		"graf": {"grafana": {"url": "http://g", "datasources": {"prometheus": "prom3"}}}}]] .. extra .. "}", json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

-- The range fixtures cover 1791581623..1791583423 (s): the command ran
-- 1791582500..1791582520 with 15 m windows on both sides.
local START = 1791582500000
local FINISH = 1791582520000
local NOW = 1791583500000

local function env(cfg: any, now: number?): any
	return { now_ms = now or NOW, decode = json.decode, encode = json.encode, null = json.null, config = cfg }
end

local function link(params: { [string]: string }?): string
	local p: { [string]: string } = {
		context = "lab",
		start = tostring(START),
		finish = tostring(FINISH),
		kind = "helm-upgrade",
		svc = "web",
		ns = "shop",
	}
	for k, v in (params or {}) :: { [string]: string } do
		p[k] = v
	end
	return Scheme.encode({ action = "impact", params = p, vars = {} })
end

local function ok(path: string): any
	return { status = 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

local function kinds(effects: { any }, kind: string): { any }
	local out = {}
	for _, e in effects do
		if e.kind == kind then
			table.insert(out, e)
		end
	end
	return out
end

local function formValue(body: string, name: string): string?
	for part in string.gmatch(body, "[^&]+") do
		local k, v = string.match(part, "^([^=]*)=(.*)$")
		if k == name and v then
			return (
				string.gsub(string.gsub(v, "+", " "), "%%(%x%x)", function(h)
					return string.char(tonumber(h, 16) :: number)
				end)
			)
		end
	end
	return nil
end

describe("impact settings", function()
	it("defaults to off with a 15 minute window", function()
		local s = Settings.read(config(""))
		expect(list(s.enabled, s.window_ms, s.on)).toEqual(list(false, 15 * 60 * 1000, "success"))
	end)

	it("reads signals per context with a * fallback, and a bare list for every context", function()
		local s, problems = Settings.read(config([[, "impact": {"enabled": true, "window": "10m", "signals": {
			"lab": [{"name": "errors", "expr": "sum(rate(x{ns=\"{{namespace}}\"}[1m]))", "unit": "reqps", "bad": "up"}],
			"*": [{"name": "up", "expr": "up"}]}}]]))
		expect(#problems).toBe(0)
		expect(s.window_ms).toBe(600000)
		expect((Settings.signalsFor(s, "lab") :: any)[1].name).toBe("errors")
		expect((Settings.signalsFor(s, "graf") :: any)[1].name).toBe("up")
		local bare = Settings.read(config([[, "impact": {"signals": [{"name": "a", "expr": "up"}]}]]))
		expect((Settings.signalsFor(bare, "graf") :: any)[1].bad).toBe("up")
	end)

	it("reports bad signals, unknown placeholders and contexts", function()
		local _, problems = Settings.read(config([[, "impact": {"window": "5", "signals": {
			"nope": [{"name": "a", "expr": "up"}],
			"lab": [{"name": "a", "expr": "x{{pod}}"}, {"expr": "up", "bad": "sideways"}]}}]]))
		local paths = {}
		for _, p in problems do
			table.insert(paths, p.path)
		end
		table.sort(paths)
		expect(paths).toEqual({
			"impact.signals.lab[1].expr",
			"impact.signals.lab[2].bad",
			"impact.signals.lab[2].name",
			"impact.signals.nope",
			"impact.window",
		})
	end)
end)

describe("impact signal resolution", function()
	it("fills placeholders from the command, escaping quotes", function()
		local signals, skipped = Signals.configured({
			{
				name = "a",
				expr = 'up{namespace="{{namespace}}",app="{{ service }}",dir="{{cwd_basename}}"}',
				bad = "up",
			},
		}, { namespace = "shop", service = 'we"b', cwd_basename = "repo" })
		expect(#skipped).toBe(0)
		expect(signals[1].expr).toBe('up{namespace="shop",app="we\\"b",dir="repo"}')
		expect(signals[1].guessed).toBe(false)
	end)

	it("skips a configured signal whose placeholder cannot be filled", function()
		local signals, skipped = Signals.configured({
			{ name = "per ns", expr = 'up{namespace="{{namespace}}"}', bad = "up" },
			{ name = "all", expr = "up", bad = "up" },
		}, { service = "web" })
		expect(#signals).toBe(1)
		expect(signals[1].name).toBe("all")
		expect(skipped[1].name).toBe("per ns")
		expect(string.find(skipped[1].reason, "namespace", 1, true) ~= nil).toBe(true)
	end)

	for _, v in VERSIONS do
		it("guesses RED queries from Prometheus " .. v .. "'s metric names and labels", function()
			local names = json.decode(Fixtures.read("prometheus/" .. v .. "/label_values_name.json")).data
			local counters = Signals.counters(names)
			expect(counters[1]).toBe("prometheus_http_requests_total")
			local labels = json.decode(Fixtures.read("prometheus/" .. v .. "/labels_match_http_requests.json")).data
			local probe: Signals.Probe = {
				counter = counters[1],
				status_label = Signals.statusLabel(labels),
				labels = labels,
				histogram = Signals.histogram(names, counters[1]),
			}
			expect(probe.status_label).toBe("code")
			expect(probe.histogram).toBe("prometheus_http_request_duration_seconds_bucket")
			local guessed = Signals.guess(probe, { namespace = "shop", service = "web" }, "1m")
			local exprs = {}
			for _, g in guessed do
				expect(g.guessed).toBe(true)
				table.insert(exprs, g.expr)
			end
			-- The counter has no namespace/service labels, so nothing scopes it.
			expect(exprs).toEqual({
				"sum(rate(prometheus_http_requests_total[1m]))",
				'sum(rate(prometheus_http_requests_total{code=~"5.."}[1m])) / sum(rate(prometheus_http_requests_total[1m]))',
				"histogram_quantile(0.95, sum by (le) (rate(prometheus_http_request_duration_seconds_bucket[1m])))",
			})
		end)
	end

	it("scopes guesses by namespace and service only when the counter has those labels", function()
		expect(Signals.selector({ "namespace", "service", "code" }, { namespace = "shop", service = "web" })).toBe(
			'namespace="shop",service="web"'
		)
		expect(Signals.selector({ "namespace", "app" }, { service = "web" })).toBe('app="web"')
		expect(Signals.selector({ "job" }, { namespace = "shop", service = "web" })).toBe("")
	end)

	it("prefers http_requests_total and finds no counter where there is none", function()
		expect(Signals.counters({ "x_requests_total", "http_requests_total", "api_http_requests_total" })).toEqual({
			"http_requests_total",
			"api_http_requests_total",
			"x_requests_total",
		})
		expect(#Signals.counters({ "up", "node_load1" })).toBe(0)
		expect(#Signals.guess({ labels = {} }, {}, "1m")).toBe(0)
	end)
end)

describe("impact delta math", function()
	local w: Delta.Window = { start_ms = 1000, finish_ms = 2000, window_ms = 1000 }
	local function series(points: { { number } }): Delta.Series
		local times, values = {}, {}
		for i, p in points do
			times[i] = p[1]
			values[i] = p[2]
		end
		return { name = "", labels = {}, times = times, values = values }
	end

	it("averages each window, excluding the command's own run", function()
		local s = series({
			{ 0, 100 },
			{ 500, 100 },
			{ 999, 100 },
			{ 1500, 9999 },
			{ 2000, 150 },
			{ 3000, 150 },
			{ 3001, 9 },
		})
		local before, after = Delta.sides(s, w)
		expect(list(before.mean, before.n, after.mean, after.n)).toEqual({ 100, 3, 150, 2 })
	end)

	it("computes delta and percent and tones by the bad direction", function()
		local b, a = { mean = 100, n = 1 }, { mean = 150, n = 1 }
		local up = Delta.compare(b, a, "up")
		expect(list(up.delta, up.pct, up.direction, up.tone)).toEqual(list(50, 50, "up", "error"))
		expect(Delta.compare(b, { mean = 110, n = 1 }, "up").tone).toBe("warning")
		expect(Delta.compare(b, a, "down").tone).toBe("success")
		expect(Delta.compare(b, a, "none").tone).toBe("info")
		expect(Delta.compare(b, { mean = 103, n = 1 }, "up").direction).toBe("flat")
		expect(Delta.formatPct(up)).toBe("+50.0%")
		expect(Delta.formatPct(Delta.compare(b, { mean = 40, n = 1 }, "down"))).toBe("-60.0%")
	end)

	it("treats errors appearing from zero as the worst case and zero to zero as flat", function()
		local appear = Delta.compare({ mean = 0, n = 5 }, { mean = 0.02, n = 5 }, "up")
		expect(list(appear.pct, appear.direction, appear.tone)).toEqual(list(nil, "up", "error"))
		expect(Delta.formatPct(appear)).toBe("up from 0")
		expect(Delta.compare({ mean = 0, n = 5 }, { mean = 0, n = 5 }, "up").tone).toBe("success")
	end)

	it("has no comparison while a side has no samples", function()
		local c = Delta.compare({ mean = 1, n = 3 }, { mean = nil, n = 0 }, "up")
		expect(list(c.delta, c.tone)).toEqual(list(nil, "muted"))
	end)

	it("reads frames into series, skipping NaN", function()
		local f = Frame.timeSeries({ job = "a" }, { 1000, 2000, 3000 }, { 1, 0 / 0, 3 })
		local s = Delta.series({ f })[1]
		expect(s.name).toBe('{job="a"}')
		expect(list(s.values[1], s.values[2], s.values[3])).toEqual(list(1, nil, 3))
	end)

	it("buckets a window for sparks, leaving empty buckets empty", function()
		local s = series({ { 0, 1 }, { 100, 3 }, { 900, 10 } })
		local b = Delta.buckets(s, 0, 1000, 4)
		expect(list(b[1], b[2], b[3], b[4])).toEqual(list(2, nil, nil, 10))
	end)
end)

describe("impact block", function()
	it("queries configured signals over both windows and never probes", function()
		local cfg = config([[, "impact": {"enabled": true, "signals": [
			{"name": "rate", "expr": "sum(rate(prometheus_http_requests_total{namespace=\"{{namespace}}\"}[5m]))"}]}]])
		local s, effects = State.init({ link() }, nil, env(cfg))
		local http = kinds(effects, "http")
		expect(#http).toBe(1)
		expect(s.guessed).toBe(false)
		local body = http[1].request.body
		expect(http[1].request.path).toBe("/api/v1/query_range")
		expect(formValue(body, "query")).toBe('sum(rate(prometheus_http_requests_total{namespace="shop"}[5m]))')
		expect(formValue(body, "start")).toBe(tostring((START - 900000) // 1000))
		expect(formValue(body, "end")).toBe(tostring((FINISH + 900000) // 1000))
	end)

	for _, v in VERSIONS do
		it("guesses, queries and compares against Prometheus " .. v, function()
			local e = env(config([[, "impact": {"enabled": true}]]))
			local s, effects = State.init({ link() }, nil, e)
			expect(s.phase).toBe("probing")
			local names = kinds(effects, "http")[1]
			expect(names.request.path).toBe("/api/v1/label/__name__/values")
			local _, probes = State.update(
				s,
				{ kind = "http_done", tag = names.tag, response = ok("prometheus/" .. v .. "/label_values_name.json") },
				e
			)
			local labelReqs = kinds(probes, "http")
			expect(#labelReqs).toBe(Signals.MAX_PROBES)
			local queries: { any } = {}
			for i, req in labelReqs do
				local body = if i == 1
					then ok("prometheus/" .. v .. "/labels_match_http_requests.json")
					else {
						status = 200,
						headers = {},
						body = '{"status":"success","data":["__name__","job"]}',
						timed_out = false,
					}
				local _, out = State.update(s, { kind = "http_done", tag = req.tag, response = body }, e)
				for _, q in kinds(out, "http") do
					table.insert(queries, q)
				end
			end
			expect(#s.rows).toBe(3)
			expect(s.rows[1].signal.guessed).toBe(true)
			expect(#queries).toBe(3)
			local timers = {}
			for _, q in queries do
				local _, out = State.update(s, {
					kind = "http_done",
					tag = q.tag,
					response = ok("prometheus/" .. v .. "/query_range_http_rate.json"),
				}, e)
				for _, tm in kinds(out, "timer") do
					table.insert(timers, tm)
				end
			end
			expect(s.phase).toBe("ready")
			-- The after window is over: final, no more refreshes.
			expect(s.final).toBe(true)
			expect(#timers).toBe(0)
			local r = s.rows[1].series[1]
			expect(r.cmp.before.n > 0 and r.cmp.after.n > 0).toBe(true)
			expect(r.cmp.pct ~= nil).toBe(true)
			local view = json.encode((Render.view(s, e)))
			expect(string.find(view, "guessed", 1, true) ~= nil).toBe(true)
		end)
	end

	it("refreshes until the after window ends, dropping stale answers", function()
		local cfg = config([[, "impact": {"enabled": true, "signals": [{"name": "rate", "expr": "up"}]}]])
		local e = env(cfg, FINISH + 60000)
		local s, effects = State.init({ link() }, nil, e)
		local q = kinds(effects, "http")[1]
		local _, out = State.update(
			s,
			{ kind = "http_done", tag = q.tag, response = ok("prometheus/3.15.0/query_range_http_rate.json") },
			e
		)
		local timer = kinds(out, "timer")[1]
		expect(timer.ms).toBe(State.refreshMs(s))
		local _, again = State.update(s, { kind = "tick", tag = timer.tag }, e)
		local q2 = kinds(again, "http")[1]
		expect(q2.tag ~= q.tag).toBe(true)
		-- The first query's late duplicate is ignored.
		State.update(s, { kind = "http_done", tag = q.tag, response = ok("prometheus/3.15.0/query_empty.json") }, e)
		expect(s.phase).toBe("querying")
	end)

	it("moves the selection with reveal and opens the signal in the Query block", function()
		local cfg = config(
			[[, "impact": {"enabled": true, "signals": [{"name": "a", "expr": "up"}, {"name": "b", "expr": "vector(1)"}]}]]
		)
		local s = State.init({ link() }, nil, env(cfg))
		local _, moved = State.key(s, { name = "down", ctrl = false, alt = false, meta = false }, env(cfg))
		expect(kinds(moved, "reveal")[1].id).toBe("main.sigs.s2")
		local _, opened = State.key(s, { name = "enter", ctrl = false, alt = false, meta = false }, env(cfg))
		local l = Scheme.decode(kinds(opened, "open")[1].target) :: Scheme.Link
		expect(list(l.action, l.params.expr, l.params.context)).toEqual({ "query", "vector(1)", "lab" })
	end)

	it("explains a context without metrics instead of querying", function()
		local cfg = config([[, "impact": {"enabled": true}]])
		local s, effects = State.init({ link({ context = "graf" }) }, nil, env(cfg))
		expect(#kinds(effects, "http")).toBe(1)
		expect(s.route and (s.route :: any).via).toBe("datasource")
		local bad = State.init({}, nil, env(cfg))
		expect(bad.problem ~= nil).toBe(true)
	end)
end)

return nil
