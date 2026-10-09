--!strict
-- The instant table is how users read label sets: every label must have a
-- stable column, and the value must never disappear off the end.
local t = require("../../lib/test")
local Frame = require("../../../plugin/lib/frame/types")
local Table = require("../../../plugin/lib/render/table")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = Frame.NULL
local T = 1710000000000

local function heads(columns: { { head: string, numeric: boolean? } }): { string }
	local out = {}
	for _, c in columns do
		table.insert(out, c.head)
	end
	return out
end

describe("Table.rows", function()
	it("has Time, __name__, sorted label columns and Value", function()
		local columns, rows = Table.rows({
			Frame.timeSeries({ __name__ = "up", job = "node", instance = "a" }, { T }, { 1 }),
			Frame.timeSeries({ __name__ = "up", job = "prom", zone = "z1" }, { T }, { 0 }),
		})
		expect(heads(columns)).toEqual({ "Time", "__name__", "instance", "job", "zone", "Value" })
		expect(columns[6].numeric).toBe(true)
		expect(rows[1].cells).toEqual({ "2024-03-09 16:00:00", "up", "a", "node", "", "1" })
		expect(rows[2].cells).toEqual({ "2024-03-09 16:00:00", "up", "", "prom", "z1", "0" })
	end)

	it("shows the latest sample of a range series", function()
		local _, rows = Table.rows({ Frame.timeSeries({}, { T, T + 1000 }, { 5, 7 }) }, { show_time = false })
		expect(rows[1].cells).toEqual({ "7" })
		expect(rows[1].time).toBe(T + 1000)
	end)

	-- NaN is a real Prometheus result; a missing sample is not.
	it("prints NaN as NaN and a missing sample as -", function()
		local _, rows = Table.rows({
			Frame.timeSeries({ k = "a" }, { T }, { 0 / 0 }),
			Frame.timeSeries({ k = "b" }, { T }, { NULL }),
		}, { show_time = false })
		expect(rows[1].cells[2]).toBe("NaN")
		expect(rows[2].cells[2]).toBe(Table.NO_VALUE)
	end)

	it("formats values with the unit", function()
		local _, rows = Table.rows({ Frame.timeSeries({}, { T }, { 2048 }) }, { unit = "bytes", show_time = false })
		expect(rows[1].cells).toEqual({ "2 KiB" })
	end)

	it("keeps the Value column when there are more labels than columns", function()
		local labels = {}
		for i = 1, 30 do
			labels[string.format("l%02d", i)] = "v"
		end
		local columns = Table.rows({ Frame.timeSeries(labels, { T }, { 1 }) })
		expect(#columns).toBe(16)
		expect(columns[16].head).toBe("Value")
	end)
end)

describe("Table.view", function()
	it("attaches the row action from each row's labels", function()
		local node = Table.view({ Frame.timeSeries({ job = "x" }, { T }, { 1 }) }, {
			row_action = function(i, labels)
				return "open:" .. i .. ":" .. labels.job
			end,
		})
		local grid = ((node.c :: { any })[1] :: any).c
		local found = nil
		for _, child in grid do
			if child.p.actions then
				found = child.p.actions.click
			end
		end
		expect(found).toBe("open:1:x")
	end)
end)

return nil
