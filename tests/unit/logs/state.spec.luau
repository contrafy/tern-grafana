--!strict
-- The Logs block as a state machine: what it sends, what it keeps, how keys,
-- chips and tail polls change the query, and that late answers to an older
-- query never overwrite a newer one. Responses are recorded Loki 3.7.8 and
-- Grafana 11/12 fixtures.
local Q = require("../query/support")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/logs/state")
local View = require("../../../plugin/lib/logs/view")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local CONFIG_TEXT = [[{
	"version": 1,
	"default_context": "lab",
	"contexts": {
		"lab": {"loki": {"url": "http://localhost:3100"}},
		"graf": {"grafana": {"url": "http://localhost:3000", "datasources": {"loki": "loki"}}}
	}
}]]

local function config(logs: any?): any
	local raw = json.decode(CONFIG_TEXT)
	raw.logs = logs
	local cfg = Validate.validate(raw)
	assert(cfg, "test config is valid")
	return cfg
end

local CFG = config()

local function link(params: { [string]: string }): string
	return Scheme.encode({ action = "logs", params = params, vars = {} })
end

local function open(params: { [string]: string }?, env: any?): (any, { any }, any)
	local e = env or Q.env(CFG)
	local s, effects = State.init(if params then { link(params) } else {}, nil, e)
	return s, effects, e
end

local function press(s: any, env: any, name: string, text: string?): { any }
	local _, effects = State.key(s, Q.key(name, text), env)
	return effects
end

local function done(s: any, env: any, tag: string, path: string, status: number?): { any }
	local _, effects = State.update(s, { kind = "http_done", tag = tag, response = Q.response(path, status) }, env)
	return effects
end

-- A click on a node with `actions = {click = a}`: Tern sends "name=value"
-- split at the first "=".
local function act(s: any, env: any, a: string): { any }
	local name, value = string.match(a, "^([^=]*)=(.*)$")
	local ev = { ev = "action", act = name or a, value = value }
	local _, effects = State.update(s, { kind = "event", ev = ev }, env)
	return effects
end

local function https(effects: { any }, prefix: string): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "http" and string.sub(e.tag, 1, #prefix) == prefix then
			table.insert(out, e)
		end
	end
	return out
end

local function param(e: any, name: string): string?
	for _, p in e.request.query or {} do
		if p[1] == name then
			return p[2]
		end
	end
	return nil
end

local LOGGEN = { expr = '{job="loggen"}', from = Q.WINDOW }

-- Opens the block on loggen and answers its query (and volume) from fixtures.
local function loaded(path: string?): (any, any)
	local s, effects, env = open(LOGGEN)
	local q = https(effects, State.QUERY_TAG)[1]
	done(s, env, q.tag, path or "loki/3.7.8/query_range_streams.json")
	local v = https(effects, State.VOLUME_TAG)[1]
	if v then
		done(s, env, v.tag, "loki/3.7.8/query_range_matrix.json")
	end
	return s, env
end

describe("opening", function()
	it("runs the link's query newest first with the configured limit and a volume query", function()
		local _, effects = open(LOGGEN)
		local q = https(effects, State.QUERY_TAG)
		expect(#q).toBe(1)
		expect(q[1].request.path).toBe("/loki/api/v1/query_range")
		expect(param(q[1], "query")).toBe('{job="loggen"}')
		expect(param(q[1], "limit")).toBe("500")
		expect(param(q[1], "direction")).toBeNil()
		expect(param(q[1], "start")).toBe(string.format("%d000000", Q.NOW_MS - 15 * 60000))
		local v = https(effects, State.VOLUME_TAG)
		expect(#v).toBe(1)
		expect(param(v[1], "query")).toBe('sum by (level, detected_level) (count_over_time({job="loggen"} [15s]))')
		expect(param(v[1], "step")).toBe("15")
	end)

	it("uses logs.limit and skips the volume when logs.volume is false", function()
		local _, effects = open(LOGGEN, Q.env(config({ limit = 50, volume = false })))
		expect(param(https(effects, State.QUERY_TAG)[1], "limit")).toBe("50")
		expect(#https(effects, State.VOLUME_TAG)).toBe(0)
	end)

	it("focuses the input when the link has no query", function()
		local s, effects = open(nil)
		expect(s.editing).toBe(true)
		expect(Q.find(effects, "focus").id).toBe(State.INPUT_ID)
	end)

	it("queries Grafana's Loki datasource for a Grafana-only context", function()
		local _, effects = open({ context = "graf", expr = '{job="loggen"}' })
		local q = https(effects, State.QUERY_TAG)[1]
		expect(q.request.path).toBe("/api/ds/query")
		local body = json.decode(q.request.body)
		expect(body.queries[1].datasource).toEqual({ type = "loki", uid = "loki" })
		expect(body.queries[1].maxLines).toBe(500)
	end)

	it("reports an unroutable context instead of querying", function()
		local cfg = Validate.validate(json.decode([[{"contexts": {"p": {"prometheus": {"url": "http://p"}}}}]]))
		local env = Q.env(cfg)
		local s, effects = open({ expr = '{a="b"}' }, env)
		expect(#https(effects, "")).toBe(0)
		expect(s.status).toBe("error")
		expect(s.failure.message).toContain("no loki")
	end)
end)

describe("results", function()
	it("shows lines newest first and volume bars with level chips", function()
		local s, env = loaded()
		expect(s.status).toBe("ok")
		expect(#s.lines).toBe(50)
		expect(s.volume.total > 0).toBe(true)
		local main = (View.view(s, env) :: any).main
		local rows = Q.nodes(main, function(n)
			return n.k == "el" and n.p.class and string.find(n.p.class, "tg-lg-row", 1, true) ~= nil
		end)
		expect(#rows).toBe(50)
		expect(rows[1].c[1].k).toBe("text")
		local bars = Q.nodes(main, function(n)
			return n.k == "chart"
		end)
		expect(bars[1].p.kind).toBe("bars")
		local chips = Q.nodes(main, function(n)
			return n.k == "badge" and n.p.actions and string.sub(n.p.actions.click, 1, 4) == "lvl="
		end)
		expect(#chips).toBe(4)
	end)

	it("shows the query error Loki returned", function()
		local s, effects, env = open({ expr = '{job="loggen"' })
		done(s, env, https(effects, State.QUERY_TAG)[1].tag, "loki/3.7.8/query_error.txt", 400)
		expect(s.status).toBe("error")
		expect(s.failure.kind).toBe("query")
		expect(s.failure.message).toContain("parse error")
	end)

	it("drops an answer to a query the user already replaced", function()
		local s, effects, env = open(LOGGEN)
		local old = https(effects, State.QUERY_TAG)[1]
		press(s, env, "r")
		done(s, env, old.tag, "loki/3.7.8/query_range_streams.json")
		expect(s.status).toBe("loading")
		expect(#s.lines).toBe(0)
	end)

	it("charts a metric query instead of listing lines", function()
		local s, effects, env = open({ expr = 'sum by (level) (count_over_time({job="loggen"}[1m]))' })
		expect(#https(effects, State.VOLUME_TAG)).toBe(0)
		local q = https(effects, State.QUERY_TAG)[1]
		expect(param(q, "step")).toBe("15")
		done(s, env, q.tag, "loki/3.7.8/query_range_matrix.json")
		expect(s.chart ~= nil).toBe(true)
		local _, assets = View.view(s, env)
		expect(assets ~= nil and assets.chart ~= nil).toBe(true)
	end)
end)

describe("keyboard", function()
	it("moves the selection and reveals the selected row", function()
		local s, env = loaded()
		local effects = press(s, env, "j")
		expect(s.sel).toBe(1)
		expect(Q.find(effects, "reveal").id).toBe("main.lines.r" .. s.lines[1].id)
		press(s, env, "G")
		expect(s.sel).toBe(50)
		effects = press(s, env, "up", "")
		expect(s.sel).toBe(49)
		expect(Q.find(effects, "reveal").id).toBe("main.lines.r" .. s.lines[49].id)
	end)

	it("opens a line's detail with its labels as chips and reveals the selected chip", function()
		local s, env = loaded("loki/3.7.8/query_range_streams_categorized.json")
		press(s, env, "j")
		press(s, env, "enter", "")
		expect(s.detail).toBe(s.lines[1].id)
		local main = (View.view(s, env) :: any).main
		local detail = Q.nodes(main, function(n)
			return n.p and n.p.key == "detail"
		end)[1]
		expect(detail ~= nil).toBe(true)
		local fields = State.fields(s.lines[1])
		expect(fields[1].kind).toBe("label")
		expect(fields[#fields].kind).toBe("parsed")
		local effects = press(s, env, "right", "")
		expect(s.field_sel).toBe(2)
		local id = Q.find(effects, "reveal").id
		expect(id).toBe("main.lines.r" .. s.lines[1].id .. ".detail.label.f2")
		-- The id resolves to a node: detail > label section > chip row f2.
		local section = Q.nodes(detail, function(n)
			return n.p and n.p.key == "label"
		end)[1]
		expect(section.c[2].p.key).toBe("f2")
	end)

	it("filters for and out of the selected chip, in the selector or as a stage", function()
		local s, env = loaded("loki/3.7.8/query_range_streams_categorized.json")
		s.expr = '{app="checkout"} | logfmt'
		press(s, env, "j")
		press(s, env, "enter", "")
		local fields = State.fields(s.lines[1])
		local envIndex = table.find(
			(function()
				local names = {}
				for i, f in fields do
					names[i] = f.name
				end
				return names
			end)(),
			"env"
		) :: number
		s.field_sel = envIndex
		local effects = press(s, env, "x")
		expect(s.expr).toBe('{app="checkout", env!="dev"} | logfmt')
		expect(#https(effects, State.QUERY_TAG)).toBe(1)
		-- Structured metadata becomes a stage after the parser.
		done(s, env, https(effects, State.QUERY_TAG)[1].tag, "loki/3.7.8/query_range_streams_categorized.json")
		press(s, env, "j")
		press(s, env, "enter", "")
		for i, f in State.fields(s.lines[1]) do
			if f.kind == "metadata" then
				act(s, env, "inc=" .. i)
				break
			end
		end
		expect(s.expr).toContain('| logfmt | detected_level = "')
	end)

	it("opens a clicked row by line id, even after a tail poll moved it", function()
		local s, env = loaded("loki/3.7.8/query_range_streams_forward.json")
		local id = s.lines[3].id
		local effects = press(s, env, "t")
		done(s, env, https(effects, State.POLL_TAG)[1].tag, "loki/3.7.8/query_range_streams.json")
		act(s, env, "row=" .. id)
		expect(s.lines[s.sel].id).toBe(id)
		expect(s.detail).toBe(id)
		act(s, env, "row=" .. id)
		expect(s.detail).toBeNil()
	end)

	it("filters by level from the level chips", function()
		local s, env = loaded()
		local effects = act(s, env, "lvl=error")
		expect(s.expr).toBe('{job="loggen", level="error"}')
		expect(param(https(effects, State.QUERY_TAG)[1], "query")).toBe('{job="loggen", level="error"}')
		act(s, env, "lvl=warning")
		expect(s.expr).toBe('{job="loggen", level="error", level="warn"}')
	end)

	it("edits the query with label suggestions from Loki", function()
		local s, _, env = open(nil)
		local effects = Q.type(s, "{ap", env, State)
		local fetch = https(effects, State.SUGGEST_TAG)
		expect(#fetch).toBe(1)
		expect(fetch[1].request.path).toBe("/loki/api/v1/labels")
		done(s, env, fetch[1].tag, "loki/3.7.8/labels.json")
		expect(s.suggest.items[1].label).toBe("app")
		-- Accepting a label name asks for its values right away.
		effects = press(s, env, "tab", "")
		expect(s.expr).toBe("{app=")
		local values = https(effects, State.SUGGEST_TAG)
		expect(values[1].request.path).toBe("/loki/api/v1/label/app/values")
		done(s, env, values[1].tag, "loki/3.7.8/label_values_app.json")
		expect(#s.suggest.items).toBe(3)
	end)
end)

describe("tail", function()
	it("polls from just before the newest line and merges without duplicates", function()
		local s, env = loaded()
		local effects = press(s, env, "t")
		expect(s.tail).toBe(true)
		local poll = https(effects, State.POLL_TAG)[1]
		expect(param(poll, "start")).toBe(string.format("%d000000", 1791577897000 - 5000))
		expect(Q.find(effects, "timer").ms).toBe(2000)
		-- The overlapping window answers lines already shown.
		done(s, env, poll.tag, "loki/3.7.8/query_range_streams.json")
		expect(#s.lines).toBe(50)
		expect(s.tail_added).toBe(0)
		-- The next tick polls again and re-arms.
		local _, tick = State.update(s, { kind = "tick", tag = State.TAIL_TAG .. s.tail_gen }, env)
		expect(#https(tick, State.POLL_TAG)).toBe(1)
		expect(Q.find(tick, "timer") ~= nil).toBe(true)
	end)

	it("adds new lines on top and keeps the selected line selected", function()
		local s, env = loaded("loki/3.7.8/query_range_streams_forward.json")
		press(s, env, "j")
		local selected = s.lines[1].id
		local effects = press(s, env, "t")
		done(s, env, https(effects, State.POLL_TAG)[1].tag, "loki/3.7.8/query_range_streams.json")
		expect(s.tail_added > 0).toBe(true)
		expect(s.lines[s.sel].id).toBe(selected)
	end)

	it("stops polling when turned off and ignores the old timer", function()
		local s, env = loaded()
		press(s, env, "t")
		local gen = s.tail_gen
		press(s, env, "t")
		expect(s.tail).toBe(false)
		local _, tick = State.update(s, { kind = "tick", tag = State.TAIL_TAG .. gen }, env)
		expect(#tick).toBe(0)
	end)

	it("makes an absolute range live, keeping its span", function()
		local s, effects, env = open({ expr = '{job="loggen"}', from = "1791577000000", to = "1791577900000" })
		done(s, env, https(effects, State.QUERY_TAG)[1].tag, "loki/3.7.8/query_range_streams.json")
		press(s, env, "t")
		expect({ s.from, s.to }).toEqual({ "now-15m", "now" })
	end)
end)

describe("saving", function()
	it("keeps the link and volume toggle, never lines", function()
		local s, env = loaded()
		press(s, env, "v")
		local saved = State.save(s)
		expect(saved.volume).toBe(false)
		expect(saved.lines).toBeNil()
		local l: any = Scheme.decode(saved.link)
		expect(l.params.expr).toBe('{job="loggen"}')
		local again = State.init({}, saved, Q.env(CFG))
		expect(again.show_volume).toBe(false)
		expect(again.expr).toBe('{job="loggen"}')
	end)
end)

return nil
