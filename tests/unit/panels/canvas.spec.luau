--!strict
-- The canvas panel (canvas/runtime/element.tsx applyLayoutStylesToDiv,
-- elements, dimensions) on tern-all-panels panel 34: a dark-blue box with
-- a dark-green border, a fixed "Targets up" label and a metric value of
-- `sum(up)` colored by thresholds (red, green from 5).
local Canvas = require("../../../plugin/lib/panels/canvas")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local function allPanels(version: string, id: number): any
	local doc = S.decode("grafana/" .. version .. "/dashboard_tern_all_panels.json")
	for _, p in doc.dashboard.panels do
		if p.id == id then
			return p
		end
	end
	error("no panel " .. id)
end

for _, version in S.VERSIONS do
	describe("canvas " .. version, function()
		it("draws the box, the label and the colored metric value", function()
			local frames = S.frames(version, "all_panels_34")
			local layout = Canvas.layout(allPanels(version, 34), frames, env, { key = "cv" }, 1000, 460)
			-- Root frame, then Box, Label, Value.
			expect(#layout.shapes).toBe(4)
			local box, label, value = layout.shapes[2], layout.shapes[3], layout.shapes[4]
			expect(box.x).toBe(10)
			expect(box.w).toBe(260)
			expect(box.fill).toBe("#1F60C4")
			expect(box.stroke).toBe("#37872D")
			expect(box.stroke_width).toBe(2)
			expect(label.text).toBe("Targets up")
			expect(label.text_color).toBe("#ffffff")
			expect(value.text).toBe(tostring(frames[1].fields[2].values[1]))
			-- sum(up) is 5 on the stack: green from 5.
			expect(value.text_color).toBe("#73BF69")
			expect(value.text_size).toBe(40)
			local _, assets =
				Canvas.view(allPanels(version, 34), frames, env, { key = "cv", size = { w = 1000, h = 460 } })
			local svg = (assets :: any).cv.bytes
			expect(string.find(svg, ">Targets up</text>", 1, true) ~= nil).toBe(true)
		end)
	end)
end

describe("canvas placement", function()
	local function place(c: string, p: string): any
		return Canvas.place(S.json('{"constraint": ' .. c .. ', "placement": ' .. p .. "}"), {
			x = 0,
			y = 0,
			w = 400,
			h = 200,
		}, env)
	end

	-- applyLayoutStylesToDiv: right/bottom anchor to the far edges,
	-- center offsets from the middle, scale is percent.
	it("places elements by their constraints", function()
		local r = place(
			'{"horizontal": "right", "vertical": "bottom"}',
			'{"right": 10, "bottom": 20, "width": 50, "height": 30}'
		)
		expect(r.x).toBe(340)
		expect(r.y).toBe(150)
		local c =
			place('{"horizontal": "center", "vertical": "center"}', '{"left": 0, "top": 0, "width": 100, "height": 50}')
		expect(c.x).toBe(150)
		expect(c.y).toBe(75)
		local s =
			place('{"horizontal": "scale", "vertical": "scale"}', '{"left": 10, "right": 20, "top": 0, "bottom": 50}')
		expect(s.x).toBe(40)
		expect(s.w).toBe(280)
		expect(s.h).toBe(100)
	end)

	it("keeps unsupported element types on the ladder", function()
		local panel = S.clone(allPanels("12.4.12", 34))
		panel.options.root.elements[1].type = "icon"
		local ok, why = Canvas.supports(panel, env)
		expect(ok).toBe(false)
		expect(why).toBe("canvas element type icon is not drawn natively")
	end)
end)

return nil
