--!strict
-- The node graph panel (nodeGraph/utils.ts processNodes, statToString,
-- applyOptionsToFrames; layout.ts) on tern-all-panels panel 28: CSV
-- `nodes` (frontend, checkout, payments, db) and `edges`
-- (frontend -> checkout -> payments -> db, checkout -> db).
local NodeGraph = require("../../../plugin/lib/panels/nodegraph")
local S = require("./support")
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
	describe("node graph " .. version, function()
		-- statToString: two decimals and the unit id from the panel options.
		it("reads nodes and edges with Grafana's stat text", function()
			local g = NodeGraph.graph(allPanels(version, 28), S.frames(version, "all_panels_28"), env)
			assert(g, "graph")
			expect(#g.nodes).toBe(4)
			expect(#g.edges).toBe(4)
			local fe = g.nodes[1]
			expect(fe.id).toBe("frontend")
			expect(fe.main).toBe("310.00 reqps")
			expect(fe.secondary).toBe("42.00 ms")
			expect(fe.title).toBe("frontend")
			expect(fe.subtitle).toBe("web")
			-- Panel overrides do not color arcs (Grafana's node graph has no
			-- field config); without options.nodes.arcs the rim is plain.
			expect(#fe.arcs).toBe(0)
		end)

		-- Longest path layers: the edge checkout -> db skips a layer, so db
		-- sits after payments; payments steps aside for the long edge.
		it("lays nodes out in layers left to right", function()
			local g = NodeGraph.graph(allPanels(version, 28), S.frames(version, "all_panels_28"), env)
			assert(g, "graph")
			NodeGraph.layered(g)
			local at: { [string]: any } = {}
			for _, n in g.nodes do
				at[n.id] = n
			end
			expect(at.frontend.x).toBe(0)
			expect(at.checkout.x).toBe(NodeGraph.LAYER_X)
			expect(at.payments.x).toBe(2 * NodeGraph.LAYER_X)
			expect(at.db.x).toBe(3 * NodeGraph.LAYER_X)
			expect(at.checkout.y).toBe(at.frontend.y)
			expect(at.db.y).toBe(at.checkout.y)
			expect(at.payments.y > at.checkout.y).toBe(true)
		end)

		it("draws nodes, arrows and the stat legend", function()
			local node, assets = NodeGraph.view(allPanels(version, 28), S.frames(version, "all_panels_28"), env, {
				key = "ng",
				size = { w = 1000, h = 440 },
			})
			local svg = (assets :: any).ng.bytes
			expect(select(2, string.gsub(svg, 'class="tgn%-node"', ""))).toBe(4)
			expect(select(2, string.gsub(svg, 'class="tgn%-arrow"', ""))).toBe(4)
			expect(string.find(svg, ">160.00 reqps<", 1, true) ~= nil).toBe(true)
			expect(string.find(svg, ">postgres<", 1, true) ~= nil).toBe(true)
			local legend = S.find(node, function(n)
				return n.p and n.p.role == "tern-grafana.legend"
			end)
			expect(S.text(legend)).toBe("mainstatsecondarystat")
		end)
	end)
end

describe("node graph options", function()
	-- options.nodes.arcs colors the arc fields (applyOptionsToFrames).
	it("draws arc sections in the configured colors", function()
		local panel = S.clone(allPanels("12.4.12", 28))
		panel.options.nodes.arcs = { { field = "arc__ok", color = "green" }, { field = "arc__errors", color = "red" } }
		local g = NodeGraph.graph(panel, S.frames("12.4.12", "all_panels_28"), env)
		assert(g, "graph")
		expect(#g.nodes[1].arcs).toBe(2)
		expect(g.nodes[1].arcs[1].color).toBe("#73BF69")
		expect(#g.legend).toBe(2)
	end)

	-- Without a nodes frame, nodes come from the edges' ends.
	it("builds nodes from edges alone", function()
		local edges = {}
		for _, f in S.frames("12.4.12", "all_panels_28") do
			if f.refId == "edges" then
				table.insert(edges, f)
			end
		end
		local g = NodeGraph.graph(allPanels("12.4.12", 28), edges, env)
		assert(g, "graph")
		expect(#g.nodes).toBe(4)
		expect(g.nodes[1].title).toBe("frontend")
	end)
end)

return nil
