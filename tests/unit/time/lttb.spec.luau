--!strict
-- Largest-Triangle-Three-Buckets (Steinarsson 2013, the algorithm Grafana's
-- and uPlot's downsamplers use), extended so missing samples stay visible gaps.
local t = require("../../lib/test")
local lttb = require("../../../plugin/lib/time/lttb")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = newproxy(false)

local function series(n: number, f: (number) -> any): ({ number }, { any })
	local times, values = {}, {}
	for i = 1, n do
		times[i] = i * 1000
		values[i] = f(i)
	end
	return times, values
end

local function isGap(v: any): boolean
	return v == NULL or (type(v) == "number" and v ~= v)
end

describe("lttb.downsample without gaps", function()
	-- The first and last samples anchor the visible range; dropping them
	-- shifts the graph's ends.
	it("keeps both endpoints and returns exactly threshold points", function()
		local times, values = series(1000, function(i)
			return math.sin(i / 20) * 100
		end)
		local t2, v2 = lttb.downsample(times, values, 50, NULL)
		expect(#t2).toBe(50)
		expect(#v2).toBe(50)
		expect(t2[1]).toBe(1000)
		expect(v2[1]).toBe(values[1])
		expect(t2[50]).toBe(1000000)
		expect(v2[50]).toBe(values[1000])
	end)

	-- The reason to use LTTB over striding: a one-sample spike survives.
	it("keeps a lone spike that striding would drop", function()
		local times, values = series(10, function(i)
			return if i == 6 then 100 else 0
		end)
		local t2, v2 = lttb.downsample(times, values, 3, NULL)
		expect(t2).toEqual({ 1000, 6000, 10000 })
		expect(v2).toEqual({ 0, 100, 0 })
	end)

	it("keeps time strictly increasing", function()
		local times, values = series(500, function(i)
			return (i * 7919) % 101
		end)
		local t2 = lttb.downsample(times, values, 40, NULL)
		for i = 2, #t2 do
			expect(t2[i] > t2[i - 1]).toBe(true)
		end
	end)

	it("returns the input untouched when it already fits", function()
		local times, values = series(10, function(i)
			return i
		end)
		local t2, v2 = lttb.downsample(times, values, 10, NULL)
		expect(t2).toBe(times)
		expect(v2).toBe(values)
		t2 = lttb.downsample(times, values, 2, NULL)
		expect(t2).toBe(times)
	end)
end)

describe("lttb.downsample with gaps", function()
	-- A gap is a scrape that never happened; bridging it with a line would
	-- invent data. One missing sample per gap keeps the break.
	it("keeps one missing marker per gap at the gap's first time", function()
		local times, values = series(300, function(i)
			return if i > 100 and i <= 150 then NULL else math.cos(i / 10)
		end)
		local t2, v2 = lttb.downsample(times, values, 60, NULL)
		local gaps = {}
		for i, v in v2 do
			if isGap(v) then
				table.insert(gaps, t2[i])
			end
		end
		expect(gaps).toEqual({ 101000 })
	end)

	it("keeps both ends of every run around a gap", function()
		local times, values = series(300, function(i)
			return if i > 100 and i <= 150 then NULL else i
		end)
		local t2 = lttb.downsample(times, values, 60, NULL)
		for _, edge in { 1000, 100000, 151000, 300000 } do
			expect(t2).toContain(edge)
		end
		expect(#t2 <= 60).toBe(true)
	end)

	it("treats NaN like the missing sentinel", function()
		local times, values = series(200, function(i)
			return if i == 50 or i == 51 then 0 / 0 else i
		end)
		local t2, v2 = lttb.downsample(times, values, 20, NULL)
		local gaps = 0
		for i, v in v2 do
			if isGap(v) then
				gaps += 1
				expect(t2[i]).toBe(50000)
			end
		end
		expect(gaps).toBe(1)
	end)

	it("keeps isolated samples between gaps", function()
		local times, values = series(100, function(i)
			if i == 40 then
				return 7
			elseif i >= 30 and i <= 50 then
				return NULL
			end
			return i
		end)
		local t2, v2 = lttb.downsample(times, values, 20, NULL)
		local found = false
		for i, ts in t2 do
			if ts == 40000 then
				found = v2[i] == 7
			end
		end
		expect(found).toBe(true)
	end)

	it("returns only markers for an all-missing series", function()
		local times, values = series(10, function()
			return NULL
		end)
		local t2, v2 = lttb.downsample(times, values, 5, NULL)
		expect(t2).toEqual({ 1000 })
		expect(v2[1]).toBe(NULL)
	end)
end)

return nil
