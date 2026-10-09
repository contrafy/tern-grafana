--!strict
-- Reducers as in packages/grafana-data/src/transformations/fieldReducer.ts
-- (doStandardCalcs and the non-standard reducers). A stat or legend that
-- reduces differently from Grafana shows a different number for the same
-- query, which is the one thing a native panel must never do.
local t = require("../../lib/test")
local Frame = require("../../../plugin/lib/frame/types")
local Reduce = require("../../../plugin/lib/panels/reduce")
local S = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = Frame.NULL

local function near(a: any, b: number)
	expect(type(a)).toBe("number")
	if math.abs(a - b) > 1e-9 * math.max(1, math.abs(b)) then
		error(string.format("expected %.12g to be near %.12g", a, b))
	end
end

-- prom_range refId A, the `user` CPU series (61 samples, no gaps), with
-- the expected values computed from the capture by Grafana's definitions.
local USER = {
	["11.6.16"] = {
		first = 0.14899999999999636,
		lastNotNull = 0.1812000000000012,
		min = 0.14219999999999572,
		max = 0.4391824327026972,
		mean = 0.18769199024850636,
		sum = 11.449211405158888,
		range = 0.29698243270270147,
		delta = 0.4502130142851432,
		diff = 0.032200000000004836,
	},
	["12.4.12"] = {
		first = 0.10023976111110837,
		lastNotNull = 0.2667999999999961,
		min = 0.10023976111110837,
		max = 0.4391824327026972,
		mean = 0.1863647732175409,
		sum = 11.368251166269996,
		range = 0.3389426715915888,
		delta = 0.49897325317403113,
		diff = 0.1665602388888877,
	},
}

local function userValues(version: string): { any }
	for _, f in S.refFrames(version, "prom_range", "A") do
		local field = f.fields[2]
		if field.labels and field.labels.mode == "user" then
			return field.values
		end
	end
	error("no user series")
end

for _, version in S.VERSIONS do
	describe("reduce over Grafana " .. version .. " prom_range", function()
		it("matches doStandardCalcs for every standard reducer", function()
			local values = userValues(version)
			local ids = { "first", "lastNotNull", "min", "max", "mean", "sum", "range", "delta", "diff" }
			local c = Reduce.calcs(values, ids, "number")
			for _, id in ids do
				near(c[id], (USER :: any)[version][id])
			end
			expect(c.count).toBe(61)
			near(c.last, (USER :: any)[version].lastNotNull)
		end)
	end)
end

describe("reduce null handling (fieldReducer.ts nullValueMode)", function()
	local values = { NULL, 4, NULL, 1, 0 / 0, 3, NULL }

	it("skips nulls by default but keeps them for first/last", function()
		local c = Reduce.calcs(values, {}, "number")
		expect(c.first).toBeNil()
		expect(c.last).toBeNil()
		expect(c.firstNotNull).toBe(4)
		expect(c.lastNotNull).toBe(3)
	end)

	-- NaN is not null: it counts, but never poisons sum, min, max or mean.
	it("counts NaN without letting it into the arithmetic", function()
		local c = Reduce.calcs(values, {}, "number")
		expect(c.count).toBe(4)
		expect(c.sum).toBe(8)
		expect(c.min).toBe(1)
		expect(c.max).toBe(4)
		near(c.mean, 8 / 3)
	end)

	it("counts nulls as zero in 'null as zero' mode", function()
		local c = Reduce.calcs(values, {}, "number", "null as zero")
		expect(c.count).toBe(7)
		expect(c.min).toBe(0)
	end)

	it("reports no value for an all-null series and zero for sum/count", function()
		local c = Reduce.calcs({ NULL, NULL }, {}, "number")
		expect(c.lastNotNull).toBeNil()
		expect(c.mean).toBeNil()
		expect(c.min).toBeNil()
		expect(c.max).toBeNil()
		expect(c.range).toBeNil()
		expect(c.sum).toBe(0)
		expect(c.count).toBe(0)
		expect(c.allIsNull).toBe(true)
	end)
end)

describe("reduce delta vs diff (fieldReducer.ts doStandardCalcs)", function()
	-- delta is a counter's increase: a drop is a reset, and the step right
	-- after a reset is not counted (previousDeltaUp); diff is last - first.
	it("treats a decrease as a counter reset in delta", function()
		local c = Reduce.calcs({ 10, 15, 20, 2, 5, 9 }, {}, "number")
		expect(c.delta).toBe(14)
		expect(c.diff).toBe(-1)
		expect(c.range).toBe(18)
	end)

	it("computes diffperc from the first value", function()
		expect(Reduce.reduce({ 50, 75 }, "diffperc", "number")).toBe(50)
	end)
end)

describe("reduce non-standard reducers", function()
	it("matches calculateMedian, calculateStdDev and percentiles", function()
		local v = { 4, 1, 3, 2 }
		expect(Reduce.reduce(v, "median")).toBe(2.5)
		near(Reduce.reduce(v, "variance"), 1.25)
		near(Reduce.reduce(v, "stdDev"), math.sqrt(1.25))
		-- calculatePercentile: sorted[round((n - 1) * p)].
		expect(Reduce.reduce({ 10, 20, 30, 40, 50 }, "p50")).toBe(30)
		expect(Reduce.reduce({ 10, 20, 30, 40, 50 }, "p90")).toBe(50)
	end)

	it("counts changes and distinct values", function()
		expect(Reduce.reduce({ 1, 1, 2, 2, 1 }, "changeCount")).toBe(2)
		expect(Reduce.reduce({ "a", "b", "a", NULL }, "distinctCount", "string")).toBe(2)
	end)

	it("reduces string fields to first/last only", function()
		local c = Reduce.calcs({ "x", "y" }, {}, "string")
		expect(c.lastNotNull).toBe("y")
		expect(c.firstNotNull).toBe("x")
		expect(c.sum).toBeNil()
		expect(c.mean).toBeNil()
	end)

	it("names reducers like Grafana's picker and knows which exist", function()
		expect(Reduce.name("lastNotNull")).toBe("Last *")
		expect(Reduce.name("sum")).toBe("Total")
		expect(Reduce.name("p95")).toBe("95th %")
		expect(Reduce.name("p1")).toBe("1st %")
		expect(Reduce.supports("allValues")).toBe(false)
		expect(Reduce.supports("p100")).toBe(false)
	end)
end)

return nil
