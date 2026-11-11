--!strict
-- Gradient bands per slice cost bytes: a pie of many slices must still fit
-- Tern's SVG cap (Kit.finish asserts it) and keep a gradient per slice.
local SvgPie = require("../../../plugin/lib/render/svg_pie")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function count(s: string, needle: string): number
	local _, n = string.gsub(s, needle, "")
	return n
end

describe("svg_pie gradient bands", function()
	it("gives each slice one band per color step on a few slices", function()
		local svg = SvgPie.render({
			{ value = 1, class = "tg-s1", color = "#97aab3", labels = {} },
			{ value = 2, class = "tg-s2", color = "#97aab3", labels = {} },
		}, { size = 400, donut = true })
		-- #97aab3: 31 levels dark, 21 light.
		expect(count(svg, "tgv%-dark")).toBe(2 * 31)
		expect(count(svg, "tgv%-light")).toBe(2 * 21)
	end)

	it("coarsens the bands of a pie with hundreds of slices to fit the cap", function()
		local slices: { SvgPie.Slice } = {}
		for i = 1, 300 do
			table.insert(slices, { value = i, class = "tg-s1", color = "#97aab3", labels = {} })
		end
		local svg = SvgPie.render(slices, { size = 800, donut = true })
		expect(#svg <= 256 * 1024).toBe(true)
		expect(count(svg, "tgv%-dark") >= 300).toBe(true)
	end)

	it("draws no band thinner than a pixel", function()
		local svg = SvgPie.render({ { value = 1, class = "tg-s1", color = "#e97659", labels = {} } }, {
			size = 72,
			donut = true,
		})
		-- Ring 20 px thick (max(r/3, 20)): 20 bands, not the 34 levels of #e97659.
		expect(count(svg, "tgv%-dark")).toBe(20)
	end)
end)

return nil
