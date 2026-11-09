--!strict
-- lib/render/ts_data insertNulls: Grafana's applyNullInsertThreshold, the
-- cases of its own spec (nullInsertThreshold.test.ts). The nulls are what
-- break a time series line where samples are missing.
local Frame = require("../../../plugin/lib/frame/types")
local TsData = require("../../../plugin/lib/render/ts_data")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local N = Frame.NULL

describe("insertNulls", function()
	it("inserts a null at every threshold step inside a longer gap", function()
		local times, cols = TsData.insertNulls({ 1, 3, 10 }, { { 4, 6, 8 }, { "a", "b", "c" } }, 1)
		expect(times).toEqual({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
		expect(cols[1]).toEqual({ 4, N, 6, N, N, N, N, N, N, 8 })
		expect(cols[2]).toEqual({ "a", N, "b", N, N, N, N, N, N, "c" })
		local t2, c2 = TsData.insertNulls({ 5, 7, 11 }, { { 4, 6, 8 } }, 2)
		expect(t2).toEqual({ 5, 7, 9, 11 })
		expect(c2[1]).toEqual({ 4, 6, N, 8 })
	end)

	-- The range edges: back from the first sample to before the range start,
	-- forward from the last while a step stays short of the range end.
	it("fills from the range start and up to the range end", function()
		local times, cols = TsData.insertNulls({ 4, 6, 13 }, { { 4, 6, 8 } }, 1, -0.5, 13)
		expect(times).toEqual({ -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 })
		expect(cols[1]).toEqual({ N, N, N, N, N, 4, N, 6, N, N, N, N, N, N, 8 })
		local day = 86400000
		local days = { 1679439600000, 1679526000000, 1679612400000, 1679698800000, 1679785200000 }
		local dt = TsData.insertNulls(days, { { 0, 1, 2, 3, 4 } }, day, 1679320395828, 1679815217157)
		-- Slots stay on the samples' own grid (11 PM UTC), not midnight.
		expect(dt[1]).toBe(1679266800000)
		expect(#dt).toBe(7)
		local tail, tc = TsData.insertNulls({ 1, 3, 10 }, { { 4, 6, 8 } }, 1, nil, 13)
		expect(tail).toEqual({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 })
		expect(tc[1][12]).toBe(N)
		expect((TsData.insertNulls({ 1 }, { { 1 } }, 1, nil, 2.5))).toEqual({ 1, 2 })
	end)

	it("returns its inputs when nothing is missing", function()
		local times, cols = { 1, 2, 3 }, { { 1, 2, 3 } }
		local t1, c1 = TsData.insertNulls(times, cols, 1)
		expect(t1 == times and c1 == cols).toBe(true)
		local one = { 1 }
		expect(TsData.insertNulls(one, { { 1 } }, 1, nil, 2) == one).toBe(true)
		local empty = {}
		expect(TsData.insertNulls(empty, { {} }, 1, 0, 10) == empty).toBe(true)
		expect(TsData.insertNulls(times, cols, 0) == times).toBe(true)
		expect(TsData.insertNulls(times, cols, -1) == times).toBe(true)
	end)

	-- A threshold far below the sampling (a year at 1 ms) stops filling
	-- every step: one null per gap still breaks the line.
	it("keeps one null per gap past INSERT_MAX steps", function()
		local times, cols = TsData.insertNulls({ 0, 1e9, 1e9 + 1 }, { { 1, 2, 3 } }, 1, -5, 2e9)
		expect(times).toEqual({ 0, 1, 1e9, 1e9 + 1 })
		expect(cols[1]).toEqual({ 1, N, 2, 3 })
	end)
end)

return nil
