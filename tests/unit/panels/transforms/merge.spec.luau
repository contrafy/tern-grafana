--!strict
-- merge, as packages/grafana-data/src/transformations/transformers/
-- merge.test.ts pins it: series stacked into one table, rows of tables that
-- share key columns combined, the dynamic and static refIds, plus a table
-- panel merging several table queries into one.
local t = require("../../../lib/test")
local T = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = T.NULL

describe("merge (merge.test.ts)", function()
	it("skip combine one serie", function()
		local a = T.frame({ T.f("Time", "time", { 1000 }), T.f("Temp", "number", { 1 }) }, "A", "A")
		local out = T.one("merge", {}, { a })
		expect(out[1]).toBe(a)
	end)

	it("combine two series into one with dynamic refId", function()
		local a = T.frame({ T.f("Time", "time", { 1000 }), T.f("Temp", "number", { 1 }) }, "A", "A")
		local b = T.frame({ T.f("Time", "time", { 2000 }), T.f("Temp", "number", { -1 }) }, "B", "B")
		local out = T.one("merge", {}, { a, b })
		expect(out[1].refId).toBe("merge-A-B")
		expect(out[1].fields[1].values).toEqual({ 1000, 2000 })
		expect(out[1].fields[2].values).toEqual({ 1, -1 })
	end)

	it("combine two series with multiple values into one, static refId", function()
		local a = T.frame({ T.f("Time", "time", { 100, 150, 200 }), T.f("Temp", "number", { 1, 4, 5 }) }, nil, "A")
		local b = T.frame({ T.f("Time", "time", { 100, 125, 126 }), T.f("Temp", "number", { -1, 2, 3 }) }, nil, "B")
		local out = T.run({ { id = "merge", options = {}, refId = "test" } }, { a, b })
		expect(out[1].refId).toBe("test")
		expect(out[1].fields[1].values).toEqual({ 100, 150, 200, 100, 125, 126 })
		expect(out[1].fields[2].values).toEqual({ 1, 4, 5, -1, 2, 3 })
	end)

	it("combine two tables, where first is partial overlapping, into one", function()
		local a = T.frame({
			T.f("Country", "string", { "United States", "United States", "Mexico", "Germany", "Canada", "Canada" }),
			T.f("AgeGroup", "string", { "50 or over", "35 - 49", "0 - 17", "35 - 49", "35 - 49", "25 - 34" }),
			T.f("Sum", "number", { 998, 1193, 1675, 146, 166, 219 }),
		}, nil, "A")
		local b = T.frame({
			T.f("AgeGroup", "string", { "0 - 17", "18 - 24", "25 - 34", "35 - 49", "50 or over" }),
			T.f("Count", "number", { 1, 3, 2, 4, 2 }),
		}, nil, "B")
		local out = T.one("merge", {}, { a, b })
		local f = out[1].fields
		expect(T.fieldNames(out[1])).toEqual({ "Country", "AgeGroup", "Sum", "Count" })
		expect(f[1].values).toEqual({
			"United States",
			"United States",
			"Mexico",
			"Germany",
			"Canada",
			"Canada",
			NULL,
		})
		expect(f[2].values).toEqual({ "50 or over", "35 - 49", "0 - 17", "35 - 49", "35 - 49", "25 - 34", "18 - 24" })
		expect(f[3].values).toEqual({ 998, 1193, 1675, 146, 166, 219, NULL })
		expect(f[4].values).toEqual({ 2, 4, 1, 4, 4, 2, 3 })
	end)

	it("drops display names and labels from the merged structure", function()
		local a = T.frame({
			T.f("Time", "time", { 1 }),
			T.f("Temp", "number", { 1 }, { job = "x" }, { displayName = "T", unit = "celsius" }),
		})
		local b = T.frame({ T.f("Time", "time", { 2 }), T.f("Temp", "number", { 2 }) })
		local out = T.one("merge", {}, { a, b })
		local temp = out[1].fields[2]
		expect(temp.labels).toBeNil()
		expect((temp.config :: any).displayName).toBeNil()
		expect((temp.config :: any).unit).toBe("celsius")
	end)

	it("combine one regular serie with an empty serie returns the regular serie's rows", function()
		local a = T.frame({ T.f("Time", "time", { 1, 2 }), T.f("Temp", "number", { 1, 2 }) }, "A")
		local empty = T.frame({}, "B")
		local out = T.one("merge", {}, { a, empty })
		expect(out[1].refId).toBe("merge-A")
		expect(out[1].fields[2].values).toEqual({ 1, 2 })
	end)
end)

describe("merge in practice", function()
	for _, version in T.panels.VERSIONS do
		it("a table merging two table queries into one row per series, Grafana " .. version, function()
			local frames = T.panels.frames(version, "prom_table")
			local n = #frames
			for i = 1, n do
				local copy = table.clone(frames[i])
				copy.refId = "B"
				table.insert(frames, copy)
			end
			local panel = {
				type = "table",
				targets = { { refId = "A", format = "table" }, { refId = "B", format = "table" } },
				transformations = { { id = "merge", options = {} } },
			}
			local out = require("../../../../plugin/lib/panels/transform").prepare(panel, frames, T.env)
			expect(#out).toBe(1)
			local names = T.names(out[1])
			expect(names[#names - 1]).toBe("Value #A")
			expect(names[#names]).toBe("Value #B")
			expect(#out[1].fields[1].values).toBe(n)
			for _, v in out[1].fields[#names].values do
				assert(v ~= T.NULL, "every row has both values")
			end
		end)
	end
end)

return nil
