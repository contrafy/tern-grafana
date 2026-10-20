--!strict
-- convertFieldType and formatTime, as packages/grafana-data/src/
-- transformations/transformers/convertFieldType.test.ts and
-- formatTime.test.ts pin them. Those tests run in Pacific/Easter (UTC-6 in
-- July, UTC-5 from September to April); the viewer offset below is set the
-- same way per case. Plus the chain dashboards use for monthly bar charts:
-- a time to "YYYY-MM" text and back to a time.
local t = require("../../../lib/test")
local T = require("./support")
local Transform = require("../../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = T.NULL

local function envAt(offset: number): any
	local e = table.clone(T.env)
	e.local_offset_min = offset
	return e
end

local function convert(conversions: { any }, fields: { any }, offset: number?): { any }
	local panel = { transformations = { { id = "convertFieldType", options = { conversions = conversions } } } }
	return Transform.prepare(panel, { T.frame(fields) }, envAt(offset or 0))[1].fields
end

describe("convertFieldType (convertFieldType.test.ts)", function()
	it("will parse properly formatted strings to time (local time)", function()
		local out = convert({ { targetField = "proper dates", destinationType = "time" } }, {
			T.f("proper dates", "string", {
				"2021-07-19 00:00:00.000",
				"2021-07-23 00:00:00.000",
				"2021-07-25 00:00:00.000",
				"2021-08-01 00:00:00.000",
				"2021-08-02 00:00:00.000",
			}),
		}, -360)
		expect(out[1].type).toBe("time")
		expect(out[1].values).toEqual({ 1626674400000, 1627020000000, 1627192800000, 1627797600000, 1627884000000 })
	end)

	it("will parse string time to specified format in time (YYYY keeps the year only)", function()
		local out = convert({ { targetField = "y", destinationType = "time", dateFormat = "YYYY" } }, {
			T.f("y", "string", { "2017-07-19 00:00:00.000", "2018-07-23 00:00:00.000" }),
		}, -300)
		expect(out[1].values).toEqual({ 1483246800000, 1514782800000 })
	end)

	it("will parse string time in the specified timezone", function()
		local field = T.f("date", "string", { "2024-01-01 00:00:00" })
		local cases: { { any } } = {
			{ "utc", "YYYY-MM-DD HH:mm:ss", 1704067200000 },
			{ "Asia/Kolkata", "YYYY-MM-DD HH:mm:ss", 1704047400000 },
			{ "utc", "", 1704067200000 },
		}
		for _, c in cases do
			local out = convert(
				{ { targetField = "date", destinationType = "time", dateFormat = c[2], timezone = c[1] } },
				{ field },
				-300
			)
			expect(out[1].values).toEqual({ c[3] })
		end
	end)

	it("will not parse improperly formatted date strings", function()
		local out = convert({ { targetField = "bad", destinationType = "time" } }, {
			T.f("bad", "string", { "2021/08-01 00:00.00:000", "2021/08/01 00.00-000" }, nil, { unit = "time" }),
		})
		expect(out[1].values).toEqual({ NULL, NULL })
		expect((out[1].config :: any).unit).toBe("time")
	end)

	it("can convert strings to numbers, commas stripped, junk to null", function()
		local out = convert({ { targetField = "s", destinationType = "number" } }, {
			T.f("s", "string", { "1,000", "2.5", "", "abc", "0x10", " 7 " }),
		})
		expect(out[1].values).toEqual({ 1000, 2.5, NULL, NULL, 16, 7 })
		local bools = convert(
			{ { targetField = "b", destinationType = "number" } },
			{ T.f("b", "boolean", { true, false }) }
		)
		expect(bools[1].values).toEqual({ 1, 0 })
	end)

	it("will convert field to booleans", function()
		local out = convert({ { targetField = "v", destinationType = "boolean" } }, {
			T.f("v", "other", { 1, 0, "", "x", NULL }),
		})
		expect(out[1].values).toEqual({ true, false, false, true, false })
	end)

	it("will convert field to strings (numbers as text, strings as JSON)", function()
		local out = convert({
			{ targetField = "numbers", destinationType = "string" },
			{ targetField = "strings", destinationType = "string" },
		}, {
			T.f("numbers", "number", { -100, 0, 1, NULL, 0 / 0 }),
			T.f("strings", "string", { "true" }),
		})
		expect(out[1].values).toEqual({ "-100", "0", "1", "null", "NaN" })
		expect(out[2].values).toEqual({ '"true"' })
	end)

	it("will support custom join separators for arrays", function()
		local out = convert({ { targetField = "a", destinationType = "string", joinWith = "|" } }, {
			T.f("a", "other", { { "a", "b" }, { 1 } }),
		})
		expect(out[1].values).toEqual({ "a|b", "1" })
	end)

	it("will convert field to complex objects (JSON.parse, else null)", function()
		local out = convert({ { targetField = "j", destinationType = "other" } }, {
			T.f("j", "string", { '{"a":1}', "nope", "5" }),
		})
		expect((out[1].values[1] :: any).a).toBe(1)
		expect(out[1].values[2]).toBe(NULL)
		expect(out[1].values[3]).toBe(5)
	end)

	it("will convert time fields to strings", function()
		local out = convert({ { targetField = "time", destinationType = "string", dateFormat = "YYYY-MM" } }, {
			T.f("time", "time", { 1626674400000, 1627020000000, 1627192800000, 1627797600000, 1627884000000 }),
		}, -360)
		expect(out[1].values).toEqual({ "2021-07", "2021-07", "2021-07", "2021-08", "2021-08" })
	end)

	it("ensureTimeField: a number field only changes type", function()
		local out = convert(
			{ { targetField = "n", destinationType = "time" } },
			{ T.f("n", "number", { 1626674400000 }) }
		)
		expect(out[1].type).toBe("time")
		expect(out[1].values).toEqual({ 1626674400000 })
	end)

	it("fieldToTimeField: ISO 8601 strings with offsets and millis", function()
		local out = convert({ { targetField = "iso", destinationType = "time" } }, {
			T.f("iso", "string", {
				"2021-11-11T19:45:00+05:30",
				"2021-11-11T19:45:00-05:30",
				"2021-11-11T19:45:00+0530",
				"2021-11-11T19:45:00-0530",
				"2021-11-11T19:45:00.0000000000+05:30",
				"2021-11-11T19:45:00.0000000000-0530",
				"2021-11-11T19:45:00.000Z",
				"2021-11-11T19:45:00.0000000000Z",
			}),
		})
		expect(out[1].values).toEqual({
			1636640100000,
			1636679700000,
			1636640100000,
			1636679700000,
			1636640100000,
			1636679700000,
			1636659900000,
			1636659900000,
		})
	end)

	it("fieldToTimeField: Unix timestamps in seconds (X) and ms (x), numbers and strings", function()
		local secs = convert({ { targetField = "s", destinationType = "time", dateFormat = "X" } }, {
			T.f("s", "number", { 1728397800, 1728397815 }),
		})
		expect(secs[1].values).toEqual({ 1728397800000, 1728397815000 })
		local strSecs = convert({ { targetField = "s", destinationType = "time", dateFormat = "X" } }, {
			T.f("s", "string", { "1728397800" }),
		})
		expect(strSecs[1].values).toEqual({ 1728397800000 })
		local strMs = convert({ { targetField = "s", destinationType = "time", dateFormat = "x" } }, {
			T.f("s", "string", { "1728397800000" }),
		})
		expect(strMs[1].values).toEqual({ 1728397800000 })
	end)

	it("should honour an all-digit date format for string values", function()
		local out = convert({ { targetField = "d", destinationType = "time", dateFormat = "YYYYMMDD" } }, {
			T.f("d", "string", { "20241008", "20241009" }),
		}, -300)
		expect(out[1].values).toEqual({ 1728363600000, 1728450000000 })
	end)

	it("enum: values become indexes into the texts, shown through a value mapping", function()
		local out = convert({
			{
				targetField = "s",
				destinationType = "enum",
				enumConfig = { text = { "low", "high" }, color = { "green" } },
			},
		}, { T.f("s", "string", { "high", "low", "other" }) })
		expect(out[1].values).toEqual({ 1, 0, NULL })
		local mapping = (out[1].config :: any).mappings[1]
		expect(mapping.type).toBe("value")
		expect(mapping.options["1"].text).toBe("high")
		expect(mapping.options["0"].color).toBe("green")
	end)

	it("reports date formats it cannot parse", function()
		expect(T.unsupported("convertFieldType", {
			conversions = { { targetField = "x", destinationType = "time", dateFormat = "GGGG-[W]WW" } },
		})).toBe("transformation convertFieldType dateFormat token GGGG is not supported")
		expect(T.unsupported("convertFieldType", {
			conversions = { { targetField = "x", destinationType = "time", dateFormat = "YYYY-MM-DD HH:mm:ss.SSS Z" } },
		})).toBeNil()
	end)
end)

describe("formatTime (formatTime.test.ts)", function()
	local values = { 1612939600000, 1689192000000, 1682025600000, 1690328089000, 1691011200000 }

	it("will convert time to formatted string, matching on the display name", function()
		local out = T.one("formatTime", { timeField = "time", outputFormat = "YYYY-MM", timezone = "utc" }, {
			T.frame({ T.f("time", "time", values) }),
		})
		expect(out[1].fields[1].values).toEqual({ "2021-02", "2023-07", "2023-04", "2023-07", "2023-08" })
		local named = T.one("formatTime", { timeField = "Created", outputFormat = "YYYY-MM", timezone = "utc" }, {
			T.frame({ T.f("created", "time", values, nil, { displayName = "Created" }) }),
		})
		expect(named[1].fields[1].type).toBe("string")
	end)

	it("will handle formats with times, and null times", function()
		local v = table.clone(values)
		v[5] = NULL
		local out = T.one("formatTime", { timeField = "time", outputFormat = "YYYY-MM h:mm:ss a", timezone = "utc" }, {
			T.frame({ T.f("time", "time", v) }),
		})
		expect(out[1].fields[1].values).toEqual({
			"2021-02 6:46:40 am",
			"2023-07 8:00:00 pm",
			"2023-04 9:20:00 pm",
			"2023-07 11:34:49 pm",
			"Invalid date",
		})
	end)
end)

describe("time conversions in practice", function()
	it("a monthly bar chart: time to YYYY-MM text, then back to a time", function()
		local fields = convert({
			{ targetField = "started", destinationType = "string", dateFormat = "YYYY-MM" },
			{ targetField = "started", destinationType = "time", dateFormat = "" },
		}, { T.f("started", "time", { 1626674400000, 1627797600000 }) })
		expect(fields[1].type).toBe("time")
		-- "2021-07" read with "YYYY-MM-DD HH:mm:ss": July 1st, midnight UTC.
		expect(fields[1].values).toEqual({ 1625097600000, 1627776000000 })
	end)
end)

return nil
