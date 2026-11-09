--!strict
-- Tbl.sortedKeys replaces local copies that order labels and names shown to
-- the user and sent in queries: the order must be the plain sorted one.
local Tbl = require("../../plugin/lib/tbl")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("Tbl.sortedKeys", function()
	it("returns every key in sorted order", function()
		expect(Tbl.sortedKeys({ job = 1, __name__ = 2, Instance = 3, a = 4 })).toEqual({
			"Instance",
			"__name__",
			"a",
			"job",
		})
		expect(Tbl.sortedKeys({ [3] = "c", [1] = "a", [2] = "b" })).toEqual({ 1, 2, 3 })
		expect(Tbl.sortedKeys({})).toEqual({})
	end)
end)

return nil
