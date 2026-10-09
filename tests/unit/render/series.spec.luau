--!strict
-- Series extraction, legend reductions and stacking decide what a chart and
-- its legend claim about the data.
local t = require("../../lib/test")
local Frame = require("../../../plugin/lib/frame/types")
local Series = require("../../../plugin/lib/render/series")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = Frame.NULL
local NaN = 0 / 0

describe("Series.calcs", function()
	-- One NaN sample (e.g. a 0/0 ratio) must not turn the mean or max into NaN.
	it("ignores nulls, NaN and infinities", function()
		local c = Series.calcs({ 1, NULL, NaN, 3, math.huge, -math.huge, NULL })
		expect(c.last).toBe(3)
		expect(c.min).toBe(1)
		expect(c.max).toBe(3)
		expect(c.mean).toBe(2)
		expect(c.count).toBe(2)
	end)

	it("reports nothing for a series without values", function()
		local c = Series.calcs({ NULL, NaN })
		expect(c.last).toBeNil()
		expect(c.mean).toBeNil()
		expect(c.count).toBe(0)
	end)
end)

describe("Series.extract", function()
	it("turns every number field into a named series and non-numbers into NULL", function()
		local frame: Frame.Frame = {
			fields = {
				Frame.field("Time", "time", { 1, 2 }),
				Frame.field("a", "number", { 1, "x" }, { __name__ = "m", k = "1" }),
				Frame.field("label", "string", { "p", "q" }),
				Frame.field("b", "number", { 3, 4 }, nil, { unit = "bytes" }),
			},
		}
		local list = Series.extract({ frame, { fields = { Frame.field("v", "number", { 1 }) } } })
		expect(#list).toBe(2)
		expect(list[1].name).toBe('m{k="1"}')
		expect(list[1].values[2]).toBe(NULL)
		expect(list[2].unit).toBe("bytes")
	end)
end)

describe("Series.join", function()
	-- Different scrape offsets per series must not misalign a stack.
	it("outer-joins on time with NULL where a series has no sample", function()
		local a = { name = "a", labels = {}, times = { 1, 2, 4 }, values = { 10, 20, 40 } }
		local b = { name = "b", labels = {}, times = { 2, 3 }, values = { 200, 300 } }
		local times, cols = Series.join({ a, b })
		expect(times).toEqual({ 1, 2, 3, 4 })
		expect(cols[1]).toEqual({ 10, 20, NULL, 40 })
		expect(cols[2]).toEqual({ NULL, 200, 300, NULL })
	end)
end)

describe("Series.stack", function()
	it("normal mode stacks running sums with each series' base below it", function()
		local tops, bottoms = Series.stack({ { 1, 2 }, { 10, 20 }, { 100, 200 } }, "normal")
		expect(tops[1]).toEqual({ 1, 2 })
		expect(tops[2]).toEqual({ 11, 22 })
		expect(tops[3]).toEqual({ 111, 222 })
		expect(bottoms[1]).toEqual({ 0, 0 })
		expect(bottoms[3]).toEqual({ 11, 22 })
	end)

	-- A missing sample adds nothing to the stack and leaves a gap in that series.
	it("skips missing samples without breaking the series above", function()
		local tops, bottoms = Series.stack({ { 1, 1 }, { NULL, 5 }, { 2, 2 } }, "normal")
		expect(tops[2][1]).toBe(NULL)
		expect(tops[3]).toEqual({ 3, 8 })
		expect(bottoms[3]).toEqual({ 1, 6 })
	end)

	it("percent mode stacks shares that end at 1", function()
		local tops = Series.stack({ { 1, 0 }, { 3, 0 } }, "percent")
		expect(tops[1][1]).toBe(0.25)
		expect(tops[2][1]).toBe(1)
		-- A zero total cannot be divided: everything sits at 0.
		expect(tops[2][2]).toBe(0)
	end)
end)

return nil
