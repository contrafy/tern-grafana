--!strict
-- rowsToFields and configFromData, as public/app/features/transformers/
-- rowsToFields/rowsToFields.test.ts and configFromQuery/
-- configFromQuery.test.ts pin them, plus the stat whose threshold comes
-- from a second query: the threshold reaches the display (lib/panels/
-- fieldconfig) and outranks the panel's default steps.
local t = require("../../../lib/test")
local T = require("./support")
local FieldConfig = require("../../../../plugin/lib/panels/fieldconfig")
local describe, it, expect = t.describe, t.it, t.expect

local function configFrame()
	return T.frame({
		T.f("Time", "time", { 1, 2, 3 }),
		T.f("Max", "number", { 1, 10, 50 }),
		T.f("Min", "number", { 1, 10, 5 }),
		T.f("Names", "string", { "first-name", "middle", "last-name" }),
	}, "A")
end

local function seriesA()
	return T.frame({
		T.f("Time", "time", { 1, 2, 3 }),
		T.f("Value", "number", { 2, 3, 4 }, nil, { displayName = "SeriesA" }),
	})
end

local function fromData(options: any, frames: { any }?): { any }
	return T.one("configFromData", options, frames or { configFrame(), seriesA() })
end

describe("configFromData (configFromQuery.test.ts)", function()
	it("returns the data unchanged when configRefId matches no frame", function()
		local a, b = configFrame(), seriesA()
		local out = fromData({ configRefId = "missing", mappings = {} }, { a, b })
		expect(out[1]).toBe(a)
		expect(out[2]).toBe(b)
	end)

	it("select and apply with two frames and default mappings and reducer (lastNotNull)", function()
		local out = fromData({ configRefId = "A", mappings = {} })
		expect(#out).toBe(1)
		local c = out[1].fields[2].config :: any
		expect(c.max).toBe(50)
		expect(c.min).toBe(5)
		expect(c.displayName).toBe("SeriesA")
	end)

	it("can apply to the config frame if it is the only frame", function()
		local out = fromData({ configRefId = "A", mappings = {} }, { configFrame() })
		expect(out[1].fields[2].name).toBe("Max")
		expect((out[1].fields[2].config :: any).max).toBe(50)
	end)

	it("ignore and custom mappings, custom reducer", function()
		local ignored = fromData({ configRefId = "A", mappings = { { fieldName = "Min", handlerKey = "__ignore" } } })
		expect((ignored[1].fields[2].config :: any).min).toBeNil()
		expect((ignored[1].fields[2].config :: any).max).toBe(50)
		local decimals = fromData({ configRefId = "A", mappings = { { fieldName = "Min", handlerKey = "decimals" } } })
		expect((decimals[1].fields[2].config :: any).decimals).toBe(5)
		local reducer =
			fromData({ configRefId = "A", mappings = { { fieldName = "Max", handlerKey = "max", reducerId = "min" } } })
		expect((reducer[1].fields[2].config :: any).max).toBe(1)
	end)

	it("skips decimals outside 0..15 or not whole", function()
		for _, v in { -3, 2.5, 42 } do
			local cfg = T.frame({ T.f("Decimals", "number", { v }) }, "A")
			local out = fromData(
				{ configRefId = "A", mappings = { { fieldName = "Decimals", handlerKey = "decimals" } } },
				{ cfg, seriesA() }
			)
			expect((out[1].fields[2].config :: any).decimals).toBeNil()
		end
	end)

	it("maps colors the panel can resolve, skips the rest", function()
		local function color(v: any): any
			local cfg = T.frame({ T.f("Color", if type(v) == "number" then "number" else "string", { v }) }, "A")
			local out = fromData(
				{ configRefId = "A", mappings = { { fieldName = "Color", handlerKey = "color" } } },
				{ cfg, seriesA() }
			)
			return (out[1].fields[2].config :: any).color
		end
		for _, ok in
			{
				"green",
				"dark-red",
				"rebeccapurple",
				"#ff0000",
				"rgb(255, 0, 0)",
				"rgba(255, 0, 0, 0.5)",
				"hsl(120, 100%, 50%)",
				"hsla(120, 100%, 50%, 0.5)",
			}
		do
			expect(color(ok)).toEqual({ fixedColor = ok, mode = "fixed" })
		end
		local bads: { any } = { -3, "-3", "notacolor", "ff0000", "rgb 255 0 0", "rgb(foo)", "rgb()", "#zz" }
		for _, bad in bads do
			expect(color(bad)).toBeNil()
		end
	end)

	it("thresholds: color argument, steps sorted ascending", function()
		local one = fromData({
			configRefId = "A",
			mappings = {
				{
					fieldName = "Max",
					handlerKey = "threshold1",
					handlerArguments = { threshold = { color = "orange" } },
				},
			},
		})
		expect((one[1].fields[2].config :: any).thresholds.steps).toEqual({ { value = 50, color = "orange" } })
		local two = fromData({
			configRefId = "A",
			mappings = {
				{
					fieldName = "Max",
					handlerKey = "threshold1",
					handlerArguments = { threshold = { color = "orange" } },
				},
				{ fieldName = "Min", handlerKey = "threshold1", handlerArguments = { threshold = { color = "blue" } } },
			},
		})
		expect((two[1].fields[2].config :: any).thresholds.steps).toEqual({
			{ value = 5, color = "blue" },
			{ value = 50, color = "orange" },
		})
	end)

	it("custom matcher and displayName mapping", function()
		local out = fromData({
			configRefId = "A",
			mappings = { { fieldName = "Names", handlerKey = "displayName", reducerId = "first" } },
			applyTo = { id = "byName", options = "Value" },
		})
		expect((out[1].fields[2].config :: any).displayName).toBe("first-name")
	end)

	it("value mappings from data (allValues by default)", function()
		local cfg = T.frame({
			T.f("Value", "string", { "1", "2" }),
			T.f("Text", "string", { "one", "two" }),
			T.f("Color", "string", { "green", "red" }),
		}, "A")
		local out = fromData({
			configRefId = "A",
			mappings = {
				{ fieldName = "Value", handlerKey = "mappings.value" },
				{ fieldName = "Text", handlerKey = "mappings.text" },
				{ fieldName = "Color", handlerKey = "mappings.color" },
			},
		}, { cfg, seriesA() })
		local m = (out[1].fields[2].config :: any).mappings[1]
		expect(m.type).toBe("value")
		expect(m.options["2"]).toEqual({ text = "two", color = "red", index = 1 })
	end)
end)

describe("rowsToFields (rowsToFields.test.ts)", function()
	it("will extract min & max from fields, other columns by lower-cased name", function()
		local input = T.frame({
			T.f("Name", "string", { "Temperature", "Pressure" }),
			T.f("Value", "number", { 10, 200 }),
			T.f("Unit", "string", { "degree", "pressurebar" }),
			T.f("Miiin", "number", { 3, 100 }),
			T.f("max", "string", { "15", "200" }),
		}, "A")
		local out = T.one("rowsToFields", { mappings = { { fieldName = "Miiin", handlerKey = "min" } } }, { input })
		local f = out[1]
		expect(f.refId).toBe("rowsToFields-A")
		expect(T.fieldNames(f)).toEqual({ "Temperature", "Pressure" })
		expect(f.fields[1].values).toEqual({ 10 })
		expect(f.fields[1].config).toEqual({ max = 15, min = 3, unit = "degree" })
		expect(f.fields[2].config).toEqual({ max = 200, min = 100, unit = "pressurebar" })
		expect(f.fields[1].labels).toEqual({})
	end)

	it("can handle custom name and value field mapping", function()
		local input = T.frame({
			T.f("Name", "string", { "Ignore" }),
			T.f("SensorName", "string", { "Temperature" }),
			T.f("Value", "number", { 10 }),
			T.f("SensorReading", "number", { 100 }),
		})
		local out = T.one("rowsToFields", {
			mappings = {
				{ fieldName = "SensorName", handlerKey = "field.name" },
				{ fieldName = "SensorReading", handlerKey = "field.value" },
			},
		}, { input })
		expect(out[1].fields[1].name).toBe("Temperature")
		expect(out[1].fields[1].values).toEqual({ 100 })
	end)

	it("colors, thresholds and other string columns as labels", function()
		local input = T.frame({
			T.f("Name", "string", { "Temperature" }),
			T.f("Value", "number", { 10 }),
			T.f("Color", "string", { "blue" }),
			T.f("Threshold1", "number", { 30 }),
			T.f("Room", "string", { "kitchen" }),
		})
		local f = T.one("rowsToFields", {}, { input })[1].fields[1]
		expect((f.config :: any).color.fixedColor).toBe("blue")
		expect((f.config :: any).thresholds.steps).toEqual({ { value = 30, color = "red" } })
		expect(f.labels).toEqual({ Room = "kitchen" })
	end)

	it("can ignore a field auto picked for value or name", function()
		local input = T.frame({
			T.f("Time", "time", { 1 }),
			T.f("Name", "string", { "a" }),
			T.f("Skip", "number", { 1 }),
			T.f("Value", "number", { 2 }),
		})
		local out = T.one("rowsToFields", { mappings = { { fieldName = "Skip", handlerKey = "__ignore" } } }, { input })
		expect(out[1].fields[1].values).toEqual({ 2 })
	end)
end)

describe("config from data in practice", function()
	it("a stat's threshold from a second query outranks the panel default", function()
		local panel = {
			type = "stat",
			transformations = {
				{
					id = "configFromData",
					options = {
						applyTo = { id = "byName", options = "Value #base" },
						configRefId = "total",
						mappings = {
							{ fieldName = "Time", handlerKey = "__ignore" },
							{ fieldName = "Value #total", handlerKey = "threshold1" },
						},
					},
				},
			},
		}
		local base = T.frame({ T.f("Time", "time", { 1 }), T.f("Value #base", "number", { 7 }) }, "base")
		local total = T.frame({ T.f("Time", "time", { 1 }), T.f("Value #total", "number", { 5 }) }, "total")
		local out = require("../../../../plugin/lib/panels/transform").prepare(panel, { base, total }, T.env)
		expect(#out).toBe(1)
		local items = FieldConfig.resolve(panel, out, T.env)
		local value = items[2]
		local steps = value.config.thresholds.steps
		expect(steps[#steps].value).toBe(5)
		expect(steps[#steps].color).toBe("red")
	end)

	it("a gauge built from rows: Field/Total columns become named fields", function()
		local input =
			T.frame({ T.f("Field", "string", { "cpu", "mem" }), T.f("Total", "number", { 3, 4 }) }, "reduce-A")
		local out = T.one("rowsToFields", {
			mappings = {
				{ fieldName = "Field", handlerKey = "field.name" },
				{ fieldName = "Total", handlerKey = "field.value" },
			},
		}, { input })
		expect(T.fieldNames(out[1])).toEqual({ "cpu", "mem" })
		expect(out[1].fields[2].values).toEqual({ 4 })
	end)
end)

return nil
