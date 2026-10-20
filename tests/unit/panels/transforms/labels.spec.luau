--!strict
-- labelsToFields, as packages/grafana-data/src/transformations/transformers/
-- labelsToFields.test.ts pins it. Label keys are visited sorted (the frames
-- here come from JSON whose labels Grafana's backend writes sorted, so the
-- order the Grafana tests get from object literals never reaches us), plus
-- the stat that shows a series' labels as rows.
local t = require("../../../lib/test")
local T = require("./support")
local Registry = require("../../../../plugin/lib/panels/registry")
local describe, it, expect = t.describe, t.it, t.expect

describe("labelsToFields (labelsToFields.test.ts)", function()
	it("data frame with two labels: a column per label, the refId kept", function()
		local source = T.frame({
			T.f("time", "time", { 1000, 2000 }),
			T.f("Value", "number", { 1, 2 }, { location = "inside", feelsLike = "ok" }),
		}, "A", "A")
		local out = T.one("labelsToFields", {}, { source })
		expect(out[1].refId).toBe("A")
		expect(T.fieldNames(out[1])).toEqual({ "time", "Value", "feelsLike", "location" })
		expect(out[1].fields[3].values).toEqual({ "ok", "ok" })
		expect(out[1].fields[4].values).toEqual({ "inside", "inside" })
		expect(out[1].fields[2].labels).toBeNil()
	end)

	it("valueLabel names the value field and drops the stale display name", function()
		local source = T.frame({
			T.f("time", "time", { 1000, 2000 }),
			T.f("Value", "number", { 1, 2 }, { location = "inside", name = "Request" }, { displayName = "Custom1" }),
		}, nil, "A")
		local out = T.one("labelsToFields", { valueLabel = "name" }, { source })
		expect(T.fieldNames(out[1])).toEqual({ "time", "Request", "location" })
		expect((out[1].fields[2].config :: any).displayName).toBeNil()
	end)

	it("two data frames with one label each keep their own columns", function()
		local a = T.frame({ T.f("time", "time", { 1 }), T.f("Value", "number", { 1 }, { job = "a" }) }, "A")
		local b = T.frame({ T.f("time", "time", { 1 }), T.f("Value", "number", { 2 }, { job = "b" }) }, "B")
		local out = T.one("labelsToFields", {}, { a, b })
		expect(#out).toBe(2)
		expect(out[1].fields[3].values).toEqual({ "a" })
		expect(out[2].fields[3].values).toEqual({ "b" })
	end)

	it("filter labels from source (keepLabels)", function()
		local source = T.frame({
			T.f("time", "time", { 1000 }),
			T.f("Value", "number", { 1 }, { location = "inside", feelsLike = "ok", sensor = "x" }),
		})
		local out = T.one("labelsToFields", { keepLabels = { "sensor", "location" } }, { source })
		expect(T.fieldNames(out[1])).toEqual({ "time", "Value", "location", "sensor" })
	end)

	it("show labels as rows: a label/value frame per labeled field, named by it", function()
		local source = T.frame({
			T.f("time", "time", { 1000, 2000 }),
			T.f("a", "number", { 1, 3 }, { foo = "thing", bar = "a", zaz = "xyz" }),
			T.f("b", "number", { 2, 4 }, { foo = "thing", bar = "b" }),
		}, nil, "A")
		local out = T.one("labelsToFields", { mode = "rows" }, { source })
		expect(#out).toBe(2)
		expect(out[1].name).toBe('a {bar="a", foo="thing", zaz="xyz"}')
		expect(out[1].fields[1].values).toEqual({ "bar", "foo", "zaz" })
		expect(out[1].fields[2].values).toEqual({ "a", "thing", "xyz" })
		expect(out[2].name).toBe('b {bar="b", foo="thing"}')
		local filtered = T.one("labelsToFields", { mode = "rows", keepLabels = { "foo", "zaz" } }, { source })
		expect(filtered[1].fields[1].values).toEqual({ "foo", "zaz" })
		expect(filtered[2].fields[2].values).toEqual({ "thing", T.NULL })
	end)
end)

describe("labelsToFields in practice", function()
	for _, version in T.panels.VERSIONS do
		it("a stat over an instant query's labels as rows renders natively, Grafana " .. version, function()
			local panel = {
				type = "stat",
				targets = { { refId = "A" } },
				options = { reduceOptions = { calcs = { "lastNotNull" }, fields = "/.*/" } },
				transformations = { { id = "labelsToFields", options = { mode = "rows" } } },
			}
			expect((Registry.supports(panel, T.env))).toBe(true)
			local frames = T.panels.frames(version, "prom_table")
			local out = require("../../../../plugin/lib/panels/transform").prepare(panel, frames, T.env)
			expect(#out).toBe(#frames)
			expect(out[1].fields[1].name).toBe("label")
			expect(table.find(out[1].fields[1].values, "instance") ~= nil).toBe(true)
		end)
	end
end)

return nil
