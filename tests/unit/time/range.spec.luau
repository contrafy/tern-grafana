--!strict
-- Relative expressions follow Grafana's date math
-- (packages/grafana-data/src/datetime/datemath.ts parseDateMath, moment
-- startOf/endOf/add); expected instants were produced by running that code on
-- moment with the same fixed offsets. Display strings follow
-- datetime/rangeutil.ts describeTimeRange/describeTextRange.
local t = require("../../lib/test")
local range = require("../../../plugin/lib/time/range")
local describe, it, expect = t.describe, t.it, t.expect

-- Friday 2024-03-15T13:45:30.123Z
local NOW = 1710510330123
local UTC = { now_ms = NOW }

local function at(text: string, roundUp: boolean, opts: range.Options?): number?
	return (range.parse(text, roundUp, opts or UTC))
end

describe("range.parse relative", function()
	it("subtracts and adds units from now", function()
		expect(at("now", false)).toBe(NOW)
		expect(at("now-6h", false)).toBe(1710488730123)
		expect(at("now-2w", false)).toBe(1709300730123)
		expect(at("now-30s/m", false)).toBe(1710510300000)
		expect(at("now+1y", false)).toBe(1742046330123)
	end)

	-- `from` rounds down and `to` rounds up, so now/d..now/d covers the whole day.
	it("rounds /d down for from and up to the last millisecond for to", function()
		expect(at("now/d", false)).toBe(1710460800000)
		expect(at("now/d", true)).toBe(1710547199999)
		expect(at("now-1d/d", false)).toBe(1710374400000)
		expect(at("now-1d/d", true)).toBe(1710460799999)
		expect(at("now-7d/d", false)).toBe(1709856000000)
		expect(at("now/s", true)).toBe(1710510330999)
		expect(at("now+1h/h", true)).toBe(1710514799999)
	end)

	it("rounds weeks, months, quarters and years on calendar boundaries", function()
		expect(at("now/w", false)).toBe(1710028800000)
		expect(at("now/w", true)).toBe(1710633599999)
		expect(at("now/M", false)).toBe(1709251200000)
		expect(at("now/M", true)).toBe(1711929599999)
		expect(at("now/Q", false)).toBe(1704067200000)
		expect(at("now/Q", true)).toBe(1711929599999)
		expect(at("now/y", false)).toBe(1704067200000)
		expect(at("now/y", true)).toBe(1735689599999)
	end)

	-- Grafana's default (en) week starts on Sunday; a Monday start moves it a day.
	it("honors the configured first day of the week", function()
		expect(at("now/w", false, { now_ms = NOW, week_start = 1 })).toBe(1710115200000)
	end)

	-- Day boundaries are local midnight: UTC-5 ends its day at 04:59:59.999Z.
	it("rounds in the given fixed UTC offset", function()
		expect(at("now/d", false, { now_ms = NOW, offset_min = -300 })).toBe(1710478800000)
		expect(at("now/d", true, { now_ms = NOW, offset_min = -300 })).toBe(1710565199999)
		expect(at("now/d", false, { now_ms = NOW, offset_min = 600 })).toBe(1710424800000)
		expect(at("now/w", false, { now_ms = NOW, offset_min = -840 })).toBe(1710079200000)
	end)

	-- moment clamps to the last day of a shorter month instead of overflowing.
	it("clamps month and year arithmetic to the end of the month", function()
		local jan31 = 1706695200000 -- 2024-01-31T10:00:00Z
		expect(at("now+1M", false, { now_ms = jan31 })).toBe(1709200800000) -- 2024-02-29T10:00Z
		local leap = 1709164800000 -- 2024-02-29T00:00:00Z
		expect(at("now+1y", false, { now_ms = leap })).toBe(1740700800000) -- 2025-02-28
		expect(at("now-1M", false)).toBe(1708004730123)
		local may31 = 1717131600000 -- 2024-05-31T05:00:00Z
		expect(at("now-1Q", false, { now_ms = may31 })).toBe(1709182800000) -- 2024-02-29T05:00Z
	end)

	it("rounds fiscal years and quarters from the fiscal start month", function()
		local fyOct = { now_ms = NOW, fiscal_year_start_month = 9 }
		expect(at("now/fy", false, fyOct)).toBe(1696118400000)
		expect(at("now/fy", true, fyOct)).toBe(1727740799999)
		local fyFeb = { now_ms = NOW, fiscal_year_start_month = 1 }
		expect(at("now/fQ", false, fyFeb)).toBe(1706745600000)
		expect(at("now/fQ", true, fyFeb)).toBe(1714521599999)
		expect(at("now-1Q/fQ", false, fyFeb)).toBe(1698796800000)
	end)

	it("ignores whitespace inside the expression", function()
		expect(at("now - 5 m", false)).toBe(1710510030123)
		expect(at("  now-5m  ", false)).toBe(1710510030123)
	end)

	it("rejects malformed math with a reason", function()
		for _, bad in { "now-123456m", "now/2d", "now-5x", "now*5m", "nowx", "now-", "now/fM", "" } do
			local v, err = range.parse(bad, false, UTC)
			expect(v).toBeNil()
			expect(err).toContain("invalid time")
		end
	end)
end)

describe("range.parse absolute", function()
	it("reads RFC 3339 with Z, numeric offsets and fractions", function()
		expect(at("2024-03-15T13:45:30Z", false)).toBe(1710510330000)
		expect(at("2024-03-15T13:45:30.5+02:00", false)).toBe(1710503130500)
		expect(at("2024-03-15t00:00:00-0500", false)).toBe(1710478800000)
		expect(at("2024-03-15 13:45:30Z", false)).toBe(1710510330000)
		expect(at("1969-12-31T23:59:59.999Z", false)).toBe(-1)
	end)

	it("reads zoneless dates and times in the configured offset", function()
		expect(at("2024-03-15", false)).toBe(1710460800000)
		expect(at("2024-03-15T00:00:00", false, { now_ms = NOW, offset_min = -300 })).toBe(1710478800000)
		expect(at("2024-03-15 13:45", false)).toBe(1710510300000)
	end)

	-- Grafana URLs carry epoch milliseconds; Prometheus and promtool use
	-- seconds. Values below 1e11 cannot be meaningful milliseconds (1973).
	it("tells epoch seconds from epoch milliseconds", function()
		expect(at("1710510330123", false)).toBe(1710510330123)
		expect(at("1710510330", false)).toBe(1710510330000)
		expect(at("1710510330.5", false)).toBe(1710510330500)
		expect(at("0", false)).toBe(0)
	end)

	it("reads Grafana's compact URL forms in UTC", function()
		expect(at("20240315", false)).toBe(1710460800000)
		expect(at("20240315T134530", false)).toBe(1710510330000)
	end)

	it("applies || math to an absolute anchor", function()
		expect(at("2024-03-15T13:45:30Z||+1d/d", false)).toBe(1710547200000)
		expect(at("2024-03-15T13:45:30Z||/d", true)).toBe(1710547199999)
	end)

	it("rejects impossible calendar dates", function()
		for _, bad in { "2024-02-30T00:00:00Z", "2023-02-29", "2024-13-01", "2024-03-15T24:00:00Z", "yesterday" } do
			expect(at(bad, false)).toBeNil()
		end
		expect(at("2024-02-29", false)).toBe(1709164800000)
	end)
end)

describe("range.resolve", function()
	it("resolves from rounded down and to rounded up", function()
		expect((range.resolve("now-1d/d", "now-1d/d", UTC))).toEqual({ from_ms = 1710374400000, to_ms = 1710460799999 })
		expect((range.resolve("now-6h", "now", UTC))).toEqual({ from_ms = 1710488730123, to_ms = NOW })
	end)

	it("reports which side is invalid and refuses an inverted range", function()
		local r, err = range.resolve("now-6x", "now", UTC)
		expect(r).toBeNil()
		expect(err).toContain("from")
		r, err = range.resolve("now", "now-1h", UTC)
		expect(r).toBeNil()
		expect(err).toContain("after")
	end)

	it("knows relative expressions from absolute times", function()
		expect(range.isRelative("now-6h")).toBe(true)
		expect(range.isRelative("2024-03-15T13:45:30Z||+1d")).toBe(false)
		expect(range.isRelative("1710510330123")).toBe(false)
	end)
end)

describe("range.describe", function()
	it("uses Grafana's quick range names", function()
		expect(range.describe("now-6h", "now")).toBe("Last 6 hours")
		expect(range.describe("now-1h", "now")).toBe("Last 1 hour")
		expect(range.describe("now/d", "now/d")).toBe("Today")
		expect(range.describe("now/d", "now")).toBe("Today so far")
		expect(range.describe("now-1d/d", "now-1d/d")).toBe("Yesterday")
		expect(range.describe("now/w", "now/w")).toBe("This week")
		expect(range.describe("now", "now+6h")).toBe("Next 6 hours")
	end)

	it("spells out other last-N ranges ending now", function()
		expect(range.describe("now-45m", "now")).toBe("Last 45 minutes")
		expect(range.describe("now-1m", "now")).toBe("Last 1 minute")
		expect(range.describe("now-3w", "now")).toBe("Last 3 weeks")
		expect(range.describe("now-2Q", "now")).toBe("Last 2 quarters")
	end)

	it("falls back to the raw expressions", function()
		expect(range.describe("now-6h", "now-1h")).toBe("now-6h to now-1h")
		expect(range.describe("now-6x", "now")).toBe("now-6x to now")
	end)

	it("formats absolute times in the configured offset", function()
		expect(range.describe("1710510330000", "2024-03-15T19:45:30Z")).toBe(
			"2024-03-15 13:45:30 to 2024-03-15 19:45:30"
		)
		expect(range.describe("1710510330000", "1710531930000", -300)).toBe(
			"2024-03-15 08:45:30 to 2024-03-15 14:45:30"
		)
		expect(range.describe("1710510330000", "now")).toBe("2024-03-15 13:45:30 to now")
	end)

	it("formats an instant with a fixed offset", function()
		expect(range.formatMs(0)).toBe("1970-01-01 00:00:00")
		expect(range.formatMs(-1)).toBe("1969-12-31 23:59:59")
		expect(range.formatMs(951868800000, 60)).toBe("2000-03-01 01:00:00")
	end)
end)

describe("range zoom and shift", function()
	local r = { from_ms = 1000, to_ms = 3000 }

	it("zooms out around the center", function()
		expect(range.zoomOut(r)).toEqual({ from_ms = 0, to_ms = 4000 })
		expect(range.zoom(r, 0.5)).toEqual({ from_ms = 1500, to_ms = 2500 })
	end)

	it("shifts by half the span in either direction", function()
		expect(range.shift(r, -1)).toEqual({ from_ms = 0, to_ms = 2000 })
		expect(range.shift(r, 1)).toEqual({ from_ms = 2000, to_ms = 4000 })
	end)

	it("keeps whole milliseconds for odd spans", function()
		expect(range.zoomOut({ from_ms = 10, to_ms = 13 })).toEqual({ from_ms = 8, to_ms = 14 })
		expect(range.shift({ from_ms = 10, to_ms = 13 }, 1)).toEqual({ from_ms = 11, to_ms = 14 })
	end)
end)

return nil
