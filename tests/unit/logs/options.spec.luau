--!strict
-- The `logs` config section: a bad value must not break the block, it falls
-- back to the default and says which key is wrong.
local Correlate = require("../../../plugin/lib/logs/correlate")
local Options = require("../../../plugin/lib/logs/options")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local DEFAULT_LABELS = { "job", "namespace", "pod", "container", "service", "service_name", "app", "instance" }

describe("logs section", function()
	it("defaults to 500 lines, a 2 s tail, volume bars and the usual correlation labels", function()
		local o, problems = Options.read(nil)
		expect(o).toEqual({
			default_range = "now-1h",
			limit = 500,
			tail_ms = 2000,
			volume = true,
			correlate_labels = DEFAULT_LABELS,
			trace_id_pattern = Correlate.DEFAULT_TRACE_PATTERN,
		})
		expect(problems).toEqual({})
	end)

	it("reads every key", function()
		local o, problems = Options.read({
			default_range = "now-15m",
			limit = 1000,
			tail_interval = "5s",
			volume = false,
			correlate_labels = { "cluster", "namespace" },
			trace_id_pattern = [[tid=(\w+)]],
		})
		expect(o).toEqual({
			default_range = "now-15m",
			limit = 1000,
			tail_ms = 5000,
			volume = false,
			correlate_labels = { "cluster", "namespace" },
			trace_id_pattern = [[tid=(\w+)]],
		})
		expect(problems).toEqual({})
	end)

	it("reports bad values and unknown keys and keeps the defaults", function()
		local o, problems = Options.read({
			limit = 0,
			tail_interval = "100ms",
			volume = "yes",
			lines = 3,
			correlate_labels = { "job", "bad-name" },
			trace_id_pattern = "trace_id=(",
		})
		expect(o).toEqual(Options.defaults())
		local paths = {}
		for _, p in problems do
			table.insert(paths, p.path)
		end
		expect(paths).toEqual({
			"logs.lines",
			"logs.limit",
			"logs.tail_interval",
			"logs.volume",
			"logs.correlate_labels",
			"logs.trace_id_pattern",
		})
	end)

	it("refuses an empty correlation list: a jump would carry no label", function()
		local _, problems = Options.read({ correlate_labels = {} })
		expect(problems[1].path).toBe("logs.correlate_labels")
	end)
end)

return nil
