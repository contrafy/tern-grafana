--!strict
-- joinByField / seriesToColumns, as packages/grafana-data/src/
-- transformations/transformers/joinByField.test.ts pins it (outer and inner
-- joins of the "even"/"odd" series, missing fields, keepUnjoinedFrames,
-- static refIds), plus the table join dashboards use: per-instance query
-- results side by side.
local t = require("../../../lib/test")
local T = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = T.NULL

local function even()
	return T.frame({
		T.f("time", "time", { 3000, 4000, 5000, 6000 }),
		T.f("temperature", "number", { 10.3, 10.4, 10.5, 10.6 }),
		T.f("humidity", "number", { 10000.3, 10000.4, 10000.5, 10000.6 }),
	}, "A", "even")
end

local function odd()
	return T.frame({
		T.f("time", "time", { 1000, 3000, 5000, 7000 }),
		T.f("temperature", "number", { 11.1, 11.3, 11.5, 11.7 }),
		T.f("humidity", "number", { 11000.1, 11000.3, 11000.5, 11000.7 }),
	}, "B", "odd")
end

describe("joinByField (joinByField.test.ts)", function()
	it("outer joins by time with a static refId; frame names become a name label", function()
		local out = T.run(
			{ { id = "seriesToColumns", options = { byField = "time" }, refId = "test" } },
			{ even(), odd() }
		)
		expect(#out).toBe(1)
		local f = out[1]
		expect(f.refId).toBe("test")
		expect(f.fields[1].values).toEqual({ 1000, 3000, 4000, 5000, 6000, 7000 })
		expect(f.fields[2].labels).toEqual({ name = "even" })
		expect(f.fields[2].values).toEqual({ NULL, 10.3, 10.4, 10.5, 10.6, NULL })
		expect(f.fields[4].labels).toEqual({ name = "odd" })
		expect(f.fields[4].values).toEqual({ 11.1, 11.3, NULL, 11.5, NULL, 11.7 })
		expect(T.names(f)).toEqual({ "time", "temperature even", "humidity even", "temperature odd", "humidity odd" })
	end)

	it("names the joined frame after its inputs (dynamic refId) and joins by any field", function()
		local out = T.one("joinByField", { byField = "temperature" }, {
			T.frame({ T.f("temperature", "number", { 1, 2 }), T.f("x", "number", { 10, 20 }) }, "A"),
			T.frame({ T.f("temperature", "number", { 2, 3 }), T.f("y", "number", { 200, 300 }) }, "B"),
		})
		expect(out[1].refId).toBe("joinByField-A-B")
		expect(out[1].fields[1].values).toEqual({ 1, 2, 3 })
		expect(out[1].fields[2].values).toEqual({ 10, 20, NULL })
		expect(out[1].fields[3].values).toEqual({ NULL, 200, 300 })
	end)

	it("joins if fields are missing (an empty frame is dropped)", function()
		local a = T.frame({ T.f("time", "time", { 1, 2, 3 }), T.f("temperature", "number", { 10, 11, 12 }) }, nil, "A")
		local b = T.frame({}, nil, "B")
		local c = T.frame({ T.f("time", "time", { 1, 2, 3 }), T.f("temperature", "number", { 20, 22, 24 }) }, nil, "C")
		local out = T.one("seriesToColumns", { byField = "time" }, { a, b, c })
		expect(#out[1].fields).toBe(3)
		expect(out[1].fields[2].values).toEqual({ 10, 11, 12 })
		expect(out[1].fields[3].labels).toEqual({ name = "C" })
	end)

	it("does not crash when byField does not exist in any frame", function()
		local out = T.one("joinByField", { byField = "nope" }, { even(), odd() })
		expect(#out).toBe(1)
		expect(#out[1].fields).toBe(0)
	end)

	it("keeps a single frame as it is (no join, static refId applied)", function()
		local out = T.run({ { id = "joinByField", options = {}, refId = "x" } }, { even() })
		expect(out[1].refId).toBe("x")
		expect(out[1].fields[2].values).toEqual({ 10.3, 10.4, 10.5, 10.6 })
	end)

	it("keepUnjoinedFrames forwards frames without the join field", function()
		local bystander = T.frame({ T.f("other", "number", { 1 }) }, "C")
		local dropped = T.one("joinByField", { byField = "time" }, { even(), odd(), bystander })
		expect(#dropped).toBe(1)
		local kept = T.one("joinByField", { byField = "time", keepUnjoinedFrames = true }, { even(), odd(), bystander })
		expect(#kept).toBe(2)
		expect(kept[1].refId).toBe("joinByField-A-B")
		expect(kept[2].refId).toBe("C")
	end)

	it("inner joins by time field", function()
		local a = T.frame({
			T.f("time", "time", { 3000, 4000, 5000, 6000 }),
			T.f("temperature", "number", { 10.3, 10.4, 10.5, 10.6 }),
		}, nil, "A")
		local b = T.frame({
			T.f("time", "time", { 1000, 3000, 5000, 7000 }),
			T.f("temperature", "number", { 11.1, 10.3, 10.5, 11.7 }),
		}, nil, "B")
		local out = T.one("joinByField", { byField = "time", mode = "inner" }, { a, b })
		expect(out[1].fields[1].values).toEqual({ 3000, 5000 })
		expect(out[1].fields[2].values).toEqual({ 10.3, 10.5 })
		expect(out[1].fields[3].values).toEqual({ 10.3, 10.5 })
	end)

	it("does not inner join if a frame lacks the field: no rows, the columns stay", function()
		local a = T.frame({ T.f("time", "time", { 1, 2 }), T.f("v", "number", { 1, 2 }) }, nil, "A")
		local b = T.frame({ T.f("other", "number", { 1 }) }, nil, "B")
		local out = T.one("joinByField", { byField = "time", mode = "inner" }, { a, b })
		expect(#out[1].fields).toBe(2)
		expect(out[1].fields[1].values).toEqual({})
	end)

	it("outerTabular keeps every row of both tables, matched rows side by side", function()
		local a = T.frame({ T.f("host", "string", { "a", "b" }), T.f("cpu", "number", { 1, 2 }) }, "A")
		local b = T.frame({ T.f("host", "string", { "b", "c" }), T.f("mem", "number", { 20, 30 }) }, "B")
		local out = T.one("joinByField", { byField = "host", mode = "outerTabular" }, { a, b })
		expect(out[1].fields[1].values).toEqual({ "b", "a", "c" })
		expect(out[1].fields[2].values).toEqual({ 2, 1, NULL })
		expect(out[1].fields[3].values).toEqual({ 20, NULL, 30 })
	end)
end)

describe("joinByField in practice", function()
	for _, version in T.panels.VERSIONS do
		it("a table of two instant queries joined by instance, Grafana " .. version, function()
			-- Two format=table refIds, each one table frame (transformDFToTable),
			-- joined into one row per instance.
			local frames = T.panels.frames(version, "prom_table")
			local b = {}
			for _, f in frames do
				local copy = table.clone(f)
				copy.refId = "B"
				table.insert(b, copy)
			end
			for _, f in b do
				table.insert(frames, f)
			end
			local panel: any = {
				type = "table",
				targets = { { refId = "A", format = "table" }, { refId = "B", format = "table" } },
				transformations = { { id = "joinByField", options = { byField = "instance", mode = "inner" } } },
			}
			local out = require("../../../../plugin/lib/panels/transform").prepare(panel, frames, T.env)
			expect(#out).toBe(1)
			local names = T.names(out[1])
			expect(names[1]).toBe("instance")
			expect(table.find(names, "Value #A") ~= nil).toBe(true)
			expect(table.find(names, "Value #B") ~= nil).toBe(true)
			-- Every instance once (the test stack's instances are distinct).
			expect(#out[1].fields[1].values).toBe(#frames // 2)
			-- Columns both tables have get Grafana's unique names, which the
			-- organize step dashboards add after a join refers to.
			expect(table.find(names, "Time 1") ~= nil).toBe(true)
			expect(table.find(names, "job 2") ~= nil).toBe(true)
			panel.transformations = {
				panel.transformations[1],
				{ id = "organize", options = { excludeByName = { ["Time 1"] = true, ["Time 2"] = true } } },
			} :: any
			local organized = require("../../../../plugin/lib/panels/transform").prepare(panel, frames, T.env)
			local kept = T.names(organized[1])
			expect(table.find(kept, "Time 1")).toBeNil()
			expect(table.find(kept, "Time 2")).toBeNil()
			expect(#kept).toBe(#names - 2)
		end)
	end
end)

return nil
