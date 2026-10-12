--!strict
-- A typo in the `investigate` section must not break the preview: a bad
-- range falls back to the default with a problem naming the path.
local Settings = require("../../../plugin/lib/investigate/settings")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function read(section: any): (any, { any })
	return Settings.read({ contexts = {}, investigate = section } :: any)
end

describe("investigate settings", function()
	it("defaults to the last hour", function()
		local s = read(nil)
		expect(s.range).toBe("1h")
		expect(s.range_ms).toBe(3600000)
	end)

	it("reads a duration", function()
		local s, problems = read({ range = "30m" })
		expect(s.range_ms).toBe(1800000)
		expect(#problems).toBe(0)
	end)

	it("falls back on a bad or unbounded range and names unknown keys", function()
		local bads: { any } = { "soon", "0s", "30d", 5 }
		for _, bad in bads do
			local s, problems = read({ range = bad })
			expect(s.range).toBe("1h")
			expect(problems[1].path).toBe("investigate.range")
		end
		local _, problems = read({ rnage = "1h" })
		expect(problems[1].path).toBe("investigate.rnage")
	end)
end)

return nil
