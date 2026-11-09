--!strict
-- Date units must read like Grafana's display processor
-- (valueFormats/dateTimeFormatters.ts with moment): a "time:" pattern is a
-- moment format, the NoDateIfToday units drop the date on today's values and
-- dateTimeFromNow is moment's fromNow. Expected strings come from moment
-- 2.30 on the same instants.
local t = require("../../lib/test")
local FieldConfig = require("../../../plugin/lib/panels/fieldconfig")
local Frame = require("../../../plugin/lib/frame/types")
local S = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

-- 2024-03-15 13:45:30.250 UTC.
local NOW = 1710510330250
local DAY = 86400000

local function item(unit: string?, fieldType: Frame.FieldType?, values: { any }?): FieldConfig.Item
	local unitJson = if unit then string.format('"unit": %q', unit) else ""
	local panel =
		S.json(string.format('{"type": "stat", "fieldConfig": {"defaults": {%s}, "overrides": []}}', unitJson))
	local frames = { { refId = "A", fields = { Frame.field("v", fieldType or "number", values or { NOW }) } } }
	return FieldConfig.resolve(panel, frames, S.env)[1]
end

local function text(unit: string?, ms: number, opts: FieldConfig.Options?): string
	return FieldConfig.display(item(unit), ms, opts).text
end

describe("fielddisplay date units", function()
	it("formats time: ids as moment patterns", function()
		expect(text("time:YYYY.MM", NOW)).toBe("2024.03")
		expect(text("time:dddd Do MMM", NOW)).toBe("Friday 15th Mar")
	end)

	it("formats the dateTimeAs units with their patterns at the display offset", function()
		expect(text("dateTimeAsIso", NOW, { offset_min = 120 })).toBe("2024-03-15 15:45:30")
		expect(text("dateTimeAsUS", NOW)).toBe("03/15/2024 1:45:30 pm")
		expect(text("dateTimeAsLocal", NOW)).toBe("03/15/2024, 01:45:30 PM")
	end)

	-- Only a value on the viewer's current day loses its date.
	it("drops the date of today's values for the NoDateIfToday units", function()
		expect(text("dateTimeAsIsoNoDateIfToday", NOW, { now_ms = NOW })).toBe("13:45:30")
		expect(text("dateTimeAsUSNoDateIfToday", NOW, { now_ms = NOW })).toBe("1:45:30 pm")
		expect(text("dateTimeAsIsoNoDateIfToday", NOW, { now_ms = NOW + DAY })).toBe("2024-03-15 13:45:30")
	end)

	it("reads dateTimeFromNow as moment's relative time", function()
		local cases: { { number | string } } = {
			{ -30000, "a few seconds ago" },
			{ -45000, "a minute ago" },
			{ -90000, "2 minutes ago" },
			{ -50 * 60000, "an hour ago" },
			{ 3 * 3600000, "in 3 hours" },
			{ -26 * DAY, "a month ago" },
			{ -40 * DAY, "a month ago" },
			{ -400 * DAY, "a year ago" },
			{ -800 * DAY, "2 years ago" },
		}
		for _, c in cases do
			expect(text("dateTimeFromNow", NOW + (c[1] :: number), { now_ms = NOW })).toBe(c[2] :: string)
		end
		-- Months are calendar months: Jan 31 to Mar 1 is one.
		local jan31, mar1 = 1706659200000, 1709251200000
		expect(text("dateTimeFromNow", mar1, { now_ms = jan31 })).toBe("in a month")
	end)

	-- A time field without a unit uses the system format, with milliseconds
	-- when its values span under a minute.
	it("shows milliseconds on a time field spanning under a minute", function()
		local short = item(nil, "time", { NOW, NOW + 30000 })
		expect(FieldConfig.display(short, NOW).text).toBe("2024-03-15 13:45:30.250")
		local long = item(nil, "time", { NOW, NOW + 120000 })
		expect(FieldConfig.display(long, NOW).text).toBe("2024-03-15 13:45:30")
	end)
end)

return nil
