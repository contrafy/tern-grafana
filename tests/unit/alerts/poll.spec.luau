--!strict
-- The background poll decides what the status segment shows for every
-- watched context: polling off must remove the segment rather than freeze
-- it, an unroutable context must show as unknown, and a failed context keeps
-- its last counts while the others update.
local Fixtures = require("../../lib/fixtures")
local Poll = require("../../../plugin/lib/alerts/poll")
local Summary = require("../../../plugin/lib/alerts/summary")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577860000
local env: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null }

local function config(alerts: string): any
	local cfg, problems = Validate.parseFile([[{"default_context": "am", "contexts": {
		"am": {"alertmanager": {"url": "http://am:9093"}},
		"graf": {"grafana": {"url": "http://g"}},
		"logs": {"loki": {"url": "http://l"}}}, "alerts": ]] .. alerts .. "}", json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

local function ok(path: string): any
	return { status = 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

describe("poll", function()
	it("polls nothing when turned off or without config", function()
		local jobs, poll_s = Poll.jobs(config('{"poll_s": 0}'))
		expect(#jobs).toBe(0)
		expect(poll_s).toBe(0)
		expect(#(Poll.jobs(nil))).toBe(0)
	end)

	it("summarizes every watched context; a failed one keeps its last counts", function()
		local jobs, poll_s = Poll.jobs(config('{"contexts": ["am", "graf", "logs"], "poll_s": 30}'))
		expect(poll_s).toBe(30)
		expect(#jobs).toBe(3)
		local prevGraf = Summary.empty(1)
		prevGraf.firing = 7
		local prev = Summary.payload({ graf = prevGraf }, 1, 30)
		jobs[1].responses.am = ok("alertmanager/0.34.1/alerts.json")
		expect(Poll.complete(jobs[2])).toBe(false)
		jobs[2].responses.am = { status = 502, headers = {}, body = "bad gateway", timed_out = false }
		jobs[2].responses.rules = ok("grafana/12.4.12/alerting_prom_alerts.json")
		expect(Poll.complete(jobs[2])).toBe(true)
		expect(Poll.complete(jobs[3])).toBe(true)
		local payload = Poll.payload(env, jobs, json.decode(json.encode(prev)), poll_s)
		expect(payload.contexts.am.firing).toBe(4)
		expect(payload.contexts.am.error).toBeNil()
		expect(payload.contexts.graf.firing).toBe(7)
		expect(payload.contexts.graf.error).toBe("http")
		expect(payload.contexts.logs.error).toBe("config")
		expect(payload.poll_s).toBe(30)
		expect(payload.updated_ms).toBe(NOW)
	end)
end)

return nil
