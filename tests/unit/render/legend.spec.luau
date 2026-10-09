--!strict
-- The legend is where numbers are read: calcs must come from the full data,
-- skip nulls/NaN, use the panel unit, and switch to cursor values on demand.
local t = require("../../lib/test")
local Frame = require("../../../plugin/lib/frame/types")
local Legend = require("../../../plugin/lib/render/legend")
local Svg = require("../../../plugin/lib/render/svg_timeseries")
local ui = require("../../../plugin/lib/ui")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = Frame.NULL

local function texts(node: ui.Node, out: { string }?): { string }
	local acc: { string } = out or {}
	local p = node.p
	if p and p.spans then
		local parts = {}
		for _, s in p.spans do
			table.insert(parts, s.t)
		end
		table.insert(acc, table.concat(parts))
	end
	if p and type(p.text) == "string" then
		table.insert(acc, p.text)
	end
	for _, c in node.c or ({} :: { ui.Node }) do
		texts(c, acc)
	end
	return acc
end

local function frames(): { Frame.Frame }
	return {
		Frame.timeSeries({ __name__ = "req", code = "200" }, { 0, 10, 20, 30 }, { 1, NULL, 0 / 0, 3 }),
		Frame.timeSeries({ __name__ = "req", code = "500" }, { 0, 10, 20, 30 }, { 4, 5, 6, NULL }),
	}
end

describe("Legend.rows", function()
	it("reduces each series ignoring nulls and NaN", function()
		local layout = Svg.render(frames()).layout
		local heads, rows = Legend.rows(layout, { mode = "table" })
		expect(heads).toEqual({ "Last *", "Min", "Max", "Mean" })
		expect(rows[1].name).toBe('req{code="200"}')
		expect(rows[1].class).toBe("tg-s1")
		expect(rows[1].values).toEqual({ "3", "1", "3", "2" })
		-- The last sample is null: "Last *" is the last real value.
		expect(rows[2].values).toEqual({ "6", "4", "6", "5" })
	end)

	it("formats values in the chart unit", function()
		local layout = Svg.render(frames(), { unit = "ms" }).layout
		local calcs: { Legend.Calc } = { "max" }
		local _, rows = Legend.rows(layout, { calcs = calcs })
		expect(rows[2].values).toEqual({ "6 ms" })
	end)

	it("shows the value at the cursor instead of calcs, with gaps as -", function()
		local layout = Svg.render(frames()).layout
		local heads, rows = Legend.rows(layout, { cursor = 10 })
		expect(heads).toEqual({ "Value" })
		expect(rows[1].values).toEqual({ Legend.NO_VALUE })
		expect(rows[2].values).toEqual({ "5" })
	end)

	-- Downsampling must not change what the legend claims about the data.
	it("computes calcs on the full series, not the drawn samples", function()
		local n = 5000
		local times, values = table.create(n), table.create(n)
		for i = 1, n do
			times[i] = i * 1000
			values[i] = if i == 2501 then 1e6 else (i % 7)
		end
		local layout = Svg.render({ Frame.timeSeries({}, times, values) }, { point_budget = 50 }).layout
		expect(#layout.series[1].times <= 50).toBe(true)
		expect(layout.series[1].calcs.count).toBe(n)
		expect(layout.series[1].calcs.max).toBe(1e6)
	end)
end)

describe("Legend.view", function()
	it("lists names with values and notes dropped series", function()
		local list = {}
		for i = 1, 12 do
			table.insert(list, Frame.timeSeries({ i = tostring(i) }, { 0 }, { i }))
		end
		local layout = Svg.render(list).layout
		local all = table.concat(texts(Legend.view(layout)), "\n")
		expect(all).toContain('{i="1"}')
		expect(all).toContain("2 more series not shown")
	end)

	it("renders a table legend with a header per calc", function()
		local layout = Svg.render(frames()).layout
		local all = texts(Legend.view(layout, { mode = "table" }))
		expect(all).toContain("Mean")
		expect(all).toContain('req{code="500"}')
	end)
end)

return nil
