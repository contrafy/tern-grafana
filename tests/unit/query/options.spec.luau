--!strict
-- A typo in the `query` section must not break the block: each bad key falls
-- back to its default and is reported where the user can fix it.
local Options = require("../../../plugin/lib/query/options")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("Options.read", function()
	it("defaults to the last hour, 600 points, a 30s refresh and exemplars on", function()
		local o, problems = Options.read(nil)
		expect(o).toEqual({ default_range = "now-1h", max_points = 600, refresh_ms = 30000, exemplars = true })
		expect(problems).toEqual({})
	end)

	it("reads valid values", function()
		local o, problems = Options.read({
			default_range = "now-6h",
			max_points = 1200,
			refresh = "1m",
			exemplars = false,
			exemplar_trace_label = "otel_trace",
		})
		expect(o).toEqual({
			default_range = "now-6h",
			max_points = 1200,
			refresh_ms = 60000,
			exemplars = false,
			exemplar_trace_label = "otel_trace",
		})
		expect(#problems).toBe(0)
	end)

	it("reports each bad value and keeps its default", function()
		local o, problems = Options.read({
			default_range = "yesterday",
			max_points = 20000,
			refresh = "1s",
			rate = 1,
			exemplars = "yes",
			exemplar_trace_label = "trace id",
		})
		expect(o).toEqual(Options.defaults())
		local paths = {}
		for _, p in problems do
			table.insert(paths, p.path)
		end
		expect(paths).toEqual({
			"query.rate",
			"query.default_range",
			"query.max_points",
			"query.refresh",
			"query.exemplars",
			"query.exemplar_trace_label",
		})
	end)

	it("rejects a section that is not an object", function()
		local _, problems = Options.read("fast")
		expect(problems[1].path).toBe("query")
	end)
end)

return nil
