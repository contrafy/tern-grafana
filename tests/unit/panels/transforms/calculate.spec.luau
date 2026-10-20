--!strict
-- calculateField, as packages/grafana-data/src/transformations/transformers/
-- calculateField.test.ts pins it: the cases below are that file's (same
-- frames, options and expected rows), plus the shapes dashboards use it in:
-- a stat or gauge reading a row reduction or a ratio of two queries.
local t = require("../../../lib/test")
local T = require("./support")
local Registry = require("../../../../plugin/lib/panels/registry")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = T.NULL

local function seriesA()
	return T.frame({ T.f("TheTime", "time", { 1000, 2000 }), T.f("A", "number", { 1, 100 }) })
end

local function seriesBC()
	return T.frame({
		T.f("TheTime", "time", { 1000, 2000 }),
		T.f("B", "number", { 2, 200 }),
		T.f("C", "number", { 3, 300 }),
		T.f("D", "string", { "first", "second" }),
		T.f("E", "boolean", { true, false }),
	})
end

local function calc(options: any, frames: { any }): { any }
	return T.one("calculateField", options, frames)
end

describe("calculateField (calculateField.test.ts)", function()
	it("will filter and alias: sums every number field of the time-joined frames", function()
		local out = calc({ alias = "The Total" }, { seriesA(), seriesBC() })
		expect(#out).toBe(1)
		expect(T.names(out[1])).toEqual({ "TheTime", "A", "B", "C", "D", "E", "The Total" })
		expect(T.col(out[1], "The Total")).toEqual({ 6, 600 })
		expect(out[1].refId).toBe("joinByField--")
	end)

	it("will replace other fields", function()
		local out = calc(
			{ mode = "reduceRow", reduce = { reducer = "mean" }, replaceFields = true },
			{ seriesA(), seriesBC() }
		)
		expect(T.names(out[1])).toEqual({ "TheTime", "Mean" })
		expect(T.col(out[1], "Mean")).toEqual({ 2, 200 })
	end)

	it("will filter by name", function()
		local out = calc(
			{ mode = "reduceRow", reduce = { include = { "B" }, reducer = "mean" }, replaceFields = true },
			{ seriesBC() }
		)
		expect(T.col(out[1], "Mean")).toEqual({ 2, 200 })
	end)

	it("binary math (operands in the pre-10.3 string form)", function()
		local out = calc(
			{ mode = "binary", binary = { left = "B", operator = "+", right = "C" }, replaceFields = true },
			{ seriesBC() }
		)
		expect(T.names(out[1])).toEqual({ "TheTime", "B + C" })
		expect(T.col(out[1], "B + C")).toEqual({ 5, 500 })
	end)

	it("field + static number", function()
		local out = calc(
			{ mode = "binary", binary = { left = "B", operator = "+", right = "2" }, replaceFields = true },
			{ seriesBC() }
		)
		expect(T.col(out[1], "B + 2")).toEqual({ 4, 202 })
	end)

	it("multiple queries + field + static number: no join, frames without the field are dropped", function()
		local out = calc(
			{ mode = "binary", binary = { left = "B", operator = "+", right = "2" }, replaceFields = true },
			{ seriesA(), seriesBC() }
		)
		expect(#out).toBe(1)
		expect(T.fieldNames(out[1])).toEqual({ "TheTime", "B + 2" })
		expect(out[1].fields[2].values).toEqual({ 4, 202 })
	end)

	it("all numbers + static number (byType left operand)", function()
		local out = calc({
			mode = "binary",
			binary = { left = { matcher = { id = "byType", options = "number" } }, operator = "+", right = "2" },
			replaceFields = true,
		}, { seriesBC() })
		expect(T.fieldNames(out[1])).toEqual({ "TheTime", "B + 2", "C + 2" })
		expect(out[1].fields[3].values).toEqual({ 5, 302 })
	end)

	it("all numbers + field number", function()
		local out = calc({
			mode = "binary",
			binary = { left = { matcher = { id = "byType", options = "number" } }, operator = "+", right = "C" },
			replaceFields = true,
		}, { seriesBC() })
		expect(T.fieldNames(out[1])).toEqual({ "TheTime", "B + C", "C + C" })
		expect(out[1].fields[2].values).toEqual({ 5, 500 })
		expect(out[1].fields[3].values).toEqual({ 6, 600 })
	end)

	it("old format field + field joins the queries; a missing right field leaves nothing", function()
		local opts = { mode = "binary", binary = { left = "A", operator = "+", right = "B" }, replaceFields = true }
		local out = calc(opts, { seriesA(), seriesBC() })
		expect(T.fieldNames(out[1])).toEqual({ "TheTime", "A + B" })
		expect(out[1].fields[2].values).toEqual({ 3, 300 })
		expect(out[1].refId).toBe("joinByField--")
		local none = calc(
			{ mode = "binary", binary = { left = "A", operator = "+", right = "Z" }, replaceFields = true },
			{ seriesA(), seriesBC() }
		)
		expect(#none).toBe(0)
	end)

	it("old format field + number does not join", function()
		local out = calc(
			{ mode = "binary", binary = { left = "A", operator = "+", right = "1336" }, replaceFields = true },
			{ seriesA(), seriesBC() }
		)
		expect(#out).toBe(1)
		expect(out[1].fields[2].name).toBe("A + 1336")
		expect(out[1].fields[2].values).toEqual({ 1337, 1436 })
	end)

	it("when alias exists sets displayName = alias to prevent downstream auto-naming", function()
		local frame = T.frame({ T.f("time", "time", { 1000, 2000 }), T.f("A", "number", { 1, 2 }) })
		local out = calc({
			alias = "Aye",
			mode = "binary",
			binary = { left = "A", operator = "+", right = "10" },
			replaceFields = true,
		}, { frame })
		local f = out[1].fields[2]
		expect(f.name).toBe("Aye")
		expect((f.config :: any).displayName).toBe("Aye")
		expect(f.values).toEqual({ 11, 12 })
	end)

	it("boolean field operands count as 1 and 0", function()
		local out = calc(
			{ mode = "binary", binary = { left = "E", operator = "+", right = "B" }, replaceFields = true },
			{ seriesBC() }
		)
		expect(out[1].fields[2].values).toEqual({ 3, 200 })
	end)

	it("reduces all field (allValues)", function()
		local out = calc(
			{ mode = "reduceRow", reduce = { include = { "B", "C" }, reducer = "allValues" }, replaceFields = true },
			{ seriesBC() }
		)
		expect(T.col(out[1], "All values")).toEqual({ { 2, 3 }, { 200, 300 } })
	end)

	it("can add index field, as percentile too", function()
		local out = calc({ mode = "index", replaceFields = true }, { seriesBC() })
		expect(#out[1].fields).toBe(1)
		expect(out[1].fields[1].values).toEqual({ 0, 1 })
		local series = T.frame({
			T.f("TheTime", "time", { 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000 }),
			T.f("Field", "number", { 2, 200, 3, 6, 3, 7, 9, 9 }),
		})
		local pct = calc({ mode = "index", replaceFields = true, index = { asPercentile = true } }, { series })
		local values = pct[1].fields[1].values
		expect(values[3]).toBe(0.25)
		expect(values[5]).toBe(0.5)
		expect(values[7]).toBe(0.75)
		expect((pct[1].fields[1].config :: any).unit).toBe("percentunit")
	end)

	it("unary: absolute value and percentage of the field total", function()
		local frame = T.frame({ T.f("x", "number", { -1, 2, NULL }) })
		local abs = calc({ mode = "unary", unary = { operator = "abs", fieldName = "x" } }, { frame })
		expect(abs[1].fields[2].name).toBe("abs(x)")
		-- Math.abs(null) is 0.
		expect(abs[1].fields[2].values).toEqual({ 1, 2, 0 })
		local pct = calc(
			{ mode = "unary", unary = { operator = "percent", fieldName = "x" } },
			{ T.frame({ T.f("x", "number", { 1, 3 }) }) }
		)
		expect(pct[1].fields[2].values).toEqual({ 0.25, 0.75 })
	end)

	local function window(w: any, values: { any }): { any }
		local out = calc({ mode = "windowFunctions", window = w }, { T.frame({ T.f("x", "number", values) }) })
		expect(#out[1].fields).toBe(2)
		return out[1].fields[2].values
	end

	it("calculates centered moving averages (odd, even, larger than the data)", function()
		local base = { windowAlignment = "centered", field = "x", windowSizeMode = "percentage", reducer = "mean" }
		local odd = table.clone(base)
		odd.windowSize = 1
		expect(window(odd, { 1, 2, 3 })).toEqual({ 1.5, 2, 2.5 })
		local even = table.clone(base)
		even.windowSize = 0.5
		expect(window(even, { 1, 2, 3 })).toEqual({ 1, 1.5, 2.5 })
		local large = table.clone(base)
		large.windowSize = 5
		expect(window(large, { 1, 2, 3 })).toEqual({ 2, 2, 2 })
	end)

	it("calculates trailing moving averages, with missing values and nulls", function()
		expect(window({
			windowAlignment = "trailing",
			field = "x",
			windowSize = 1,
			windowSizeMode = "percentage",
			reducer = "mean",
		}, { 1, 2, 3 })).toEqual({ 1, 1.5, 2 })
		expect(window({
			windowAlignment = "trailing",
			field = "x",
			windowSize = 2,
			windowSizeMode = "fixed",
			reducer = "mean",
		}, { 1, NULL, 3, 4, 5 })).toEqual({ 1, 1, 3, 3.5, 4.5 })
		expect(window({
			windowAlignment = "trailing",
			field = "x",
			windowSize = 0.75,
			windowSizeMode = "percentage",
			reducer = "mean",
		}, { 1, NULL, 2, 7 })).toEqual({ 1, 1, 1.5, 4.5 })
	end)

	it("calculates trailing moving variance and centered stddev", function()
		expect(window({
			windowAlignment = "trailing",
			field = "x",
			windowSize = 1,
			windowSizeMode = "percentage",
			reducer = "variance",
		}, { 1, 2, 3 })).toEqual({ 0, 0.25, 2 / 3 })
		local sd = window({
			windowAlignment = "centered",
			field = "x",
			windowSize = 1,
			windowSizeMode = "percentage",
			reducer = "stdDev",
		}, { 1, 2, 3 })
		expect(sd[1]).toBe(0.5)
		expect(math.abs(sd[2] - math.sqrt(2 / 3)) < 1e-12).toBe(true)
	end)

	it("calculates cumulative total and mean, nulls counting as 0", function()
		local frame = T.frame({ T.f("x", "number", { 1, NULL, 2, 3 }) })
		local sum = calc({ mode = "cumulativeFunctions", cumulative = { field = "x", reducer = "sum" } }, { frame })
		expect(sum[1].fields[2].name).toBe("cumulative sum(x)")
		expect(sum[1].fields[2].values).toEqual({ 1, 1, 3, 6 })
		local mean = calc({ mode = "cumulativeFunctions", cumulative = { field = "x", reducer = "mean" } }, { frame })
		expect(mean[1].fields[2].values).toEqual({ 1, 0.5, 1, 1.5 })
	end)

	it("throws (falls back) when the window size is not positive", function()
		expect(T.unsupported("calculateField", {
			mode = "windowFunctions",
			window = { windowAlignment = "trailing", field = "x", windowSize = 0, reducer = "mean" },
		})).toBe("transformation calculateField window size 0 is not supported")
		expect(T.unsupported("calculateField", { mode = "cumulativeFunctions", cumulative = { reducer = "max" } })).toBe(
			"transformation calculateField cumulative reducer max is not supported"
		)
		expect(T.unsupported("calculateField", { mode = "reduceRow", reduce = { reducer = "nope" } })).toBe(
			"transformation calculateField reducer nope is not supported"
		)
		expect(T.unsupported("calculateField", { mode = "reduceRow", reduce = { reducer = "allValues" } })).toBeNil()
	end)

	it("getNameFromOptions: names per mode", function()
		local frame = T.frame({ T.f("x", "number", { 1, 2 }) })
		local function nameOf(options: any): string
			local out = calc(options, { frame })
			local fields = out[1].fields
			return fields[#fields].name
		end
		expect(nameOf({
			mode = "windowFunctions",
			window = { windowAlignment = "trailing", reducer = "mean", field = "x" },
		})).toBe("trailing moving mean(x)")
		expect(nameOf({ mode = "windowFunctions", window = { reducer = "mean" } })).toBe(" moving mean")
		expect(
			nameOf({ mode = "binary", binary = { left = { fixed = "1" }, operator = "-", right = { fixed = 0.5 } } })
		).toBe("1 - 0.5")
		expect(nameOf({ mode = "reduceRow", reduce = { reducer = "max" } })).toBe("Max")
		expect(nameOf({ mode = "reduceRow" })).toBe("math")
		expect(nameOf({ mode = "index" })).toBe("Row")
	end)

	it("JavaScript arithmetic: null counts as 0, a join gap is NaN, x/0 is Infinity", function()
		local a = T.frame({ T.f("t", "time", { 1, 2, 3 }), T.f("A", "number", { 1, NULL, 3 }) })
		local b = T.frame({ T.f("t", "time", { 1, 3 }), T.f("B", "number", { 0, 2 }) })
		local out = calc({
			mode = "binary",
			binary = {
				left = { matcher = { id = "byName", options = "A" } },
				operator = "/",
				right = { matcher = { id = "byName", options = "B" } },
			},
			replaceFields = true,
		}, { a, b })
		local v = out[1].fields[2].values
		expect(v[1]).toBe(math.huge)
		-- Row 2: A is null (0) and B a gap (undefined): 0 / NaN.
		expect(v[2] ~= v[2]).toBe(true)
		expect(v[3]).toBe(1.5)
	end)
end)

describe("calculateField in practice", function()
	for _, version in T.panels.VERSIONS do
		it("a stat over the row mean of a multi-series query reads one series, Grafana " .. version, function()
			local panel = {
				type = "stat",
				targets = { { refId = "A" } },
				transformations = {
					{
						id = "calculateField",
						options = {
							alias = "SLI value",
							mode = "reduceRow",
							reduce = { reducer = "mean" },
							replaceFields = true,
						},
					},
				},
			}
			local frames = T.panels.refFrames(version, "prom_range", "A")
			local ok = Registry.supports(panel, T.env)
			expect(ok).toBe(true)
			local out = require("../../../../plugin/lib/panels/transform").prepare(panel, frames, T.env)
			expect(#out).toBe(1)
			expect(T.names(out[1])).toEqual({ "Time", "SLI value" })
			local sum = 0
			for _, f in frames do
				sum += f.fields[2].values[1]
			end
			local got = out[1].fields[2].values[1]
			expect(math.abs(got - sum / #frames) < 1e-9).toBe(true)
		end)

		it("a gauge over the ratio of two queries joins them by time, Grafana " .. version, function()
			local frames = T.panels.frames(version, "prom_range")
			local idle, total = frames[1], frames[#frames]
			local out = T.one("calculateField", {
				alias = "ratio",
				mode = "binary",
				binary = {
					left = { matcher = { id = "byName", options = "idle" } },
					operator = "/",
					right = { matcher = { id = "byName", options = "sum(up)" } },
				},
				replaceFields = true,
			}, { idle, total })
			expect(#out).toBe(1)
			expect(T.names(out[1])).toEqual({ "Time", "ratio" })
			local v = out[1].fields[2].values
			expect(#v).toBe(61)
			expect(v[1]).toBe(idle.fields[2].values[1] / total.fields[2].values[1])
		end)
	end
end)

return nil
