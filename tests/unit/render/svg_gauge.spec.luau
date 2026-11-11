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
		bands = { { from = 0, to = 1, class = "tg-gc1" } },
		ring = { { from = 0, to = 0.5, class = "tg-gc1" }, { from = 0.5, to = 1, class = "tg-gc2" } },
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

-- effects.gradient is a CSS conic-gradient in Grafana: the color at an
-- angle of the arc is its place on the scale between the stops. Tern's SVG
-- has none, so each sub-arc is stroked with a linear gradient between its
-- two stops laid along its chord: at both ends of every sub-arc the
-- gradient's parameter must be the place between the stops there, or the
-- colors would jump at the joints.
describe("radial gauge gradient", function()
	for _, style in { "gauge", "circle" } do
		it("puts the conic gradient's color at each sub-arc end: " .. style, function()
			local s = spec(style, 400, 300)
			s.ring = nil
			s.labels = nil
			s.fill_to = 0.8
			s.gradient = { { at = 0, class = "tg-gc1" }, { at = 0.5, class = "tg-gc2" }, { at = 1, class = "tg-gc3" } }
			local svg = SvgGauge.render(s)
			local d = SvgGauge.dimensions(s)
			-- Each gradient: its line and the scale run of its stop pair.
			local lines: { [string]: { number } } = {}
			for id, x1, y1, x2, y2, a in
				string.gmatch(
					svg,
					'<linearGradient id="(%w+)" gradientUnits="userSpaceOnUse" x1="([%d.%-]+)" y1="([%d.%-]+)" x2="([%d.%-]+)" y2="([%d.%-]+)"><stop offset="0" class="([%w%-]+)"/>'
				)
			do
				local from = if a == "tg-gc1" then 0 else 0.5
				lines[id] = {
					tonumber(x1) :: number,
					tonumber(y1) :: number,
					tonumber(x2) :: number,
					tonumber(y2) :: number,
					from,
				}
			end
			local function fraction(x: number, y: number): number
				-- Degrees past the start, a rounded start point a hair before it
				-- still at 0.
				local deg = math.deg(math.atan2(y - d.cy, x - d.cx)) + 90
				return ((deg - d.start + 0.5) % 360 - 0.5) / d.range
			end
			local subs = 0
			for id, x0, y0, x1, y1 in
				string.gmatch(
					svg,
					'stroke="url%(#(%w+)%)"[^>]*d="M([%d.-]+) ([%d.-]+)A[%d.]+ [%d.]+ 0 %d 1 ([%d.-]+) ([%d.-]+)"'
				)
			do
				subs += 1
				local g = lines[id]
				assert(g, "gradient " .. id)
				local gx, gy = g[3] - g[1], g[4] - g[2]
				for _, p in
					{
						{ tonumber(x0) :: number, tonumber(y0) :: number },
						{ tonumber(x1) :: number, tonumber(y1) :: number },
					}
				do
					local along = ((p[1] - g[1]) * gx + (p[2] - g[2]) * gy) / (gx * gx + gy * gy)
					expect(math.abs(along - (fraction(p[1], p[2]) - g[5]) / 0.5) < 0.01).toBe(true)
				end
			end
			-- 0.8 of 220 (360) degrees in sub-arcs of at most 10 degrees per stop pair.
			expect(subs).toBe(if style == "gauge" then 18 else 29)
			-- Colors are the stops' classes, not computed fills.
			expect(
				string.find(svg, '<stop offset="0" class="tg-gc1"/><stop offset="1" class="tg-gc2"/>', 1, true) ~= nil
			).toBe(true)
			expect(
				string.find(svg, '<stop offset="0" class="tg-gc2"/><stop offset="1" class="tg-gc3"/>', 1, true) ~= nil
			).toBe(true)
		end)
	end
end)

return nil
