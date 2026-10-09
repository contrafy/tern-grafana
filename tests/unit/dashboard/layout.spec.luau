--!strict
-- Tern blocks have no pane width, so the 24-column grid becomes nested flex
-- rows and columns with fractional widths. The layout must keep Grafana's
-- arrangement recognisable: panels side by side stay side by side, stacked
-- stats stay stacked next to a tall panel, and keyboard focus moves to the
-- panel that is visually next in that direction.
local Layout = require("../../../plugin/lib/dashboard/layout")
local Model = require("../../../plugin/lib/dashboard/model")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function items(panels: { Model.Panel }): { Layout.Item }
	local out = {}
	for _, p in panels do
		table.insert(out, { key = "p" .. p.id, grid = p.grid })
	end
	return out
end

-- A compact picture of a layout tree: panels as keys, gaps as "_<basis>".
local function shape(nodes: { Layout.Node }): { any }
	local out: { any } = {}
	for _, n in nodes do
		if n.kind == "panel" then
			table.insert(out, n.key .. "@" .. string.format("%.3f", n.basis))
		elseif n.kind == "gap" then
			table.insert(out, "_" .. string.format("%.3f", n.basis))
		else
			table.insert(out, { [n.kind .. "@" .. string.format("%.3f", n.basis)] = shape((n :: any).children) })
		end
	end
	return out
end

for _, version in S.VERSIONS do
	local env = S.env()
	local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_panels.json")), env))
	local overview = items(d.sections[1].panels)

	describe("layout of tern-panels Overview on Grafana " .. version, function()
		it("splits into bands by y and columns by x, stacking the stats over the bar gauge", function()
			local stacked: any = {
				["col@0.333"] = {
					{ ["row@1.000"] = { "p5@0.500", "p6@0.500" } },
					{ ["row@1.000"] = { "p8@1.000" } },
				},
			}
			local expected: { any } = {
				{ ["row@1.000"] = { "p2@0.500", "p3@0.500" } },
				{ ["row@1.000"] = { "p4@0.500", stacked, "p7@0.167" } },
				{ ["row@1.000"] = { "p9@0.500", "p10@0.500" } },
			}
			expect(shape(Layout.arrange(overview))).toEqual(expected)
		end)

		it("orders panels for reading: band by band, stacked columns top to bottom", function()
			expect(Layout.order(Layout.arrange(overview))).toEqual({
				"p2",
				"p3",
				"p4",
				"p5",
				"p6",
				"p8",
				"p7",
				"p9",
				"p10",
			})
		end)

		it("moves focus to the visually adjacent panel", function()
			expect(Layout.neighbor(overview, "p4", "right")).toBe("p5")
			expect(Layout.neighbor(overview, "p5", "down")).toBe("p8")
			expect(Layout.neighbor(overview, "p8", "right")).toBe("p7")
			expect(Layout.neighbor(overview, "p7", "up")).toBe("p3")
			expect(Layout.neighbor(overview, "p2", "down")).toBe("p4")
			expect(Layout.neighbor(overview, "p9", "down")).toBeNil()
			expect(Layout.neighbor(overview, "p2", "left")).toBeNil()
		end)
	end)
end

describe("layout edge cases", function()
	it("keeps empty grid space as a gap so a right-half panel stays on the right", function()
		local nodes = Layout.arrange({ { key = "a", grid = { x = 12, y = 0, w = 12, h = 4 } } })
		expect(shape(nodes)).toEqual({ { ["row@1.000"] = { "_0.500", "a@0.500" } } })
	end)

	it("falls back to reading order for overlapping panels instead of looping", function()
		local nodes = Layout.arrange({
			{ key = "a", grid = { x = 0, y = 0, w = 12, h = 4 } },
			{ key = "b", grid = { x = 6, y = 2, w = 12, h = 4 } },
		})
		expect(Layout.order(nodes)).toEqual({ "a", "b" })
	end)
end)

return nil
