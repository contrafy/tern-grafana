--!strict
-- The dashboard block driving panel modules (local://PANELS2.md contract):
-- modules that need no query never query, module requests go to the
-- dashboard's Grafana or to the external URL without credentials and their
-- parsed answers reach the view, live panels share one timer that redraws
-- without querying, and panel time overrides change the query range and
-- the header like Grafana's panel chrome. Metadata (description, links,
-- transparent) shows as Grafana shows it.
local Registry = require("../../../plugin/lib/panels/registry")
local Repeat = require("../../../plugin/lib/dashboard/repeat")
local S = require("./support")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/dashboard/state")
local View = require("../../../plugin/lib/dashboard/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local ui = require("../../../plugin/lib/ui")
local describe, it, expect = t.describe, t.it, t.expect

-- A live panel without queries that fetches a Grafana API and a feed.
Registry.register({
	types = { "tern-test-live" },
	supports = function(_: any, _: any): (boolean, string?)
		return true, nil
	end,
	queries = function(_: any): boolean
		return false
	end,
	requests = function(_: any, ctx: any, _: any): { any }
		return {
			{
				tag = "starred",
				signal = "dashboards",
				request = { method = "GET", path = "/api/search", query = { { "starred", "true" } } },
			},
			{
				tag = "feed",
				signal = "external",
				request = { method = "GET", path = "https://example.com/feed.xml?from=" .. ctx.time.from_ms },
			},
		}
	end,
	parse = function(_: any, tag: string, response: any, _: any): any
		return tag .. ":" .. tostring(#response.body)
	end,
	liveMs = function(_: any, _: any): number?
		return 1000
	end,
	view = function(_: any, _: { any }, env: any, opts: any): (any, any)
		local extra = opts.extra or {}
		return ui.text({
			ui.span(
				string.format("now=%d starred=%s feed=%s", env.now_ms, tostring(extra.starred), tostring(extra.feed))
			),
		}, { key = opts.key }),
			nil
	end,
})

type Harness = { s: State.State, env: any, pending: { [string]: any }, opened: { string } }

local function answer(version: string, e: any): string?
	local tag = e.tag
	if string.match(tag, "^dash/") then
		return S.grafana(version, "dashboard_tern_panels.json")
	elseif string.match(tag, "^fs/") then
		return S.grafana(version, "frontend_settings.json")
	elseif string.match(tag, "^user/") then
		return S.grafana(version, "user.json")
	elseif string.match(tag, "^lib/") then
		return S.grafana(version, "library_element.json")
	elseif string.match(tag, "^var/") then
		return S.grafana(version, "ds_proxy_prom_label_values.json")
	end
	return nil
end

local function apply(h: Harness, version: string, effects: { any })
	for _, e in effects do
		if e.kind == "open" then
			table.insert(h.opened, e.target)
		elseif e.kind == "http" or e.kind == "timer" then
			local path = if e.kind == "http" then answer(version, e) else nil
			if path then
				local _, more =
					State.update(h.s, { kind = "http_done", tag = e.tag, response = S.response(path) }, h.env)
				apply(h, version, more)
			else
				h.pending[e.tag] = e
			end
		end
	end
end

local LINK = "tern-grafana://dashboard?context=lab&uid=tern-panels"

-- Loads tern-panels with `edit` applied to the dashboard model first (panel
-- JSON by id), then re-plans the panels.
local function start(version: string, edit: (panels: { [number]: any }) -> ()): Harness
	local env = S.env()
	local s, effects = State.init({ LINK }, nil, env)
	local h: Harness = { s = s, env = env, pending = {}, opened = {} }
	apply(h, version, effects)
	local byId: { [number]: any } = {}
	for _, sec in (h.s.dashboard :: any).sections do
		for _, p in sec.panels do
			byId[p.id] = p
		end
	end
	edit(byId)
	h.pending = {}
	local _, more = State.update(
		h.s,
		{ kind = "key", key = { name = "r", text = "r", ctrl = false, alt = false, shift = false, meta = false } } :: any,
		h.env
	)
	apply(h, version, more)
	return h
end

local function pendingWith(h: Harness, prefix: string): { any }
	local out = {}
	for tag, e in h.pending do
		if string.sub(tag, 1, #prefix) == prefix then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b)
		return a.tag < b.tag
	end)
	return out
end

local function flatten(node: any, out: { string }?): string
	local acc = out or {}
	if type(node) == "table" then
		local p = node.p
		if type(p) == "table" then
			if type(p.text) == "string" then
				table.insert(acc, p.text)
			end
			for _, field in { p.spans, p.head } do
				if type(field) == "table" then
					for _, sp in field do
						if type(sp) == "table" and type(sp.t) == "string" then
							table.insert(acc, sp.t)
						end
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

local function findNode(node: any, pred: (any) -> boolean): any
	if type(node) ~= "table" then
		return nil
	end
	if pred(node) then
		return node
	end
	for _, c in node.c or {} do
		local hit = findNode(c, pred)
		if hit then
			return hit
		end
	end
	return nil
end

local function toLive(p: any)
	p.type = "tern-test-live"
	p.json.type = "tern-test-live"
end

for _, version in S.VERSIONS do
	describe("dashboard panel modules on Grafana " .. version, function()
		it("never queries a module without queries and sends its requests by signal", function()
			local h = start(version, function(panels)
				toLive(panels[10])
			end)
			expect(h.s.panels.p10.decision.mode).toBe("native")
			expect(#pendingWith(h, "q/1/") > 0).toBe(true)
			for _, e in pendingWith(h, "q/") do
				expect(string.find(e.tag, "/p10$") == nil).toBe(true)
			end
			local reqs = pendingWith(h, "x/")
			expect(#reqs).toBe(2)
			local grafana, feed = reqs[1], reqs[2]
			expect(grafana.route.via).toBe("grafana")
			expect(grafana.route.endpoint.url).toBe("http://localhost:3000")
			expect(grafana.request.path).toBe("/api/search")
			-- External: the feed's own origin, no credentials, no Grafana org.
			expect(feed.route.endpoint.url).toBe("https://example.com")
			expect(feed.route.endpoint.auth.type).toBe("none")
			expect(string.match(feed.request.path, "^/feed%.xml%?from=%d+$") ~= nil).toBe(true)
		end)

		it("hands parsed answers to the view as opts.extra", function()
			local h = start(version, function(panels)
				toLive(panels[10])
			end)
			for _, e in pendingWith(h, "x/") do
				State.update(h.s, { kind = "http_done", tag = e.tag, response = S.body(200, "abc") }, h.env)
			end
			local view = View.view(h.s, h.env) :: any
			local text = flatten(view.main)
			expect(string.find(text, "starred=starred:3 feed=feed:3", 1, true) ~= nil).toBe(true)
		end)

		it("redraws live panels on one timer without querying again", function()
			local h = start(version, function(panels)
				toLive(panels[10])
			end)
			local timers = pendingWith(h, "live/")
			expect(#timers).toBe(1)
			local tick = timers[1]
			expect(tick.ms).toBe(1000 - h.env.now_ms % 1000)
			local before = flatten((View.view(h.s, h.env) :: any).main)
			h.env.now_ms += 1000
			local _, effects: any = State.update(h.s, { kind = "tick", tag = tick.tag }, h.env)
			expect(#effects).toBe(1)
			expect(effects[1].kind).toBe("timer")
			expect(effects[1].tag).toBe(tick.tag)
			local after = flatten((View.view(h.s, h.env) :: any).main)
			expect(before ~= after).toBe(true)
			expect(string.find(after, "now=" .. tostring(h.env.now_ms), 1, true) ~= nil).toBe(true)
			-- Expanding another panel leaves no live panel on screen.
			State.update(h.s, { kind = "event", ev = { ev = "action", act = "expand", value = "p2" } }, h.env)
			expect(h.s.live_ms).toBeNil()
			local _, stale = State.update(h.s, { kind = "tick", tag = tick.tag }, h.env)
			expect(#stale).toBe(0)
		end)

		it("queries a panel over its timeFrom/timeShift range and shows the override", function()
			local h = start(version, function(panels)
				panels[2].json.timeFrom = "1h"
				panels[2].json.timeShift = "1h"
			end)
			local q = h.pending["q/1/2/p2"] or h.pending["q/1/1/p2"]
			assert(q, "panel 2 query")
			local body = json.decode(q.request.body)
			expect(body.from).toBe(tostring(S.NOW_MS - 2 * 3600000))
			expect(body.to).toBe(tostring(S.NOW_MS - 3600000))
			local view = View.view(h.s, h.env) :: any
			expect(string.find(flatten(view.main), "Last 1 hour timeshift -1h", 1, true) ~= nil).toBe(true)
		end)

		it("shows the description behind an info marker, links as chips, transparent without a card", function()
			local h = start(version, function(panels)
				panels[2].json.description = "What $job means"
				panels[2].json.links = { { title = "Runbook", url = "/d/abc?${__url_time_range}" } }
				panels[2].json.transparent = true
			end)
			local view = View.view(h.s, h.env) :: any
			local card = findNode(view.main, function(n)
				return n.p and n.p.key == "p2"
			end)
			expect(card.k).toBe("el")
			expect(card.p.class).toBe("tgp2-plain tgp2-sel")
			local info = findNode(card, function(n)
				return n.p and n.p.class == "tgp2-info"
			end)
			expect(string.sub(info.p.title, 1, 5)).toBe("What ")
			local link = findNode(card, function(n)
				return n.p and n.p.class == "tgp2-link"
			end)
			expect(flatten(link)).toBe("Runbook")
			local _, effects: any =
				State.update(h.s, { kind = "event", ev = { ev = "action", act = "plink", value = "1:p2" } }, h.env)
			local target = assert(Scheme.decode(effects[1].target))
			expect(target.params.url).toBe("http://localhost:3000/d/abc?from=now-1h&to=now")
			-- The expanded panel shows the description in full.
			State.update(h.s, { kind = "event", ev = { ev = "action", act = "expand", value = "p2" } }, h.env)
			local single = View.view(h.s, h.env) :: any
			local md = findNode(single.main, function(n)
				return n.k == "md"
			end)
			expect(string.sub(md.p.text, 1, 5)).toBe("What ")
			expect(Repeat.find(h.s.sections, "p2") ~= nil).toBe(true)
		end)
	end)
end

return nil
