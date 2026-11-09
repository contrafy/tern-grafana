--!strict
-- The treemap panel's tilings against real d3-hierarchy: every case of
-- treemap/d3_hierarchy_3.1.2.json was laid out once by d3-hierarchy 3.1.2
-- (the d3 7.9.0 marcusolsson-treemap-panel 2.1.1 bundles) and its
-- descendants() rectangles recorded. The panel draws exactly these
-- rectangles, so any drift is a visible difference from Grafana.
local Layout = require("../../../plugin/lib/panels/treemap_layout")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local REF = S.decode("treemap/d3_hierarchy_3.1.2.json")

local function input(node: any): Layout.Input
	local kids: { Layout.Input }? = nil
	if node.children then
		local list: { Layout.Input } = {}
		for _, c in node.children do
			table.insert(list, input(c))
		end
		kids = list
	end
	return { name = node.name, value = node.value, children = kids }
end

local function close(a: number, b: number): boolean
	return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(b))
end

describe("treemap layout", function()
	for _, case in REF.cases do
		it(case.name .. " matches d3", function()
			local p = case.padding
			local tiles = Layout.layout(input(case.root), case.width, case.height, {
				tiling = case.tiling,
				round = case.round,
				padding_inner = p.inner,
				padding_top = p.top,
				padding_right = p.right,
				padding_bottom = p.bottom,
				padding_left = p.left,
			})
			expect(#tiles).toBe(#case.tiles)
			for i, want in case.tiles do
				local got = tiles[i]
				local same = got.input.name == want.name
					and got.depth == want.depth
					and close(got.value, want.value)
					and close(got.x0, want.x0)
					and close(got.y0, want.y0)
					and close(got.x1, want.x1)
					and close(got.y1, want.y1)
				if not same then
					expect({
						i = i,
						name = got.input.name,
						depth = got.depth,
						value = got.value,
						x0 = got.x0,
						y0 = got.y0,
						x1 = got.x1,
						y1 = got.y1,
					}).toEqual({
						i = i,
						name = want.name,
						depth = want.depth,
						value = want.value,
						x0 = want.x0,
						y0 = want.y0,
						x1 = want.x1,
						y1 = want.y1,
					})
				end
			end
		end)
	end

	-- Leaves are what the panel draws; a group (a node with children) is
	-- drawn under them at 5% opacity.
	it("marks leaves and groups", function()
		local g: Layout.Input = { name = "g", children = { { name = "a", value = 1 } } }
		local b: Layout.Input = { name = "b", value = 2 }
		local tiles = Layout.layout({ name = "All", children = { g, b } }, 100, 100)
		expect(tiles[1].leaf).toBe(false)
		expect(tiles[2].input.name).toBe("b")
		expect(tiles[2].leaf).toBe(true)
		expect(tiles[3].input.name).toBe("g")
		expect(tiles[3].leaf).toBe(false)
		expect(tiles[4].leaf).toBe(true)
	end)
end)

return nil
