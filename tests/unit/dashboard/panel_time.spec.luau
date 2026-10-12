--!strict
-- Panel time overrides as Grafana's PanelTimeRange.getTimeOverride
-- (public/app/features/dashboard-scene/scene/panel-timerange/
-- PanelTimeRange.tsx) computes them: the query range a panel really uses and
-- the info its header shows.
local t = require("../../lib/test")
local PanelTime = require("../../../plugin/lib/dashboard/panel_time")
local Range = require("../../../plugin/lib/time/range")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577907000
local HOUR = 3600000
local OPTS = { now_ms = NOW }

local function parent(from: string, to: string): PanelTime.Parent
	return { from = from, to = to, range = assert(Range.resolve(from, to, OPTS)) }
end

describe("describeTextRange", function()
	it("reads a bare duration as the last N units and names Grafana's quick ranges", function()
		local r = PanelTime.describeTextRange("1h")
		expect(r.from).toBe("now-1h")
		expect(r.to).toBe("now")
		expect(r.display).toBe("Last 1 hour")
		expect(PanelTime.describeTextRange("2d").display).toBe("Last 2 days")
		expect(PanelTime.describeTextRange("now/d").display).toBe("Today so far")
		expect(PanelTime.describeTextRange("+1h").display).toBe("Next 1 hour")
		expect(PanelTime.describeTextRange("nonsense").invalid).toBe(true)
	end)
end)

describe("panel time override", function()
	it("replaces a relative dashboard range with timeFrom", function()
		local o = PanelTime.apply({ timeFrom = "1h" }, parent("now-6h", "now"), OPTS)
		expect(o.range.from_ms).toBe(NOW - HOUR)
		expect(o.range.to_ms).toBe(NOW)
		expect(o.info).toBe("Last 1 hour")
		expect(o.overridden).toBe(true)
	end)

	it("keeps an absolute dashboard range under timeFrom", function()
		local p = parent("2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z")
		local o = PanelTime.apply({ timeFrom = "1h" }, p, OPTS)
		expect(o.range).toEqual(p.range)
		expect(o.info).toBe("")
	end)

	it("shifts the range back by timeShift, relative and absolute", function()
		local o = PanelTime.apply({ timeShift = "1h" }, parent("now-6h", "now"), OPTS)
		expect(o.range.from_ms).toBe(NOW - 7 * HOUR)
		expect(o.range.to_ms).toBe(NOW - HOUR)
		expect(o.info).toBe("timeshift -1h")
		local p = parent("2026-10-01T00:00:00Z", "2026-10-02T00:00:00Z")
		local a = PanelTime.apply({ timeShift = "1d" }, p, OPTS)
		expect(a.range.from_ms).toBe(p.range.from_ms - 24 * HOUR)
		expect(a.range.to_ms).toBe(p.range.to_ms - 24 * HOUR)
	end)

	it("combines both, interpolates variables, and hides the info on request", function()
		local o = PanelTime.apply(
			{ timeFrom = "$span", timeShift = "1h" },
			parent("now-6h", "now"),
			OPTS,
			function(s: string): string
				return (string.gsub(s, "%$span", "2h"))
			end
		)
		expect(o.range.from_ms).toBe(NOW - 3 * HOUR)
		expect(o.range.to_ms).toBe(NOW - HOUR)
		expect(o.info).toBe("Last 2 hours timeshift -1h")
		local hidden = PanelTime.apply({ timeFrom = "2h", hideTimeOverride = true }, parent("now-6h", "now"), OPTS)
		expect(hidden.info).toBe("")
		expect(hidden.range.from_ms).toBe(NOW - 2 * HOUR)
	end)

	it("reports invalid values and keeps the dashboard range", function()
		local p = parent("now-6h", "now")
		local o = PanelTime.apply({ timeFrom = "soon" }, p, OPTS)
		expect(o.info).toBe("invalid time override")
		expect(o.range).toEqual(p.range)
		expect(PanelTime.apply({ timeShift = "later" }, p, OPTS).info).toBe("invalid timeshift")
	end)
end)

return nil
