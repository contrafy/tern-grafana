--!strict
-- A typo in the `query` section must not break the block: each bad key falls
-- back to its default and is reported where the user can fix it.
local Options = require("../../../plugin/lib/query/options")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("Options.read", function()
	it("defaults to the last hour, 600 points and a 30s refresh", function()
		local o, problems = Options.read(nil)
		expect(o).toEqual({ default_range = "now-1h", max_points = 600, refresh_ms = 30000 })
		expect(problems).toEqual({})
	end)

	it("reads valid values", function()
		local o, problems = Options.read({ default_range = "now-6h", max_points = 1200, refresh = "1m" })
		expect(o).toEqual({ default_range = "now-6h", max_points = 1200, refresh_ms = 60000 })
		expect(#problems).toBe(0)
	end)

	it("reports each bad value and keeps its default", function()
		local o, problems = Options.read({ default_range = "yesterday", max_points = 20000, refresh = "1s", rate = 1 })
		expect(o).toEqual(Options.defaults())
		local paths = {}
		for _, p in problems do
			table.insert(paths, p.path)
		end
		expect(paths).toEqual({ "query.rate", "query.default_range", "query.max_points", "query.refresh" })
	end)

	it("rejects a section that is not an object", function()
		local _, problems = Options.read("fast")
		expect(problems[1].path).toBe("query")
	end)
end)

return nil
