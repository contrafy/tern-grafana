--!strict
-- The Logs block's ways out and its shared time range: a line that names a
-- trace gets a "trace" chip (and `T`) opening the trace block, `M` opens the
-- Query block on the series selector the line's stream labels share with
-- `logs.correlate_labels`, and with sync on (`S`) range changes publish to
-- kv while other blocks' ranges are adopted on the poll tick, never the
-- block's own echo. Responses are recorded Loki 3.7.8 fixtures.
local Q = require("../query/support")
local Scheme = require("../../../plugin/lib/links/scheme")
local Shared = require("../../../plugin/lib/time/shared")
local State = require("../../../plugin/lib/logs/state")
local Validate = require("../../../plugin/lib/config/validate")
local View = require("../../../plugin/lib/logs/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function config(logs: any?): any
	local raw = json.decode([[{
		"version": 1,
		"default_context": "lab",
		"contexts": {"lab": {"loki": {"url": "http://localhost:3100"}}}
	}]])
	raw.logs = logs
	local cfg = Validate.validate(raw)
	assert(cfg, "test config is valid")
	return cfg
end

local LOGGEN = Scheme.encode({ action = "logs", params = { expr = '{job="loggen"}', from = Q.WINDOW }, vars = {} })

local function open(cfg: any?, saved: any?): (any, any, { any })
	local env = Q.env(cfg or config())
	local s, effects = State.init({ LOGGEN }, saved, env)
	return s, env, effects
end

local function queries(effects: { any }): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "http" and string.sub(e.tag, 1, #State.QUERY_TAG) == State.QUERY_TAG then
			table.insert(out, e)
		end
	end
	return out
end

local function answer(s: any, env: any, effects: { any }, path: string)
	local q = queries(effects)[1]
	State.update(s, { kind = "http_done", tag = q.tag, response = Q.response(path) }, env)
end

local function loaded(path: string, cfg: any?): (any, any)
	local s, env, effects = open(cfg)
	answer(s, env, effects, path)
	return s, env
end

local function press(s: any, env: any, text: string): { any }
	local _, effects = State.key(s, Q.key(text, text), env)
	return effects
end

local function opened(effects: { any }): Scheme.Link?
	local e = Q.find(effects, "open")
	return if e then Scheme.decode(e.target) else nil
end

local function selectWhere(s: any, pred: (any) -> boolean): any
	for i, l in s.lines do
		if pred(l) then
			s.sel = i
			return l
		end
	end
	error("no such line")
end

local FORWARD = "loki/3.7.8/query_range_streams_forward.json"

describe("trace chips", function()
	it("marks the lines that name a trace and opens it from the chip or T", function()
		local s, env = loaded(FORWARD)
		local withId, without = 0, 0
		for _, l in s.lines do
			if State.traceIdOf(s, l) then
				withId += 1
			else
				without += 1
			end
		end
		-- loggen writes trace_id on its payment errors, not on its warnings.
		expect(withId > 0).toBe(true)
		expect(without > 0).toBe(true)

		local line = selectWhere(s, function(l)
			return string.find(l.line, "trace_id=", 1, true) ~= nil
		end)
		local id = string.match(line.line, "trace_id=(%x+)")
		local view: any = View.view(s, env)
		local chips = Q.nodes(view.main, function(n)
			return n.p and n.p.actions and n.p.actions.click == "trace=" .. line.id
		end)
		expect(#chips).toBe(1)

		local link = opened(press(s, env, "T"))
		expect(link and link.action).toBe("trace")
		expect(link and link.params.id).toBe(id)
		expect(link and link.params.context).toBe("lab")

		local _, effects =
			State.update(s, { kind = "event", ev = { ev = "action", act = "trace", value = line.id } }, env)
		expect((opened(effects) :: any).params.id).toBe(id)
	end)

	it("says so when the selected line names no trace", function()
		local s, env = loaded(FORWARD)
		selectWhere(s, function(l)
			return State.traceIdOf(s, l) == nil
		end)
		local effects = press(s, env, "T")
		expect(Q.find(effects, "open")).toBeNil()
		expect(Q.find(effects, "toast").text).toContain("no trace id")
	end)

	it("follows a configured pattern instead of the default", function()
		local s = loaded(FORWARD, config({ trace_id_pattern = [[order_id=(\d+)]] }))
		for _, l in s.lines do
			-- Order ids are too short to be trace ids; nothing is marked.
			expect(State.traceIdOf(s, l)).toBeNil()
		end
	end)
end)

describe("metrics jump", function()
	it("opens the Query block on the selected line's correlation labels over the same range", function()
		local s, env = loaded(FORWARD)
		selectWhere(s, function(l)
			return l.labels.level == "warn"
		end)
		local link = opened(press(s, env, "M")) :: any
		expect(link.action).toBe("query")
		expect(link.params.expr).toBe('{job="loggen",service_name="payments",app="payments"}')
		expect(link.params.from).toBe(Q.WINDOW)
		expect(link.params.to).toBe("now")
		expect(link.params.context).toBe("lab")
	end)

	it("uses the query's selector with no line selected, and the configured labels", function()
		local s, env = loaded(FORWARD, config({ correlate_labels = { "env", "job" } }))
		s.sel = nil
		local link = opened(press(s, env, "M")) :: any
		expect(link.params.expr).toBe('{job="loggen"}')
	end)

	it("warns when nothing correlates", function()
		local s, env = loaded(FORWARD, config({ correlate_labels = { "cluster" } }))
		local effects = press(s, env, "M")
		expect(Q.find(effects, "open")).toBeNil()
		expect(Q.find(effects, "toast").text).toContain("cluster")
	end)
end)

describe("shared time", function()
	it("is off by default: range keys stay local", function()
		local s, env = loaded(FORWARD)
		local effects = press(s, env, "3")
		expect(Q.find(effects, "kv_set")).toBeNil()
		expect(#queries(effects)).toBe(1)
	end)

	it("publishes on S and on every range change, with a synced badge", function()
		local s, env = loaded(FORWARD)
		local effects = press(s, env, "S")
		Q.applyKv(env, effects)
		expect(Q.find(effects, "timer").tag).toBe(Shared.TAG .. s.sync.gen)
		local rec = env.kv[Shared.KEY]
		expect(rec.from).toBe(Q.WINDOW)
		expect(rec.origin).toBe(s.sync.origin)
		local view: any = View.view(s, env)
		expect(Q.byKey(view.main, "sync") ~= nil).toBe(true)

		effects = press(s, env, "3")
		Q.applyKv(env, effects)
		expect(env.kv[Shared.KEY].from).toBe("now-1h")
		expect(env.kv[Shared.KEY].seq).toBe(rec.seq + 1)
		expect(State.save(s).sync).toBe(true)
	end)

	it("adopts another block's range on the tick and ignores its own echo", function()
		local s, env = loaded(FORWARD)
		Q.applyKv(env, press(s, env, "S"))
		local tick = Shared.TAG .. s.sync.gen
		local _, effects = State.update(s, { kind = "tick", tag = tick }, env)
		expect(#queries(effects)).toBe(0)
		expect(Q.find(effects, "timer").tag).toBe(tick)

		env.kv[Shared.KEY] = Shared.publish({ from = "now-6h", to = "now" }, nil, "query-1-2", env.kv[Shared.KEY])
		_, effects = State.update(s, { kind = "tick", tag = tick }, env)
		expect(s.from).toBe("now-6h")
		expect(#queries(effects)).toBe(1)
		-- The same record again changes nothing.
		_, effects = State.update(s, { kind = "tick", tag = tick }, env)
		expect(#queries(effects)).toBe(0)
	end)

	it("joins the range others already share instead of overwriting it", function()
		local s, env = loaded(FORWARD)
		env.kv[Shared.KEY] = Shared.publish({ from = "now-24h", to = "now" }, nil, "dashboard-1-2", nil)
		local effects = press(s, env, "S")
		expect(Q.find(effects, "kv_set")).toBeNil()
		expect(s.from).toBe("now-24h")
		expect(#queries(effects)).toBe(1)
	end)

	it("comes back synced and polling after a restart", function()
		local s, env = loaded(FORWARD)
		press(s, env, "S")
		local again, _, effects = open(nil, State.save(s))
		expect(again.sync.on).toBe(true)
		expect(Q.find(effects, "timer").tag).toBe(Shared.TAG .. again.sync.gen)
	end)
end)

return nil
