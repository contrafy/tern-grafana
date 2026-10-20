--!strict
-- The compatibility report must say what the Dashboard block would actually
-- do: for every recorded fixture dashboard, on both Grafana versions, each
-- panel's rung and reason equal the decision the open Dashboard block makes
-- (with every row expanded). The report then groups the causes so the most
-- common one comes first, counts a repeated panel once, and the scan reads
-- a whole stack politely (paged search, a few dashboards at a time, each
-- library panel once) and says when it stopped at the configured cap.
local Analyze = require("../../../plugin/lib/compat/analyze")
local CompatConfig = require("../../../plugin/lib/compat/config")
local CompatState = require("../../../plugin/lib/compat/state")
local CompatView = require("../../../plugin/lib/compat/view")
local DashState = require("../../../plugin/lib/dashboard/state")
local Model = require("../../../plugin/lib/dashboard/model")
local Route = require("../../../plugin/lib/config/route")
local S = require("../dashboard/support")
local Scheme = require("../../../plugin/lib/links/scheme")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function key(name: string, text: string?, shift: boolean?): any
	return { name = name, text = text, ctrl = false, alt = false, shift = shift == true, meta = false }
end

local function char(c: string): any
	return key(c, c, string.upper(c) == c and string.lower(c) ~= c)
end

local DASHBOARDS = {
	{ uid = "tern-panels", fs = "frontend_settings.json" },
	{ uid = "tern-variables", fs = "frontend_settings.json" },
	{ uid = "tern-all-panels", fs = "frontend_settings_all_panels.json" },
	{ uid = "tern-observability", fs = "frontend_settings.json" },
	{ uid = "tern-sql", fs = "frontend_settings_sql.json" },
}

local function dashFixture(version: string, uid: string): string
	return S.grafana(version, "dashboard_" .. string.gsub(uid, "-", "_") .. ".json")
end

-- The Dashboard block's decisions, answered from fixtures, every row expanded.
local function blockDecisions(version: string, uid: string, fs: string): { [string]: any }
	local env = S.env()
	local s, effects = DashState.init({ "tern-grafana://dashboard?context=lab&uid=" .. uid }, nil, env)
	local function apply(list: { any })
		for _, e in list do
			if e.kind ~= "http" then
				continue
			end
			local tg = e.tag
			local path: string? = nil
			if string.match(tg, "^dash/") then
				path = dashFixture(version, uid)
			elseif string.match(tg, "^fs/") then
				path = S.grafana(version, fs)
			elseif string.match(tg, "^user/") then
				path = S.grafana(version, "user.json")
			elseif string.match(tg, "^lib/") then
				path = S.grafana(version, "library_element.json")
			elseif string.match(tg, "^var/") then
				if e.request.path == "/api/ds/query" then
					path = S.grafana(version, "ds_query_prom_instant.json")
				elseif string.find(e.request.path, "__name__", 1, true) then
					path = "prometheus/3.15.0/label_values_name.json"
				else
					path = S.grafana(version, "ds_proxy_prom_label_values.json")
				end
			end
			if path then
				local _, more = DashState.update(s, { kind = "http_done", tag = tg, response = S.response(path) }, env)
				apply(more)
			end
		end
	end
	apply(effects)
	local _, more = DashState.key(s, char("C"), env)
	apply(more)
	local out: { [string]: any } = {}
	for _, sec in s.sections do
		if string.find(sec.key, ".", 1, true) then
			continue
		end
		for _, inst in sec.panels do
			if inst.clone == 0 then
				local d = s.panels[inst.key].decision
				out[tostring(inst.panel.id)] = { mode = d.mode, reason = d.reason }
			end
		end
	end
	return out
end

local function settingsFor(version: string, fs: string): Analyze.Settings
	local route = assert(Route.route(S.CONFIG, "lab", "dashboards"))
	return assert((Analyze.settings(route, S.response(S.grafana(version, fs)), S.env())), "settings must parse")
end

local function analyzed(version: string, uid: string, fs: string): { Analyze.PanelResult }
	local env = S.env()
	local d = assert(Model.parseResponse(S.response(dashFixture(version, uid)), env))
	for _, lib in Model.libraryRefs(d) do
		local model = Model.parseLibrary(S.response(S.grafana(version, "library_element.json")), env)
		Model.applyLibrary(d, lib, model, env)
	end
	return Analyze.panels(d, settingsFor(version, fs), env)
end

local function byId(panels: { Analyze.PanelResult }): { [string]: Analyze.PanelResult }
	local out: { [string]: Analyze.PanelResult } = {}
	for _, p in panels do
		out[tostring(p.id)] = p
	end
	return out
end

for _, version in S.VERSIONS do
	describe("compat analysis on Grafana " .. version, function()
		it("puts every fixture panel on the rung the Dashboard block chooses, with its reason", function()
			for _, dash in DASHBOARDS do
				local expected = blockDecisions(version, dash.uid, dash.fs)
				local got: { [string]: any } = {}
				for id, p in byId(analyzed(version, dash.uid, dash.fs)) do
					got[id] = { mode = p.mode, reason = p.reason }
				end
				expect(next(expected) ~= nil).toBe(true)
				expect(got).toEqual(expected)
			end
		end)

		it("analyzes panels of collapsed rows and resolves library panels", function()
			local panels = byId(analyzed(version, "tern-panels", "frontend_settings.json"))
			local collapsed = 0
			for _, p in panels do
				if p.collapsed then
					collapsed += 1
				end
			end
			expect(collapsed > 0).toBe(true)
			expect(panels["18"].library).toBe(true)
			expect(panels["18"].type).toBe("bargauge")
			expect(panels["18"].mode).toBe("native")
		end)

		it("counts a repeated panel and a repeated row's panels once, naming the variable", function()
			local panels = analyzed(version, "tern-variables", "frontend_settings.json")
			local ids: { number } = {}
			for _, p in panels do
				table.insert(ids, p.id)
			end
			table.sort(ids)
			expect(ids).toEqual({ 1, 2, 3, 4, 6 })
			local p = byId(panels)
			expect(p["3"].repeat_var).toBe("job")
			expect(p["6"].row_repeat_var).toBe("instance")
			-- `${ds}` resolves through the datasource variable, as in the block.
			expect(p["1"].mode).toBe("native")
		end)

		it("says a missing library element cannot be loaded", function()
			local env = S.env()
			local d = assert(Model.parseResponse(S.response(dashFixture(version, "tern-panels")), env))
			for _, lib in Model.libraryRefs(d) do
				Model.applyLibrary(d, lib, Model.parseLibrary(S.body(404, '{"message":"not found"}'), env), env)
			end
			local p = byId(Analyze.panels(d, settingsFor(version, "frontend_settings.json"), env))["18"]
			expect(p.blocker).toBe("library panel could not be loaded")
			expect(p.mode).toBe(if version == "12.4.12" then "png" else "browser")
		end)
	end)
end

-- A synthetic stack: causes that differ only by a name or a variable group
-- together, and the most common cause comes first.
local function panel(id: number, typ: string, ds: any, extra: { [string]: any }?): any
	local p: { [string]: any } = {
		id = id,
		type = typ,
		title = "P" .. id,
		gridPos = { x = 0, y = id, w = 12, h = 4 },
		datasource = ds,
		targets = { { refId = "A", expr = "up" } },
	}
	if extra then
		for k, v in extra do
			p[k] = v
		end
	end
	return p
end

local function dashboardBody(uid: string, panels: { any }, templating: { any }?): string
	return json.encode({
		meta = { slug = uid },
		dashboard = { uid = uid, title = "Dash " .. uid, panels = panels, templating = { list = templating or {} } },
	})
end

local PROM = { type = "prometheus", uid = "prom3" }

local SYNTH = {
	a = dashboardBody("a", {
		panel(1, "acme-flow-panel", PROM),
		panel(2, "acme-flow-panel", PROM),
		panel(3, "timeseries", { type = "mysql", uid = "sql1" }),
		panel(4, "timeseries", "${missing}"),
		panel(5, "timeseries", PROM),
	}),
	b = dashboardBody("b", {
		panel(1, "acme-flow-panel", PROM),
		panel(2, "timeseries", "$other"),
		panel(3, "stat", { type = "mysql", uid = "sql2" }),
	}),
}

describe("compat summary", function()
	local env = S.env()
	local settings = settingsFor("12.4.12", "frontend_settings.json")
	local results: { Analyze.DashResult } = {}
	for _, uid in { "a", "b" } do
		local d = assert(Model.parseResponse(S.body(200, SYNTH[uid]), env))
		table.insert(results, Analyze.result(uid, d.title, nil, Analyze.panels(d, settings, env), nil))
	end
	local sum = Analyze.summarize(results)

	it("groups by cause with names and variables generalized, most panels first", function()
		local rows: { string } = {}
		for _, r in sum.reasons do
			table.insert(
				rows,
				string.format("%s | %d | %d | %s", r.reason, r.panels, r.dashboards, Analyze.typesText(r.types))
			)
		end
		expect(rows).toEqual({
			"panel type acme-flow-panel is not rendered natively | 3 | 2 | acme-flow-panel (3)",
			"datasource $var is not resolved | 2 | 2 | timeseries (2)",
			"mysql queries are not run natively | 2 | 2 | stat (1), timeseries (1)",
		})
		expect(sum.native).toBe(1)
		expect(sum.png).toBe(7)
		expect(sum.panels).toBe(8)
	end)

	it("keeps each panel's own reason for the per-panel rows", function()
		local a = results[1].panels
		expect(a[4].blocker).toBe("datasource ${missing} is not resolved")
		expect(Analyze.group('unknown datasource "x1"')).toBe('unknown datasource "..."')
	end)
end)

-- The block: scan flow over fixture answers.
type Harness = { s: CompatState.State, env: any, pending: { [string]: any }, opened: { string }, copied: { string } }

local function config(extra: string?): any
	return assert(Validate.parseFile([[{"default_context": "lab", ]] .. (extra or "") .. [[ "contexts": {
	"lab": {"grafana": {"url": "http://localhost:3000", "org_id": 1}},
	"other": {"grafana": {"url": "http://localhost:3011", "org_id": 1}}}}]], json.decode))
end

local function collect(h: Harness, effects: { any })
	for _, e in effects do
		if e.kind == "http" then
			h.pending[e.tag] = e
		elseif e.kind == "open" then
			table.insert(h.opened, e.target)
		elseif e.kind == "copy" then
			table.insert(h.copied, e.text)
		end
	end
end

local function start(cfg: any?, saved: any?): Harness
	local env = S.env(cfg or config())
	local s, effects = CompatState.init({}, saved, env)
	local h: Harness = { s = s, env = env, pending = {}, opened = {}, copied = {} }
	collect(h, effects)
	return h
end

local function answer(h: Harness, tg: string, response: any)
	assert(h.pending[tg], "no pending request " .. tg)
	h.pending[tg] = nil
	local _, effects = CompatState.update(h.s, { kind = "http_done", tag = tg, response = response }, h.env)
	collect(h, effects)
end

local function pendingTags(h: Harness, prefix: string): { string }
	local out: { string } = {}
	for tg in h.pending do
		if string.sub(tg, 1, #prefix) == prefix then
			table.insert(out, tg)
		end
	end
	table.sort(out)
	return out
end

local function hits(n: number): string
	local list: { any } = {}
	for i = 1, n do
		table.insert(list, { uid = "d" .. i, title = "D" .. i, type = "dash-db" })
	end
	return json.encode(list)
end

local VERSION = "12.4.12"

describe("compat block", function()
	it("reads settings and the first search page, then the found dashboards and each library once", function()
		local h = start()
		local paths: { string } = {}
		for _, e in h.pending do
			table.insert(paths, e.request.path)
		end
		table.sort(paths)
		expect(paths).toEqual({ "/api/frontend/settings", "/api/search" })
		expect(h.pending["c/1/s/1"].request.query).toEqual({
			{ "type", "dash-db" },
			{ "limit", "1000" },
			{ "page", "1" },
		})
		answer(h, "c/1/s/1", S.response(S.grafana(VERSION, "search.json")))
		-- Nothing loads before the datasource catalog is known.
		expect(pendingTags(h, "c/1/d/")).toEqual({})
		answer(h, "c/1/fs", S.response(S.grafana(VERSION, "frontend_settings.json")))
		expect(pendingTags(h, "c/1/d/")).toEqual({ "c/1/d/1", "c/1/d/2", "c/1/d/3" })
		for i, uid in { "tern-observability", "tern-panels", "tern-variables" } do
			answer(h, "c/1/d/" .. i, S.response(dashFixture(VERSION, uid)))
		end
		expect(pendingTags(h, "c/1/l/")).toEqual({ "c/1/l/tern-lib-up" })
		expect(h.s.phase).toBe("scanning")
		answer(h, "c/1/l/tern-lib-up", S.response(S.grafana(VERSION, "library_element.json")))
		expect(h.s.phase).toBe("done")
		expect(#CompatState.ordered(h.s)).toBe(3)
		expect(CompatState.title(h.s)).toBe("Compatibility: lab")
	end)

	it("keeps at most four dashboards loading", function()
		local h = start()
		answer(h, "c/1/fs", S.response(S.grafana(VERSION, "frontend_settings.json")))
		answer(h, "c/1/s/1", S.body(200, hits(6)))
		expect(#pendingTags(h, "c/1/d/")).toBe(4)
		answer(h, "c/1/d/1", S.body(200, SYNTH.a))
		expect(pendingTags(h, "c/1/d/")).toEqual({ "c/1/d/2", "c/1/d/3", "c/1/d/4", "c/1/d/5" })
	end)

	it("pages the search while pages come back full", function()
		local saved = CompatState.PAGE_SIZE
		CompatState.PAGE_SIZE = 2
		local h = start()
		answer(h, "c/1/s/1", S.body(200, hits(2)))
		expect(h.pending["c/1/s/2"] ~= nil).toBe(true)
		answer(h, "c/1/s/2", S.body(200, "[]"))
		CompatState.PAGE_SIZE = saved
		expect(h.s.search_done).toBe(true)
		expect(h.s.capped).toBe(false)
	end)

	it("stops at compat.max_dashboards and says so", function()
		local cfg = config([["compat": {"max_dashboards": 2},]])
		expect(CompatConfig.read(cfg).max_dashboards).toBe(2)
		local h = start(cfg)
		answer(h, "c/1/fs", S.response(S.grafana(VERSION, "frontend_settings.json")))
		answer(h, "c/1/s/1", S.body(200, hits(5)))
		expect(h.s.capped).toBe(true)
		expect(#h.s.hits).toBe(2)
		answer(h, "c/1/d/1", S.body(200, SYNTH.a))
		answer(h, "c/1/d/2", S.body(404, '{"message":"Dashboard not found"}'))
		expect(h.s.phase).toBe("done")
		local text = assert(CompatState.markdown(h.s, h.env))
		expect(text).toContain("Capped: scanned the first 2 of at least 5 dashboards")
		expect(text).toContain("| 2 | 1 | Grafana PNG | panel type acme-flow-panel is not rendered natively |")
		expect(text).toContain("Could not be analyzed: dashboard not found")
	end)

	it("drops answers to a scan that a rescan replaced", function()
		local h = start()
		CompatState.key(h.s, char("r"), h.env)
		answer(h, "c/1/fs", S.response(S.grafana(VERSION, "frontend_settings.json")))
		expect(h.s.settings).toBeNil()
	end)

	it("does not rescan a restored block until r", function()
		local h = start(nil, { context = "other", filter = "", show_native = false })
		expect((next(h.pending))).toBeNil()
		expect(h.s.phase).toBe("idle")
		expect(h.s.context).toBe("other")
		local _, effects = CompatState.key(h.s, char("r"), h.env)
		expect(#effects).toBe(2)
	end)

	it("opens dashboards and panels natively, filters, and copies a report without URLs", function()
		local h = start()
		answer(h, "c/1/fs", S.response(S.grafana(VERSION, "frontend_settings.json")))
		answer(h, "c/1/s/1", S.body(200, json.encode({ { uid = "a", title = "Dash a", type = "dash-db" } })))
		answer(h, "c/1/d/1", S.body(200, SYNTH.a))
		-- The dashboard row, then its four non-native panels.
		expect(#h.s.rows).toBe(5)
		local _, e1 = CompatState.key(h.s, key("enter"), h.env)
		collect(h, e1)
		local _, e2 = CompatState.key(h.s, key("down"), h.env)
		collect(h, e2)
		local _, e3 = CompatState.key(h.s, key("enter"), h.env)
		collect(h, e3)
		local _, e4 = CompatState.key(h.s, char("d"), h.env)
		collect(h, e4)
		expect(h.opened).toEqual({
			Scheme.encode({ action = "dashboard", params = { context = "lab", uid = "a" }, vars = {} }),
			Scheme.encode({ action = "panel", params = { context = "lab", uid = "a", panel = "1" }, vars = {} }),
			Scheme.encode({ action = "dashboard", params = { context = "lab", uid = "a", panel = "1" }, vars = {} }),
		})
		CompatState.key(h.s, char("/"), h.env)
		for _, c in { "m", "y", "s", "q", "l" } do
			CompatState.key(h.s, char(c), h.env)
		end
		CompatState.key(h.s, key("enter"), h.env)
		expect(#h.s.rows).toBe(2)
		CompatState.key(h.s, key("escape"), h.env)
		CompatState.key(h.s, char("n"), h.env)
		expect(#h.s.rows).toBe(6)
		local _, e5 = CompatState.key(h.s, char("m"), h.env)
		collect(h, e5)
		expect(#h.copied).toBe(1)
		expect((string.find(h.copied[1], "localhost", 1, true))).toBeNil()
		expect(h.copied[1]).toContain("| P3 | 3 | timeseries | Grafana PNG | mysql queries are not run natively |  |")
		-- The header button's action (Tern itself handles an action named "copy").
		local ev: any = { ev = "action", act = "markdown" }
		local _, e6 = CompatState.update(h.s, { kind = "event", ev = ev }, h.env)
		expect((e6[1] :: any).kind).toBe("copy")
		-- The view builds over the finished report.
		local v: any = CompatView.view(h.s, h.env)
		expect(v.main ~= nil).toBe(true)
	end)
end)

return nil
