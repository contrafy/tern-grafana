--!strict
-- groupingToMatrix, as packages/grafana-data/src/transformations/
-- transformers/groupingToMatrix.test.ts pins it (https://raw.
-- githubusercontent.com/grafana/grafana/main/packages/grafana-data/src/
-- transformations/transformers/groupingToMatrix.test.ts), plus the bar chart
-- a grouped Prometheus table feeds. The nested-frame value case has no
-- counterpart: Tern's frames carry no frame-typed fields.
local t = require("../../../lib/test")
local T = require("./support")
local Barchart = require("../../../../plugin/lib/panels/barchart")
local Registry = require("../../../../plugin/lib/panels/registry")
local Transform = require("../../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

-- Each field as "name type: v1, v2, ..." ('' for an empty string).
local function shape(frame: any): { string }
	local out: { string } = {}
	for _, f in frame.fields do
		local values: { string } = {}
		for _, v in f.values do
			table.insert(values, if v == T.NULL then "null" elseif v == "" then "''" else tostring(v))
		end
		table.insert(out, f.name .. " " .. f.type .. ": " .. table.concat(values, ", "))
	end
	return out
end

local function crc(valueConfig: any?): any
	return T.frame({
		T.f("Column", "string", { "C1", "C1", "C2" }),
		T.f("Row", "string", { "R1", "R2", "R1" }),
		T.f("Temp", "number", { 1, 4, 5 }, nil, valueConfig),
	}, nil, "A")
end

local NAMED = { columnField = "Column", rowField = "Row", valueField = "Temp" }

describe("groupingToMatrix (groupingToMatrix.test.ts)", function()
	it("generates Matrix with default fields", function()
		local source = T.frame({
			T.f("Time", "time", { 1000, 1001, 1002 }, nil, { interval = 60000 }),
			T.f("Value", "number", { 1, 2, 3 }),
		}, nil, "A")
		local out = T.one("groupingToMatrix", {}, { source })
		expect(shape(out[1])).toEqual({
			"Time\\Time time: 1000, 1001, 1002",
			"1000 number: 1, '', ''",
			"1001 number: '', 2, ''",
			"1002 number: '', '', 3",
		})
		expect(out[1].fields[1].config).toEqual({ interval = 60000 })
		expect(out[1].fields[2].config).toEqual({})
		expect(out[1].name).toBeNil()
		expect(out[1].refId).toBeNil()
	end)

	it("generates Matrix with multiple fields", function()
		local out = T.one("groupingToMatrix", NAMED, { crc() })
		expect(shape(out[1])).toEqual({ "Row\\Column string: R1, R2", "C1 number: 1, 4", "C2 number: 5, ''" })
	end)

	it("generates Matrix with empty entries", function()
		local cases: { { option: string?, shown: string } } = {
			{ option = nil, shown = "''" },
			{ option = "null", shown = "null" },
			{ option = "false", shown = "false" },
			{ option = "true", shown = "true" },
			{ option = "empty", shown = "''" },
			{ option = "zero", shown = "0" },
		}
		for _, c in cases do
			local source = T.frame({ T.f("Time", "time", { 1000, 1001 }), T.f("Value", "number", { 1, 2 }) }, nil, "A")
			local out = T.one("groupingToMatrix", { emptyValue = c.option }, { source })
			expect(shape(out[1])).toEqual({
				"Time\\Time time: 1000, 1001",
				"1000 number: 1, " .. c.shown,
				"1001 number: " .. c.shown .. ", 2",
			})
		end
	end)

	it("properly handles null column name values", function()
		local source = T.frame({
			T.f("Column", "string", { "C1", T.NULL, "C2" }),
			T.f("Row", "string", { "R1", "R2", "R1" }),
			T.f("Temp", "number", { 1, 4, 5 }, nil, { unit = "celsius" }),
		}, nil, "C")
		local out = T.one("groupingToMatrix", NAMED, { source })
		-- A null column has no name.
		expect(shape(out[1])).toEqual({
			"Row\\Column string: R1, R2",
			"C1 number: 1, ''",
			" number: '', 4",
			"C2 number: 5, ''",
		})
		expect(out[1].fields[1].config).toEqual({})
		expect(out[1].fields[3].config).toEqual({ unit = "celsius" })
	end)

	it("properly handles the value display name (by ignoring it)", function()
		local out = T.one(
			"groupingToMatrix",
			{ columnField = "Column", rowField = "Row", valueField = "CustomName" },
			{ crc({ displayName = "CustomName" }) }
		)
		expect(shape(out[1])).toEqual({ "Row\\Column string: R1, R2", "C1 number: 1, 4", "C2 number: 5, ''" })
		expect(out[1].fields[2].config).toEqual({})
		expect(T.names(out[1])).toEqual({ "Row\\Column", "C1", "C2" })
	end)

	it("generates Matrix with multiple fields and value type", function()
		local out = T.one("groupingToMatrix", NAMED, { crc({ unit = "celsius" }) })
		expect(shape(out[1])).toEqual({ "Row\\Column string: R1, R2", "C1 number: 1, 4", "C2 number: 5, ''" })
		expect(out[1].fields[2].config).toEqual({ unit = "celsius" })
		expect(out[1].fields[3].config).toEqual({ unit = "celsius" })
	end)
end)

describe("groupingToMatrix as Grafana reads it", function()
	it("passes anything but one frame, or a frame missing a field, through", function()
		local a, b = crc(), crc()
		local two = T.one("groupingToMatrix", NAMED, { a, b })
		expect(two[1]).toBe(a)
		expect(two[2]).toBe(b)
		local missing = T.one("groupingToMatrix", { columnField = "Nope", rowField = "Row", valueField = "Temp" }, {
			a,
		})
		expect(missing[1]).toBe(a)
	end)

	it("keeps the last value of a repeated cell and fills a null cell with emptyValue", function()
		local source = T.frame({
			T.f("Column", "string", { "C1", "C1", "C2" }),
			T.f("Row", "string", { "R1", "R1", "R1" }),
			T.f("Temp", "number", { 1, 2, T.NULL }),
		})
		local out = T.one(
			"groupingToMatrix",
			{ columnField = "Column", rowField = "Row", valueField = "Temp", emptyValue = "zero" },
			{
				source,
			}
		)
		expect(shape(out[1])).toEqual({ "Row\\Column string: R1", "C1 number: 2", "C2 number: 0" })
	end)

	it("shares the cells of the column values 1 and '1' (String keys) but makes two columns", function()
		local source = T.frame({
			T.f("Column", "other", { 1, "1" }),
			T.f("Row", "string", { "R1", "R2" }),
			T.f("Temp", "number", { 7, 8 }),
		})
		local out = T.one("groupingToMatrix", NAMED, { source })
		expect(shape(out[1])).toEqual({ "Row\\Column string: R1, R2", "1 number: 7, 8", "1 number: 7, 8" })
	end)
end)

-- Busy CPU time by mode and minute: the range query as a table, grouped by
-- time and mode, then one bar series per mode along time.
describe("groupingToMatrix in practice", function()
	for _, version in T.panels.VERSIONS do
		it("a bar chart draws one series per mode from a grouped table, Grafana " .. version, function()
			local panel = {
				type = "barchart",
				targets = { { refId = "A", format = "table" } },
				options = { xField = "Time\\mode" },
				transformations = {
					{
						id = "groupBy",
						options = {
							fields = {
								Time = { operation = "groupby" },
								mode = { operation = "groupby" },
								Value = { operation = "aggregate", aggregations = { "max" } },
							},
						},
					} :: any,
					{
						id = "groupingToMatrix",
						options = { columnField = "mode", rowField = "Time", valueField = "Value (max)" },
					} :: any,
				},
			}
			expect((Registry.supports(panel, T.env))).toBe(true)
			local source = T.panels.refFrames(version, "prom_range", "A")
			local frames = Transform.prepare(panel, source, T.env)
			expect(#frames).toBe(1)
			local names = T.names(frames[1])
			expect(names[1]).toBe("Time\\mode")
			expect(#names).toBe(1 + #source)
			local prep = Barchart.prepare(panel, frames, T.env)
			assert(prep, "prepared")
			expect(prep.x.field.type).toBe("time")
			expect(#prep.x.field.values).toBe(#source[1].fields[1].values)
			expect(#prep.series).toBe(#source)
			expect(prep.series[1].name).toBe("idle")
			-- The idle column holds the idle series' samples.
			expect(prep.series[1].field.values[1]).toBe(source[1].fields[2].values[1])
			local _, assets = Barchart.view(panel, frames, T.env, { key = "p", size = { w = 600, h = 300 } })
			expect(#(assets :: any).p.bytes > 0).toBe(true)
		end)
	end
end)

return nil
