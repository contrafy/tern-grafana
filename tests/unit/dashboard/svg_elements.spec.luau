--!strict
-- Tern's SVG sanitizer draws only svg, g, defs, linearGradient, stop, path,
-- circle, line, rect, mask and text; anything else is dropped with its
-- subtree (verified live on Tern 0.9.16: clipPath, radialGradient, ellipse,
-- polygon, polyline, use, pattern and foreignObject never reach the page).
-- A renderer emitting one of them draws an invisible shape, so every SVG the
-- dashboard block sends for tern-all-panels (one panel per core type, the
-- recorded answers) must stay within the drawn set.
local Fixtures = require("../../lib/fixtures")
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local SvgCanvas = require("../../../plugin/lib/render/svg_canvas")
local View = require("../../../plugin/lib/dashboard/view")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local DRAWN = {
	svg = true,
	g = true,
	defs = true,
	linearGradient = true,
	stop = true,
	path = true,
	circle = true,
	line = true,
	rect = true,
	mask = true,
	text = true,
}

-- Element names Tern would drop, in order of appearance.
local function dropped(svg: string): { string }
	local out = {}
	for name in string.gmatch(svg, "<([%a][%w]*)") do
		if not DRAWN[name] then
			table.insert(out, name)
		end
	end
	return out
end

local function fixtureFor(version: string, tag: string): string?
	if string.match(tag, "^dash/") then
		return S.grafana(version, "dashboard_tern_all_panels.json")
	elseif string.match(tag, "^fs/") then
		return S.grafana(version, "frontend_settings_all_panels.json")
	elseif string.match(tag, "^user/") then
		return S.grafana(version, "user.json")
	end
	return nil
end

for _, version in S.VERSIONS do
	describe("SVG elements on Grafana " .. version, function()
		it("draws every tern-all-panels SVG with elements Tern renders", function()
			local env = S.env()
			env.now_ms = tonumber(S.doc(S.grafana(version, "ds_query_all_panels_3.request.json")).to) :: number
			local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=tern-all-panels" }, nil, env)
			local h = S.harness(s, env, function(e: any): any
				if string.match(e.tag, "^flag/") then
					-- No OpenFeature answer: features stay at their defaults.
					return S.body(404, "")
				end
				local path = fixtureFor(version, e.tag)
				return if path then S.response(path) else nil
			end, true)
			S.drive(h, effects)
			for tag in h.pending do
				local id = string.match(tag, "^q/%d+/%d+/p(%d+)$")
				local path = if id then S.grafana(version, "ds_query_all_panels_" .. id .. ".json") else nil
				if path and Fixtures.has(path) then
					State.update(h.s, { kind = "http_done", tag = tag, response = S.response(path) }, h.env)
				end
			end
			local _, assets = View.view(h.s, h.env)
			local svgs = 0
			for key, asset in (assets or {}) :: any do
				if asset.mime == "image/svg+xml" then
					svgs += 1
					local bad = dropped(asset.bytes)
					expect(key .. ": " .. table.concat(bad, ",")).toBe(key .. ": ")
				end
			end
			expect(svgs > 10).toBe(true)
		end)
	end)
end

describe("canvas shapes", function()
	it("draws an ellipse element as a path Tern renders", function()
		local svg = SvgCanvas.render({
			width = 200,
			height = 100,
			shapes = {
				{
					kind = "ellipse",
					x = 10,
					y = 10,
					w = 120,
					h = 60,
					fill = "#1F60C4",
					stroke = "#37872D",
					stroke_width = 2,
				},
			},
			lines = {},
		})
		expect(#dropped(svg)).toBe(0)
		-- Two half-ellipse arcs with the box's radii (box minus the border).
		expect(string.find(svg, 'd="M11.0 40.0A59.0 29.0 0 1 0 129.0 40.0A59.0 29.0 0 1 0 11.0 40.0Z"', 1, true) ~= nil).toBe(
			true
		)
	end)
end)

return nil
