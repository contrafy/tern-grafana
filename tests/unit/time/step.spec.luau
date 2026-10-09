--!strict
-- Intervals follow Grafana: the panel interval ($__interval for frontend
-- datasources) is packages/grafana-data/src/datetime/rangeutil.ts
-- calculateInterval/roundInterval; the Prometheus step and the built-in
-- variables follow pkg/promlib/models/query.go (calculatePrometheusInterval,
-- calculateRateInterval, InterpolateVariables, AlignTimeRange) with
-- grafana-plugin-sdk-go backend/gtime RoundInterval/FormatInterval. Durations
-- follow Prometheus common/model ParseDuration and Duration.String.
local t = require("../../lib/test")
local step = require("../../../plugin/lib/time/step")
local describe, it, expect = t.describe, t.it, t.expect

local HOUR = 3600000
local DAY = 24 * HOUR

describe("step.roundInterval (rangeutil.ts)", function()
	-- Each bucket's lower edge is exclusive of the rounding below it.
	it("rounds to Grafana's table at every edge", function()
		local cases = {
			{ 9.999, 1 },
			{ 10, 10 },
			{ 14.999, 10 },
			{ 15, 20 },
			{ 35, 50 },
			{ 1499, 1000 },
			{ 1500, 2000 },
			{ 7499, 5000 },
			{ 7500, 10000 },
			{ 12500, 15000 },
			{ 17500, 20000 },
			{ 45000, 60000 },
			{ 89999, 60000 },
			{ 90000, 120000 },
			{ 2700000, 3600000 },
			{ 86399999, 43200000 },
			{ 86400000, 86400000 },
			{ 604800000, 604800000 },
			{ 1814399999, 604800000 },
			{ 1814400000, 2592000000 },
			{ 3628800000, 31536000000 },
		}
		for _, c in cases do
			expect({ c[1], step.roundInterval(c[1]) }).toEqual({ c[1], c[2] })
		end
	end)
end)

describe("step.roundStep (gtime.RoundInterval)", function()
	-- The backend table uses inclusive upper edges and differs above 1 day.
	it("rounds with inclusive edges and the backend's day/week/month rows", function()
		local cases = {
			{ 10, 1 },
			{ 10.000001, 10 },
			{ 12500, 10000 },
			{ 12501, 15000 },
			{ 25000, 20000 },
			{ 172800000, DAY },
			{ 604800000, DAY },
			{ 604800001, 7 * DAY },
			{ 1814400000, 7 * DAY },
			{ 1814400001, 30 * DAY },
			{ 63071999999, 30 * DAY },
			{ 63072000000, 365 * DAY },
		}
		for _, c in cases do
			expect({ c[1], step.roundStep(c[1]) }).toEqual({ c[1], c[2] })
		end
	end)
end)

describe("step.interval (calculateInterval)", function()
	it("divides the range by max data points and rounds", function()
		expect(step.interval(6 * HOUR, 1000)).toEqual({ interval_ms = 20000, interval_str = "20s" })
		expect(step.interval(1000, 1000)).toEqual({ interval_ms = 1, interval_str = "1ms" })
		expect(step.interval(30 * DAY, 1000)).toEqual({ interval_ms = 1800000, interval_str = "30m" })
	end)

	-- The minimum interval is the datasource scrape interval: going below it
	-- returns empty buckets. It is applied unrounded.
	it("never goes below the minimum interval, which is not rounded", function()
		expect(step.interval(6 * HOUR, 1000, 30000)).toEqual({ interval_ms = 30000, interval_str = "30s" })
		expect(step.interval(6 * HOUR, 1000, 45000)).toEqual({ interval_ms = 45000, interval_str = "45s" })
		expect(step.interval(6 * HOUR, 1000, 10000)).toEqual({ interval_ms = 20000, interval_str = "20s" })
	end)
end)

describe("step.formatInterval", function()
	it("keeps only the largest whole unit", function()
		expect(step.formatInterval(90000)).toBe("1m")
		expect(step.formatInterval(1500)).toBe("1s")
		expect(step.formatInterval(500)).toBe("500ms")
		expect(step.formatInterval(25 * HOUR)).toBe("1d")
		expect(step.formatInterval(400 * DAY)).toBe("1y")
		expect(step.formatInterval(0.5)).toBe("1ms")
	end)
end)

describe("step.promStep (calculatePrometheusInterval)", function()
	it("rounds range / max data points with the backend table", function()
		expect(step.promStep(6 * HOUR, 1000)).toBe(20000)
		expect(step.promStep(30 * DAY, 100)).toBe(6 * HOUR)
	end)

	it("uses the minimum step unrounded when the computed step is smaller", function()
		expect(step.promStep(HOUR, 1000, 15000)).toBe(15000)
		expect(step.promStep(HOUR, 1000, 45000)).toBe(45000)
	end)

	-- Prometheus refuses more than 11000 points per series, so Grafana floors
	-- the step at range / 11000 regardless of the requested resolution.
	it("never asks for more than 11000 points", function()
		expect(step.promStep(7 * DAY, 100000, 15000)).toBe(60000)
	end)

	it("defaults to 1500 points and a 15s minimum", function()
		expect(step.promStep(DAY, 0)).toBe(60000)
		expect(step.promStep(10 * 60000, 1000)).toBe(15000)
	end)

	it("multiplies by the legacy interval factor", function()
		expect(step.promStep(6 * HOUR, 1000, nil, 2)).toBe(40000)
	end)
end)

describe("step.rateInterval", function()
	-- rate() needs at least four scrapes in its window to survive a missed
	-- scrape, and one scrape more than the step to not drop samples.
	it("is max(interval + scrape, 4 * scrape)", function()
		expect(step.rateInterval(20000, 15000)).toBe(60000)
		expect(step.rateInterval(45000, 15000)).toBe(60000)
		expect(step.rateInterval(46000, 15000)).toBe(61000)
		expect(step.rateInterval(120000, 15000)).toBe(135000)
		expect(step.rateInterval(20000, 30000)).toBe(120000)
	end)

	it("assumes a 15s scrape interval when none is configured", function()
		expect(step.rateInterval(20000)).toBe(60000)
	end)
end)

describe("step.align (AlignTimeRange)", function()
	it("floors start and end to multiples of the step", function()
		local s, e = step.align(1710510330123, 1710531930123, 15000)
		expect({ s, e }).toEqual({ 1710510330000, 1710531930000 })
		s, e = step.align(1710510330000, 1710510345000, 15000)
		expect({ s, e }).toEqual({ 1710510330000, 1710510345000 })
	end)

	-- Daily steps line up with local midnight (2024-03-15T00:00+01:00).
	it("aligns in the dashboard's UTC offset", function()
		local s = step.align(1710510330123, 1710510330123, DAY, 3600)
		expect(s).toBe(1710457200000)
	end)
end)

describe("step.macros and step.interpolate (InterpolateVariables)", function()
	it("derives every built-in range variable", function()
		expect(step.macros(6 * HOUR, 20000, 20000)).toEqual({
			interval = "20s",
			interval_ms = "20000",
			range = "21600s",
			range_s = "21600",
			range_ms = "21600000",
			rate_interval = "1m",
			rate_interval_ms = "60000",
		})
	end)

	it("rounds $__range to whole seconds, halves away from zero", function()
		local m = step.macros(1500, 1, 1)
		expect(m.range).toBe("2s")
		expect(m.range_s).toBe("2")
		expect(m.range_ms).toBe("1500")
	end)

	it("uses the frontend interval and scrape interval for $__rate_interval", function()
		local m = step.macros(30 * DAY, 6 * HOUR, 2 * HOUR, 30000)
		expect(m.interval).toBe("6h")
		expect(m.rate_interval).toBe("2h30s")
		expect(m.rate_interval_ms).toBe("7230000")
	end)

	-- Longer names first, so $__interval_ms is not read as $__interval + "_ms".
	it("replaces both spellings without clobbering longer names", function()
		local m = step.macros(6 * HOUR, 20000, 20000)
		local expr = "rate(x[$__rate_interval]) * $__interval_ms / ${__range_s} + $__range + ${__interval} "
			.. "+ $__rate_interval_ms + ${__range_ms} + $__range_ms + ${__rate_interval}"
		expect(step.interpolate(expr, m)).toBe(
			"rate(x[1m]) * 20000 / 21600 + 21600s + 20s + 60000 + 21600000 + 21600000 + 1m"
		)
	end)

	it("leaves unrelated dollar text alone", function()
		local m = step.macros(6 * HOUR, 20000, 20000)
		expect(step.interpolate('up{job="$job"} $__intervals', m)).toBe('up{job="$job"} 20ss')
	end)
end)

describe("step.parseDuration / formatDuration (Prometheus)", function()
	it("parses compound durations in descending unit order", function()
		expect(step.parseDuration("1h30m")).toBe(5400000)
		expect(step.parseDuration("500ms")).toBe(500)
		expect(step.parseDuration("1y")).toBe(365 * DAY)
		expect(step.parseDuration("2w")).toBe(14 * DAY)
		expect(step.parseDuration("1d12h")).toBe(36 * HOUR)
		expect(step.parseDuration("1m30s250ms")).toBe(90250)
		expect(step.parseDuration("0")).toBe(0)
	end)

	-- The HTTP API also accepts a bare float number of seconds for step.
	it("reads bare numbers as seconds", function()
		expect(step.parseDuration("30")).toBe(30000)
		expect(step.parseDuration("1.5")).toBe(1500)
	end)

	it("rejects anything Prometheus would reject", function()
		for _, bad in { "", "1m1h", "1.5m", "-1m", "5x", "1h 30m", "ms", "1hh" } do
			expect(step.parseDuration(bad)).toBeNil()
		end
	end)

	it("formats like model.Duration.String", function()
		expect(step.formatDuration(0)).toBe("0s")
		expect(step.formatDuration(5400000)).toBe("1h30m")
		expect(step.formatDuration(500)).toBe("500ms")
		expect(step.formatDuration(1500)).toBe("1s500ms")
		expect(step.formatDuration(60000)).toBe("1m")
		expect(step.formatDuration(36 * HOUR)).toBe("1d12h")
		expect(step.formatDuration(14 * DAY)).toBe("2w")
		-- Years and weeks only when exact.
		expect(step.formatDuration(365 * DAY)).toBe("1y")
		expect(step.formatDuration(366 * DAY)).toBe("366d")
		expect(step.formatDuration(8 * DAY)).toBe("8d")
	end)

	it("round-trips", function()
		for _, ms in { 1, 999, 61000, 5400000, 36 * HOUR, 14 * DAY, 730 * DAY } do
			expect(step.parseDuration(step.formatDuration(ms))).toBe(ms)
		end
	end)
end)

describe("step.maxPoints", function()
	-- Grafana asks for one point per pixel; a terminal cell is about 8 px wide.
	it("asks for one point per pixel of the pane", function()
		expect(step.maxPoints(200)).toBe(1600)
		expect(step.maxPoints(200, 2)).toBe(400)
		expect(step.maxPoints(80, 1.5)).toBe(120)
	end)

	it("asks for at least one point", function()
		expect(step.maxPoints(0)).toBe(1)
		expect(step.maxPoints(-5)).toBe(1)
	end)
end)

return nil
