--!strict
-- History lives in a shared, world-readable kv file: it must stay bounded,
-- keep one entry per expression (re-running moves it to the front), keep
-- contexts apart, and survive whatever another version wrote there.
local History = require("../../../plugin/lib/query/history")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("History", function()
	it("keeps the newest first and each expression once", function()
		local h = History.add(nil, "lab", "up")
		h = History.add(h, "lab", "rate(x[5m])")
		h = History.add(h, "lab", "  up  ")
		expect(History.list(h, "lab")).toEqual({ "up", "rate(x[5m])" })
	end)

	it("caps each context's list", function()
		local h: any = nil
		for i = 1, History.CAP + 20 do
			h = History.add(h, "lab", "q" .. i)
		end
		local list = History.list(h, "lab")
		expect(#list).toBe(History.CAP)
		expect(list[1]).toBe("q" .. (History.CAP + 20))
		expect(list[History.CAP]).toBe("q21")
	end)

	it("keeps contexts apart", function()
		local h = History.add(History.add(nil, "lab", "up"), "prod", "sum(up)")
		expect(History.list(h, "lab")).toEqual({ "up" })
		expect(History.list(h, "prod")).toEqual({ "sum(up)" })
	end)

	it("ignores blank expressions and malformed stored values", function()
		expect(History.list(History.add(nil, "lab", "   "), "lab")).toEqual({})
		expect(History.list("garbage", "lab")).toEqual({})
		local mixed: any = { lab = S.list("up", 3, "", { x = 1 }) }
		expect(History.list(mixed, "lab")).toEqual({ "up" })
		expect(History.list(History.add({ lab = "nope" }, "lab", "up"), "lab")).toEqual({ "up" })
	end)

	it("filters case-insensitively", function()
		expect(History.filter({ "rate(Node_cpu[5m])", "up" }, "node")).toEqual({ "rate(Node_cpu[5m])" })
	end)
end)

return nil
