--!strict
-- Repeats are how one dashboard covers every job or instance. A repeated
-- panel must produce one copy per selected value laid out the way Grafana
-- does (maxPerRow, wrapping, panels below moved down), and every copy must
-- query its own value; a repeated row copies its section per value.
local Interpolate = require("../../../plugin/lib/dashboard/interpolate")
local Model = require("../../../plugin/lib/dashboard/model")
local Repeat = require("../../../plugin/lib/dashboard/repeat")
local S = require("./support")
local Variables = require("../../../plugin/lib/dashboard/variables")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local JOBS = { "alertmanager", "down", "loki", "node", "prometheus", "tempo" }

local function options(list: { string }): { Variables.Option }
	local out = {}
	for _, v in list do
		table.insert(out, { text = v, value = v })
	end
	return out
end

for _, version in S.VERSIONS do
	local env = S.env()
	local function setup(): (Model.Dashboard, { Variables.Variable })
		local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_variables.json")), env))
		local vars = Variables.fromModel(d.templating, env)
		for _, v in vars do
			if v.name == "job" then
				Variables.setOptions(v, options(JOBS))
			elseif v.name == "instance" then
				Variables.setOptions(v, options({ "node-exporter:9100", "prometheus:9090" }))
			elseif v.status == "pending" then
				Variables.setOptions(v, options({ "x" }))
			end
		end
		return d, vars
	end

	describe("repeat on tern-variables, Grafana " .. version, function()
		it("repeats the stat per job, four per line, and moves later panels down", function()
			local d, vars = setup()
			local sections = Repeat.expand(d, vars)
			local first = sections[1]
			local grid: { string } = {}
			for _, inst in first.panels do
				local g = inst.panel.grid
				table.insert(grid, string.format("%s %d %d %d", inst.key, g.x, g.y, g.w))
			end
			expect(grid).toEqual({
				"p1 0 0 12",
				"p2 12 0 12",
				"p3 0 8 6",
				"p3.1 6 8 6",
				"p3.2 12 8 6",
				"p3.3 18 8 6",
				"p3.4 0 12 6",
				"p3.5 6 12 6",
				-- Was at y = 12: pushed below the second line of copies.
				"p4 0 16 24",
			})
		end)

		it("gives each copy its own value for queries and titles", function()
			local d, vars = setup()
			local inst = assert(Repeat.find(Repeat.expand(d, vars), "p3.3"))
			local scope = Interpolate.merge(Variables.scope(vars), inst.scoped)
			expect(Interpolate.replace(inst.panel.title, scope, { format = Interpolate.text })).toBe("up for node")
			expect(Interpolate.replace('{job=~"$job"}', scope, { format = Interpolate.prometheus })).toBe(
				'{job=~"node"}'
			)
		end)

		it("copies a repeated row per instance with the instance in scope", function()
			local d, vars = setup()
			local sections = Repeat.expand(d, vars)
			expect(#sections).toBe(3)
			expect(sections[2].key).toBe("r5")
			expect(sections[3].key).toBe("r5.1")
			expect(sections[3].panels[1].key).toBe("r5.1/p6")
			local scope = Interpolate.merge(Variables.scope(vars), sections[3].scoped)
			expect(Interpolate.replace("Instance $instance", scope, { format = Interpolate.text })).toBe(
				"Instance prometheus:9090"
			)
		end)

		it("shows a panel once when its repeat variable selects a single value", function()
			local d, vars = setup()
			Variables.select(assert(Variables.find(vars, "job")), { "node" })
			local keys = {}
			for _, inst in Repeat.expand(d, vars)[1].panels do
				table.insert(keys, inst.key)
			end
			expect(keys).toEqual({ "p1", "p2", "p3", "p4" })
		end)
	end)
end

return nil
