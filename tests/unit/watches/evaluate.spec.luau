--!strict
-- A watch is a personal alert: it must fire exactly when the threshold has
-- held for `for`, resolve on the first evaluation without it, never fire on
-- NaN or on no data (and say there was no data), and ride out a failed query
-- without resolving or restarting its `for` timer.
local Evaluate = require("../../../plugin/lib/watches/evaluate")
local Fixtures = require("../../lib/fixtures")
local Metrics = require("../../../plugin/lib/source/metrics")
local Route = require("../../../plugin/lib/config/route")
local Settings = require("../../../plugin/lib/watches/settings")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577898000
local env: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null }

local CONFIG = (
	Validate.parseFile(
		[[{"contexts": {"lab": {"prometheus": {"url": "http://p"},
		"grafana": {"url": "http://g", "datasources": {"prometheus": "prom3"}}},
		"graf": {"grafana": {"url": "http://g", "datasources": {"prometheus": "prom3"}}}},
		"default_context": "lab"}]],
		json.decode
	)
) :: any

local function watch(fields: string): any
	local cfg = table.clone(CONFIG)
	cfg.watches = json.decode("[{" .. fields .. "}]")
	local list, problems = Settings.read(cfg)
	assert(#problems == 0, problems[1] and Validate.format(problems[1]))
	return list[1]
end

local function result(path: string, context: string?): any
	local route = Route.route(CONFIG, context or "lab", "metrics") :: any
	return Metrics.parse(
		route,
		{ status = 200, headers = {}, body = Fixtures.read(path), timed_out = false },
		env,
		"instant"
	)
end

local UP = "prometheus/3.15.0/query_vector.json"

describe("compare", function()
	it("applies every operator", function()
		expect(Evaluate.compare(">", 2, 1)).toBe(true)
		expect(Evaluate.compare(">=", 1, 1)).toBe(true)
		expect(Evaluate.compare("<", 1, 1)).toBe(false)
		expect(Evaluate.compare("<=", 1, 1)).toBe(true)
		expect(Evaluate.compare("==", 0, 0)).toBe(true)
		expect(Evaluate.compare("!=", 0, 0)).toBe(false)
	end)

	it("never lets NaN cross a threshold, even with !=", function()
		for _, op in { ">", ">=", "<", "<=", "==", "!=" } do
			expect(Evaluate.compare(op :: any, 0 / 0, 1)).toBe(false)
		end
	end)
end)

describe("observe", function()
	it("counts the series that cross the threshold (Prometheus direct)", function()
		local obs = Evaluate.observe(watch('"name": "d", "expr": "up", "op": "==", "threshold": 0'), result(UP))
		expect(obs).toEqual({ series = 6, matching = 1, nan = 0, value = 0 })
	end)

	it("reads Grafana /api/ds/query frames the same way", function()
		local obs = Evaluate.observe(
			watch('"name": "d", "expr": "up", "op": "<", "threshold": 1'),
			result("grafana/12.4.12/ds_query_prom_instant.json", "graf")
		)
		expect(obs).toEqual({ series = 6, matching = 1, nan = 0, value = 0 })
	end)

	it("reports the most extreme crossing value", function()
		local obs = Evaluate.observe(
			watch('"name": "s", "expr": "scalar(sum(up))", "op": ">", "threshold": 2'),
			result("prometheus/3.15.0/query_scalar.json")
		)
		expect(obs).toEqual({ series = 1, matching = 1, nan = 0, value = 5 })
	end)

	it("counts NaN samples apart and never as crossing; infinities cross but carry no value", function()
		local obs = Evaluate.observe(
			watch('"name": "n", "expr": "x", "op": "!=", "threshold": 5'),
			result("prometheus/3.15.0/query_range_nan_inf.json")
		)
		expect(obs).toEqual({ series = 3, matching = 2, nan = 1 })
	end)

	it("an empty result is no data, not a crossing", function()
		local obs = Evaluate.observe(
			watch('"name": "e", "expr": "x", "op": "<", "threshold": 1'),
			result("prometheus/3.15.0/query_empty.json")
		)
		expect(obs).toEqual({ series = 0, matching = 0, nan = 0 })
	end)

	it("a server error becomes an error observation", function()
		local r = result("prometheus/3.15.0/query_error_parse.json")
		local obs = Evaluate.observe(watch('"name": "e", "expr": "x", "op": "<", "threshold": 1'), r)
		expect(obs.error).toBe((r :: any).error.kind)
		expect(obs.matching).toBe(0)
	end)
end)

local HIT = { series = 1, matching = 1, nan = 0, value = 0 }
local MISS = { series = 1, matching = 0, nan = 0, value = 1 }
local EMPTY = { series = 0, matching = 0, nan = 0 }
local FAIL = { series = 0, matching = 0, nan = 0, error = "network" }

-- Feeds observations one minute apart and returns the statuses.
local function run(w: any, observations: { any }): ({ string }, any)
	local state: any = nil
	local out: { string } = {}
	for i, obs in observations do
		state = Evaluate.step(state, w, obs, NOW + (i - 1) * 60000)
		table.insert(out, state.status)
	end
	return out, state
end

describe("transitions", function()
	it("fires on the first crossing when for is 0s", function()
		local w = watch('"name": "d", "expr": "up", "op": "<", "threshold": 1')
		expect((run(w, { MISS, HIT, HIT, MISS }))).toEqual({ "ok", "firing", "firing", "ok" })
	end)

	it("stays pending until the condition held for `for`, measured from its first crossing", function()
		local w = watch('"name": "d", "expr": "up", "op": "<", "threshold": 1, "for": "2m"')
		local statuses, state = run(w, { HIT, HIT, HIT, HIT })
		expect(statuses).toEqual({ "pending", "pending", "firing", "firing" })
		expect(state.active_ms).toBe(NOW)
		expect(state.since_ms).toBe(NOW + 120000)
	end)

	it("restarts the for timer after one evaluation without the condition", function()
		local w = watch('"name": "d", "expr": "up", "op": "<", "threshold": 1, "for": "2m"')
		expect((run(w, { HIT, HIT, MISS, HIT, HIT, HIT }))).toEqual({
			"pending",
			"pending",
			"ok",
			"pending",
			"pending",
			"firing",
		})
	end)

	it("no data resolves a firing watch and is reported", function()
		local w = watch('"name": "d", "expr": "up", "op": "<", "threshold": 1')
		local statuses, state = run(w, { HIT, EMPTY })
		expect(statuses).toEqual({ "firing", "ok" })
		expect(state.no_data).toBe(true)
	end)

	it("a failed query keeps firing and pending state and the for timer, flagged as an error", function()
		local w = watch('"name": "d", "expr": "up", "op": "<", "threshold": 1, "for": "2m"')
		local statuses, state = run(w, { HIT, FAIL, HIT })
		expect(statuses).toEqual({ "pending", "pending", "firing" })
		expect(state.error).toBeNil()
		local _, failed = run(w, { HIT, HIT, HIT, FAIL })
		expect(failed.status).toBe("firing")
		expect(failed.error).toBe("network")
	end)

	it("drops state built for an older definition of the watch", function()
		local old = watch('"name": "d", "expr": "up", "op": "<", "threshold": 1')
		local _, firing = run(old, { HIT })
		local new = watch('"name": "d", "expr": "up", "op": "<", "threshold": 1, "for": "5m"')
		local state = Evaluate.step(firing, new, HIT, NOW + 60000)
		expect(state.status).toBe("pending")
	end)
end)

return nil
