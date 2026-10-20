--!strict
-- sortBy and filterByValue, as packages/grafana-data/src/transformations/
-- transformers/sortBy.test.ts, filterByValue.test.ts and matchers/
-- valueMatchers/*.test.ts pin them, plus the uses dashboards make of them:
-- a table sorted by its value column, a stat showing only positive series
-- and a table hiding rows without a key.
local t = require("../../../lib/test")
local T = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = T.NULL

describe("sortBy (sortBy.test.ts)", function()
	local function frame()
		return T.frame({
			T.f("time", "time", { 3, 1, 2 }),
			T.f("message", "string", { "c", "a", "b" }),
			T.f("n", "number", { 1, 2, 1 }),
		})
	end

	it("does not apply when config is missing sort fields", function()
		local f = frame()
		expect(T.one("sortBy", {}, { f })[1]).toBe(f)
	end)

	it("sorts time ascending and descending", function()
		expect(T.one("sortBy", { sort = { { field = "time" } } }, { frame() })[1].fields[2].values).toEqual({
			"a",
			"b",
			"c",
		})
		expect(T.one("sortBy", { sort = { { field = "time", desc = true } } }, { frame() })[1].fields[2].values).toEqual({
			"c",
			"b",
			"a",
		})
	end)

	it("uses later fields to break ties, each with its own direction", function()
		local out = T.one("sortBy", { sort = { { field = "n" }, { field = "time", desc = true } } }, { frame() })
		expect(out[1].fields[1].values).toEqual({ 3, 2, 1 })
		expect(out[1].fields[3].values).toEqual({ 1, 1, 2 })
	end)

	it("skips fields missing from the frame; no match leaves the rows", function()
		local out = T.one("sortBy", { sort = { { field = "nope" }, { field = "message" } } }, { frame() })
		expect(out[1].fields[2].values).toEqual({ "a", "b", "c" })
		local none = T.one("sortBy", { sort = { { field = "nope" } } }, { frame() })
		expect(none[1].fields[2].values).toEqual({ "c", "a", "b" })
	end)

	it("orders strings case-insensitively and puts empty ones last", function()
		local out = T.one("sortBy", { sort = { { field = "s" } } }, {
			T.frame({ T.f("s", "string", { "b", "", "A", NULL, "a" }) }),
		})
		expect(out[1].fields[1].values).toEqual({ "A", "a", "b", "", NULL })
	end)

	it("in practice: a table sorted by its value column, descending", function()
		local out = T.one("sortBy", { sort = { { desc = true, field = "Value #A" } } }, {
			T.frame({ T.f("instance", "string", { "a", "b", "c" }), T.f("Value #A", "number", { 2, 9, 5 }) }),
		})
		expect(out[1].fields[1].values).toEqual({ "b", "c", "a" })
	end)
end)

describe("filterByValue (filterByValue.test.ts, valueMatchers/*.test.ts)", function()
	local function data()
		return T.frame({
			T.f("time", "time", { 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000 }),
			T.f("numbers", "number", { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }),
			T.f("text", "string", { "a", "b", "c", "d", NULL, "f", "g", "h", "i", "j" }),
		})
	end

	local function filter(options: any): any
		return T.one("filterByValue", options, { data() })[1]
	end

	it("should exclude values", function()
		local out = filter({
			type = "exclude",
			match = "any",
			filters = { { fieldName = "numbers", config = { id = "lowerOrEqual", options = { value = 5 } } } },
		})
		expect(out.fields[2].values).toEqual({ 6, 7, 8, 9, 10 })
		expect(out.fields[1].values).toEqual({ 6000, 7000, 8000, 9000, 10000 })
	end)

	it("should not include null values when matching by regex", function()
		local out = filter({
			type = "include",
			match = "any",
			filters = { { fieldName = "text", config = { id = "regex", options = { value = ".*" } } } },
		})
		expect(#out.fields[3].values).toBe(9)
	end)

	it("should include values; match any and match all", function()
		local any = filter({
			type = "include",
			match = "any",
			filters = {
				{ fieldName = "numbers", config = { id = "lower", options = { value = 2 } } },
				{ fieldName = "numbers", config = { id = "greater", options = { value = 9 } } },
			},
		})
		expect(any.fields[2].values).toEqual({ 1, 10 })
		local all = filter({
			type = "include",
			match = "all",
			filters = {
				{ fieldName = "numbers", config = { id = "greaterOrEqual", options = { value = 3 } } },
				{ fieldName = "numbers", config = { id = "between", options = { from = 2, to = 5 } } },
			} :: { any },
		})
		expect(all.fields[2].values).toEqual({ 3, 4 })
	end)

	it("value matchers: equal is loose, between can be inclusive, null checks", function()
		local function only(config: any): { any }
			return filter({ type = "include", match = "any", filters = { { fieldName = "numbers", config = config } } }).fields[2].values
		end
		expect(only({ id = "equal", options = { value = "3" } })).toEqual({ 3 })
		expect(#only({ id = "notEqual", options = { value = 3 } })).toBe(9)
		expect(only({ id = "between", options = { from = 2, to = 4, inclusive = true } })).toEqual({ 2, 3, 4 })
		expect(only({ id = "greater", options = { value = "8" } })).toEqual({ 9, 10 })
		local nulls = filter({
			type = "include",
			match = "any",
			filters = { { fieldName = "text", config = { id = "isNull", options = {} } } },
		})
		expect(nulls.fields[2].values).toEqual({ 5 })
	end)

	it("a missing field matches nothing, unless missingField is ignore", function()
		local strict = filter({
			type = "include",
			match = "any",
			filters = { { fieldName = "nope", config = { id = "isNull" } } },
		})
		expect(#strict.fields[1].values).toBe(0)
		local ignore = filter({
			type = "exclude",
			match = "any",
			missingField = "ignore",
			filters = { { fieldName = "nope", config = { id = "isNull" } } },
		})
		expect(#ignore.fields[1].values).toBe(10)
	end)

	it("reports matchers it cannot evaluate", function()
		expect(T.unsupported("filterByValue", {
			filters = { { fieldName = "x", config = { id = "inSet", options = { values = { 1 }, mode = "display" } } } },
		})).toBe("transformation filterByValue value matcher inSet on display values is not supported")
		expect(T.unsupported("filterByValue", { filters = { { fieldName = "x", config = { id = "fancy" } } } })).toBe(
			"transformation filterByValue value matcher fancy is not supported"
		)
	end)

	it("in practice: a stat keeps the positive rows; a table drops rows without a key", function()
		local stat = T.one("filterByValue", {
			type = "include",
			match = "all",
			filters = { { fieldName = "Value #host", config = { id = "greater", options = { value = 0 } } } },
		}, { T.frame({ T.f("host", "string", { "a", "b", "c" }), T.f("Value #host", "number", { 0, 3, NULL }) }) })
		expect(stat[1].fields[1].values).toEqual({ "b" })
		local tbl = T.one("filterByValue", {
			type = "exclude",
			match = "all",
			filters = { { fieldName = "Dashboard UID", config = { id = "isNull", options = {} } } },
		}, { T.frame({ T.f("Dashboard UID", "string", { "x", NULL }), T.f("n", "number", { 1, 2 }) }) })
		expect(tbl[1].fields[2].values).toEqual({ 1 })
	end)
end)

return nil
