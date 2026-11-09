--!strict
-- tern-stat-fidelity in the dashboard block: Grafana draws an untitled panel
-- without a header (no "Panel N"), and its stats name their field instead.
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local View = require("../../../plugin/lib/dashboard/view")
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
	local id = string.match(tag, "^q/%d+/%d+/p(%d+)$")
	if id then
		return S.grafana(version, "ds_query_stat_fidelity_" .. id .. ".json")
	end
	return nil
end

local function start(version: string): Harness
	local env = S.env()
	local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=tern-stat-fidelity" }, nil, env)
	local h = S.harness(s, env, function(e: any): any
		local path = fixtureFor(version, e.tag)
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
	end)
end

return nil
