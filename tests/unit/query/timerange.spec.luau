--!strict
-- Range keys must agree with Grafana's (half-span shift, x2 zoom out) and
-- keep a live "last N" range live when zooming, so auto-refresh keeps
-- following now instead of freezing on the moment the key was pressed.
local TimeRange = require("../../../plugin/lib/query/timerange")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577898000
local H = 3600000

local function pair(a: string?, b: string?): { string? }
	return { a, b }
end

describe("TimeRange", function()
	it("maps 1..9 to Grafana's quick ranges", function()
		expect(pair(TimeRange.forKey("1", "now-1h", "now", NOW))).toEqual({ "now-5m", "now" })
		expect(pair(TimeRange.forKey("3", "x", "y", NOW))).toEqual({ "now-1h", "now" })
		expect(pair(TimeRange.forKey("9", "now-1h", "now", NOW))).toEqual({ "now-7d", "now" })
	end)

	it("shifts by half a span into absolute times", function()
		expect(pair(TimeRange.forKey("[", "now-1h", "now", NOW))).toEqual({
			string.format("%d", NOW - 3 * H / 2),
			string.format("%d", NOW - H / 2),
		})
		local from, to = TimeRange.forKey("]", tostring(NOW - 2 * H), tostring(NOW), NOW)
		expect(pair(from, to)).toEqual({ string.format("%d", NOW - H), string.format("%d", NOW + H) })
	end)

	it("zooms a live range around now and keeps it live", function()
		expect(pair(TimeRange.forKey("-", "now-1h", "now", NOW))).toEqual({ "now-2h", "now" })
		expect(pair(TimeRange.forKey("+", "now-1h", "now", NOW))).toEqual({ "now-30m", "now" })
		expect(pair(TimeRange.forKey("=", "now-5m", "now", NOW))).toEqual({ "now-150s", "now" })
		expect(pair(TimeRange.forKey("-", "now-12h", "now", NOW))).toEqual({ "now-1d", "now" })
		expect(pair(TimeRange.forKey("+", "now-15s", "now", NOW))).toEqual({ "now-10s", "now" })
	end)

	it("zooms any other range around its center", function()
		local from, to = TimeRange.forKey("-", tostring(NOW - 2 * H), tostring(NOW), NOW)
		expect(pair(from, to)).toEqual({ string.format("%d", NOW - 3 * H), string.format("%d", NOW + H) })
		local f2, t2 = TimeRange.forKey("+", "now/d", "now/d", NOW)
		expect(f2 ~= nil and t2 ~= nil).toBe(true)
	end)

	it("ignores other keys and unresolvable ranges", function()
		expect(pair(TimeRange.forKey("x", "now-1h", "now", NOW))).toEqual({})
		expect(pair(TimeRange.forKey("0", "now-1h", "now", NOW))).toEqual({})
		expect(pair(TimeRange.forKey("[", "bogus", "now", NOW))).toEqual({})
	end)
end)

return nil
