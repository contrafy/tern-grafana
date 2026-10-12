--!strict
-- From a span to its logs (`L`): `trace.logs_query` filled with the span's
-- service and the trace id, over the trace widened by a minute, in the
-- block's context. The search tab's range takes part in the shared time
-- range (`S`): range keys publish, other blocks' ranges are adopted on the
-- poll tick. Responses are the recorded Tempo 2.10.8 trace and search.
local Correlate = require("../../../plugin/lib/logs/correlate")
local Fixtures = require("../../lib/fixtures")
local Scheme = require("../../../plugin/lib/links/scheme")
local Shared = require("../../../plugin/lib/time/shared")
local State: any = require("../../../plugin/lib/trace/state")
local Validate = require("../../../plugin/lib/config/validate")
local View = require("../../../plugin/lib/trace/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577900000
local TRACE = "82c9f1c2bda850d878e52762cc0816"

local function env(trace: string?): any
	local text = [[{"default_context": "lab", "contexts": {"lab": {"tempo": {"url": "http://t:3200"}}}]]
	if trace then
		text ..= ', "trace": ' .. trace
	end
	local cfg, problems = Validate.parseFile(text .. "}", json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	local kv: { [string]: any } = {}
	return {
		now_ms = NOW,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		config = cfg,
		kv = kv,
		kv_get = function(k: string): any
			return kv[k]
		end,
	}
end

local function response(path: string): any
	return { status = 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

local function key(text: string): any
	return { name = text, text = text, ctrl = false, alt = false, shift = false, meta = false }
end

local function find(effects: { any }, kind: string): any
	for _, e in effects do
		if e.kind == kind then
			return e
		end
	end
	return nil
end

local function searches(effects: { any }): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "http" and string.match(e.tag, "^search:") then
			table.insert(out, e)
		end
	end
	return out
end

local function link(params: { [string]: string }): { string }
	return { Scheme.encode({ action = "trace", params = params, vars = {} }) }
end

local function opened(e: any): any
	local s, effects = State.init(link({ context = "lab", id = TRACE }), nil, e)
	local req = find(effects, "http")
	State.update(s, { kind = "http_done", tag = req.tag, response = response("tempo/2.10.8/trace.json") }, e)
	return s
end

local function press(s: any, e: any, text: string): { any }
	local _, effects = State.key(s, key(text), e)
	return effects
end

describe("span logs", function()
	it("opens the logs of the selected span's service carrying the trace id, around the trace", function()
		local e = env()
		local s = opened(e)
		press(s, e, "j")
		local span = State.selected(s)
		local target = find(press(s, e, "L"), "open").target
		local l = Scheme.decode(target) :: any
		expect(l.action).toBe("logs")
		expect(l.params.context).toBe("lab")
		expect(l.params.expr).toBe(string.format('{service_name="%s"} |= "00%s"', span.raw.service, TRACE))
		local tr = s.trace
		local from, to = Correlate.window(tr.start_ms, tr.duration_ns / 1e6)
		expect(tonumber(l.params.from)).toBe(from)
		expect(tonumber(l.params.to)).toBe(to)
		expect(tonumber(l.params.from) < tr.start_ms).toBe(true)
	end)

	it("follows trace.logs_query", function()
		local e = env([[{"logs_query": "{app=\"${service}\"} |= \"span=${spanId}\""}]])
		local s = opened(e)
		local span = State.selected(s)
		local l = Scheme.decode(find(press(s, e, "L"), "open").target) :: any
		expect(l.params.expr).toBe(string.format('{app="%s"} |= "span=%s"', span.raw.service, span.raw.span_id))
	end)

	it("does nothing on L before a trace is loaded", function()
		local e = env()
		local s = State.init(link({ context = "lab", id = TRACE }), nil, e)
		expect(find(press(s, e, "L"), "open")).toBeNil()
	end)
end)

describe("shared time in search", function()
	local function searching(e: any): any
		local s, effects = State.init(link({ context = "lab" }), nil, e)
		local req = searches(effects)[1]
		State.update(s, { kind = "http_done", tag = req.tag, response = response("tempo/2.10.8/search.json") }, e)
		return s
	end

	it("publishes range keys only while synced", function()
		local e = env()
		local s = searching(e)
		expect(find(press(s, e, "3"), "kv_set")).toBeNil()
		local effects = press(s, e, "S")
		e.kv[Shared.KEY] = find(effects, "kv_set").value
		expect(find(effects, "timer").tag).toBe(Shared.TAG .. s.sync.gen)
		local view: any = View.view(s, e)
		local chips = 0
		for _, n in view.main.c[1].c do
			if n.p and n.p.key == "sync" then
				chips += 1
			end
		end
		expect(chips).toBe(1)
		effects = press(s, e, "5")
		expect(find(effects, "kv_set").value.from).toBe("now-6h")
		expect(#searches(effects)).toBe(1)
		expect(State.save(s).sync).toBe(true)
	end)

	it("searches a range another block shares, and on the trace tab waits for the next visit", function()
		local e = env()
		local s = searching(e)
		e.kv[Shared.KEY] = find(press(s, e, "S"), "kv_set").value
		local tick = Shared.TAG .. s.sync.gen
		e.kv[Shared.KEY] = Shared.publish({ from = "now-3h", to = "now" }, nil, "logs-1-1", e.kv[Shared.KEY])
		local _, effects = State.update(s, { kind = "tick", tag = tick }, e)
		expect(s.from).toBe("now-3h")
		expect(#searches(effects)).toBe(1)
		expect(find(effects, "timer").tag).toBe(tick)

		s.tab = "trace"
		e.kv[Shared.KEY] = Shared.publish({ from = "now-12h", to = "now" }, nil, "logs-1-1", e.kv[Shared.KEY])
		_, effects = State.update(s, { kind = "tick", tag = tick }, e)
		expect(s.from).toBe("now-12h")
		expect(#searches(effects)).toBe(0)
		expect(s.hits).toBeNil()
	end)
end)

return nil
