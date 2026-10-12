--!strict
-- The flame graph panel (@grafana/flamegraph dataTransform.ts
-- nestedSetToLevels, colors.ts, murmur3.ts, rendering.ts) on the
-- tern-all-panels flame graph (panel 26: a TestData CSV nested set
-- total > checkout > db.query, render > template; payments > charge).
local Flamegraph = require("../../../plugin/lib/panels/flamegraph")
local Frame = require("../../../plugin/lib/frame/types")
local S = require("./support")
local SvgFlame = require("../../../plugin/lib/render/svg_flame")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local function allPanels(version: string, id: number): any
	local doc = S.decode("grafana/" .. version .. "/dashboard_tern_all_panels.json")
	for _, p in doc.dashboard.panels do
		if p.id == id then
			return p
		end
	end
	error("no panel " .. id)
end

for _, version in S.VERSIONS do
	describe("flame graph " .. version, function()
		-- A row starts where its previous sibling ends; children start at
		-- their parent.
		it("lays out the nested set as levels", function()
			local p = Flamegraph.profile(S.frames(version, "all_panels_26"))
			assert(p, "profile")
			expect(p.levels).toBe(4)
			expect(p.total).toBe(1000)
			local by: { [string]: Flamegraph.Item } = {}
			for _, item in p.items do
				by[item.label] = item
			end
			expect(by.checkout.start).toBe(0)
			expect(by.payments.start).toBe(600)
			expect(by.render.start).toBe(350)
			expect(by.template.start).toBe(350)
			expect(by.charge.start).toBe(600)
			expect((by.template.parent :: Flamegraph.Item).label).toBe("render")
		end)

		it("draws labeled bars with Grafana's package colors and the top table", function()
			local node, assets = Flamegraph.view(allPanels(version, 26), S.frames(version, "all_panels_26"), env, {
				key = "fg",
				size = { w = 1000, h = 440 },
			})
			local svg = (assets :: any).fg.bytes
			expect(string.find(svg, ">total (1000)</text>", 1, true) ~= nil).toBe(true)
			-- murmur3("db.") % 24 = 18: #65c5db, as in Grafana's render.
			expect(string.find(svg, 'fill="#65c5db"', 1, true) ~= nil).toBe(true)
			expect(S.text(node)).toContain("1000 | 1 K samples (Count)")
			local top = S.find(node, function(n)
				return n.p and n.p.role == "tern-grafana.flamegraph-top"
			end)
			expect(S.text(top)).toContain("db.query350350")
		end)
	end)
end

describe("flame graph colors", function()
	-- Hashes from Grafana's murmurhash3_32_gc.
	it("hashes package names like Grafana", function()
		expect(SvgFlame.murmur3("total", 0)).toBe(1214258741)
		expect(SvgFlame.murmur3("db.", 0)).toBe(3159380442)
		expect(SvgFlame.murmur3("github.com/x/y.", 0)).toBe(3576735425)
		expect(SvgFlame.murmur3("abcde", 0)).toBe(3902511862)
		expect(SvgFlame.murmur3("", 0)).toBe(0)
	end)

	it("finds package names with the profiler matchers", function()
		expect(SvgFlame.packageName("db.query")).toBe("db.")
		expect(SvgFlame.packageName("github.com/x/y.Func")).toBe("github.com/x/y.")
		expect(SvgFlame.packageName("total")).toBe("total")
		expect(SvgFlame.packageName("app/main.py:42")).toBe("app/")
	end)

	-- The top table counts a recursive symbol's total once.
	it("sums self and outermost totals per symbol", function()
		local frames: { any } = {
			{
				fields = {
					Frame.field("level", "number", { 0, 1, 2 }),
					Frame.field("value", "number", { 10, 8, 5 }),
					Frame.field("self", "number", { 2, 3, 5 }),
					Frame.field("label", "string", { "root", "f", "f" }),
				},
			},
		}
		local p = Flamegraph.profile(frames)
		assert(p, "profile")
		local syms = Flamegraph.symbols(p)
		expect(syms[1].label).toBe("f")
		expect(syms[1].self).toBe(8)
		expect(syms[1].total).toBe(8)
	end)
end)

return nil
