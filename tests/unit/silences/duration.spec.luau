--!strict
-- The end time is the one thing a silence cannot be wrong about: a typo must
-- be refused rather than read as some other length, and the times sent must
-- be the RFC 3339 UTC Alertmanager parses.
local Duration = require("../../../plugin/lib/silences/duration")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("duration", function()
	it("offers 1h, 2h, 4h and 1d presets, then custom", function()
		local labels = {}
		for _, p in Duration.PRESETS do
			table.insert(labels, p.label .. "=" .. p.s)
		end
		expect(labels).toEqual({ "1h=3600", "2h=7200", "4h=14400", "1d=86400" })
		expect(Duration.CUSTOM).toBe(5)
	end)

	it("parses compound custom durations", function()
		expect((Duration.parse("90m"))).toBe(5400)
		expect((Duration.parse("1d12h"))).toBe(129600)
		expect((Duration.parse("1h 30m"))).toBe(5400)
		expect((Duration.parse("2W"))).toBe(1209600)
		expect((Duration.parse("45s"))).toBe(45)
	end)

	it("refuses anything else instead of guessing", function()
		for _, bad in { "", "90", "1.5h", "h", "1y", "0m", "-1h", "1h-" } do
			local n, err = Duration.parse(bad)
			expect(n).toBeNil()
			expect(type(err)).toBe("string")
		end
		expect((Duration.parse("400d"))).toBeNil()
	end)

	it("shows at most two units", function()
		expect(Duration.format(5400)).toBe("1h 30m")
		expect(Duration.format(93784)).toBe("1d 2h")
		expect(Duration.format(86400 + 60)).toBe("1d")
		expect(Duration.format(42)).toBe("42s")
	end)

	it("writes RFC 3339 UTC with milliseconds", function()
		expect(Duration.iso(1791577898000)).toBe("2026-10-09T20:31:38.000Z")
		expect(Duration.iso(1791577898123 + 3600000)).toBe("2026-10-09T21:31:38.123Z")
	end)
end)

return nil
