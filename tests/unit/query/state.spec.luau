--!strict
-- The Query block as a state machine: what each key and message does, which
-- requests it sends, and what it keeps. Responses are the recorded fixtures
-- of both Prometheus versions and of Grafana 11 and 12's /api/ds/query.
local History = require("../../../plugin/lib/query/history")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/query/state")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local CFG = S.config()

local function link(params: { [string]: string }): string
	return Scheme.encode({ action = "query", params = params, vars = {} })
end

local function open(params: { [string]: string }?, env: any?): (any, { any }, any)
	local e = env or S.env(CFG)
	local s, effects = State.init(if params then { link(params) } else {}, nil, e)
	return s, effects, e
end

local function press(s: any, env: any, name: string, text: string?, mods: { [string]: boolean }?): ({ any }, boolean)
	local _, effects, changed = State.key(s, S.key(name, text, mods), env)
	return effects, changed
end

local function done(s: any, env: any, tag: string, path: string, status: number?): { any }
	local _, effects = State.update(s, { kind = "http_done", tag = tag, response = S.response(path, status) }, env)
	return effects
end

-- The form fields of a POSTed Prometheus query.
local function form(effect: any): { [string]: string }
	local out: { [string]: string } = {}
	for _, p in (Scheme.parseQuery(effect.request.body or "") or {}) :: { any } do
		out[p.name] = p.value
	end
	return out
end

local RANGE = { context = "lab", expr = "rate(node_cpu_seconds_total[1m])", from = S.WINDOW, to = "now" }

describe("Query block init", function()
	it("starts in the input, focused, without querying, when there is no expression", function()
		local s, effects = open()
		expect(s.editing).toBe(true)
		expect(s.context).toBe("lab")
		expect(s.from).toBe("now-1h")
		expect(S.find(effects, "focus").id).toBe(State.INPUT_ID)
		expect(S.find(effects, "http")).toBeNil()
	end)

	it("runs the linked query over the linked range with the step Grafana would use", function()
		local s, effects = open(RANGE)
		local http = S.find(effects, "http")
		expect(http.tag).toBe("q:1")
		expect(http.request.path).toBe("/api/v1/query_range")
		local f = form(http)
		expect(f.query).toBe("rate(node_cpu_seconds_total[1m])")
		-- The recorded fixtures were captured over exactly this window and step.
		expect({ f.start, f["end"], f.step }).toEqual({ "1791576998", "1791577898", "15" })
		expect(s.status).toBe("loading")
		expect(s.editing).toBe(false)
	end)

	it("expands Grafana's interval macros before sending", function()
		local _, effects = open({ context = "lab", expr = "rate(x[$__rate_interval]) / $__range_s", from = S.WINDOW })
		expect(form(S.find(effects, "http")).query).toBe("rate(x[1m]) / 900")
	end)

	it("honors the query section's default range and point budget", function()
		local env = S.env(S.config(nil, { default_range = "now-6h", max_points = 100 }))
		local s, effects = State.init({ link({ context = "lab", expr = "up" }) }, nil, env)
		expect(s.from).toBe("now-6h")
		-- 6h / 100 points = 216s, rounded to Grafana's 5m step.
		expect(form(S.find(effects, "http")).step).toBe("300")
	end)

	it("reports a bad query section as warnings and still works", function()
		local env = S.env(S.config(nil, { max_points = "lots" }))
		local s = State.init({}, nil, env)
		expect(s.notices).toEqual({ "query.max_points: must be a whole number from 10 to 11000" })
		expect(s.options.max_points).toBe(600)
	end)

	it("routes through the link's Grafana datasource when the context has Grafana", function()
		local _, effects = open({ context = "both", expr = "up", ds = "other", from = S.WINDOW })
		local http = S.find(effects, "http")
		expect(http.route.via).toBe("datasource")
		expect(http.route.datasource_uid).toBe("other")
		expect(http.request.path).toBe("/api/ds/query")
		local body = S.env(CFG).decode(http.request.body)
		expect(body.queries[1].datasource.uid).toBe("other")
	end)

	it("says how to configure the plugin when there is no config", function()
		local s: any = State.init({}, nil, S.env(nil))
		expect(s.status).toBe("error")
		expect(s.failure.kind).toBe("config")
		expect(s.failure.message).toContain("config.json")
	end)

	it("refuses an unknown context instead of querying another", function()
		local s, effects = open({ context = "nope", expr = "up" })
		expect(s.failure.message).toBe('Unknown context "nope"')
		expect(S.find(effects, "http")).toBeNil()
	end)

	it("ignores an invalid link with a warning and opens with defaults", function()
		local s = State.init({ "tern-grafana://query?token=abc" }, nil, S.env(CFG))
		expect(s.notices[1]).toContain("credential")
		expect(s.expr).toBe("")
		expect(s.context).toBe("lab")
	end)
end)

describe("Query block save", function()
	it("round-trips the link, mode and cursor, never results", function()
		local s, _, env = open({ context = "graf", expr = 'up{job="node"}', ds = "prom3", from = "now-3h", to = "now" })
		done(s, env, "q:1", "grafana/12.4.12/ds_query_prom_range.json")
		press(s, env, "left")
		local saved = State.save(s)
		expect(saved.mode).toBe("graph")
		expect(type(saved.cursor)).toBe("number")
		expect(saved.link).toBe(link({
			context = "graf",
			expr = 'up{job="node"}',
			ds = "prom3",
			from = "now-3h",
			to = "now",
			mode = "graph",
		}))
		local keys = {}
		for k in saved do
			table.insert(keys, k)
		end
		table.sort(keys)
		expect(keys).toEqual({ "cursor", "link", "mode" })

		-- A restored block (same args, the saved state) shows the edited query.
		local args = { link({ context = "lab", expr = "old" }) }
		local r = State.init(args, saved, env)
		expect({ r.context, r.expr, r.ds, r.from, r.to, r.mode }).toEqual({
			"graf",
			'up{job="node"}',
			"prom3",
			"now-3h",
			"now",
			"graph",
		})
		expect(r.restore_cursor).toBe(saved.cursor)
	end)

	it("keeps table mode across a restart", function()
		local s = open({ context = "lab", expr = "up", mode = "table" })
		expect(s.mode).toBe("table")
		local r = State.init({}, State.save(s), S.env(CFG))
		expect(r.mode).toBe("table")
	end)
end)

describe("Query block results", function()
	for _, version in S.PROMETHEUS do
		it("renders a range result as a chart on Prometheus " .. version, function()
			local s, _, env = open(RANGE)
			done(s, env, "q:1", "prometheus/" .. version .. "/query_range_multi.json")
			expect(s.status).toBe("ok")
			expect(s.chart ~= nil).toBe(true)
			expect(#s.chart.layout.series + s.chart.layout.dropped).toBe(30)
			expect(s.chart.layout.t_from).toBe(S.NOW_MS - 900000)
		end)

		it("shows Prometheus " .. version .. "'s parse error message", function()
			local s, _, env = open({ context = "lab", expr = "sum(rate(up[5m])", from = S.WINDOW })
			done(s, env, "q:1", "prometheus/" .. version .. "/query_error_parse.json", 400)
			expect(s.status).toBe("error")
			expect(s.failure.kind).toBe("query")
			expect(s.failure.message).toContain("unclosed left parenthesis")
			expect(s.chart).toBeNil()
		end)

		it("lists an instant vector in table mode on Prometheus " .. version, function()
			local s, _, env = open({ context = "lab", expr = "up", mode = "table", from = S.WINDOW })
			done(s, env, "q:1", "prometheus/" .. version .. "/query_vector.json")
			expect(s.status).toBe("ok")
			expect(#s.frames).toBe(6)
			expect(s.chart).toBeNil()
		end)
	end

	for _, version in S.GRAFANA do
		it("renders Grafana " .. version .. "'s /api/ds/query frames as a chart", function()
			local s, _, env = open({ context = "graf", expr = "sum by (mode) (rate(x[1m]))", from = S.WINDOW })
			done(s, env, "q:1", "grafana/" .. version .. "/ds_query_prom_range.json")
			expect(s.status).toBe("ok")
			expect(#s.chart.layout.series > 0).toBe(true)
		end)

		it("shows Grafana " .. version .. "'s downstream query error", function()
			local s, _, env = open({ context = "graf", expr = "sum(rate(up[1m])", from = S.WINDOW })
			done(s, env, "q:1", "grafana/" .. version .. "/ds_query_prom_error.json", 400)
			expect(s.status).toBe("error")
			expect(s.failure.message).toContain("unclosed left parenthesis")
		end)
	end

	it("drops an answer to a superseded query", function()
		local s, _, env = open(RANGE)
		local again = press(s, env, "r")
		expect(S.find(again, "http").tag).toBe("q:2")
		done(s, env, "q:1", "prometheus/3.15.0/query_range_multi.json")
		expect(s.status).toBe("loading")
		expect(s.chart).toBeNil()
		done(s, env, "q:2", "prometheus/3.15.0/query_range_multi.json")
		expect(s.status).toBe("ok")
	end)

	it("drops a late range answer after switching to table mode", function()
		local s, _, env = open(RANGE)
		press(s, env, "t")
		done(s, env, "q:1", "prometheus/3.15.0/query_range_multi.json")
		expect(s.chart).toBeNil()
		expect(s.status).toBe("loading")
	end)

	it("restores a saved cursor once the chart covers it", function()
		local s0, _, env = open(RANGE)
		done(s0, env, "q:1", "prometheus/3.15.0/query_range_multi.json")
		press(s0, env, "left")
		local saved = State.save(s0)
		local s = State.init({ link(RANGE) }, saved, env)
		done(s, env, "q:1", "prometheus/3.15.0/query_range_multi.json")
		expect(s.cursor_t).toBe(saved.cursor)
	end)
end)

describe("Query block keys", function()
	local function ready(): (any, any)
		local s, _, env = open(RANGE)
		done(s, env, "q:1", "prometheus/3.15.0/query_range_multi.json")
		return s, env
	end

	it("moves the chart cursor by sample, ten with shift, without a new query", function()
		local s, env = ready()
		local times = s.chart.layout.times
		local fx, changed = press(s, env, "left")
		expect(changed).toBe(true)
		expect(#fx).toBe(0)
		expect(s.cursor_t).toBe(times[#times])
		press(s, env, "left", nil, { shift = true })
		expect(s.cursor_t).toBe(times[#times - 10])
		press(s, env, "right")
		expect(s.cursor_t).toBe(times[#times - 9])
	end)

	it("toggles graph and table, re-querying only on a change", function()
		local s, env = ready()
		local _, same = press(s, env, "g")
		expect(same).toBe(false)
		local fx = press(s, env, "t")
		expect(s.mode).toBe("table")
		expect(S.find(fx, "http").request.path).toBe("/api/v1/query")
		expect(form(S.find(fx, "http")).time).toBe("1791577898")
		local _, left = press(s, env, "left")
		expect(left).toBe(false)
	end)

	it("changes the range with quick keys, shift and zoom, and re-queries", function()
		local s, env = ready()
		local fx = press(s, env, "5")
		expect({ s.from, s.to }).toEqual({ "now-6h", "now" })
		expect(S.find(fx, "http") ~= nil).toBe(true)
		press(s, env, "-")
		expect(s.from).toBe("now-12h")
		press(s, env, "+", "+", { shift = true })
		expect(s.from).toBe("now-6h")
		press(s, env, "[")
		expect({ s.from, s.to }).toEqual({
			string.format("%d", S.NOW_MS - 9 * 3600000),
			string.format("%d", S.NOW_MS - 3 * 3600000),
		})
		expect(s.gen).toBe(5)
	end)

	it("cycles contexts in name order and re-queries there", function()
		local s, env = ready()
		local fx = press(s, env, "c")
		expect(s.context).toBe("both")
		expect(S.find(fx, "http").route.context).toBe("both")
		press(s, env, "c")
		expect(s.context).toBe("graf")
	end)

	it("copies the query", function()
		local s, env = ready()
		local fx = press(s, env, "y")
		expect(S.find(fx, "copy").text).toBe(RANGE.expr)
	end)

	it("opens Grafana Explore through the browse link so our route does not claim it back", function()
		local s, _, env = open({ context = "graf", expr = "up", from = "now-6h" })
		local fx = press(s, env, "o")
		local target = S.find(fx, "open").target
		local l = Scheme.decode(target) :: any
		expect(l.action).toBe("browse")
		expect(l.params.url).toContain("http://localhost:3000/explore?schemaVersion=1&panes=")
		local panes = Scheme.percentDecode(string.match(l.params.url, "panes=(.*)$") :: string, true) :: string
		local state = env.decode(panes).a
		expect(state.queries[1].expr).toBe("up")
		expect(state.datasource).toBe("prom3")
		expect(state.range).toEqual({ from = "now-6h", to = "now" })
	end)

	it("explains why a context without Grafana cannot open Explore", function()
		local s, env = ready()
		local fx = press(s, env, "o")
		expect(S.find(fx, "open")).toBeNil()
		expect(S.find(fx, "toast").text).toBe('Context "lab" has no Grafana endpoint')
	end)

	it("opens help and closes it with escape before closing the block", function()
		local s, env = ready()
		press(s, env, "?")
		expect(s.overlay).toBe("help")
		local _, ignored = press(s, env, "r")
		expect(ignored).toBe(false)
		local fx = press(s, env, "escape")
		expect(s.overlay).toBeNil()
		expect(S.find(fx, "exit")).toBeNil()
		expect(S.find(press(s, env, "escape"), "exit") ~= nil).toBe(true)
		expect(S.find(press(s, env, "q"), "exit") ~= nil).toBe(true)
	end)

	it("leaves unknown keys to Tern", function()
		local s, env = ready()
		local fx, changed = press(s, env, "z")
		expect(changed).toBe(false)
		expect(#fx).toBe(0)
		local _, f5 = press(s, env, "f5")
		expect(f5).toBe(false)
	end)

	it("auto-refreshes on a timer until turned off, dropping the old timer's ticks", function()
		local s, env = ready()
		local fx = press(s, env, "a")
		local timer = S.find(fx, "timer")
		expect(timer.ms).toBe(30000)
		local _, tickFx = State.update(s, { kind = "tick", tag = timer.tag }, env)
		expect(S.find(tickFx, "http") ~= nil).toBe(true)
		expect(S.find(tickFx, "timer").tag).toBe(timer.tag)
		press(s, env, "a")
		expect(s.refresh_ms).toBeNil()
		local _, stale = State.update(s, { kind = "tick", tag = timer.tag }, env)
		expect(#stale).toBe(0)
	end)

	it("does not stack queries when a refresh tick finds one running", function()
		local s, env = ready()
		local timer = S.find(press(s, env, "a"), "timer")
		press(s, env, "r")
		local _, tickFx = State.update(s, { kind = "tick", tag = timer.tag }, env)
		expect(S.find(tickFx, "http")).toBeNil()
		expect(S.find(tickFx, "timer") ~= nil).toBe(true)
	end)
end)

describe("Query block input", function()
	it("edits in the input, runs on Enter and remembers the expression", function()
		local s, _, env = open()
		S.type(s, "sum(up)", env, State)
		expect(S.list(s.expr, s.cursor)).toEqual(S.list("sum(up)", 7))
		local fx = press(s, env, "enter")
		expect(form(S.find(fx, "http")).query).toBe("sum(up)")
		local kv = S.find(fx, "kv_set")
		expect(kv.key).toBe(History.KEY)
		expect(kv.value).toEqual({ lab = { "sum(up)" } })
		expect(s.editing).toBe(true)
	end)

	it("leaves the input on escape so keys are commands again", function()
		local s, _, env = open()
		S.type(s, "up", env, State)
		local fx = press(s, env, "escape")
		expect(s.editing).toBe(false)
		expect(S.find(fx, "focus").id).toBeNil()
		expect(S.find(fx, "exit")).toBeNil()
		press(s, env, "/")
		expect(s.editing).toBe(true)
		-- In the input, letters are text, not commands.
		local typed = press(s, env, "q")
		expect(S.find(typed, "exit")).toBeNil()
		expect(s.expr).toBe("upq")
	end)

	it("enters the input when it is clicked", function()
		local s, _, env = open(RANGE)
		local _, fx = State.update(s, { kind = "event", ev = { ev = "focus", id = State.INPUT_ID } }, env)
		expect(s.editing).toBe(true)
		expect(S.find(fx, "focus").id).toBe(State.INPUT_ID)
	end)

	it("dedupes history across blocks by re-reading kv before writing", function()
		local env = S.env(CFG)
		local a = State.init({}, nil, env)
		local b = State.init({}, nil, env)
		S.type(a, "up", env, State)
		S.applyKv(env, (press(a, env, "enter")))
		S.type(b, "sum(up)", env, State)
		S.applyKv(env, (press(b, env, "enter")))
		S.type(a, "", env, State)
		S.applyKv(env, (press(a, env, "enter")))
		expect(History.list(env.kv[History.KEY], "lab")).toEqual({ "up", "sum(up)" })
	end)

	it("picks from history and runs it", function()
		local s, _, env = open()
		env.kv[History.KEY] = { lab = { "sum(up)", "up" } }
		press(s, env, "escape")
		press(s, env, "h")
		expect(s.overlay).toBe("history")
		press(s, env, "down")
		local fx = press(s, env, "enter")
		expect(s.overlay).toBeNil()
		expect(s.expr).toBe("up")
		expect(form(S.find(fx, "http")).query).toBe("up")
		expect(S.find(fx, "kv_set").value.lab).toEqual({ "up", "sum(up)" })
	end)

	it("filters the history picker by typing", function()
		local s, _, env = open()
		env.kv[History.KEY] = { lab = { "sum(up)", "rate(x[5m])" } }
		press(s, env, "escape")
		press(s, env, "h")
		S.type(s, "rate", env, State)
		expect(State.historyVisible(s.history)).toEqual({ "rate(x[5m])" })
		press(s, env, "enter")
		expect(s.expr).toBe("rate(x[5m])")
	end)

	it("says when there is no history yet", function()
		local s, _, env = open(RANGE)
		local fx = press(s, env, "h")
		expect(s.overlay).toBeNil()
		expect(S.find(fx, "toast").text).toBe("No query history for lab")
	end)
end)

describe("Query block suggestions", function()
	local function typing(text: string): (any, any, { any })
		local s, _, env = open()
		return s, env, S.type(s, text, env, State)
	end

	it("fetches metric names and metadata once, on first need", function()
		local s, env, fx = typing("node_c")
		local https = S.all(fx, "http")
		expect(#https).toBe(2)
		expect(https[1].request.path).toBe("/api/v1/label/__name__/values")
		expect(https[2].request.path).toBe("/api/v1/metadata")
		expect(s.suggest.loading).toBe(true)
		done(s, env, https[1].tag, "prometheus/3.15.0/label_values_name.json")
		done(s, env, https[2].tag, "prometheus/3.15.0/metadata.json")
		local labels = {}
		for _, item in s.suggest.items do
			table.insert(labels, item.label)
		end
		expect(labels).toContain("node_cpu_seconds_total")
		expect(#S.all(S.type(s, "pu", env, State), "http")).toBe(0)
	end)

	it("refetches after the cache expires", function()
		local s, env, fx = typing("node_")
		for _, h in S.all(fx, "http") do
			done(s, env, h.tag, "prometheus/3.15.0/label_values_name.json")
		end
		env.now_ms += State.TTL_MS + 1
		expect(#S.all(S.type(s, "c", env, State), "http")).toBe(2)
	end)

	it("asks for label values of the metric being matched", function()
		local s, env, fx = typing('up{job="')
		local https = S.all(fx, "http")
		local http = https[#https]
		expect(http.request.path).toBe("/api/v1/label/job/values")
		local match = nil
		for _, q in http.request.query or {} do
			if q[1] == "match[]" then
				match = q[2]
			end
		end
		expect(match).toBe("up")
		done(s, env, http.tag, "grafana/12.4.12/ds_proxy_prom_label_values.json")
		expect(#s.suggest.items).toBe(6)
	end)

	it("keeps each context's cache apart", function()
		local s, env, fx = typing("node_")
		for _, h in S.all(fx, "http") do
			done(s, env, h.tag, "prometheus/3.15.0/label_values_name.json")
		end
		press(s, env, "escape")
		press(s, env, "c")
		-- Re-entering the input suggests for the text already there.
		local again = press(s, env, "i")
		expect(#S.all(again, "http")).toBe(2)
		expect(S.find(again, "http").route.context).toBe("both")
	end)

	it("accepts with tab, or with enter after moving through the list", function()
		local s, env, fx = typing("node_cpu_s")
		for _, h in S.all(fx, "http") do
			if h.request.path == "/api/v1/label/__name__/values" then
				done(s, env, h.tag, "prometheus/3.15.0/label_values_name.json")
			end
		end
		press(s, env, "tab")
		expect(s.expr).toBe("node_cpu_seconds_total")
		S.type(s, "{mo", env, State)
		expect(s.suggest ~= nil).toBe(true)
	end)

	it("accepts the selected item on enter instead of running", function()
		local s, env = typing("ra")
		press(s, env, "down")
		local fx = press(s, env, "enter")
		expect(S.find(fx, "http")).toBeNil()
		expect(string.sub(s.expr, -1)).toBe("(")
	end)

	it("drops suggestions for a context after a response arrives late", function()
		local s, env, fx = typing("node_")
		press(s, env, "escape")
		for _, h in S.all(fx, "http") do
			done(s, env, h.tag, "prometheus/3.15.0/label_values_name.json")
		end
		expect(s.suggest).toBeNil()
	end)

	it("lists everything on ctrl+space at an empty position", function()
		local s, _, env = open()
		press(s, env, "space", " ", { ctrl = true })
		expect(#s.suggest.items > 0).toBe(true)
	end)
end)

return nil
