--!strict
-- limit, as packages/grafana-data/src/transformations/transformers/
-- limit.test.ts pins it (https://raw.githubusercontent.com/grafana/grafana/
-- main/packages/grafana-data/src/transformations/transformers/limit.test.ts),
-- plus a table capped by a dashboard variable and a top-N bar chart.
local t = require("../../../lib/test")
local T = require("./support")
local Barchart = require("../../../../plugin/lib/panels/barchart")
local Registry = require("../../../../plugin/lib/panels/registry")
local Table = require("../../../../plugin/lib/panels/table")
local Transform = require("../../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

local function series(): any
	return T.frame({
		T.f("time", "time", { 3000, 4000, 5000, 6000, 7000, 8000 }),
		T.f("message", "string", { "one", "two", "two", "three", "three", "three" }),
		T.f("values", "number", { 1, 2, 2, 3, 3, 3 }),
	}, nil, "A")
end

-- Each column as "v1, v2, ...".
local function columns(frame: any): { string }
	local out: { string } = {}
	for _, f in frame.fields do
		local values: { string } = {}
		for _, v in f.values do
			table.insert(values, tostring(v))
		end
		table.insert(out, table.concat(values, ", "))
	end
	return out
end

describe("limit (limit.test.ts)", function()
	it("should limit the number of items by removing from the end if the number is positive", function()
		local out = T.one("limit", { limitField = 3 }, { series() })
		expect(T.fieldNames(out[1])).toEqual({ "time", "message", "values" })
		expect(columns(out[1])).toEqual({ "3000, 4000, 5000", "one, two, two", "1, 2, 2" })
	end)

	it("should limit the number of items by removing from the front if the limit is negative", function()
		local out = T.one("limit", { limitField = -3 }, { series() })
		expect(columns(out[1])).toEqual({ "6000, 7000, 8000", "three, three, three", "3, 3, 3" })
	end)

	it("should not limit the number of items if limit > number of items", function()
		local source = series()
		local out = T.one("limit", { limitField = 7 }, { source })
		expect(out[1]).toBe(source)
	end)
end)

describe("limit options as Grafana reads them", function()
	it("defaults to 10 rows", function()
		local values = {}
		for i = 1, 12 do
			values[i] = i
		end
		local out = T.one("limit", {}, { T.frame({ T.f("v", "number", values) }) })
		expect(#out[1].fields[1].values).toBe(10)
	end)

	it("reads a string limit with parseInt: '2 rows' is 2, 'x' leaves the frames alone", function()
		expect(columns(T.one("limit", { limitField = "2 rows" }, { series() })[1])[3]).toBe("1, 2")
		expect(columns(T.one("limit", { limitField = " -1" }, { series() })[1])[3]).toBe("3")
		local source = series()
		expect(T.one("limit", { limitField = "x" }, { source })[1]).toBe(source)
	end)

	it("cuts a fractional limit like Array.slice and 0 to no rows", function()
		expect(columns(T.one("limit", { limitField = 2.7 }, { series() })[1])[3]).toBe("1, 2")
		-- slice(6 - 2.5, 6) starts at index 3: three rows, not two.
		expect(columns(T.one("limit", { limitField = -2.5 }, { series() })[1])[3]).toBe("3, 3, 3")
		expect(columns(T.one("limit", { limitField = 0 }, { series() })[1])[3]).toBe("")
	end)

	it("takes the limit from a dashboard variable", function()
		local out = T.run({ { id = "limit", options = { limitField = "$top" } } }, { series() }, function(s: string)
			return (string.gsub(s, "%$top", "4"))
		end)
		expect(#out[1].fields[1].values).toBe(4)
	end)
end)

describe("limit in practice", function()
	for _, version in T.panels.VERSIONS do
		it("a table shows the first $top rows of the `up` table, Grafana " .. version, function()
			local panel = {
				type = "table",
				targets = { { refId = "A", format = "table" } },
				transformations = { { id = "limit", options = { limitField = "$top" } } },
			}
			expect((Registry.supports(panel, T.env))).toBe(true)
			local frames = Transform.prepare(panel, T.panels.frames(version, "prom_table"), T.env, function(s: string)
				return (string.gsub(s, "%$top", "2"))
			end)
			local tbl = Table.build(panel, frames, T.env, { key = "t" })
			expect(#tbl.rows).toBe(2)
		end)

		-- Top 3 CPU modes: each series reduced to its mean, sorted, capped.
		it("a top-3 bar chart keeps the three busiest modes, Grafana " .. version, function()
			local panel = {
				type = "barchart",
				targets = { { refId = "A" } },
				options = { xField = "Field" },
				transformations = {
					{ id = "reduce", options = { reducers = { "mean" } } } :: any,
					{ id = "sortBy", options = { sort = { { field = "Mean", desc = true } } } } :: any,
					{ id = "limit", options = { limitField = 3 } } :: any,
				},
			}
			expect((Registry.supports(panel, T.env))).toBe(true)
			local source = T.panels.refFrames(version, "prom_range", "A")
			local means: { { name: string, mean: number } } = {}
			for _, f in source do
				local sum = 0
				for _, v in f.fields[2].values do
					sum += v
				end
				table.insert(
					means,
					{ name = (f.fields[2].config :: any).displayName, mean = sum / #f.fields[2].values }
				)
			end
			table.sort(means, function(a, b)
				return a.mean > b.mean
			end)
			local prep = Barchart.prepare(panel, Transform.prepare(panel, source, T.env), T.env)
			assert(prep, "prepared")
			expect(prep.x.field.values).toEqual({ means[1].name, means[2].name, means[3].name })
			expect(#prep.series).toBe(1)
			expect(prep.series[1].name).toBe("Mean")
		end)
	end
end)

return nil
