--!strict
-- The `logs` config section: a bad value must not break the block, it falls
-- back to the default and says which key is wrong.
local Options = require("../../../plugin/lib/logs/options")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("logs section", function()
	it("defaults to 500 lines, a 2 s tail and volume bars", function()
		local o, problems = Options.read(nil)
		expect(o).toEqual({ default_range = "now-1h", limit = 500, tail_ms = 2000, volume = true })
		expect(problems).toEqual({})
	end)

	it("reads every key", function()
		local o, problems =
			Options.read({ default_range = "now-15m", limit = 1000, tail_interval = "5s", volume = false })
		expect(o).toEqual({ default_range = "now-15m", limit = 1000, tail_ms = 5000, volume = false })
		expect(problems).toEqual({})
	end)

	it("reports bad values and unknown keys and keeps the defaults", function()
		local o, problems = Options.read({ limit = 0, tail_interval = "100ms", volume = "yes", lines = 3 })
		expect(o).toEqual(Options.defaults())
		local paths = {}
		for _, p in problems do
			table.insert(paths, p.path)
		end
		expect(paths).toEqual({ "logs.lines", "logs.limit", "logs.tail_interval", "logs.volume" })
	end)
end)

return nil
