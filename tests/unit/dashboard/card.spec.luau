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
	it("lays panels out over the block's width in cells, never narrower than 1600 px", function()
		expect(View.designWidth({ cols = 234 } :: any)).toBe(math.floor(234 * View.CELL_PX))
		expect(View.designWidth({} :: any)).toBe(1600)
		-- A block left at Tern's initial 80x24: designed narrower than its
		-- card, every image would sit small at the card's left.
		expect(View.designWidth({ cols = 80 } :: any)).toBe(1600)
	end)
end)

return nil
