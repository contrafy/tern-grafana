--!strict
-- The watch poller must query each watch on its own interval (not all on
-- the fastest one), route watches without a context to the host's default,
-- tolerate one bad watch without losing the others, and resume after a host
-- restart without restarting `for` timers or re-announcing what fires.
local Hosts = require("../../../plugin/lib/hosts/hosts")
local Poll = require("../../../plugin/lib/watches/poll")
local Settings = require("../../../plugin/lib/watches/settings")
local Validate = require("../../../plugin/lib/config/validate")
local Fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577898000
local env: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null }

local function config(watches: string, extra: string?): any
	local cfg, problems = Validate.parseFile([[{"default_context": "lab", "contexts": {
			"lab": {"prometheus": {"url": "http://lab"}},
			"graf": {"grafana": {"url": "http://g", "datasources": {"prometheus": "prom3"}}},
			"logs": {"loki": {"url": "http://l"}}}, "watches": ]] .. watches .. (extra or "") .. "}", json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

describe("settings", function()
	it("fills defaults: for 0s, severity warning, interval 60s", function()
		local list, problems = Settings.read(config('[{"name": "a", "expr": "up", "op": "<", "threshold": 1}]'))
		expect(#problems).toBe(0)
		expect(list[1].for_ms).toBe(0)
		expect(list[1].severity).toBe("warning")
		expect(list[1].interval_ms).toBe(60000)
		expect(list[1].context).toBeNil()
	end)

	it("skips a bad watch with a problem naming its path and keeps the others", function()
		local list, problems = Settings.read(config([=[[
			{"name": "a", "expr": "up", "op": "=>", "threshold": 1},
			{"name": "b", "expr": "up", "op": "<", "threshold": "1", "interval": "5s", "context": "nope"},
			{"name": "c", "expr": "up", "op": "<", "threshold": 1, "for": "5 minutes"},
			{"name": "d", "expr": "up", "op": ">=", "threshold": 0.5, "severity": "Critical", "interval": "30s"},
			{"name": "d", "expr": "up", "op": ">", "threshold": 1}]]=]))
		expect(#list).toBe(1)
		expect(list[1].name).toBe("d")
		expect(list[1].severity).toBe("critical")
		expect(list[1].interval_ms).toBe(30000)
		local paths: { string } = {}
		for _, p in problems do
			table.insert(paths, p.path)
		end
		expect(paths).toEqual({
			"watches[1].op",
			"watches[2].context",
			"watches[2].threshold",
			"watches[2].interval",
			"watches[3].for",
			"watches[5].name",
		})
	end)

	it("rejects an object where a list belongs", function()
		local list, problems = Settings.read(config('{"name": "a"}'))
		expect(#list).toBe(0)
		expect(problems[1].path).toBe("watches")
	end)
end)

describe("scheduling", function()
	local cfg = config([=[[
		{"name": "fast", "expr": "up", "op": "<", "threshold": 1, "interval": "15s"},
		{"name": "slow", "expr": "up", "op": "<", "threshold": 1, "interval": "2m"}]]=])
	local watches = Settings.read(cfg)

	local function evaluated(at: number): any
		local states: any = {}
		for _, w in watches do
			states[w.name] = { status = "ok", since_ms = at, eval_ms = at, def = w.def, series = 1, matching = 0 }
		end
		return states
	end

	it("runs every watch at first, then each on its own interval", function()
		expect(#Poll.due(watches, {}, NOW)).toBe(2)
		local states = evaluated(NOW)
		expect(#Poll.due(watches, states, NOW + 10000)).toBe(0)
		local due = Poll.due(watches, states, NOW + 15000)
		expect(#due).toBe(1)
		expect(due[1].name).toBe("fast")
		expect(#Poll.due(watches, states, NOW + 120000)).toBe(2)
	end)

	it("sleeps until the next watch falls due, never less than a second", function()
		local states = evaluated(NOW)
		expect(Poll.nextDelay(watches, states, NOW + 5000)).toBe(10000)
		expect(Poll.nextDelay(watches, states, NOW + 60000)).toBe(Poll.MIN_DELAY_MS)
		expect(Poll.nextDelay({}, {}, NOW)).toBe(Poll.IDLE_MS)
	end)

	it("a changed definition is due at once", function()
		local states = evaluated(NOW)
		states.fast.def = "old"
		local due = Poll.due(watches, states, NOW + 1000)
		expect(#due).toBe(1)
		expect(due[1].name).toBe("fast")
	end)
end)

describe("jobs", function()
	local cfg = config(
		[=[[
		{"name": "plain", "expr": "up", "op": "<", "threshold": 1},
		{"name": "graf", "context": "graf", "expr": "up", "op": "<", "threshold": 1},
		{"name": "logs", "context": "logs", "expr": "up", "op": "<", "threshold": 1}]]=],
		', "hosts": {"build-*": "graf"}'
	)
	local watches = Settings.read(cfg)

	it("routes a watch without a context to the host default, else default_context", function()
		expect((Poll.job(cfg, watches[1], NOW).route :: any).context).toBe("lab")
		local onHost = Hosts.apply(cfg, "build-7") :: any
		local job = Poll.job(onHost, watches[1], NOW)
		expect((job.route :: any).context).toBe("graf")
		expect((job.request :: any).path).toBe("/api/ds/query")
	end)

	it("an unroutable watch becomes a config error without a request", function()
		local job = Poll.job(cfg, watches[3], NOW)
		expect(job.request).toBeNil()
		local state = Poll.finish(env, nil, job, nil, NOW)
		expect(state.error).toBe("config")
		expect(state.status).toBe("ok")
	end)

	it("evaluates the response into state", function()
		local w = Settings.read(config('[{"name": "down", "expr": "up", "op": "==", "threshold": 0}]'))[1]
		local job = Poll.job(config("[]"), w, NOW)
		local body = Fixtures.read("prometheus/3.15.0/query_vector.json")
		local state = Poll.finish(env, nil, job, { status = 200, headers = {}, body = body, timed_out = false }, NOW)
		expect(state.status).toBe("firing")
		expect(state.matching).toBe(1)
	end)
end)

describe("summary", function()
	local cfg = config('[{"name": "down", "expr": "up", "op": "<", "threshold": 1, "for": "5m"}]')
	local watches = Settings.read(cfg)
	local w = watches[1]
	local pending = {
		down = {
			status = "pending",
			since_ms = NOW,
			active_ms = NOW,
			eval_ms = NOW,
			def = w.def,
			series = 1,
			matching = 1,
			value = 0,
			no_data = false,
		},
	}

	it("names the context a watch was evaluated in and survives a kv round trip", function()
		local payload = Poll.payload(watches, pending :: any, cfg, NOW)
		expect(payload.watches[1].context).toBe("lab")
		local back = Poll.read(json.decode(json.encode(payload)))
		expect(back).toEqual(payload)
	end)

	it("restores recent state of unchanged watches after a restart", function()
		local raw = json.decode(json.encode(Poll.payload(watches, pending :: any, cfg, NOW)))
		local restored = Poll.restore(raw, watches, NOW + 60000)
		expect(restored.down.status).toBe("pending")
		expect(restored.down.active_ms).toBe(NOW)
	end)

	it("does not restore after a long gap or for a changed watch", function()
		local raw = json.decode(json.encode(Poll.payload(watches, pending :: any, cfg, NOW)))
		expect(Poll.restore(raw, watches, NOW + 60 * 60000)).toEqual({})
		local changed = Settings.read(config('[{"name": "down", "expr": "up", "op": "<", "threshold": 2}]'))
		expect(Poll.restore(raw, changed, NOW + 60000)).toEqual({})
		expect(Poll.restore({ v = 99 }, watches, NOW)).toEqual({})
	end)
end)

return nil
