--!strict
-- Public dashboards (grafana.com 9578 Alertmanager, the Alertmanager mixin's
-- overview, 11074) on the dashboard chrome Grafana draws around panels,
-- reproduced by dev dashboard tern-pub-chrome (schema 18: legacy string
-- datasource references): repeated panels side by side end up one under
-- the other's copies, annotation layers whose datasource is "$ds" or a
-- datasource name still draw, layers get switches next to the variables,
-- panel links sit behind an icon, a failed query is a header icon over
-- "No data", and an empty panel says "No data" the way PanelDataErrorView
-- does. Without these a public dashboard reads in a different order, loses
-- its restart markers or shows a URL where Grafana shows an icon.
local Common = require("../../../plugin/lib/panels/common")
local Repeat = require("../../../plugin/lib/dashboard/repeat")
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local View = require("../../../plugin/lib/dashboard/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Harness = S.Harness

local LINK = "tern-grafana://dashboard?context=lab&uid=tern-pub-chrome"

local function start(version: string, saved: any?): Harness
	local env = S.env()
	local s, effects = State.init({ LINK }, saved, env)
	local h = S.harness(s, env, function(e: any): any
		local tag = e.tag
		local path = if string.match(tag, "^dash/")
			then "dashboard_tern_pub_chrome.json"
			elseif string.match(tag, "^fs/") then "frontend_settings.json"
			elseif string.match(tag, "^flag/") then "ofrep_table_auto_column_widths.json"
			elseif string.match(tag, "^user/") then "user.json"
			else nil
		return if path then S.response(S.grafana(version, path)) else nil
	end)
	S.drive(h, effects)
	return h
end

local function pending(h: Harness, prefix: string): { any }
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

local function find(node: any, pred: (any) -> boolean): any
	if type(node) ~= "table" then
		return nil
	end
	if pred(node) then
		return node
	end
	for _, c in node.c or {} do
		local hit = find(c, pred)
		if hit then
			return hit
		end
	end
	return nil
end

local function text(node: any, out: { string }?): string
	local acc = out or {}
	if type(node) == "table" then
		local p = node.p
		if type(p) == "table" then
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
			text(c, acc)
		end
	end
	return table.concat(acc)
end

-- The Prometheus expressions of the annotation layer requests in flight.
local function layerExprs(h: Harness): { string }
	local out: { string } = {}
	for _, e in pending(h, "layer/") do
		if e.request.path == "/api/ds/query" then
			local q = json.decode(e.request.body).queries[1]
			expect(q.datasource.uid).toBe("prom3")
			expect(q.datasource.type).toBe("prometheus")
			table.insert(out, q.expr)
		end
	end
	table.sort(out)
	return out
end

local function card(h: Harness, key: string): any
	local view = View.view(h.s, h.env) :: any
	local node = find(view.main, function(n)
		return n.p and n.p.key == key and (n.k == "card" or n.k == "el")
	end)
	return (assert(node, key))
end

-- A UI action; only the requests it sends stay pending.
local function act(h: Harness, name: string, value: string): { any }
	h.pending = {}
	local _, effects = State.update(h.s, { kind = "event", ev = { ev = "action", act = name, value = value } }, h.env)
	S.drive(h, effects)
	return effects
end

for _, version in S.VERSIONS do
	describe("tern-pub-chrome on Grafana " .. version, function()
		-- DashboardGridItem: a horizontal repeat is a full-width item, so
		-- the panel beside it (same y) compacts below all of its copies.
		it("places every copy of a repeated panel before the panel beside it", function()
			local h = start(version)
			local rows: { string } = {}
			for _, inst in h.s.sections[1].panels do
				local g = inst.panel.grid
				table.insert(rows, string.format("%s %g %g %g", inst.key, g.x, g.y, g.w))
			end
			-- integration: All of 5 values, 4 per line, 7 rows each.
			expect(rows).toEqual({
				"p1 0 0 6",
				"p1.1 6 0 6",
				"p1.2 12 0 6",
				"p1.3 18 0 6",
				"p1.4 0 7 6",
				"p2 0 14 6",
				"p2.1 6 14 6",
				"p2.2 12 14 6",
				"p2.3 18 14 6",
				"p2.4 0 21 6",
				"p3 0 28 12",
				"p4 12 28 6",
				"p5 18 28 6",
				"p6 12 32 12",
			})
			expect(Repeat.find(h.s.sections, "p2.4") ~= nil).toBe(true)
		end)

		-- DashboardMigrator schema 36 + the datasource service: "$ds" is the
		-- datasource variable's Prometheus, "Prometheus 3" a name.
		it("runs annotation layers with variable and name datasource references", function()
			local h = start(version)
			expect(layerExprs(h)).toEqual({ "(minute() % 15 == bool 0) > 0" })
			-- The disabled Deploys layer has a switch; turning it on runs it.
			act(h, "layer", "Deploys")
			expect(layerExprs(h)).toEqual({ "(minute() % 15 == bool 0) > 0", "(minute() % 20 == bool 5) > 0" })
			expect(h.s.layer_on.Deploys).toBe(true)
		end)

		it("shows a switch per visible layer in the variable bar and keeps it with the block", function()
			local h = start(version)
			local view = View.view(h.s, h.env) :: any
			local vars = assert(find(view.main, function(n)
				return n.p and n.p.key == "vars"
			end))
			-- The built-in layer is hidden (hide: true): no switch.
			expect(find(vars, function(n)
				return n.p and n.p.key == "a.Annotations & Alerts"
			end)).toBe(nil)
			local restarts = assert(find(vars, function(n)
				return n.p and n.p.key == "a.Restarts"
			end))
			expect(text(restarts)).toBe("Restarts " .. View.SWITCH_ON)
			expect(restarts.p.actions.click).toBe("layer=Restarts")
			act(h, "layer", "Restarts")
			expect(#layerExprs(h)).toBe(0)
			local saved = State.save(h.s)
			expect(saved.layers.Restarts).toBe(false)
			-- A restored block keeps the layer off.
			local again = start(version, json.decode(json.encode(saved)))
			expect(#layerExprs(again)).toBe(0)
			-- The variables picker lists the switches too.
			again.s.picker = { kind = "vars", query = "" }
			local found = false
			for _, item in State.pickerItems(again.s) do
				if item.id == "layer:Restarts" then
					found = true
					expect(item.detail).toBe("annotations off")
				end
			end
			expect(found).toBe(true)
		end)

		-- VizPanelLinks: an external-link icon; one link opens on click,
		-- several open a menu of them.
		it("puts panel links behind a header icon", function()
			local h = start(version)
			local c = card(h, "p3")
			local link = assert(find(c, function(n)
				return n.p and n.p.class == "tgp2-links"
			end))
			expect(text(link)).toBe(View.LINK_GLYPH)
			expect((string.find(text(c), "grafana.com", 1, true))).toBe(nil)
			expect(link.p.actions.click).toBe("plinks=p3")
			act(h, "plinks", "p3")
			local items = State.pickerItems(h.s)
			expect(#items).toBe(2)
			expect(items[1].label).toBe("Runbook")
			local _, effects: any = State.update(h.s, { kind = "event", ev = { ev = "select", item = "1" } }, h.env)
			expect(h.s.picker).toBe(nil)
			expect(effects[1].kind).toBe("open")
		end)

		-- PanelChrome's PanelStatus: the error is an icon in the header with
		-- the message on hover, the body PanelDataErrorView's "No data";
		-- the focused card and the expanded panel spell the message out.
		it("shows a failed query as a header icon over No data", function()
			local h = start(version)
			local q: any = nil
			for _, e in pending(h, "q/") do
				if string.match(e.tag, "/p6$") then
					q = e
				end
			end
			assert(q, "panel 6 query")
			local _, more = State.update(h.s, {
				kind = "http_done",
				tag = q.tag,
				response = S.response(S.grafana(version, "ds_query_prom_error.json")),
			}, h.env)
			S.drive(h, more)
			h.s.focus = "p1"
			local c = card(h, "p6")
			local icon = assert(find(c, function(n)
				return n.p and n.p.class == "tgp2-err"
			end))
			expect(text(icon)).toBe(View.ERROR_GLYPH)
			expect(#icon.p.title > 0).toBe(true)
			local body = assert(find(c, function(n)
				return n.p and n.p.key == "body"
			end))
			expect((string.find(text(body), icon.p.title, 1, true))).toBe(nil)
			expect(find(body, function(n)
				return n.p and n.p.class == "tg-nodata"
			end) ~= nil).toBe(true)
			h.s.focus = "p6"
			expect(string.find(text(card(h, "p6")), icon.p.title, 1, true) ~= nil).toBe(true)
		end)

		-- The block's width in cells (cx.cols, updated on resize) is the
		-- dashboard width: a wider pane redraws the chart wider, not padded.
		it("redraws native panels for the pane's width", function()
			local h = start(version)
			for _, e in pending(h, "q/") do
				if string.match(e.tag, "/p3$") then
					local _, more = State.update(h.s, {
						kind = "http_done",
						tag = e.tag,
						response = S.response(S.grafana(version, "ds_query_prom_range.json")),
					}, h.env)
					S.drive(h, more)
				end
			end
			local function width(): number
				local image = find(card(h, "p3"), function(n)
					return n.k == "image" and type(n.p.w) == "number"
				end)
				return assert(image, "p3 chart").p.w
			end
			local narrow = width()
			h.env.cols = 234
			expect(width() > narrow).toBe(true)
		end)
	end)
end

describe("PanelDataErrorView", function()
	it("centers the field defaults' noValue, else No data", function()
		local env = S.env()
		local n = Common.noData({}, env, "k") :: any
		expect(n.p.class).toBe("tg-nodata")
		expect(text(n)).toBe("No data")
		expect(text(Common.noData({ fieldConfig = { defaults = { noValue = "-" } } }, env, "k"))).toBe("-")
	end)
end)

return nil
