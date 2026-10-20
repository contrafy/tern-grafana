--!strict
-- Tern keeps every distinct blob for the session, so a refresh that brought
-- the same samples must draw the same bytes: a range ending at now is drawn
-- with its end on the query step, which only moves when a new sample can
-- exist, and an absolute range is never moved.
local Redraw = require("../../../plugin/lib/render/redraw")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("Redraw.snapRange", function()
	it("draws two refreshes inside one step over the same range", function()
		local a1, b1 = Redraw.snapRange(1006000 - 3600000, 1006000, 15000)
		local a2, b2 = Redraw.snapRange(1014000 - 3600000, 1014000, 15000)
		expect({ a1, b1 }).toEqual({ a2, b2 })
		expect(b1).toBe(1005000)
		expect(b1 - a1).toBe(3600000)
	end)

	it("moves on once the next step boundary passed", function()
		local _, b1 = Redraw.snapRange(0, 1005000, 15000)
		local _, b2 = Redraw.snapRange(15000, 1020000, 15000)
		expect(b2 - b1).toBe(15000)
	end)

	it("leaves the range alone without a positive step", function()
		expect({ Redraw.snapRange(1, 7, nil) }).toEqual({ 1, 7 })
		expect({ Redraw.snapRange(1, 7, 0) }).toEqual({ 1, 7 })
	end)
end)

describe("Redraw.relative", function()
	it("snaps ends relative to now only", function()
		expect(Redraw.relative("now")).toBe(true)
		expect(Redraw.relative("now-5m")).toBe(true)
		expect(Redraw.relative("2026-10-09T20:00:00Z")).toBe(false)
		expect(Redraw.relative("1791577907000")).toBe(false)
		expect(Redraw.relative(nil)).toBe(false)
	end)
end)

return nil
