--!strict
-- Radial gauge SVGs carry a viewBox tight around what they draw: Grafana
-- draws a gauge at min(width, height) of its panel, so an image scaled to a
-- narrow pane must not keep the panel's empty sides (or it shrinks to a
-- sliver). The box must still hold the whole arc, ring, labels and text.
local SvgGauge = require("../../../plugin/lib/render/svg_gauge")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function spec(style: any, w: number, h: number): SvgGauge.Spec
	return {
		width = w,
		height = h,
		style = style,
		bar_width_factor = 0.5,
		rounded = true,
		fill_from = 0,
		fill_to = 0.6,
		bands = { { from = 0, to = 1, tone = "success" } },
		ring = { { from = 0, to = 0.5, tone = "success" }, { from = 0.5, to = 1, tone = "error" } },
		labels = { { at = 0, text = "0" }, { at = 0.5, text = "50" }, { at = 1, text = "100" } },
		text = "42",
		suffix = "%",
		name = "cpu",
	}
end

local function viewBox(svg: string): (number, number, number, number)
	local x, y, w, h = string.match(svg, 'viewBox="(%-?[%d.]+) (%-?[%d.]+) ([%d.]+) ([%d.]+)"')
	return tonumber(x) :: number, tonumber(y) :: number, tonumber(w) :: number, tonumber(h) :: number
end

describe("radial gauge viewBox", function()
	for _, style in { "v1", "gauge", "circle" } do
		for _, size in { { 800, 264 }, { 220, 600 } } do
			local name = string.format("%s in %dx%d", style, size[1], size[2])
			it("is tight around the arc, ring, labels and text: " .. name, function()
				local s = spec(style, size[1], size[2])
				local svg, w, h = SvgGauge.render(s)
				local x, y, vw, vh = viewBox(svg)
				expect(vw).toBe(w)
				expect(vh).toBe(h)
				-- Inside the design box.
				expect(x >= 0 and y >= 0 and x + vw <= size[1] and y + vh <= size[2]).toBe(true)
				-- Holds every drawn arc end and the labels.
				local d = SvgGauge.dimensions(s)
				local b = SvgGauge.arcBounds(s, d)
				expect(b.x0 >= x - 0.01 and b.y0 >= y - 0.01).toBe(true)
				expect(b.x1 <= x + vw + 0.01 and b.y1 <= y + vh + 0.01).toBe(true)
				for _, at in { 0, 1 } do
					local a = (d.start + at * d.range - 90) * math.pi / 180
					local px, py = d.cx + d.radius * math.cos(a), d.cy + d.radius * math.sin(a)
					expect(px >= x and px <= x + vw and py >= y and py <= y + vh).toBe(true)
				end
				-- Square-ish: no side of empty panel kept, so the gauge fills the
				-- pane at min(width, height) like Grafana's.
				expect(math.max(vw, vh) / math.min(vw, vh) < 1.6).toBe(true)
			end)
		end
	end
end)

return nil
