--!strict
-- The series reader and sparks are shared by every lens that shows PromQL
-- results. The HTTP API's `data.result` and promtool's `-o json` are the same
-- `model.Value` shapes, so the reader is checked against recorded API bodies
-- of both Prometheus generations; sparks must keep a dead series from
-- looking like the busiest one and never exceed the bar budget.
local Fixtures = require("../../lib/fixtures")
local SeriesView = require("../../../plugin/lib/lens/series")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local VERSIONS = { "2.53.5", "3.15.0" }

local function result(version: string, name: string): any
	return json.decode(Fixtures.read("prometheus/" .. version .. "/" .. name .. ".json")).data.result
end

describe("SeriesView.readJson", function()
	for _, version in VERSIONS do
		describe(version, function()
			it("reads a vector with every label and one sample per series", function()
				local kind, series, unparsed = SeriesView.readJson(result(version, "query_vector"))
				expect(kind).toBe("vector")
				expect(unparsed).toBe(0)
				expect(#series > 0).toBe(true)
				for _, s in series do
					expect(s.labels.__name__).toBe("up")
					expect(#s.times).toBe(1)
					expect(s.times[1]).toBe(1791577898000)
				end
			end)

			it("reads a range matrix with NaN and infinities kept as numbers", function()
				local kind, series = SeriesView.readJson(result(version, "query_range_nan_inf"))
				expect(kind).toBe("matrix")
				local byKind: { [string]: number } = {}
				for _, s in series do
					byKind[s.labels.kind] = s.values[1]
				end
				expect(byKind.nan ~= byKind.nan).toBe(true)
				expect(byKind.inf).toBe(math.huge)
				expect(byKind.neginf).toBe(-math.huge)
			end)

			it("reads a scalar as one unlabeled sample", function()
				local kind, series = SeriesView.readJson(result(version, "query_scalar"))
				expect(kind).toBe("scalar")
				expect(series[1].labels).toEqual({})
				expect(series[1].times).toEqual({ 1791577898000 })
			end)

			it("reads nothing from an empty result, without counting it unreadable", function()
				local kind, series, unparsed = SeriesView.readJson(result(version, "query_empty"))
				expect(kind).toBeNil()
				expect(#series).toBe(0)
				expect(unparsed).toBe(0)
			end)
		end)
	end
end)

describe("SeriesView.spark", function()
	local function series(n: number, f: (number) -> number): ({ number }, { number })
		local times, values = table.create(n), table.create(n)
		for i = 1, n do
			times[i] = 1791577598000 + (i - 1) * 15000
			values[i] = f(i)
		end
		return times, values
	end

	it("never exceeds the bar budget, also for gap-heavy series", function()
		local times, values = series(1000, function(i: number): number
			return math.sin(i / 20)
		end)
		local bars = SeriesView.spark(times, values)
		expect(#bars).toBe(SeriesView.MAX_SPARK)
		local gappy, gv = series(1000, function(i: number): number
			return if i % 2 == 0 then 0 / 0 else i
		end)
		expect(#SeriesView.spark(gappy, gv) <= SeriesView.MAX_SPARK).toBe(true)
		expect(#SeriesView.spark(times, values, 10) <= 10).toBe(true)
	end)

	it("keeps short series whole", function()
		local times, values = series(5, function(i: number): number
			return i
		end)
		expect(#SeriesView.spark(times, values)).toBe(5)
	end)

	-- Tern scales bars to the tallest, so a series near 1000 must not look flat.
	it("maps each series onto its own min..max and draws missing samples as stubs", function()
		local times, values = series(4, function(i: number): number
			return ({ 1000, 1001, 0 / 0, 1000.5 })[i]
		end)
		local bars = SeriesView.spark(times, values)
		expect(bars[1].value).toBe(0.1)
		expect(bars[2].value).toBe(1)
		expect(bars[3].value).toBeNil()
		expect(bars[4].value).toBe(0.55)
		expect(bars[2].title).toBe("1001 at 2026-10-09 20:26:53")
		local flat = SeriesView.spark(series(3, function(): number
			return 7
		end))
		expect({ flat[1].value, flat[2].value, flat[3].value }).toEqual({ 1, 1, 1 })
	end)
end)

return nil
