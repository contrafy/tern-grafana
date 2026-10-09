--!strict
-- What the block shows for each state: a chart image whose bytes ship as an
-- asset (so the runner can turn them into a blob) with one legend row per
-- drawn series, the instant table, the server's error message, and the
-- overlays in the layer region.
local Assets = require("../../../plugin/lib/render/assets")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/query/state")
local View = require("../../../plugin/lib/query/view")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local CFG = S.config()

local function open(params: { [string]: string }): (any, any)
	local env = S.env(CFG)
	local s = State.init({ Scheme.encode({ action = "query", params = params, vars = {} }) }, nil, env)
	return s, env
end

local function answer(s: any, env: any, path: string, status: number?)
	State.update(s, { kind = "http_done", tag = "q:" .. s.gen, response = S.response(path, status) }, env)
end

local function legendRows(main: any): { any }
	local list = S.nodes(main, function(n)
		return n.p ~= nil and n.p.role == "tern-grafana.legend"
	end)[1]
	return if list then list.c else {}
end

describe("Query view", function()
	for _, version in S.PROMETHEUS do
		it("shows a chart image backed by an SVG asset, one legend row per series (" .. version .. ")", function()
			local s, env = open({ context = "lab", expr = "rate(node_cpu_seconds_total[1m])", from = S.WINDOW })
			answer(s, env, "prometheus/" .. version .. "/query_range_multi.json")
			local regions, assets = View.view(s, env)
			local main = (regions :: any).main
			local image = S.nodes(main, function(n)
				return n.k == "image"
			end)[1]
			expect(image.p.asset).toBe("chart")
			expect((assets :: any).chart.mime).toBe(Assets.SVG)
			expect((assets :: any).chart.bytes).toBe(s.chart.svg)
			expect(#legendRows(main)).toBe(#s.chart.layout.series)
			expect(image.c).toBeNil()
		end)
	end

	it("draws the cursor as an overlay without changing the chart bytes", function()
		local s, env = open({ context = "lab", expr = "x", from = S.WINDOW })
		answer(s, env, "prometheus/3.15.0/query_range_multi.json")
		local _, before = View.view(s, env)
		State.key(s, S.key("left"), env)
		local regions, after = View.view(s, env)
		local image = S.nodes((regions :: any).main, function(n)
			return n.k == "image"
		end)[1]
		expect(image.c[1].p.key).toBe("cur")
		expect((after :: any).chart.bytes).toBe((before :: any).chart.bytes)
	end)

	it("shows the instant result as a table with one row per series", function()
		local s, env = open({ context = "lab", expr = "up", mode = "table", from = S.WINDOW })
		answer(s, env, "prometheus/3.15.0/query_vector.json")
		local regions, assets = View.view(s, env)
		local main = (regions :: any).main
		local rows = S.nodes(main, function(n)
			return n.p ~= nil and type(n.p.key) == "string" and string.match(n.p.key, "^r%d+$") ~= nil
		end)
		expect(#rows).toBe(6)
		expect(assets).toBeNil()
	end)

	it("shows the server's error in an error card", function()
		local s, env = open({ context = "lab", expr = "sum(rate(up[5m])", from = S.WINDOW })
		answer(s, env, "prometheus/2.53.5/query_error_parse.json", 400)
		local regions = View.view(s, env)
		local card = S.byKey((regions :: any).main, "error")
		expect(card.k).toBe("card")
		expect(card.p.head[1].t).toBe("Query error (HTTP 400)")
		expect(card.c[1].p.spans[1].t).toContain("unclosed left parenthesis")
	end)

	it("shows context, range, step and a spinner while loading", function()
		local s, env = open({ context = "lab", expr = "up", from = "now-1h" })
		local main = (View.view(s, env) :: any).main
		local head = S.byKey(main, "head")
		expect(S.byKey(head, "ctx").p.text).toBe("lab")
		expect(S.byKey(head, "range").p.spans[1].t).toBe("Last 1 hour")
		expect(S.byKey(head, "step").p.spans[1].t).toBe("step 15s")
		expect(S.byKey(head, "spin").k).toBe("spinner")
	end)

	for _, version in S.PROMETHEUS do
		it("counts server and config warnings in the header and lists them (" .. version .. ")", function()
			local expr = "histogram_quantile(0.9, rate(node_cpu_seconds_total[5m]))"
			local s, env = open({ context = "lab", expr = expr, mode = "table", from = S.WINDOW })
			s.notices = { "query.refresh: bad" }
			answer(s, env, "prometheus/" .. version .. "/query_warning.json")
			local main = (View.view(s, env) :: any).main
			expect(S.byKey(main, "warn").p.text).toBe("2 warnings")
			local lines = S.byKey(main, "warnings").c
			expect(lines[1].p.spans[1].t).toBe("query.refresh: bad")
			expect(lines[2].p.spans[1].t).toContain('bucket label "le" is missing')
		end)
	end

	it("keeps the input's caret in UTF-16 units", function()
		local env = S.env(CFG)
		local s = State.init({}, nil, env)
		S.type(s, 'x{a="', env, State)
		State.key(s, S.key("paste", "é"), env)
		local input = S.byKey((View.view(s, env) :: any).main, "q")
		expect(input.k).toBe("input")
		expect(input.p.cursor).toBe(6)
	end)

	it("lists suggestions under the input with stable item ids", function()
		local env = S.env(CFG)
		local s = State.init({}, nil, env)
		S.type(s, "rat", env, State)
		State.key(s, S.key("down"), env)
		local list = S.byKey((View.view(s, env) :: any).main, "sugg")
		expect(list.k).toBe("list")
		expect(list.c[1].p.label[1].t).toBe("rate")
		expect(list.p.selected).toBe("main.sugg.s1")
		State.update(s, { kind = "event", ev = { ev = "activate", id = "main.sugg.s1" } }, env)
		expect(s.expr).toBe("rate(")
	end)

	it("puts help and history in the layer", function()
		local s, env = open({ context = "lab", expr = "up", from = S.WINDOW })
		State.key(s, S.key("?"), env)
		expect(((View.view(s, env) :: any).layer).p.role).toBe("tern-grafana.query-help")
		State.key(s, S.key("escape"), env)
		env.kv["tern-grafana.query.history"] = { lab = { "up", "sum(up)" } }
		State.key(s, S.key("h"), env)
		local layer = (View.view(s, env) :: any).layer
		local list = S.byKey(layer, "hist")
		expect(#list.c).toBe(2)
		expect(list.p.selected).toBe("layer.hist.h1")
	end)
end)

return nil
