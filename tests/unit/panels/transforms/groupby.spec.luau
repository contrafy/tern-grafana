--!strict
-- groupBy, as packages/grafana-data/src/transformations/transformers/
-- groupBy.test.ts pins it (https://raw.githubusercontent.com/grafana/grafana/
-- main/packages/grafana-data/src/transformations/transformers/groupBy.test.ts),
-- plus the bar chart and stat a grouped Prometheus table feeds.
local t = require("../../../lib/test")
local T = require("./support")
local Barchart = require("../../../../plugin/lib/panels/barchart")
local Registry = require("../../../../plugin/lib/panels/registry")
local Stat = require("../../../../plugin/lib/panels/stat")
local Transform = require("../../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

local function series(values: { any }?, name: string?): any
	return T.frame({
		T.f("time", "time", { 3000, 4000, 5000, 6000, 7000, 8000 }),
		T.f("message", "string", { "one", "two", "two", "three", "three", "three" }),
		T.f("values", "number", values or { 1, 2, 2, 3, 3, 3 }),
	}, nil, name or "A")
end

local function simple(group: string, values: string, reducer: string): any
	return {
		fields = {
			[group] = { operation = "groupby", aggregations = {} },
			[values] = { operation = "aggregate", aggregations = { reducer } },
		},
	}
end

-- Each field as "name type: v1, v2, ...".
local function shape(frame: any): { string }
	local out: { string } = {}
	for _, f in frame.fields do
		local values: { string } = {}
		for _, v in f.values do
			table.insert(values, if v == T.NULL then "null" else tostring(v))
		end
		table.insert(out, f.name .. " " .. f.type .. ": " .. table.concat(values, ", "))
	end
	return out
end

describe("groupBy (groupBy.test.ts)", function()
	it("should not apply transformation if config is missing group by fields", function()
		local source = series()
		local options = { fields = { message = { operation = "aggregate", aggregations = { "count" } } } }
		expect(T.one("groupBy", options, { source })[1]).toBe(source)
	end)

	it("should group values by message", function()
		local options = { fields = { message = { operation = "groupby", aggregations = {} } } }
		local out = T.one("groupBy", options, { series() })
		expect(shape(out[1])).toEqual({ "message string: one, two, three" })
		expect(out[1].fields[1].config).toEqual({})
	end)

	it("should group values by message and summarize values", function()
		local out = T.one("groupBy", simple("message", "values", "sum"), { series() })
		expect(shape(out[1])).toEqual({ "message string: one, two, three", "values (sum) number: 1, 4, 9" })
		expect(out[1].fields[2].config).toEqual({})
	end)

	it("should group by and compute a few calculations for each group of values", function()
		local out = T.one("groupBy", {
			fields = {
				message = { operation = "groupby", aggregations = {} },
				time = { operation = "aggregate", aggregations = { "count", "last" } },
				values = { operation = "aggregate", aggregations = { "sum" } },
			},
		}, { series() })
		expect(shape(out[1])).toEqual({
			"message string: one, two, three",
			"time (count) number: 1, 2, 3",
			"time (last) time: 3000, 5000, 8000",
			"values (sum) number: 1, 4, 9",
		})
	end)

	it("should group values in data frames individually", function()
		local out = T.one("groupBy", simple("message", "values", "sum"), {
			series(),
			series({ 0, 2, 5, 3, 3, 2 }, "B"),
		})
		expect(shape(out[1])[2]).toBe("values (sum) number: 1, 4, 9")
		expect(shape(out[2])[2]).toBe("values (sum) number: 0, 7, 8")
	end)

	it("should group values and keep the order of the fields", function()
		local source = T.frame({
			T.f("message", "string", { "500", "404", "404", "one", "one", "two", "200" }),
			T.f("values", "number", { 1, 2, 2, 3, 3, 3, 4 }),
		}, nil, "A")
		local out = T.one("groupBy", simple("message", "values", "sum"), { source })
		expect(shape(out[1])).toEqual({
			"message string: 500, 404, one, two, 200",
			"values (sum) number: 1, 4, 6, 3, 4",
		})
	end)

	it("should group by and skip fields that do not have values for a group", function()
		local one = T.frame({
			T.f("Time", "time", { 1688470200000, 1688471100000, 1688470200000, 1688471100000 }),
			T.f("Value", "number", { 1, 2, 3, 4 }),
		}, nil, "Series1")
		local two = T.frame({ T.f("Time", "time", {}), T.f("Value", "number", {}) }, nil, "Series2")
		local out = T.one("groupBy", {
			fields = {
				Series1 = { operation = "aggregate", aggregations = { "sum" } },
				Series2 = { operation = "aggregate", aggregations = { "sum" } },
				Time = { operation = "groupby", aggregations = {} },
				Value = { operation = "aggregate", aggregations = { "sum" } },
			},
		}, { one, two })
		expect(shape(out[1])).toEqual({ "Time time: 1688470200000, 1688471100000", "Value (sum) number: 4, 6" })
	end)

	it('should retain "time" field type when used as aggregation (max, etc)', function()
		local source = T.frame({
			T.f("user", "string", { "A", "B", "A", "B" }),
			T.f("time", "time", { 7, 2, 1, 5 }),
		}, "A", "issues")
		local out = T.one("groupBy", simple("user", "time", "max"), { source })
		expect(shape(out[1])).toEqual({ "user string: A, B", "time (max) time: 7, 5" })
		expect(out[1].refId).toBe("A")
		-- A frame name would turn into a label under a later join.
		expect(out[1].name).toBeNil()
	end)

	it("should match on base name for group if did not match on displayName", function()
		local source = T.frame({
			T.f("message", "string", { "A", "A" }, nil, { displayName = "MyMessage" }),
			T.f("values", "number", { 1, 2 }),
		}, nil, "A")
		local out = T.one("groupBy", simple("message", "values", "sum"), { source })
		expect(shape(out[1])).toEqual({ "message string: A", "values (sum) number: 3" })
		expect(out[1].fields[1].config).toEqual({ displayName = "MyMessage" })
	end)

	it("should match on base name for aggregate if did not match on displayName", function()
		local source = T.frame({
			T.f("raw-group", "string", { "GroupA", "GroupA", "GroupB" }, nil, { displayName = "display-group" }),
			T.f("raw-agg", "string", { "a", "b", "c" }, nil, { displayName = "display-agg" }),
		}, nil, "A")
		local out = T.one("groupBy", {
			fields = {
				["raw-agg"] = { operation = "aggregate", aggregations = { "count" } },
				["raw-group"] = { operation = "groupby", aggregations = {} },
			},
		}, { source })
		expect(shape(out[1])).toEqual({ "raw-group string: GroupA, GroupB", "display-agg (count) number: 2, 1" })
	end)

	it("should not aggregate fields without an operation", function()
		local source = T.frame({
			T.f("category", "string", { "A", "A", "B", "B" }),
			T.f("values", "number", { 1, 2, 3, 4 }),
		}, nil, "A")
		local out = T.one("groupBy", {
			fields = {
				category = { operation = "groupby", aggregations = {} },
				values = { aggregations = { "sum" }, operation = T.panels.env.null },
			},
		}, { source })
		expect(shape(out[1])).toEqual({ "category string: A, B" })
	end)

	it("should calculate count on a grouped field when selected", function()
		local source = T.frame({
			T.f("category", "string", { "A", "A", "B", "B", "B" }),
			T.f("values", "number", { 1, 2, 3, 4, 5 }),
		}, nil, "A")
		local out = T.one("groupBy", {
			fields = { category = { operation = "groupby", aggregations = { "count" } }, values = {} },
		}, { source })
		expect(shape(out[1])).toEqual({ "category string: A, B", "category (count) number: 2, 3" })
	end)

	-- shouldCalculateField's it.each table.
	it("calculates an aggregate with reducers, a group-by field only for count alone", function()
		local cases: { { operation: string, aggregations: { string }, calculated: boolean } } = {
			{ operation = "aggregate", aggregations = {}, calculated = false },
			{ operation = "aggregate", aggregations = { "count" }, calculated = true },
			{ operation = "aggregate", aggregations = { "sum", "count" }, calculated = true },
			{ operation = "groupby", aggregations = {}, calculated = false },
			{ operation = "groupby", aggregations = { "count" }, calculated = true },
			{ operation = "groupby", aggregations = { "sum" }, calculated = false },
			{ operation = "groupby", aggregations = { "sum", "count" }, calculated = false },
		}
		for _, c in cases do
			local source = T.frame({ T.f("key", "string", { "k" }), T.f("testField", "string", { "x" }) })
			local out = T.one("groupBy", {
				fields = {
					key = { operation = "groupby", aggregations = {} },
					testField = { operation = c.operation, aggregations = c.aggregations },
				},
			}, { source })
			local calculated = false
			for _, f in out[1].fields do
				calculated = calculated or string.sub(f.name, 1, 10) == "testField "
			end
			expect(calculated).toBe(c.calculated)
		end
	end)
end)

describe("groupBy quirks Grafana has", function()
	it('keys groups by String(values): ("a,b", "c") and ("a", "b,c") are one group', function()
		local source = T.frame({
			T.f("x", "string", { "a,b", "a" }),
			T.f("y", "string", { "c", "b,c" }),
			T.f("v", "number", { 1, 2 }),
		})
		local out = T.one("groupBy", {
			fields = {
				x = { operation = "groupby" },
				y = { operation = "groupby" },
				v = { operation = "aggregate", aggregations = { "sum" } },
			},
		}, { source })
		expect(shape(out[1])).toEqual({ "x string: a,b", "y string: c", "v (sum) number: 3" })
	end)

	it("ignores nulls in reducers and names columns by reducer id", function()
		local source = T.frame({
			T.f("job", "string", { "api", "api", "db" }),
			T.f("lat", "number", { 2, T.NULL, 6 }, nil, { unit = "ms" }),
		})
		local out = T.one("groupBy", {
			fields = {
				job = { operation = "groupby" },
				lat = { operation = "aggregate", aggregations = { "mean", "count", "allIsNull", "p95" } },
			},
		}, { source })
		expect(shape(out[1])).toEqual({
			"job string: api, db",
			"lat (mean) number: 2, 6",
			"lat (count) number: 1, 1",
			"lat (allIsNull) boolean: false, false",
			"lat (p95) number: 2, 6",
		})
		-- The aggregate column starts from an empty config: no unit.
		expect(out[1].fields[2].config).toEqual({})
	end)

	it("drops frames that lack every group-by field", function()
		local out = T.one("groupBy", simple("message", "values", "sum"), {
			T.frame({ T.f("other", "string", { "a" }) }),
			series(),
		})
		expect(#out).toBe(1)
		expect(out[1].fields[1].name).toBe("message")
	end)
end)

-- The tern-panels instant `up` table (format table: Time, __name__, env,
-- instance, job, Value), grouped by metric name: one category, the jobs
-- up summed and counted.
describe("groupBy in practice", function()
	for _, version in T.panels.VERSIONS do
		local function grouped(panelType: string): (any, { any })
			local panel = {
				type = panelType,
				targets = { { refId = "A", format = "table" } },
				options = if panelType == "barchart" then { xField = "__name__" } else nil,
				transformations = {
					{
						id = "groupBy",
						options = {
							fields = {
								__name__ = { operation = "groupby", aggregations = {} },
								Value = { operation = "aggregate", aggregations = { "sum", "count" } },
							},
						},
					},
				},
			}
			expect((Registry.supports(panel, T.env))).toBe(true)
			return panel, Transform.prepare(panel, T.panels.frames(version, "prom_table"), T.env)
		end

		it("a bar chart draws the grouped sums and counts, Grafana " .. version, function()
			local panel, frames = grouped("barchart")
			expect(T.names(frames[1])).toEqual({ "__name__", "Value (sum)", "Value (count)" })
			local prep = Barchart.prepare(panel, frames, T.env)
			assert(prep, "prepared")
			expect(prep.x.field.values).toEqual({ "up" })
			expect(#prep.series).toBe(2)
			-- Five of the six targets are up.
			expect(prep.series[1].field.values).toEqual({ 5 })
			expect(prep.series[2].field.values).toEqual({ 6 })
		end)

		it("a stat shows one tile per aggregate, Grafana " .. version, function()
			local panel, frames = grouped("stat")
			local tiles = Stat.tiles(panel, frames, T.env, { key = "s" })
			expect(#tiles).toBe(2)
			expect(tiles[1].title).toBe("Value (sum)")
			expect(tiles[1].value).toBe("5")
			expect(tiles[2].title).toBe("Value (count)")
			expect(tiles[2].value).toBe("6")
		end)
	end
end)

return nil
