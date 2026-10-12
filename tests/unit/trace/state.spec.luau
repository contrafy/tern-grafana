--!strict
-- The trace block opens a trace from a link (or restores the one the user
-- last looked at), lets the keyboard walk and fold the span tree with every
-- move revealed, and searches with TraceQL. Through Grafana it asks
-- /api/ds/query first and, when Grafana's Tempo plugin itself fails (Grafana
-- 11.6 on every search), the datasource proxy, saying so; a late answer for
-- a superseded request never overwrites a newer one. Saved state holds ids
-- and the query, never span data.
local Fixtures = require("../../lib/fixtures")
local Scheme = require("../../../plugin/lib/links/scheme")
local Settings = require("../../../plugin/lib/trace/settings")
-- `any`: the spec reads optional state fields after answers it knows arrived.
local State: any = require("../../../plugin/lib/trace/state")
local Validate = require("../../../plugin/lib/config/validate")
local View = require("../../../plugin/lib/trace/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577900000
local TRACE = "82c9f1c2bda850d878e52762cc0816"
local ROOT, FIRST, SECOND = "fd222e3b400b8c5e", "a0f1187d5c9dc4d6", "93f869ac82c50e2b"

local function config(text: string): any
	local cfg, problems = Validate.parseFile(text, json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

local CFG = config([[{"default_context": "lab", "contexts": {
	"lab": {"tempo": {"url": "http://t:3200"}},
	"g11": {"grafana": {"url": "http://g:3011", "datasources": {"tempo": "tempo"}}},
	"prom": {"prometheus": {"url": "http://p:9090"}}}}]])

local ENV: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null, config = CFG }

local function response(path: string, status: number?): any
	return { status = status or 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

local function key(text: string, name: string?): any
	return {
		name = name or text,
		text = if name then nil else text,
		ctrl = false,
		alt = false,
		shift = false,
		meta = false,
	}
end

local function https(effects: { any }): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "http" then
			table.insert(out, e)
		end
	end
	return out
end

local function find(effects: { any }, kind: string): any
	for _, e in effects do
		if e.kind == kind then
			return e
		end
	end
	return nil
end

local function link(params: { [string]: string }): { string }
	return { Scheme.encode({ action = "trace", params = params, vars = {} }) }
end

local function answer(s: any, effect: any, path: string, status: number?): (any, { any })
	return State.update(s, { kind = "http_done", tag = effect.tag, response = response(path, status) }, ENV)
end

local function press(s: any, k: any): { any }
	local _, effects = State.key(s, k, ENV)
	return effects
end

local function selectedId(s: any): string?
	local span = State.selected(s)
	return if span then span.raw.span_id else nil
end

local function opened(): (any, { any })
	local s, effects = State.init(link({ context = "lab", id = TRACE }), nil, ENV)
	local req = https(effects)[1]
	expect(req.request.path).toBe("/api/traces/" .. TRACE)
	local s2, after = answer(s, req, "tempo/2.10.8/trace.json")
	return s2, after
end

describe("trace block: a trace", function()
	it("loads the linked trace from Tempo and lists its spans as a tree", function()
		local s = opened()
		expect(s.tab).toBe("trace")
		expect(#s.rows).toBe(3)
		expect(selectedId(s)).toBe(ROOT)
		expect(State.title(s)).toBe("Trace 82c9f1c2: payments lets-go")
	end)

	it("moves the selection with j/k and reveals every move", function()
		local s = opened()
		local effects = press(s, key("j"))
		expect(selectedId(s)).toBe(FIRST)
		expect(find(effects, "reveal").id).toBe(string.format("main.wf.r%d", s.rows[s.sel]))
		press(s, key("end", "end"))
		expect(selectedId(s)).toBe(SECOND)
		effects = press(s, key("p"))
		expect(selectedId(s)).toBe(ROOT)
		expect(find(effects, "reveal") ~= nil).toBe(true)
	end)

	it("folds and unfolds a subtree, and h on a leaf goes to its parent", function()
		local s = opened()
		press(s, key("h"))
		expect(#s.rows).toBe(1)
		press(s, key("l"))
		expect(#s.rows).toBe(3)
		press(s, key("l"))
		expect(selectedId(s)).toBe(FIRST)
		press(s, key("h"))
		expect(selectedId(s)).toBe(ROOT)
		press(s, key("space", "space"))
		expect(#s.rows).toBe(1)
	end)

	it("opens the selected span's detail with its attributes", function()
		local s = opened()
		press(s, key("j"))
		press(s, key("enter", "enter"))
		expect(s.detail).toBe(true)
		local view: any = View.view(s, ENV)
		local found = false
		for _, n in view.main.c do
			if n.p and n.p.key == "wf" then
				for _, row in n.c do
					if row.p.key == "d2" then
						found = true
					end
				end
			end
		end
		expect(found).toBe(true)
	end)

	it("selects the span a link names once the trace arrives", function()
		local s, effects = State.init(link({ context = "lab", id = TRACE, span = SECOND }), nil, ENV)
		local after
		s, after = answer(s, https(effects)[1], "tempo/2.10.8/trace.json")
		expect(selectedId(s)).toBe(SECOND)
		expect(s.detail).toBe(true)
		expect(find(after, "reveal") ~= nil).toBe(true)
	end)

	it("jumps between error spans", function()
		local s = opened()
		press(s, key("e"))
		expect(selectedId(s)).toBe(FIRST)
	end)

	it("says a missing trace is not found", function()
		local s, effects = State.init(link({ context = "lab", id = "beef" }), nil, ENV)
		s = answer(s, https(effects)[1], "tempo/2.10.8/trace_not_found.txt", 404)
		expect(s.trace).toBeNil()
		expect(s.trace_error.message).toBe("trace not found")
	end)

	it("loads a trace id typed with /", function()
		local s = opened()
		local effects = press(s, key("/"))
		expect(find(effects, "focus").id).toBe(State.INPUT_ID)
		s.line = { text = "", cursor = 0 }
		for c in string.gmatch("BEEF", ".") do
			press(s, key(c))
		end
		effects = press(s, key("enter", "enter"))
		expect(https(effects)[1].request.path).toBe("/api/traces/beef")
		expect(s.editing).toBeNil()
	end)

	it("drops a late answer for a trace the user moved away from", function()
		local s, effects = State.init(link({ context = "lab", id = TRACE }), nil, ENV)
		local stale = https(effects)[1]
		press(s, key("r"))
		s = answer(s, stale, "tempo/2.10.8/trace.json")
		expect(s.trace).toBeNil()
	end)
end)

describe("trace block: through Grafana", function()
	it("asks /api/ds/query and reads Grafana's Trace frame", function()
		local s, effects = State.init(link({ context = "g11", id = TRACE }), nil, ENV)
		local req = https(effects)[1]
		expect(req.request.path).toBe("/api/ds/query")
		s = answer(s, req, "grafana/11.6.16/ds_query_tempo_trace.json")
		expect(#s.rows).toBe(3)
	end)

	it("falls back to the datasource proxy when Grafana's Tempo search fails, and says so", function()
		local s, effects = State.init(link({ context = "g11" }), nil, ENV)
		expect(s.tab).toBe("search")
		local search = https(effects)[1]
		expect(search.request.path).toBe("/api/ds/query")
		local tags = https(effects)[2]
		expect(tags.request.path).toBe("/api/datasources/proxy/uid/tempo/api/v2/search/tags")
		local after
		s, after = answer(s, search, "grafana/11.6.16/ds_query_tempo_search.json", 500)
		local retry = https(after)[1]
		expect(retry.request.path).toBe("/api/datasources/proxy/uid/tempo/api/search")
		expect(s.note).toContain("datasource proxy")
		expect(s.search_error).toBeNil()
		s = answer(s, retry, "grafana/11.6.16/ds_proxy_tempo_search.json")
		expect(#s.hits).toBe(10)
		-- Later searches go straight to the proxy.
		effects = press(s, key("r"))
		expect(https(effects)[1].request.path).toBe("/api/datasources/proxy/uid/tempo/api/search")
	end)
end)

describe("trace block: search", function()
	local function searched(): any
		local s, effects = State.init({}, nil, ENV)
		local req = https(effects)[1]
		expect(req.request.path).toBe("/api/search")
		expect(req.request.query[1]).toEqual({ "q", "{}" })
		return (answer(s, req, "tempo/2.10.8/search.json"))
	end

	it("runs {} over the default range when opened without a trace", function()
		local s = searched()
		expect(#s.hits).toBe(10)
		expect(s.from).toBe(Settings.DEFAULT_RANGE)
	end)

	it("opens the selected hit in place with enter and in a new block with o", function()
		local s = searched()
		local effects = press(s, key("j"))
		expect(find(effects, "reveal").id).toBe("main.hits.h2")
		local hit = s.hits[2]
		effects = press(s, key("o"))
		local open = find(effects, "open")
		expect(open.target).toBe(Scheme.encode({
			action = "trace",
			params = { context = "lab", id = string.gsub(hit.trace_id, "^0+", "") },
			vars = {},
		}))
		effects = press(s, key("enter", "enter"))
		expect(s.tab).toBe("trace")
		expect(https(effects)[1].request.path).toBe("/api/traces/" .. string.gsub(hit.trace_id, "^0+", ""))
	end)

	it("changes the range with the query block's range keys and searches again", function()
		local s = searched()
		local effects = press(s, key("3"))
		expect(s.from).toBe("now-1h")
		expect(#https(effects)).toBe(1)
		effects = press(s, key("1"))
		expect(s.from).toBe("now-5m")
		local q = https(effects)[1].request.query
		expect(q[3]).toEqual({ "start", string.format("%d", (NOW - 300000) // 1000) })
	end)

	it("shows Tempo's TraceQL parse error", function()
		local s, effects = State.init({}, nil, ENV)
		s = answer(s, https(effects)[1], "tempo/2.10.8/search_error.txt", 400)
		expect(s.search_error.message).toContain("invalid TraceQL query")
	end)

	it("adds a tag value as a condition and searches", function()
		local s, effects = State.init({}, nil, ENV)
		s = answer(s, https(effects)[2], "tempo/2.10.8/search_tags_v2.json")
		expect(#s.tags > 0).toBe(true)
		local _, picked = State.update(
			s,
			{ kind = "event", ev = { ev = "action", act = "tag", value = "resource.service.name" } } :: any,
			ENV
		)
		local values = https(picked)[1]
		expect(values.request.path).toBe("/api/v2/search/tag/resource.service.name/values")
		s = answer(s, values, "tempo/2.10.8/search_tag_values_v2.json")
		local _, run =
			State.update(s, { kind = "event", ev = { ev = "action", act = "value", value = "2" } } :: any, ENV)
		expect(s.q).toBe('{ resource.service.name = "payments" }')
		expect(https(run)[1].request.query[1]).toEqual({ "q", '{ resource.service.name = "payments" }' })
	end)

	it("builds TraceQL conditions into the last selector", function()
		expect(State.addMatcher("{}", "status", "error")).toBe('{ status = "error" }')
		expect(State.addMatcher("", "name", "GET")).toBe('{ name = "GET" }')
		expect(State.addMatcher('{ resource.service.name = "api" }', "status", "error")).toBe(
			'{ resource.service.name = "api" && status = "error" }'
		)
		expect(State.addMatcher("{ a = 1 } | count() > 2", "b", "x")).toBe('{ a = 1 } | count() > 2 && { b = "x" }')
	end)
end)

describe("trace block: config and saved state", function()
	it("reopens what the user last looked at, not the link that opened the block", function()
		local s = opened()
		local saved = State.save(s)
		expect(saved).toEqual({
			context = "lab",
			tab = "trace",
			trace_id = "00" .. TRACE,
			q = "{}",
			from = "now-1h",
			to = "now",
		})
		saved.trace_id = "beef"
		local restored, effects = State.init(link({ context = "lab", id = TRACE }), saved, ENV)
		expect(restored.trace_id).toBe(string.rep("0", 28) .. "beef")
		expect(https(effects)[1].request.path).toBe("/api/traces/beef")
	end)

	it("explains a context without Tempo", function()
		local s = State.init(link({ context = "prom" }), nil, ENV)
		expect(s.problem).toContain("tempo")
	end)

	it("reads the trace section with defaults and problems", function()
		local cfg = config([[{"default_context": "lab", "contexts": {"lab": {"tempo": {"url": "http://t:3200"}}},
			"trace": {"search_limit": 50, "range": "now-6h"}}]])
		local settings, problems = Settings.read(cfg)
		expect(settings).toEqual({ search_limit = 50, range = "now-6h" })
		expect(#problems).toBe(0)
		local bad = config([[{"default_context": "lab", "contexts": {"lab": {"tempo": {"url": "http://t:3200"}}},
			"trace": {"search_limit": 0, "range": "yesterday", "colour": 1}}]])
		settings, problems = Settings.read(bad)
		expect(settings).toEqual({ search_limit = Settings.DEFAULT_LIMIT, range = Settings.DEFAULT_RANGE })
		expect(#problems).toBe(3)
		local s = State.init(
			{},
			nil,
			{ now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null, config = bad } :: any
		)
		expect(#s.config_problems).toBe(3)
	end)
end)

return nil
