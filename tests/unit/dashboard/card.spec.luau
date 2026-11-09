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
end)

return nil
