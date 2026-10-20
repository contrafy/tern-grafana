--!strict
-- reduce, as packages/grafana-data/src/transformations/transformers/
-- reduce.test.ts pins it (series to rows with several reducers, all-null
-- series, labels to fields, reduce fields mode), plus the gauge that sums a
-- query per field.
local t = require("../../../lib/test")
local T = require("./support")
local Registry = require("../../../../plugin/lib/panels/registry")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = T.NULL

local function multiA()
	return T.frame({
		T.f("time", "time", { 3000, 4000, 5000, 6000 }),
		T.f("temperature", "number", { 3, 4, 5, 6 }),
		T.f("humidity", "number", { 10000.3, 10000.4, 10000.5, 10000.6 }),
	}, "B", "A")
end

local function multiB()
	return T.frame({
		T.f("time", "time", { 1000, 3000, 5000, 7000 }),
		T.f("temperature", "number", { 1, 3, 5, 7 }),
		T.f("humidity", "number", { 11000.1, 11000.3, 11000.5, 11000.7 }),
	}, "E", "B")
end

describe("reduce (reduce.test.ts)", function()
	it("reduces multiple data frames with many fields and dynamic refId", function()
		local out = T.one("reduce", { reducers = { "first", "min", "max", "last", "uniqueValues", "count" } }, {
			multiA(),
			multiB(),
		})
		expect(#out).toBe(1)
		local f = out[1]
		expect(f.refId).toBe("reduce-B-E")
		expect(T.fieldNames(f)).toEqual({ "Field", "First", "Min", "Max", "Last", "All unique values", "Count" })
		expect(f.fields[1].values).toEqual({ "A temperature", "A humidity", "B temperature", "B humidity" })
		expect(f.fields[2].values).toEqual({ 3, 10000.3, 1, 11000.1 })
		expect(f.fields[4].values).toEqual({ 6, 10000.6, 7, 11000.7 })
		expect(f.fields[6].type).toBe("other")
		expect(f.fields[6].values[3]).toEqual({ 1, 3, 5, 7 })
		expect(f.fields[7].type).toBe("number")
		expect(f.fields[7].values).toEqual({ 4, 4, 4, 4 })
	end)

	it("reduces a frame of all nulls to NaN, keeping the row", function()
		local nulls = T.frame({ T.f("time", "time", { 1, 2 }), T.f("temperature", "number", { NULL, NULL }) }, "C", "A")
		local out = T.one("reduce", { reducers = { "max", "count" } }, { multiB(), nulls })
		local max = out[1].fields[2].values
		expect(#max).toBe(3)
		expect(max[3] ~= max[3]).toBe(true)
		-- Nulls are ignored (reduceField's default nullValueMode).
		expect(out[1].fields[3].values[3]).toBe(0)
	end)

	it("reduces keeping label fields", function()
		local a = T.frame({
			T.f("time", "time", { 3000, 4000 }),
			T.f("value", "number", { 3, 4 }, { state = "CA" }),
			T.f("value", "number", { 3, 5 }, { state = "NY" }),
		})
		local b = T.frame({
			T.f("time", "time", { 3000, 4000 }),
			T.f("value", "number", { 3, 6 }, { state = "CA", country = "USA" }),
			T.f("value", "number", { 3, 7 }, { country = "USA" }),
		})
		local out = T.one("reduce", { reducers = { "max" }, labelsToFields = true }, { a, b })
		local f = out[1]
		expect(T.fieldNames(f)).toEqual({ "Field", "state", "country", "Max" })
		expect(f.fields[1].values).toEqual({ "value", "value", "value", "value" })
		expect(f.fields[2].values).toEqual({ "CA", "NY", "CA", NULL })
		expect(f.fields[3].values).toEqual({ NULL, NULL, "USA", "USA" })
		expect(f.fields[4].values).toEqual({ 4, 5, 6, 7 })
	end)

	it("reduce fields mode keeps the frames, one value per reducer with a reducer label", function()
		local out = T.one("reduce", { mode = "reduceFields", reducers = { "max", "last" } }, { multiA() })
		local f = out[1]
		expect(f.refId).toBe("B")
		expect(#f.fields).toBe(4)
		expect(f.fields[1].values).toEqual({ 6 })
		expect(f.fields[1].labels).toEqual({ reducer = "Max" })
		expect(f.fields[2].labels).toEqual({ reducer = "Last" })
		local withTime = T.one(
			"reduce",
			{ mode = "reduceFields", reducers = { "max" }, includeTimeField = true },
			{ multiA() }
		)
		-- getFieldType: every reducer but first/last (and their NotNull) yields a number.
		expect(withTime[1].fields[1].type).toBe("number")
		expect(withTime[1].fields[1].values).toEqual({ 6000 })
	end)

	it("keeps the static refId when no reducer is selected", function()
		local out = T.run({ { id = "reduce", options = { reducers = {} }, refId = "x" } }, { multiA() })
		expect(out[1].refId).toBe("x")
		expect(#out[1].fields).toBe(3)
	end)

	it("names an unknown reducer as the reason to fall back", function()
		expect(T.unsupported("reduce", { reducers = { "max", "nope" } })).toBe(
			"transformation reduce reducer nope is not supported"
		)
	end)
end)

describe("reduce in practice", function()
	for _, version in T.panels.VERSIONS do
		it("a gauge over the per-field sums of a query, Grafana " .. version, function()
			local panel = {
				type = "gauge",
				targets = { { refId = "A" } },
				transformations = {
					{
						id = "reduce",
						options = {
							includeTimeField = false,
							labelsToFields = false,
							mode = "reduceFields",
							reducers = { "sum" },
						},
					},
				},
			}
			expect((Registry.supports(panel, T.env))).toBe(true)
			local frames = T.panels.refFrames(version, "prom_range", "A")
			local out = require("../../../../plugin/lib/panels/transform").prepare(panel, frames, T.env)
			expect(#out).toBe(#frames)
			expect(#out[1].fields).toBe(1)
			local sum = 0
			for _, v in frames[1].fields[2].values do
				sum += v
			end
			expect(math.abs(out[1].fields[1].values[1] - sum) < 1e-9).toBe(true)
		end)
	end
end)

return nil
