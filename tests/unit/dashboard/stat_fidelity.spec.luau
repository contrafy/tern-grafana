--!strict
-- tern-stat-fidelity in the dashboard block: Grafana draws an untitled panel
-- without a header (no "Panel N"), and its stats name their field instead;
-- a short stat's value stays readable inside its height-capped card.
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local Stat = require("../../../plugin/lib/panels/stat")
local View = require("../../../plugin/lib/dashboard/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Harness = S.Harness

local function fixtureFor(version: string, tag: string): string?
	if string.match(tag, "^dash/") then
		return S.grafana(version, "dashboard_tern_stat_fidelity.json")
	elseif string.match(tag, "^fs/") then
		return S.grafana(version, "frontend_settings.json")
	elseif string.match(tag, "^user/") then
		return S.grafana(version, "user.json")
	end
	local id = tonumber(string.match(tag, "^q/%d+/%d+/p(%d+)$"))
	if id then
		-- Variants (id >= 100) answer with their source panel's query.
		return S.grafana(version, "ds_query_stat_fidelity_" .. (if id >= 100 then id // 100 else id) .. ".json")
	end
	return nil
end

-- `edit` rewrites the dashboard JSON before the block gets it.
local function start(version: string, edit: ((dashboard: any) -> ())?): Harness
	local env = S.env()
	local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=tern-stat-fidelity" }, nil, env)
	local h = S.harness(s, env, function(e: any): any
		local path = fixtureFor(version, e.tag)
		if path and edit and string.match(e.tag, "^dash/") then
			local doc = S.doc(path)
			edit(doc.dashboard)
			return S.body(200, json.encode(doc))
		end
		return if path then S.response(path) else nil
	end, true)
	S.drive(h, effects)
	return h
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

local function card(h: Harness, key: string): any
	local view: any = View.view(h.s, h.env)
	local hit = find(view.main, function(n)
		return n.k == "card" and n.p.key == key
	end)
	assert(hit, "card " .. key)
	return hit
end

for _, version in S.VERSIONS do
	describe("tern-stat-fidelity on Grafana " .. version, function()
		it("draws an untitled panel without a head line and keeps a titled panel's", function()
			local h = start(version)
			expect(h.s.panels.p1.status).toBe("ready")
			expect(#card(h, "p1").p.head).toBe(0)
			local titled = card(h, "p6").p.head
			expect(titled[1].t).toBe("Hosts reporting")
		end)

		it("shows the untitled stat's field name above its value", function()
			local h = start(version)
			local name = find(card(h, "p1"), function(n)
				return n.k == "text" and n.p.spans[1].t == "Current Billable Usage Cost"
			end)
			expect(name ~= nil).toBe(true)
		end)

		-- Without a head the card is still the focus target: selection and
		-- the expand key work as on any panel.
		it("focuses, selects and expands an untitled panel", function()
			local h = start(version)
			h.s.focus = "p1"
			local c = card(h, "p1")
			expect(c.p.selected).toBe(true)
			expect(c.p.actions.dblclick).toBe("expand=p1")
			local _, effects =
				State.key(h.s, { name = "enter", ctrl = false, alt = false, shift = false, meta = false }, h.env)
			S.drive(h, effects)
			expect(h.s.expanded).toBe(true)
		end)

		-- On Grafana Cloud's cardinality dashboards a 6x3 stat with a
		-- description drew "22" 5x4 px: the description's chip line and
		-- BigValue's padding came off a room that already had the tile's.
		-- Every short stat, with or without a description, links, a
		-- sparkline or a name, keeps a value of at least a line that fits the
		-- room its card has under the head and chip lines it draws.
		it("keeps a short stat's value between one line and its card's room", function()
			local META = { "none", "description", "links", "both" }
			local variants: { { id: number, h: number, meta: string } } = {}
			local h = start(version, function(d: any)
				local panels = {}
				for _, p in d.panels do
					if p.id < 12 then
						continue
					end
					local n = 0
					for _, gh in { 2, 3, 4 } do
						for _, gw in { 6, 12 } do
							for _, meta in META do
								n += 1
								local v = json.decode(json.encode(p))
								v.id = p.id * 100 + n
								v.gridPos = { x = 0, y = #panels * 4, w = gw, h = gh }
								v.description = if meta == "description" or meta == "both"
									then "What this stat counts."
									else nil
								v.links = if meta == "links" or meta == "both"
									then { { title = "Tern panels dashboard", url = "/d/tern-panels/tern-panels" } }
									else nil
								table.insert(panels, v)
								table.insert(variants, { id = v.id, h = gh, meta = meta })
							end
						end
					end
				end
				d.panels = panels
			end)
			expect(#variants).toBe(72)
			for _, v in variants do
				local key = "p" .. v.id
				expect(h.s.panels[key].status).toBe("ready")
				local c = card(h, key)
				local chips = find(c, function(n)
					return n.p and n.p.key == "meta"
				end) ~= nil
				expect(chips).toBe(v.meta ~= "none")
				local spark = find(c, function(n)
					return n.k == "chart" and n.p.kind == "spark"
				end) ~= nil
				-- Grafana's panel header holds the info icon and links: the chips
				-- sit at the card head's end, never on a line of their own.
				local endId = c.p["end"]
				expect(if endId then string.sub(endId, -5) == ".meta" else false).toBe(chips)
				-- A tile too short for its padding and a line of value drops the
				-- padding (Grafana still draws a 2-row stat's value).
				local tight = find(c, function(n)
					return n.p and type(n.p.class) == "string" and string.find(n.p.class, "tgp-stat-tight", 1, true)
				end) ~= nil
				local room = View.cardHeight(v.h, false, #c.p.head > 0 or chips)
					- (if tight then 0 else Stat.TILE_PAD_Y)
					- (if spark then Stat.SPARK_PX else 0)
				local image = find(c, function(n)
					return n.k == "image"
				end)
				assert(image, "value of " .. key)
				local name = find(c, function(n)
					return n.p and n.p.key == "t"
				end)
				local nameH = 0
				if name and not string.find(name.p.class, "tgp-stat-clamp0", 1, true) then
					nameH = assert(tonumber(string.match(name.p.class, "tgp%-stat%-fs(%d+)"))) * 1.2
				end
				expect(image.p.h >= View.LINE_PX).toBe(true)
				expect(image.p.h + nameH <= room).toBe(true)
			end
		end)
	end)
end

return nil
