--!strict
-- Suggestion lists stay cached per context but bounded: a long session
-- typing many label names must not grow memory without end, and the lists
-- every keystroke needs (metric names, metadata) are never the ones dropped.
local SuggestCache = require("../../plugin/lib/suggest_cache")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function entry(at: number): SuggestCache.Entry
	return { status = "ok", at_ms = at, values = { "x" } }
end

describe("suggestion cache", function()
	it("drops the least recently used list past its bound, never a pinned one", function()
		local c = SuggestCache.new({ names = true }, 3)
		SuggestCache.put(c, "lab", "names", entry(0))
		SuggestCache.put(c, "lab", "a", entry(0))
		SuggestCache.put(c, "lab", "b", entry(0))
		SuggestCache.put(c, "lab", "c", entry(0))
		SuggestCache.get(c, "lab", "a")
		SuggestCache.put(c, "lab", "d", entry(0))
		expect(SuggestCache.get(c, "lab", "b")).toBeNil()
		for _, k in { "names", "a", "c", "d" } do
			expect(SuggestCache.get(c, "lab", k) ~= nil).toBe(true)
		end
		-- Contexts are bounded apart.
		SuggestCache.put(c, "prod", "a", entry(0))
		expect(SuggestCache.get(c, "lab", "a") ~= nil).toBe(true)
	end)

	it("keeps lists fresh for their TTL, failures for a shorter one", function()
		expect(SuggestCache.fresh(entry(0), SuggestCache.TTL_MS - 1)).toBe(true)
		expect(SuggestCache.fresh(entry(0), SuggestCache.TTL_MS)).toBe(false)
		expect(SuggestCache.fresh({ status = "error", at_ms = 0 }, SuggestCache.ERROR_TTL_MS)).toBe(false)
		expect(SuggestCache.fresh({ status = "pending", at_ms = 0 }, 1e12)).toBe(true)
	end)
end)

return nil
