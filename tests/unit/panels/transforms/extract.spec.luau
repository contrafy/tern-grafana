--!strict
-- extractFields, as public/app/features/transformers/extractFields/
-- extractFields.test.ts and fieldExtractor.test.ts pin it (JSON with paths,
-- key/value pairs with quotes and separators, delimiters, regular
-- expressions, deduplicated names, keepTime), plus the two dashboard uses:
-- a Loki labels object split into columns and key=value log lines.
local t = require("../../../lib/test")
local T = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = T.NULL

local function extract(options: any, fields: { any }): any
	return T.one("extractFields", options, { T.frame(fields) })[1]
end

local function kvp(line: string): (any, { string })
	local out = extract({ source = "line", format = "kvp", replace = true }, { T.f("line", "string", { line }) })
	local values: { [string]: any } = {}
	for _, f in out.fields do
		values[f.name] = f.values[1]
	end
	return values, T.fieldNames(out)
end

describe("extractFields (extractFields.test.ts, fieldExtractor.test.ts)", function()
	it("adds fields from JSON in a string, typed by their first value, in key order", function()
		local out = extract({ source = "line", replace = true }, {
			T.f("ts", "time", { 1, 2 }),
			T.f("line", "string", { '{"sym":"AAPL","v":10,"z":1.5,"ok":true}', '{"sym":"MSFT","v":11,"n":null}' }),
		})
		expect(T.fieldNames(out)).toEqual({ "sym", "v", "z", "ok", "n" })
		expect(out.fields[1].type).toBe("string")
		expect(out.fields[2].type).toBe("number")
		expect(out.fields[4].type).toBe("boolean")
		expect(out.fields[1].values).toEqual({ "AAPL", "MSFT" })
		expect(out.fields[3].values).toEqual({ 1.5, NULL })
		expect(out.fields[5].type).toBe("other")
	end)

	it("gets nested path values, with aliases and Not Found", function()
		local out = extract({
			source = "line",
			format = "json",
			replace = true,
			jsonPaths = { { path = "a.b[1]", alias = "second" }, { path = "c" }, { path = "" } } :: { any },
		}, { T.f("line", "string", { '{"a":{"b":[1,2]},"d":1}' }) })
		expect(T.fieldNames(out)).toEqual({ "second", "c" })
		expect(out.fields[1].values).toEqual({ 2 })
		expect(out.fields[2].values).toEqual({ "Not Found" })
	end)

	it("keeps the time field on replace", function()
		local out = extract({ source = "line", replace = true, keepTime = true }, {
			T.f("Time", "time", { 1 }),
			T.f("line", "string", { '{"a":1}' }),
		})
		expect(T.fieldNames(out)).toEqual({ "Time", "a" })
	end)

	it("skips null values and keeps the other fields without replace", function()
		local out = extract({ source = "line" }, { T.f("line", "string", { NULL, '{"a":1}' }) })
		expect(T.fieldNames(out)).toEqual({ "line", "a" })
		expect(out.fields[2].values).toEqual({ NULL, 1 })
	end)

	it("key-values with single/double quotes", function()
		local v, names = kvp('a="1",   "b"=\'2\',c=3  x:y ;\r\nz="d and 4"')
		expect(names).toEqual({ "a", "b", "c", "x", "z" })
		expect(v).toEqual({ a = "1", b = "2", c = "3", x = "y", z = "d and 4" })
	end)

	it("key-values with nested quotes and separators", function()
		local v =
			kvp('a="1",   "b"=\'2\',c=3  x:y ;\r\nz="dbl_quotes=\\"Double Quotes\\" sgl_quotes=\'Single Quotes\'"')
		expect(v.z).toBe("dbl_quotes=\"Double Quotes\" sgl_quotes='Single Quotes'")
		local w = kvp('a="1",   "b"=\'2\',c=3  x:y ;\r\nz="This is; testing& validating, 1=:2"')
		expect(w.z).toBe("This is; testing& validating, 1=:2")
	end)

	it("key-values where some values are empty, URL style, Prometheus style", function()
		expect((kvp("a=, \"b\"='2',c=3  x: "))).toEqual({ a = "", b = "2", c = "3", x = "" })
		expect((kvp("a=b&c=d&x=123"))).toEqual({ a = "b", c = "d", x = "123" })
		expect((kvp('{foo="bar", baz="42"}'))).toEqual({ foo = "bar", baz = "42" })
	end)

	it("deduplicates names against kept fields and each other", function()
		local out = extract({ source = "foo", format = "json" }, { T.f("foo", "string", { '{"foo":"x"}' }) })
		expect(T.fieldNames(out)).toEqual({ "foo", "foo 1" })
		local replaced = extract(
			{ source = "foo", format = "json", replace = true },
			{ T.f("foo", "string", { '{"foo":"x"}' }) }
		)
		expect(T.fieldNames(replaced)).toEqual({ "foo" })
	end)

	it("splits by regexp named groups and by delimiter", function()
		local re = extract(
			{ source = "line", format = "regexp", regExp = "/(?<method>\\w+) (?<path>\\S+)/", replace = true },
			{
				T.f("line", "string", { "GET /index.html" }),
			}
		)
		expect(T.fieldNames(re)).toEqual({ "method", "path" })
		expect(re.fields[2].values).toEqual({ "/index.html" })
		local delim = extract({ source = "line", format = "delimiter", replace = true }, {
			T.f("line", "string", { " a , b,c " }),
		})
		expect(T.fieldNames(delim)).toEqual({ "a", "b", "c" })
		expect(delim.fields[1].values).toEqual({ 1 })
	end)
end)

describe("extractFields in practice", function()
	it("a Loki labels object becomes one column per label", function()
		local out = extract({ source = "labels", replace = true }, {
			T.f("labels", "other", { { job = "api", level = "error" }, { job = "web" } }),
		})
		expect(T.fieldNames(out)).toEqual({ "job", "level" })
		expect(out.fields[1].values).toEqual({ "api", "web" })
		expect(out.fields[2].values).toEqual({ "error", NULL })
	end)

	it("key=value log lines become a table", function()
		local out = extract({ source = "Line", format = "kvp", replace = true }, {
			T.f("Line", "string", { 'level=warn msg="slow query" duration=1.2s' }),
		})
		expect(T.fieldNames(out)).toEqual({ "level", "msg", "duration" })
		expect(out.fields[2].values).toEqual({ "slow query" })
	end)
end)

return nil
