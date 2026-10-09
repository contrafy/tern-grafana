--!strict
-- Axes must read like Grafana's (uPlot as configured by UPlotAxisBuilder.ts):
-- round tick values on y, and time labels whose detail matches the zoom.
local t = require("../../lib/test")
local Axis = require("../../../plugin/lib/render/axis")
local Range = require("../../../plugin/lib/time/range")
local describe, it, expect = t.describe, t.it, t.expect

local SECOND = 1000
local MINUTE = 60 * SECOND
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR

local function at(iso: string): number
	return Range.parse(iso, false, { now_ms = 0 }) :: number
end

local function isNiceStep(step: number): boolean
	local mag = 10 ^ math.floor(math.log10(step) + 1e-9)
	local m = step / mag
	for _, nice in { 1, 2, 2.5, 5 } do
		if math.abs(m - nice) < 1e-9 then
			return true
		end
	end
	return false
end

describe("Axis.niceScale", function()
	it("uses 1/2/2.5/5 x 10^n steps and widens the range to whole steps", function()
		for _, case in { { 0, 97 }, { 3.2, 7.9 }, { -42, 1234 }, { 1e-6, 9e-6 }, { 1e9, 3.7e9 } } do
			local s = Axis.niceScale(case[1], case[2], 270)
			expect(isNiceStep(s.step)).toBe(true)
			expect(s.min <= case[1]).toBe(true)
			expect(s.max >= case[2]).toBe(true)
			expect(math.abs(s.min / s.step - math.floor(s.min / s.step + 0.5)) < 1e-6).toBe(true)
			expect(math.abs(s.max / s.step - math.floor(s.max / s.step + 0.5)) < 1e-6).toBe(true)
			for _, v in s.ticks do
				expect(math.abs(v / s.step - math.floor(v / s.step + 0.5)) < 1e-6).toBe(true)
			end
		end
	end)

	it("keeps ticks at least 30 px apart", function()
		local s = Axis.niceScale(0, 97, 270)
		expect(s.step).toBe(20)
		expect(s.ticks).toEqual({ 0, 20, 40, 60, 80, 100 })
	end)

	-- Labels are printed from these values; float drift would print 0.30000000000000004.
	it("produces exact decimal tick values", function()
		local s = Axis.niceScale(0.1, 0.7, 270)
		expect(s.step).toBe(0.1)
		expect(s.ticks).toEqual({ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7 })
	end)

	-- A flat series (e.g. `up` == 1) still needs a visible range around it.
	it("opens a range around a constant value", function()
		local s = Axis.niceScale(1, 1, 270)
		expect(s.min < 1 and s.max > 1).toBe(true)
		local z = Axis.niceScale(0, 0, 270)
		expect(z.min <= 0 and z.max > 0).toBe(true)
	end)

	it("keeps a panel's hard min and max exactly", function()
		local s = Axis.niceScale(13, 87, 270, 0, 100)
		expect(s.min).toBe(0)
		expect(s.max).toBe(100)
	end)

	it("uses the 15 px spacing on short plots", function()
		local short = Axis.niceScale(0, 100, 150)
		local tall = Axis.niceScale(0, 100, 151)
		expect(#short.ticks > #tall.ticks).toBe(true)
	end)
end)

describe("Axis.timeFormat (UPlotAxisBuilder formatTime)", function()
	it("picks the format from the increment and the visible range", function()
		expect(Axis.timeFormat(500, MINUTE)).toBe("HH:mm:ss.SSS")
		expect(Axis.timeFormat(30 * SECOND, HOUR)).toBe("HH:mm:ss")
		-- Grafana compares `<= minute`, so a one-minute step still shows seconds.
		expect(Axis.timeFormat(MINUTE, HOUR)).toBe("HH:mm:ss")
		expect(Axis.timeFormat(5 * MINUTE, 6 * HOUR)).toBe("HH:mm")
		expect(Axis.timeFormat(2 * HOUR, DAY)).toBe("HH:mm")
		expect(Axis.timeFormat(2 * HOUR, 2 * DAY)).toBe("MM/DD HH:mm")
		expect(Axis.timeFormat(DAY, 7 * DAY)).toBe("MM/DD HH:mm")
		expect(Axis.timeFormat(2 * DAY, 30 * DAY)).toBe("MM/DD")
		expect(Axis.timeFormat(90 * DAY, 3 * 365 * DAY)).toBe("YYYY-MM")
		expect(Axis.timeFormat(365 * DAY, 10 * 365 * DAY)).toBe("YYYY")
	end)
end)

describe("Axis.timeTicks", function()
	it("labels a 1 h range with HH:mm on round 5 minute marks", function()
		local from = at("2024-03-15T10:00:00Z")
		local r = Axis.timeTicks(from, from + HOUR, 900)
		expect(r.incr).toBe(5 * MINUTE)
		expect(r.labels[1]).toBe("10:00")
		expect(r.labels[2]).toBe("10:05")
		expect(r.labels[#r.labels]).toBe("11:00")
	end)

	it("labels a 5 m range with seconds", function()
		local from = at("2024-03-15T10:00:00Z")
		local r = Axis.timeTicks(from, from + 5 * MINUTE, 900)
		expect(r.format).toBe("HH:mm:ss")
		expect(r.labels[2]).toBe("10:00:30")
	end)

	it("labels a 7 d range with dates and times at midnight", function()
		local from = at("2024-03-15T00:00:00Z")
		local r = Axis.timeTicks(from, from + 7 * DAY, 900)
		expect(r.incr).toBe(DAY)
		expect(r.labels[1]).toBe("03/15 00:00")
		expect(r.labels[2]).toBe("03/16 00:00")
	end)

	it("labels a 90 d range with MM/DD", function()
		local from = at("2024-01-01T00:00:00Z")
		local r = Axis.timeTicks(from, from + 90 * DAY, 900)
		expect(r.format).toBe("MM/DD")
	end)

	-- Month steps follow the calendar, not 30-day blocks.
	it("puts multi-year month ticks on quarter starts", function()
		local from = at("2022-02-10T00:00:00Z")
		local r = Axis.timeTicks(from, from + 3 * 365 * DAY, 900)
		expect(r.format).toBe("YYYY-MM")
		expect(#r.labels > 2).toBe(true)
		for i, label in r.labels do
			expect(({ ["01"] = true, ["04"] = true, ["07"] = true, ["10"] = true })[string.sub(label, 6, 7)]).toBe(true)
			expect(Range.formatMs(r.ticks[i])).toBe(label .. "-01 00:00:00")
		end
	end)

	it("labels a decade with years on January 1", function()
		local from = at("2015-06-01T00:00:00Z")
		local r = Axis.timeTicks(from, from + 10 * 365 * DAY, 900)
		expect(r.format).toBe("YYYY")
		expect(r.labels[1]).toBe("2016")
		expect(Range.formatMs(r.ticks[1])).toBe("2016-01-01 00:00:00")
	end)

	-- Ticks fall on round local times, not round UTC times.
	it("aligns to the display offset", function()
		local from = at("2024-03-15T00:00:00Z")
		local r = Axis.timeTicks(from, from + 12 * HOUR, 900, 330)
		for _, label in r.labels do
			expect(string.sub(label, -2)).toBe("00")
		end
	end)
end)

return nil
