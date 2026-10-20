--!strict
-- seriesToRows, as packages/grafana-data/src/transformations/transformers/
-- seriesToRows.test.ts pins it (https://raw.githubusercontent.com/grafana/
-- grafana/main/packages/grafana-data/src/transformations/transformers/
-- seriesToRows.test.ts), plus the old table panel whose "timeseries_to_rows"
-- migrates to it.
local t = require("../../../lib/test")
local T = require("./support")
local Registry = require("../../../../plugin/lib/panels/registry")
local Table = require("../../../../plugin/lib/panels/table")
local Transform = require("../../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

local function temp(name: string, times: { number }, values: { number }, refId: string?, config: any?): any
	return T.frame({ T.f("Time", "time", times), T.f("Temp", "number", values, nil, config) }, refId, name)
end

-- Each field as "name type: v1, v2, ..." (the test's unwrap)...
local function unwrap(frame: any): { string }
	local out: { string } = {}
	for _, f in frame.fields do
		local values: { string } = {}
		for _, v in f.values do
			table.insert(values, tostring(v))
		end
		table.insert(out, f.name .. " " .. f.type .. ": " .. table.concat(values, ", "))
	end
	return out
end

-- ...and every field's config.
local function configs(frame: any): { any }
	local out = {}
	for _, f in frame.fields do
		table.insert(out, f.config or {})
	end
	return out
end

describe("seriesToRows (seriesToRows.test.ts)", function()
	it("should do transform even with only one series", function()
		local out = T.one("seriesToRows", {}, { temp("A", { 1000 }, { 1 }) })
		expect(unwrap(out[1])).toEqual({ "Time time: 1000", "Metric string: A", "Value number: 1" })
		expect(configs(out[1])).toEqual({ {}, {}, {} })
	end)

	it("combine two series into one with static refId", function()
		local out = T.run({ { id = "seriesToRows", options = {}, refId = "test" } }, {
			temp("A", { 1000 }, { 1 }),
			temp("B", { 2000 }, { -1 }),
		})
		expect(out[1].refId).toBe("test")
		expect(unwrap(out[1])).toEqual({ "Time time: 2000, 1000", "Metric string: B, A", "Value number: -1, 1" })
	end)

	it("combine two series with multiple values into one with dynamic refid", function()
		local out = T.one("seriesToRows", {}, {
			temp("A", { 100, 150, 200 }, { 1, 4, 5 }, "A"),
			temp("B", { 100, 125, 126 }, { -1, 2, 3 }, "B"),
		})
		expect(out[1].refId).toBe("seriesToRows-A-B")
		expect(unwrap(out[1])).toEqual({
			"Time time: 200, 150, 126, 125, 100, 100",
			"Metric string: A, A, B, B, A, B",
			"Value number: 5, 4, 3, 2, 1, -1",
		})
	end)

	it("combine three series into one", function()
		local out = T.one("seriesToRows", {}, {
			temp("A", { 1000 }, { 1 }),
			temp("B", { 2000 }, { -1 }),
			temp("C", { 500 }, { 2 }),
		})
		expect(out[1].fields[1].values).toEqual({ 2000, 1000, 500 })
		expect(out[1].fields[2].values).toEqual({ "B", "A", "C" })
		expect(out[1].fields[3].values).toEqual({ -1, 1, 2 })
	end)

	it("combine two time series, where first serie fields has displayName, into one", function()
		local a = T.frame({
			T.f("Time", "time", { 100, 150, 200 }, nil, { displayName = "Random time" }),
			T.f("Temp", "number", { 1, 4, 5 }, nil, { displayName = "Temp" }),
		}, nil, "A")
		local out = T.one("seriesToRows", {}, { a, temp("B", { 100, 125, 126 }, { -1, 2, 3 }) })
		expect(unwrap(out[1])).toEqual({
			"Time time: 200, 150, 126, 125, 100, 100",
			"Metric string: A, A, B, B, A, B",
			"Value number: 5, 4, 3, 2, 1, -1",
		})
		expect(configs(out[1])).toEqual({ {}, {}, {} })
	end)

	it("combine two time series, where first serie fields has units, into one", function()
		local out = T.one("seriesToRows", {}, {
			temp("A", { 100, 150, 200 }, { 1, 4, 5 }, nil, { unit = "celsius" }),
			temp("B", { 100, 125, 126 }, { -1, 2, 3 }),
		})
		expect(out[1].fields[3].config).toEqual({ unit = "celsius" })
	end)

	it("combine two time series, where second serie fields has units, into one", function()
		local out = T.one("seriesToRows", {}, {
			temp("A", { 100, 150, 200 }, { 1, 4, 5 }),
			temp("B", { 100, 125, 126 }, { -1, 2, 3 }, nil, { unit = "celsius" }),
		})
		expect(out[1].fields[3].config).toEqual({})
	end)

	it("keeps the static refId when the input is not time series and is passed through", function()
		local table_ = T.frame({ T.f("Name", "string", { "a", "b" }), T.f("Value", "number", { 1, 2 }) }, "A", "A")
		local out = T.run({ { id = "seriesToRows", options = {}, refId = "T-A" } }, { table_ })
		expect(#out).toBe(1)
		expect(out[1].refId).toBe("T-A")
		expect(T.fieldNames(out[1])).toEqual({ "Name", "Value" })
	end)
end)

describe("seriesToRows as Grafana reads it", function()
	it("names a frame without a name by its value field and drops empty frames", function()
		local a = T.frame({ T.f("Time", "time", { 1 }), T.f("Value", "number", { 7 }, { job = "api" }) }, "A")
		local empty = T.frame({ T.f("Time", "time", {}), T.f("Value", "number", {}) }, "B")
		local out = T.one("seriesToRows", {}, { a, empty })
		expect(out[1].refId).toBe("seriesToRows-A")
		expect(out[1].fields[2].values).toEqual({ "api" })
		-- The Value column loses the series labels.
		expect(out[1].fields[3].labels).toBeNil()
	end)

	it("passes frames through when a time field is not ascending", function()
		local a = T.frame({ T.f("Time", "time", { 2, 1 }), T.f("Value", "number", { 1, 2 }) }, "A")
		local out = T.one("seriesToRows", {}, { a })
		expect(out[1]).toBe(a)
	end)
end)

-- Old table panels (table-old, Grafana 7) with "Time series to rows".
describe("seriesToRows in practice", function()
	for _, version in T.panels.VERSIONS do
		it("an old time-series-to-rows table lists every CPU mode sample, Grafana " .. version, function()
			local panel = {
				type = "table-old",
				targets = { { refId = "A" } },
				transform = "timeseries_to_rows",
				styles = {},
			}
			expect((Registry.supports(panel, T.env))).toBe(true)
			local migrated = assert((Registry.effective(panel, T.env)), "migrated")
			local source = T.panels.refFrames(version, "prom_range", "A")
			local frames = Transform.prepare(migrated, source, T.env)
			expect(#frames).toBe(1)
			expect(T.names(frames[1])).toEqual({ "Time", "Metric", "Value" })
			local tbl = Table.build(migrated, frames, T.env, { key = "t" })
			expect(#tbl.rows).toBe(#source * #source[1].fields[1].values)
			-- Newest first; at the latest timestamp the modes keep query order.
			expect(tbl.rows[1][2].text).toBe("idle")
			expect(tbl.rows[2][2].text).toBe("iowait")
		end)
	end
end)

return nil
