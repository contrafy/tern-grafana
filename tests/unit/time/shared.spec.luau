--!strict
-- Synced blocks share one kv record. What matters: a block never re-applies
-- its own write (it would re-query in a loop), a record older than one
-- already seen never rolls the range back, joining adopts the others' range
-- instead of yanking them to the newcomer's, and sync off writes nothing.
local Shared = require("../../../plugin/lib/time/shared")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function env(): any
	local kv: { [string]: any } = {}
	return {
		now_ms = 1791577898000,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		kv = kv,
		kv_get = function(key: string): any
			return kv[key]
		end,
	}
end

local function apply(e: any, effect: any)
	if effect and effect.kind == "kv_set" then
		e.kv[effect.key] = effect.value
	end
end

local function synced(kind: string, e: any): Shared.Sync
	local s = Shared.new(kind, e.now_ms)
	Shared.toggle(s)
	return s
end

describe("Shared.publish and adopt", function()
	it("stores Grafana range strings, the cursor, the origin and a seq past the stored one", function()
		local v = Shared.publish(
			{ from = "now-1h", to = "now" },
			1791577000000,
			"a",
			{ seq = 7, origin = "b", from = "x", to = "y" }
		)
		expect(v).toEqual({ from = "now-1h", to = "now", cursor_ms = 1791577000000, origin = "a", seq = 8 })
		expect(Shared.publish({ from = "now-1h", to = "now" }, nil, "a", nil).seq).toBe(1)
	end)

	it("ignores its own echo and records its seq", function()
		local mine: Shared.Sync = { on = true, origin = "a", seq = 0, gen = 1 }
		local r, c = Shared.adopt({ from = "now-1h", to = "now", origin = "a", seq = 3 }, mine)
		expect(r).toBeNil()
		expect(c).toBeNil()
		expect(mine.seq).toBe(3)
	end)

	it("adopts another block's newer record once", function()
		local mine: Shared.Sync = { on = true, origin = "a", seq = 2, gen = 1 }
		local value = { from = "now-6h", to = "now", cursor_ms = 5, origin = "b", seq = 3 }
		local r, c = Shared.adopt(value, mine)
		expect(r).toEqual({ from = "now-6h", to = "now" })
		expect(c).toBe(5)
		-- The same record polled again is not news.
		expect((Shared.adopt(value, mine))).toBeNil()
	end)

	it("never rolls back to a stale seq", function()
		local mine: Shared.Sync = { on = true, origin = "a", seq = 9, gen = 1 }
		expect((Shared.adopt({ from = "now-5m", to = "now", origin = "b", seq = 4 }, mine))).toBeNil()
		expect(mine.seq).toBe(9)
	end)

	it("ignores records that are not well formed", function()
		local mine: Shared.Sync = { on = true, origin = "a", seq = 0, gen = 1 }
		for _, bad in
			{ "x", { from = 1, to = "now", origin = "b", seq = 1 }, { from = "now", to = "now", seq = 1 } } :: { any }
		do
			expect((Shared.adopt(bad, mine))).toBeNil()
		end
	end)
end)

describe("Shared between two blocks", function()
	it("propagates a range change from one synced block to another", function()
		local e = env()
		local a, b = synced("query", e), synced("query", e)
		apply(e, Shared.share(a, { from = "now-3h", to = "now" }, nil, e))
		local r = Shared.poll(b, e)
		expect(r).toEqual({ from = "now-3h", to = "now" })
		-- The writer does not adopt its own record back.
		expect((Shared.poll(a, e))).toBeNil()
		-- b answers with a cursor move; a sees it, b does not see itself.
		apply(e, Shared.share(b, { from = "now-3h", to = "now" }, 1791577500000, e))
		local ra, ca = Shared.poll(a, e)
		expect(ra).toEqual({ from = "now-3h", to = "now" })
		expect(ca).toBe(1791577500000)
		expect((Shared.poll(b, e))).toBeNil()
	end)

	it("writes and reads nothing while sync is off", function()
		local e = env()
		local a = Shared.new("query", e.now_ms)
		expect(Shared.share(a, { from = "now-1h", to = "now" }, nil, e)).toBeNil()
		e.kv[Shared.KEY] = { from = "now-2d", to = "now", origin = "x", seq = 1 }
		expect((Shared.poll(a, e))).toBeNil()
	end)

	it("joins on the shared range, or publishes its own when nobody shares one", function()
		local e = env()
		local first = Shared.new("query", e.now_ms)
		expect(Shared.toggle(first)).toEqual({ kind = "timer", tag = Shared.TAG .. "1", ms = Shared.POLL_MS })
		local r, _, write = Shared.join(first, { from = "now-1h", to = "now" }, nil, e)
		expect(r).toBeNil()
		apply(e, write)
		local second = Shared.new("dashboard", e.now_ms)
		Shared.toggle(second)
		local r2, _, write2 = Shared.join(second, { from = "now-7d", to = "now" }, nil, e)
		expect(r2).toEqual({ from = "now-1h", to = "now" })
		expect(write2).toBeNil()
	end)

	it("drops poll ticks of an earlier sync generation", function()
		local s = Shared.new("query", 0)
		Shared.toggle(s)
		local tick = Shared.timer(s).tag
		Shared.toggle(s)
		Shared.toggle(s)
		expect(Shared.isTick(s, tick)).toBe(false)
		expect(Shared.isTick(s, Shared.timer(s).tag)).toBe(true)
	end)

	it("gives every block its own origin", function()
		expect(Shared.origin("query", 1) ~= Shared.origin("query", 1)).toBe(true)
	end)
end)

return nil
