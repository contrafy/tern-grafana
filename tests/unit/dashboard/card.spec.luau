--!strict
-- The px a dashboard card's body gets (View.cardHeight), which every
-- native panel sizes itself to. A transparent panel has no card chrome
-- (tgp2-plain: 5 px above and below, a head line and a chip line of 16 px
-- each with a 4 px gap): sized as a card's body it lost 14 px, which cut the
-- untitled dynamic text panel of the user's "Right Now" dashboard (24x7) at
-- its last bar. The px below were measured on the live cards.
local View = require("../../../plugin/lib/dashboard/view")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("View.cardHeight", function()
	it("gives a transparent panel its plain chrome only", function()
		-- 7 rows: 258 px, capped at 16 lines (256 px).
		expect(View.cardHeight(7, false, false, true)).toBe(256 - 10)
		-- Titled (Top 10 Issues, 14 rows: 32 lines).
		expect(View.cardHeight(14, false, true, true)).toBe(512 - 30)
		-- Titled with a link chip line (Current Billable Usage Cost by Product, 12 rows: 28 lines).
		expect(View.cardHeight(12, true, true, true)).toBe(448 - 50)
	end)

	it("keeps a card's head and padding", function()
		expect(View.cardHeight(8, false, true)).toBe(18 * 16 - 40)
		expect(View.cardHeight(8, false, false)).toBe(18 * 16 - 24)
		expect(View.cardHeight(8, true, true)).toBe(18 * 16 - 64)
	end)

	-- PanelPlugin.setNoPadding (stat, canvas, geomap, dynamic text): Grafana
	-- gives the panel its box less the 2 px border and the header, so a
	-- padded body clipped the bottom of jdzw5lf's dynamic text by 11 px.
	it("gives a no-padding panel the card less its border and head only", function()
		expect(View.cardHeight(8, false, true, false, true)).toBe(18 * 16 - 2 - 28)
		expect(View.cardHeight(8, false, false, false, true)).toBe(18 * 16 - 2)
		-- Transparent, untitled (jdzw5lf panel 1, 7 rows: 16 lines).
		expect(View.cardHeight(7, false, false, true, true)).toBe(256 - 2)
		expect(View.cardHeight(14, false, true, true, true)).toBe(512 - 2 - 4 - 20)
	end)
end)

-- Tern images never scale up: a w=12 panel designed for a 1600 px dashboard
-- left ~11% of a 1846 px pane's card empty on the right.
describe("View.designWidth", function()
	it("lays panels out over the block's width in cells", function()
		expect(View.designWidth({ cols = 234, rows = 60 } :: any)).toBe(math.floor(234 * View.CELL_PX))
		-- Narrower than Grafana's desktop: designed at the pane's width, so a
		-- 3-column bar gauge fills its card instead of shrinking to its top
		-- (Node Exporter Full's Pressure in a 1264 px pane).
		expect(View.designWidth({ cols = 160, rows = 50 } :: any)).toBe(math.floor(160 * View.CELL_PX))
		expect(View.designWidth({ cols = 20, rows = 10 } :: any)).toBe(View.MIN_DESIGN_WIDTH)
	end)

	-- A block that never got Tern's resize notice reports the initial 80x24
	-- forever (Tern 0.9.16): designed 632 px, every image would sit small
	-- at its card's left. That size, or none, designs for 1600 px.
	it("uses Grafana's desktop width for an unknown or initial 80x24 size", function()
		expect(View.designWidth({} :: any)).toBe(1600)
		expect(View.designWidth({ cols = 80, rows = 24 } :: any)).toBe(1600)
		expect(View.designWidth({ cols = 80, rows = 30 } :: any)).toBe(math.floor(80 * View.CELL_PX))
	end)
end)

return nil
