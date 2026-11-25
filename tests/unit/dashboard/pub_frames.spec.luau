--!strict
-- tern-pub-frames in the dashboard block (synthetic copies of public
-- dashboards' transformations), checked against Grafana's render:
-- - calculateField saved with empty options runs on its defaultOptions
--   (reduceRow sum), so the row sum is named "Total", not "math" (17781);
-- - a query without series answers a frame with no fields, which Grafana's
--   panels receive: calculateField adds an empty Total field to it and the
--   stat draws a blank value instead of "No data" (17781 Store Operations);
-- - targets saved without a refId get A and B on load
--   (PanelModel.ensureQueryIds), so the table format names the value columns
--   "Value #A" and "Value #B" that the groupBy reads (node-exporter mixin
--   Disk Space Usage).
local S = require("./support")
local PS = require("../panels/support")
local State = require("../../../plugin/lib/dashboard/state")
local View = require("../../../plugin/lib/dashboard/view")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Harness = S.Harness

local function fixtureFor(version: string, tag: string): string?
	if string.match(tag, "^dash/") then
		return S.grafana(version, "dashboard_tern_pub_frames.json")
	elseif string.match(tag, "^fs/") then
		return S.grafana(version, "frontend_settings.json")
	elseif string.match(tag, "^flag/") then
		return S.grafana(version, "ofrep_table_auto_column_widths.json")
	elseif string.match(tag, "^user/") then
		return S.grafana(version, "user.json")
	end
	local id = string.match(tag, "^q/%d+/%d+/p(%d+)$")
	return if id then S.grafana(version, "ds_query_pub_frames_" .. id .. ".json") else nil
end

-- The text a panel shows: its card's nodes and its SVG assets.
local function shown(version: string): (string) -> string
	local env = S.env()
	local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=tern-pub-frames" }, nil, env)
	local h = S.harness(s, env, function(e: any): any
		local path = fixtureFor(version, e.tag)
		return if path then S.response(path) else nil
	end, true)
	S.drive(h, effects)
	local view: any, assets: any = View.view(h.s, h.env)
	return function(key: string): string
		local card = assert(
			PS.find(view.main, function(n: any): boolean
				return n.k == "card" and n.p.key == key
			end),
			"card " .. key
		)
		local parts = { PS.text(card) }
		for k, a in assets do
			if string.sub(k, 1, #key) == key then
				table.insert(parts, (string.gsub(a.bytes, "<[^>]*>", " ")))
			end
		end
		return table.concat(parts, " ")
	end
end

local function has(text: string, s: string): boolean
	return string.find(text, s, 1, true) ~= nil
end

for _, version in S.VERSIONS do
	describe("tern-pub-frames on Grafana " .. version, function()
		local text = shown(version)

		it("names calculateField's default row sum Total", function()
			local p1 = text("p1")
			expect(has(p1, "Prometheus")).toBe(true)
			expect(has(p1, "Total")).toBe(true)
			expect(has(p1, "math")).toBe(false)
		end)

		it("draws a blank Total for a query without series, not No data", function()
			local p2 = text("p2")
			expect(has(p2, "No data")).toBe(false)
			expect(has(p2, "N/A")).toBe(false)
		end)

		it("gives targets without a refId A and B, so the disk table groups both queries", function()
			local p3 = text("p3")
			expect(has(p3, "No data")).toBe(false)
			for _, s in
				{ "Mounted on", "Size", "Available", "Used, %", "/etc/hostname", "/etc/hosts", "/etc/resolv.conf" }
			do
				expect(has(p3, s)).toBe(true)
			end
			expect(has(p3, "Value #A")).toBe(false)
		end)
	end)
end

return nil
