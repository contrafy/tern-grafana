--!strict
-- The JSON API datasource selects values with jsonpath-plus 10.3.0
-- (eval: false); a path that selects other values (or fails otherwise) than
-- in Grafana gives a panel other numbers. Every case of
-- jsonpath/jsonpath_plus_10.3.0.json was evaluated once by jsonpath-plus
-- 10.3.0 itself (values as JSON.stringify wrote them, the error it threw,
-- and the last part of JSONPath.toPathArray, the plugin's default field
-- name), over documents whose object key order matters.
local JP = require("../../../plugin/lib/datasources/jsonpath")
local Fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local REF = json.decode(Fixtures.read("jsonpath/jsonpath_plus_10.3.0.json"))

describe("JSONPath like jsonpath-plus 10.3.0", function()
	local docs: { [string]: any } = {}
	for name, text in REF.docs do
		docs[name] = assert(JP.decode(text))
	end

	local byDoc: { [string]: { any } } = {}
	for _, c in REF.cases do
		byDoc[c.doc] = byDoc[c.doc] or {}
		table.insert(byDoc[c.doc], c)
	end
	for name, cases in byDoc do
		it(string.format("selects what it selects on the %s document (%d paths)", name, #cases), function()
			local wrong: { string } = {}
			for _, c in cases do
				local values, err = JP.query(c.path, docs[name])
				local got = if err then "error: " .. err else JP.stringify(JP.array(values :: { any }))
				local want = if c.error then "error: " .. c.error else c.values
				local parts = JP.toPathArray(c.path)
				local last = parts[#parts]
				if got ~= want or last ~= (if c.name == json.null then nil else c.name) then
					table.insert(wrong, string.format("%s: %s (name %s)", c.path, got, tostring(last)))
				end
			end
			expect(wrong).toEqual({})
		end)
	end
end)

describe("JSON documents", function()
	it("keeps object keys in JavaScript's order and empty arrays apart from empty objects", function()
		local doc = assert(JP.decode('{"b": {}, "10": [], "a": [1, {"y": 2, "x": null}], "2": "two", "b": true}'))
		expect(JP.stringify(doc)).toBe('{"2":"two","10":[],"b":true,"a":[1,{"y":2,"x":null}]}')
	end)

	it("decodes escapes in keys and strings next to plain ones", function()
		local doc = assert(JP.decode('{ "k\\u0041" : "a\\"b\\\\c\\n\\ud83d\\ude00" ,\n\t"plain":"x", "e": ""}'))
		expect(doc.keys).toEqual({ "kA", "plain", "e" })
		expect(doc.values.kA).toBe('a"b\\c\n' .. utf8.char(0x1F600))
		expect(doc.values.plain).toBe("x")
		expect(doc.values.e).toBe("")
	end)

	it("rejects what JSON.parse rejects", function()
		for _, text in { "", "{", "[1,]", "{'a': 1}", "01", "1 2", '"\t"', "NaN" } do
			local v, err = JP.decode(text)
			expect(v).toBeNil()
			expect(type(err)).toBe("string")
		end
	end)

	it("writes numbers as JavaScript's String(number) does", function()
		local cases: { { any } } = {
			{ 0.1, "0.1" },
			{ 1e21, "1e+21" },
			{ 1.2345678901234568e20, "123456789012345680000" },
			{ 1.5e-5, "0.000015" },
			{ 1e-7, "1e-7" },
			{ -2.5e-10, "-2.5e-10" },
			{ 2 ^ 53 + 2, "9007199254740994" },
		}
		for _, c in cases do
			expect(JP.numberString(c[1])).toBe(c[2])
		end
	end)
end)

return nil
