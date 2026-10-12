--!strict
-- Tail polls overlap on purpose (a late line must not be missed), so the
-- same entries come back on every poll: each must show once, a different
-- stream logging the same text in the same second must still show, and the
-- buffer stays within the line limit by dropping the oldest.
local FrameLoki = require("../../../plugin/lib/frame/loki")
local Loki = require("../../../plugin/lib/source/loki")
local S = require("../source/support")
local Tail = require("../../../plugin/lib/logs/tail")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local route = table.clone(S.direct)
route.signal = "logs"

local all = (Loki.parse(route, S.response("loki/3.7.8/query_range_streams.json"), S.env) :: any).lines

-- Lines with ts in [from_s, to_s] (seconds), as a poll over that window returns.
local function window(from_s: number, to_s: number): { any }
	local out = {}
	for _, l in all do
		local s = math.floor(l.time_ms / 1000)
		if s >= from_s and s <= to_s then
			table.insert(out, l)
		end
	end
	return out
end

local function ids(lines: { any }): { string }
	local out = {}
	for i, l in lines do
		out[i] = l.id
	end
	return out
end

describe("merge", function()
	it("keeps each entry once across overlapping windows", function()
		local first = window(1791577873, 1791577885)
		local merged, added = Tail.merge({}, first, 500)
		expect(added).toBe(#first)
		local second = window(1791577880, 1791577897)
		merged, added = Tail.merge(merged, second, 500)
		expect(added).toBe(#window(1791577886, 1791577897))
		expect(ids(merged)).toEqual(ids(all))
		local _, again = Tail.merge(merged, second, 500)
		expect(again).toBe(0)
	end)

	it("keeps two streams' identical lines at the same instant", function()
		local a = {
			FrameLoki.streams(
				{ result = { { stream = { app = "a" }, values = { { "1000000000", "same" } } } } },
				S.env
			)[1],
		}
		local b =
			FrameLoki.streams({ result = { { stream = { app = "b" }, values = { { "1000000000", "same" } } } } }, S.env)
		local merged, added = Tail.merge(a, b, 10)
		expect(added).toBe(1)
		expect(#merged).toBe(2)
	end)

	it("keeps the newest lines when over the limit", function()
		local merged = Tail.merge(window(1791577873, 1791577885), window(1791577886, 1791577897), 10)
		expect(#merged).toBe(10)
		expect(ids(merged)).toEqual(ids(table.move(all, 1, 10, 1, {})))
	end)

	it("puts a late line in timestamp order", function()
		local late = window(1791577873, 1791577873)
		local merged = Tail.merge(window(1791577874, 1791577897), late, 500)
		expect(ids(merged)).toEqual(ids(all))
	end)
end)

describe("window start", function()
	it("starts before the newest line by the overlap, never before the range", function()
		expect(Tail.windowStart({}, 1000, 2000)).toBe(1000)
		expect(Tail.windowStart(all, 0, 2000)).toBe(1791577897000 - 5000)
		expect(Tail.windowStart(all, 0, 4000)).toBe(1791577897000 - 8000)
		expect(Tail.windowStart(all, 1791577896000, 2000)).toBe(1791577896000)
	end)
end)

return nil
