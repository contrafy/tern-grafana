--!strict
-- The keyboard cursor is the only way to read exact values off a chart in
-- Tern (no SVG tooltips, no hover), so it must land on real samples, report
-- gaps honestly and never run off the ends.
local t = require("../../lib/test")
local Cursor = require("../../../plugin/lib/render/cursor")
local Frame = require("../../../plugin/lib/frame/types")
local Layout = require("../../../plugin/lib/render/layout")
local Svg = require("../../../plugin/lib/render/svg_timeseries")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = Frame.NULL

-- Series a at t = 0, 10, 20, 30 (a gap at 20); series b at t = 5, 25.
local function layout(): Layout.Layout
	local a = Frame.timeSeries({ s = "a" }, { 0, 10, 20, 30 }, { 1, 2, NULL, 4 })
	local b = Frame.timeSeries({ s = "b" }, { 5, 25 }, { 50, 250 })
	return Svg.render({ a, b }).layout
end

describe("Cursor.read", function()
	it("reads each series at its sample nearest the cursor", function()
		local r = Cursor.read(layout(), 9)
		expect(r[1].time).toBe(10)
		expect(r[1].value).toBe(2)
		expect(r[2].time).toBe(5)
		expect(r[2].value).toBe(50)
		expect(r[1].class).toBe("tg-s1")
		expect(r[2].name).toBe('{s="b"}')
	end)

	it("takes the earlier sample on an exact tie", function()
		expect(Cursor.read(layout(), 15)[1].time).toBe(10)
	end)

	-- Showing a neighbour's value inside an outage would invent data.
	it("reports a gap as no value instead of a farther sample", function()
		local r = Cursor.read(layout(), 20)
		expect(r[1].time).toBe(20)
		expect(r[1].value).toBeNil()
	end)

	it("clamps to the first and last sample outside the data", function()
		local l = layout()
		expect(Cursor.read(l, -100)[1].time).toBe(0)
		expect(Cursor.read(l, 1000)[1].time).toBe(30)
	end)
end)

describe("Cursor.step", function()
	it("walks the union of all series' sample times", function()
		local l = layout()
		expect(l.times).toEqual({ 0, 5, 10, 20, 25, 30 })
		expect(Cursor.step(l, 5, 1)).toBe(10)
		expect(Cursor.step(l, 10, -1)).toBe(5)
		expect(Cursor.step(l, 0, 1, 3)).toBe(20)
	end)

	it("starts at the newest sample going left and the oldest going right", function()
		local l = layout()
		expect(Cursor.step(l, nil, -1)).toBe(30)
		expect(Cursor.step(l, nil, 1)).toBe(0)
	end)

	it("stops at the edges", function()
		local l = layout()
		expect(Cursor.step(l, 30, 1)).toBe(30)
		expect(Cursor.step(l, 0, -1)).toBe(0)
		expect(Cursor.step(l, 25, 1, 10)).toBe(30)
		expect(Cursor.step(l, 5, -1, 10)).toBe(0)
	end)

	-- After a refresh the old cursor time may fall between new samples.
	it("moves to the neighbouring sample from an off-grid time", function()
		local l = layout()
		expect(Cursor.step(l, 12, 1)).toBe(20)
		expect(Cursor.step(l, 12, -1)).toBe(10)
	end)

	it("has nowhere to go without samples", function()
		expect(Cursor.step(Svg.render({}).layout, nil, 1)).toBeNil()
	end)
end)

describe("Cursor.fraction", function()
	-- The overlay is placed as a fraction of the scaled image's width.
	it("maps the time range onto the plot area and back", function()
		local l = layout()
		expect(Cursor.fraction(l, l.t_from)).toBe(l.plot_left / l.width)
		expect(Cursor.fraction(l, l.t_to)).toBe(l.plot_right / l.width)
		local mid = Cursor.fraction(l, 15)
		expect(mid > l.plot_left / l.width and mid < l.plot_right / l.width).toBe(true)
		expect(math.abs(Layout.timeAtFraction(l, mid) - 15) < 1e-6).toBe(true)
	end)
end)

return nil
