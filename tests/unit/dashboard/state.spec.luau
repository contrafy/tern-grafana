--!strict
-- The dashboard block end to end against recorded Grafana answers: what it
-- fetches and in which order (dashboard and settings, library panels,
-- variables in dependency order, then one query per native panel), which
-- rung each fixture panel lands on per Grafana version, and what the keys
-- and clicks do. Late answers to superseded requests must never overwrite
-- newer data, and nothing that opens a pane may happen in init.
local PanelState = require("../../../plugin/lib/dashboard/panel_state")
local Repeat = require("../../../plugin/lib/dashboard/repeat")
local S = require("./support")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/dashboard/state")
local View = require("../../../plugin/lib/dashboard/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function key(name: string, text: string?, shift: boolean?): any
	return { name = name, text = text, ctrl = false, alt = false, shift = shift == true, meta = false }
end

local function char(c: string): any
	return key(c, c, string.upper(c) == c and string.lower(c) ~= c)
end

type Harness = {
	s: State.State,
	env: any,
	-- Requests not answered yet, by tag.
	pending: { [string]: any },
	opened: { string },
}

local function fixtureFor(version: string, uid: string, e: any): string?
	local tag = e.tag
	if string.match(tag, "^dash/") then
		return S.grafana(version, "dashboard_" .. string.gsub(uid, "-", "_") .. ".json")
	elseif string.match(tag, "^fs/") then
		return S.grafana(version, "frontend_settings.json")
	elseif string.match(tag, "^user/") then
		return S.grafana(version, "user.json")
	elseif string.match(tag, "^lib/") then
		return S.grafana(version, "library_element.json")
	elseif string.match(tag, "^var/") then
		if e.request.path == "/api/ds/query" then
			return S.grafana(version, "ds_query_prom_instant.json")
		elseif string.find(e.request.path, "__name__", 1, true) then
			return "prometheus/3.15.0/label_values_name.json"
		end
		return S.grafana(version, "ds_proxy_prom_label_values.json")
	elseif string.match(tag, "^search/") then
		return S.grafana(version, "search.json")
	end
	return nil
end

-- Applies effects, answering loading requests from fixtures right away and
-- keeping panel queries and renders pending for the test to answer.
local function apply(h: Harness, version: string, uid: string, effects: { any })
	for _, e in effects do
		if e.kind == "open" then
			table.insert(h.opened, e.target)
		elseif e.kind == "http" then
			local path = fixtureFor(version, uid, e)
			if path then
				local _, more =
					State.update(h.s, { kind = "http_done", tag = e.tag, response = S.response(path) }, h.env)
				apply(h, version, uid, more)
			else
				h.pending[e.tag] = e
			end
		end
	end
end

local function start(version: string, link: string, solo: boolean?): (Harness, { any })
	local env = S.env()
	local s, effects
	if solo then
		s, effects = PanelState.init({ link }, nil, env)
	else
		s, effects = State.init({ link }, nil, env)
	end
	local uid = assert((Scheme.decode(link))).params.uid
	local h: Harness = { s = s, env = env, pending = {}, opened = {} }
	apply(h, version, uid, effects)
	return h, effects
end

local function pendingKinds(h: Harness, prefix: string): { string }
	local out: { string } = {}
	for tag in h.pending do
		if string.sub(tag, 1, #prefix) == prefix then
			table.insert(out, (string.gsub(tag, "^q/%d+/%d+/", "")))
		end
	end
	table.sort(out)
	return out
end

local function press(h: Harness, version: string, k: any): (boolean, { any })
	local _, effects, changed = State.key(h.s, k, h.env)
	apply(h, version, h.s.uid or "", effects)
	return changed, effects
end

local function modes(h: Harness): { [string]: string }
	local out: { [string]: string } = {}
	for _, k in h.s.order do
		local inst = assert(Repeat.find(h.s.sections, k))
		out[tostring(inst.panel.id)] = h.s.panels[k].decision.mode
	end
	return out
end

-- Every text span and markdown text in a view tree, joined.
local function flatten(node: any, out: { string }?): string
	local acc = out or {}
	if type(node) == "table" then
		local p = node.p
		if type(p) == "table" then
			if type(p.text) == "string" then
				table.insert(acc, p.text)
			end
			if type(p.spans) == "table" then
				for _, sp in p.spans do
					if type(sp) == "table" and type(sp.t) == "string" then
						table.insert(acc, sp.t)
					end
				end
			end
		end
		for _, c in node.c or {} do
			flatten(c, acc)
		end
	end
	return table.concat(acc, "\n")
end

-- The ids Tern gives the nodes of a region (docs: guides/blocks, "Regions,
-- node ids and keys"): the root is the region name, each child
-- `<parent id>.<key or 0-based index>`. Returns id -> node.
local function ids(region: string, root: any): { [string]: any }
	local out: { [string]: any } = {}
	local function walk(node: any, id: string)
		out[id] = node
		for i, c in node.c or {} do
			local k = c.p and c.p.key
			walk(c, id .. "." .. (if k ~= nil then tostring(k) else tostring(i - 1)))
		end
	end
	walk(root, region)
	return out
end

local PANELS = "tern-grafana://dashboard?context=lab&uid=tern-panels"

for _, version in S.VERSIONS do
	local renderer = version == "12.4.12"

	describe("dashboard block loading tern-panels on Grafana " .. version, function()
		it("only fetches in init: the dashboard, Grafana's settings and the signed-in user", function()
			local env = S.env()
			local s, effects = State.init({ PANELS }, nil, env)
			expect(s.phase).toBe("loading")
			local paths = {}
			for _, e in effects do
				expect(e.kind).toBe("http")
				table.insert(paths, (e :: any).request.path)
			end
			expect(paths).toEqual({ "/api/dashboards/uid/tern-panels", "/api/frontend/settings", "/api/user" })
		end)

		it("puts each fixture panel on its rung: native, or PNG with a renderer, else browser", function()
			local h = start(version, PANELS)
			expect(h.s.phase).toBe("ready")
			local other = if renderer then "png" else "browser"
			expect(modes(h)).toEqual({
				["2"] = "native",
				["3"] = "native",
				["4"] = "native",
				["5"] = "native",
				["6"] = "native",
				["7"] = "native",
				["8"] = "native",
				["9"] = "native",
				["10"] = "native",
				["12"] = "native",
				["13"] = other,
				["14"] = other,
				-- The library panel, resolved to its bar gauge.
				["18"] = "native",
			})
			local heat = h.s.panels.p13.decision.reason :: string
			expect(string.find(heat, "heatmap", 1, true) ~= nil).toBe(true)
			if not renderer then
				expect(string.find(heat, "Grafana has no image renderer", 1, true) ~= nil).toBe(true)
			end
		end)

		it("queries every visible native panel once, skipping text and collapsed rows", function()
			local h = start(version, PANELS)
			expect(pendingKinds(h, "q/")).toEqual({ "p12", "p18", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9" })
			-- Grafana's renderer takes one render at a time (it answers 429 to bursts).
			local renders = pendingKinds(h, "png/")
			expect(#renders).toBe(if renderer then 1 else 0)
		end)

		it("shows query results and drops an answer to a superseded query", function()
			local h = start(version, PANELS)
			local tag = "q/1/1/p2"
			expect(h.pending[tag] ~= nil).toBe(true)
			-- A range key re-sends every query with a new generation.
			press(h, version, char("3"))
			expect(h.s.from).toBe("now-1h")
			expect(h.pending["q/1/2/p2"] ~= nil).toBe(true)
			local ok = S.response(S.grafana(version, "ds_query_prom_range.json"))
			State.update(h.s, { kind = "http_done", tag = tag, response = ok }, h.env)
			expect(h.s.panels.p2.data).toBeNil()
			State.update(h.s, { kind = "http_done", tag = "q/1/2/p2", response = ok }, h.env)
			expect(h.s.panels.p2.status).toBe("ready")
			expect(#(h.s.panels.p2.data :: any).frames > 0).toBe(true)
			local view = View.view(h.s, h.env) :: any
			expect(view.main ~= nil).toBe(true)
		end)

		it("collapses and expands a row by clicking its header", function()
			local h = start(version, PANELS)
			local _, effects =
				State.update(h.s, { kind = "event", ev = { ev = "action", act = "row", value = "r15" } }, h.env)
			apply(h, version, "tern-panels", effects)
			expect(table.find(h.s.order, "p16") ~= nil).toBe(true)
			-- Expanding a row queries the panels it hid.
			expect(h.pending["q/1/1/p16"] ~= nil).toBe(true)
			State.update(h.s, { kind = "event", ev = { ev = "action", act = "row", value = "r11" } }, h.env)
			expect(table.find(h.s.order, "p12")).toBeNil()
		end)
	end)

	describe("dashboard block keys on Grafana " .. version, function()
		it("moves focus by grid geometry and expands the focused panel", function()
			local h = start(version, PANELS)
			expect(h.s.focus).toBe("p2")
			press(h, version, key("down"))
			expect(h.s.focus).toBe("p4")
			press(h, version, key("right"))
			expect(h.s.focus).toBe("p5")
			press(h, version, key("enter"))
			expect(h.s.expanded).toBe(true)
			expect(Scheme.encode(assert(State.link(h.s)))).toBe(
				"tern-grafana://dashboard?context=lab&from=now-1h&panel=5&to=now&uid=tern-panels"
			)
			press(h, version, key("escape"))
			expect(h.s.expanded).toBe(false)
		end)

		it("toggles labels on the focused logs panel with l", function()
			local h = start(version, PANELS)
			h.s.focus = "p12"
			local tag = ""
			for k in h.pending do
				if string.match(k, "/p12$") then
					tag = k
				end
			end
			expect(tag ~= "").toBe(true)
			State.update(h.s, {
				kind = "http_done",
				tag = tag,
				response = S.response(S.grafana(version, "ds_query_loki_logs.json")),
			}, h.env)
			local before = flatten((View.view(h.s, h.env) :: any).main)
			expect((press(h, version, char("l")))).toBe(true)
			expect(h.s.labels.p12).toBe(true)
			local after = flatten((View.view(h.s, h.env) :: any).main)
			expect(before == after).toBe(false)
			press(h, version, char("l"))
			expect(h.s.labels.p12).toBe(false)
			-- Not a logs panel: l does nothing.
			h.s.focus = "p2"
			expect((press(h, version, char("l")))).toBe(false)
		end)

		it("scrolls the newly focused card into view, by the id Tern gives it", function()
			local h = start(version, PANELS)
			local view = View.view(h.s, h.env) :: any
			local nodes = ids("main", view.main)
			local _, effects = press(h, version, key("down"))
			expect(h.s.focus).toBe("p4")
			local reveal: any = nil
			for _, e in effects do
				if e.kind == "reveal" then
					reveal = e
				end
			end
			expect(reveal ~= nil).toBe(true)
			local card = nodes[reveal.id]
			expect(card ~= nil and card.k).toBe("card")
			expect(card.p.key).toBe("p4")
			-- Grid cards are cut at Grafana's panel height: 8 rows.
			expect(card.p.max).toEqual({ h = "20lines" })
			-- A key that does not move focus scrolls nothing.
			local _, none = press(h, version, char("r"))
			for _, e in none do
				expect(e.kind == "reveal").toBe(false)
			end
		end)

		it("pins the focused panel as a panel block and opens solo pages in the browser pane", function()
			local h = start(version, PANELS)
			press(h, version, char("p"))
			expect(h.opened[1]).toBe("tern-grafana://panel?context=lab&from=now-1h&panel=2&to=now&uid=tern-panels")
			press(h, version, char("o"))
			local browse = assert((Scheme.decode(h.opened[2])), "the browse link must decode")
			expect(browse.action).toBe("browse")
			expect(browse.params.url).toBe(
				"http://localhost:3000/d-solo/tern-panels/tern-panels?orgId=1&panelId=2&from=now-1h&to=now"
			)
		end)

		it("saves a link that restores the same view without fetching anything else", function()
			local h = start(version, PANELS)
			press(h, version, char("6"))
			local saved = State.save(h.s)
			expect(saved.link).toBe("tern-grafana://dashboard?context=lab&from=now-12h&to=now&uid=tern-panels")
			local again, effects = State.init({}, saved, S.env())
			expect(again.from).toBe("now-12h")
			expect(#effects).toBe(3)
		end)

		it("re-runs every panel on r and keeps auto-refresh at the dashboard's 30s", function()
			local h = start(version, PANELS)
			expect(h.s.refresh_ms).toBe(30000)
			press(h, version, char("r"))
			expect(h.pending["q/1/2/p2"] ~= nil).toBe(true)
		end)
	end)

	describe("dashboard block variables on Grafana " .. version, function()
		local VARS = "tern-grafana://dashboard?context=lab&uid=tern-variables&var-mode=idle"

		it("loads variables in dependency order, then repeats panels per job", function()
			local h = start(version, VARS)
			local job = h.s.vars[2]
			expect(job.name).toBe("job")
			expect(job.values).toEqual({ "$__all" })
			expect(h.s.vars[6].values).toEqual({ "idle" })
			local q = pendingKinds(h, "q/")
			expect(table.find(q, "p3.5") ~= nil).toBe(true)
			expect(table.find(q, "r5.1/p6") ~= nil).toBe(true)
			local body = json.decode(h.pending["q/1/1/p1"].request.body)
			expect(body.queries[1].expr).toBe(
				'sum by (mode) (rate(node_cpu_seconds_total{mode=~"idle", instance=~".*"}[1m]))'
			)
		end)

		it("re-queries only the panels a picked variable changes", function()
			local h = start(version, VARS)
			h.pending = {}
			State.update(h.s, { kind = "event", ev = { ev = "action", act = "var", value = "handler" } }, h.env)
			expect(h.s.picker and h.s.picker.kind).toBe("var")
			for _ = 1, #"/api/v1/.*" do
				press(h, version, key("backspace"))
			end
			for c in string.gmatch("/metrics", ".") do
				press(h, version, key(c, c))
			end
			press(h, version, key("enter"))
			expect(h.s.picker).toBeNil()
			expect(pendingKinds(h, "q/")).toEqual({ "p2" })
		end)

		-- As in Grafana, a custom all value is used raw unless the text format is asked for.
		it("interpolates variables into a text panel's content", function()
			local h = start(version, VARS)
			local d = assert(h.s.dashboard, "the dashboard must load")
			local json_: { [string]: any } = {
				id = 99,
				type = "text",
				title = "Notes",
				gridPos = { x = 0, y = 40, w = 24, h = 4 },
				options = { mode = "markdown", content = "Mode ${mode} for ${job:text} ($job) via ${ds:text}" },
			}
			table.insert(d.sections[1].panels, {
				id = 99,
				type = "text",
				title = "Notes",
				grid = { x = 0, y = 40, w = 24, h = 4 },
				json = json_,
			})
			press(h, version, char("r"))
			local view = View.view(h.s, h.env) :: any
			local text = flatten(view.main)
			expect(string.find(text, "Mode idle for All (.*) via Prometheus 3", 1, true) ~= nil).toBe(true)
		end)

		it("toggles values of a multi-value variable and applies them on enter", function()
			local h = start(version, VARS)
			State.update(h.s, { kind = "event", ev = { ev = "action", act = "var", value = "mode" } }, h.env)
			State.update(h.s, { kind = "event", ev = { ev = "select", item = "user" } }, h.env)
			State.update(h.s, { kind = "event", ev = { ev = "select", item = "system" } }, h.env)
			press(h, version, key("enter"))
			expect(h.s.vars[6].values).toEqual({ "idle", "user", "system" })
			local view = View.view(h.s, h.env) :: any
			expect(view.layer).toBeNil()
		end)
	end)

	describe("panel block on Grafana " .. version, function()
		it("shows and queries only its panel, with the copy's repeat value", function()
			local h = start(
				version,
				"tern-grafana://panel?context=lab&uid=tern-variables&panel=3&var-job=node&var-mode=idle",
				true
			)
			expect(h.s.order).toEqual({ "p3" })
			expect(pendingKinds(h, "q/")).toEqual({ "p3" })
			expect(State.title(h.s)).toBe("up for node")
			expect(State.save(h.s).link).toBe(
				"tern-grafana://panel?context=lab&from=now-30m&panel=3&to=now&uid=tern-variables&var-ds=prom3&var-handler=%2Fapi%2Fv1%2F.%2A&var-instance=%24__all&var-job=node&var-metric=Buffers&var-mode=idle&var-step=1m&var-topjob=alertmanager"
			)
		end)

		it("needs a panel id", function()
			local s = PanelState.init({ "tern-grafana://dashboard?context=lab&uid=tern-panels" }, nil, S.env())
			expect(s.phase).toBe("error")
		end)
	end)

	if renderer then
		describe("dashboard block PNG rung on Grafana " .. version, function()
			it("renders one panel at a time and backs off when the renderer is busy", function()
				local h = start(version, PANELS)
				local first = assert(pendingKinds(h, "png/")[1], "a render must be pending")
				local tag1 = "png/1/1"
				expect(first).toBe(tag1)
				local _, effects = State.update(h.s, {
					kind = "http_done",
					tag = tag1,
					response = S.body(429, "Too many requests"),
				}, h.env)
				local timer: any = nil
				for _, e in effects do
					expect(e.kind == "http").toBe(false)
					if e.kind == "timer" then
						timer = e
					end
				end
				expect(timer and timer.ms).toBe(State.PNG_BACKOFF_MS)
				-- No error shown for a busy renderer: the panel keeps its placeholder.
				expect(State.pngError(h.s, h.s.panels.p13)).toBeNil()
				local _, retry = State.update(h.s, { kind = "tick", tag = timer.tag }, h.env)
				expect(#retry).toBe(1)
				expect((retry[1] :: any).request.path).toBe("/render/d-solo/tern-panels/tern-panels")
				-- A finished render lets the next panel's render go out.
				local _, next_ = State.update(h.s, {
					kind = "http_done",
					tag = (retry[1] :: any).tag,
					response = S.response(S.grafana(version, "render_d_solo.png")),
				}, h.env)
				expect(#next_).toBe(1)
				expect((next_[1] :: any).kind).toBe("http")
				-- A hard failure is shown and not retried until the next refresh.
				local _, after = State.update(h.s, {
					kind = "http_done",
					tag = (next_[1] :: any).tag,
					response = S.body(500, "{}"),
				}, h.env)
				expect(#after).toBe(0)
				local failed = 0
				for _, k in { "p13", "p14" } do
					if State.pngError(h.s, h.s.panels[k]) then
						failed += 1
					end
				end
				expect(failed).toBe(1)
			end)

			it("caches the render and draws it as an image asset", function()
				local h = start(version, PANELS)
				local tag: string? = nil
				for k in h.pending do
					if string.sub(k, 1, 4) == "png/" then
						tag = k
					end
				end
				assert(tag, "a render must be pending")
				State.update(
					h.s,
					{ kind = "http_done", tag = tag, response = S.response(S.grafana(version, "render_d_solo.png")) },
					h.env
				)
				local _, assets = View.view(h.s, h.env)
				local found = false
				for k, a in assets :: any do
					if string.sub(k, 1, 4) == "png/" then
						found = true
						expect(a.mime).toBe("image/png")
					end
				end
				expect(found).toBe(true)
			end)
		end)
	end
end

describe("dashboard block search and errors", function()
	it("opens a search picker without a uid and loads the picked dashboard", function()
		local env = S.env()
		local s, effects = State.init({}, nil, env)
		expect(s.phase).toBe("search")
		expect((effects[1] :: any).request.path).toBe("/api/search")
		State.update(s, {
			kind = "http_done",
			tag = (effects[1] :: any).tag,
			response = S.response(S.grafana("12.4.12", "search.json")),
		}, env)
		local titles = {}
		for _, item in State.pickerItems(s) do
			table.insert(titles, item.label)
		end
		expect(table.find(titles, "Tern Panels") ~= nil).toBe(true)
		local _, more = State.update(s, { kind = "event", ev = { ev = "select", item = "tern-variables" } }, env)
		expect(s.uid).toBe("tern-variables")
		expect((more[1] :: any).request.path).toBe("/api/dashboards/uid/tern-variables")
	end)

	it("shows a missing dashboard as an error", function()
		local env = S.env()
		local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=tern-no-such-dashboard" }, nil, env)
		State.update(s, {
			kind = "http_done",
			tag = (effects[1] :: any).tag,
			response = S.response(S.grafana("12.4.12", "dashboard_missing.json"), 404),
		}, env)
		expect(s.phase).toBe("error")
		expect(s.error).toBe("dashboard not found")
	end)

	it("explains a missing config instead of failing", function()
		local s = State.init({ PANELS }, nil, S.env(false))
		expect(s.phase).toBe("error")
		expect(string.find(s.error or "", "config", 1, true) ~= nil).toBe(true)
	end)
end)

return nil
