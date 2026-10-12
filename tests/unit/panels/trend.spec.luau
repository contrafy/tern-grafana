--!strict
-- The trend panel (public/app/plugins/panel/trend TrendPanel.tsx, utils.ts
-- prepSeries) on the tern-all-panels trend (panel 20: csv rpm,power,torque).
local Frame = require("../../../plugin/lib/frame/types")
local S = require("./support")
local Trend = require("../../../plugin/lib/panels/trend")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local PANEL = [[{
	"id": 20, "type": "trend", "title": "Trend: power by rpm",
	"options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom", "calcs": []},
		"xField": "rpm"},
	"fieldConfig": {"defaults": {"custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 10,
		"showPoints": "never", "spanNulls": false, "axisPlacement": "auto"},
		"color": {"mode": "palette-classic"}, "unit": "watt"}, "overrides": []}
}]]

local function frames(): { Frame.Frame }
	return {
		{
			refId = "A",
			fields = {
				Frame.field("rpm", "number", { 1000, 1500, 2000, 2500, 3000, 3500, 4000 }),
				Frame.field("power", "number", { 22, 35, 51, 64, 75, 82, 86 }),
				Frame.field("torque", "number", { 190, 210, 240, 245, 238, 224, 205 }),
			},
		},
	}
end

local function count(s: string, needle: string): number
	local n, i = 0, 1
	while true do
		local a = string.find(s, needle, i, true)
		if a == nil then
			return n
		end
		n += 1
		i = a + 1
	end
end

describe("trend", function()
	it("plots every other number field against xField", function()
		local prep = Trend.prepare(S.json(PANEL), frames(), env)
		assert(prep, "prepared")
		expect(prep.x.name).toBe("rpm")
		expect(#prep.series).toBe(2)
	end)

	-- Palette indices skip the x field (setClassicPaletteIdxs), so power is
	-- the first palette color; fillOpacity 10 adds an area per series.
	it("draws lines with fills in palette order and the x unit range", function()
		local node, assets = Trend.view(S.json(PANEL), frames(), env, { key = "t", size = { w = 600, h = 300 } })
		local svg = (assets :: any).t.bytes
		expect(count(svg, 'class="tg-s1 tg-line"')).toBe(1)
		expect(count(svg, 'class="tg-s2 tg-line"')).toBe(1)
		expect(count(svg, "tg-area")).toBe(2)
		-- The defaults' unit applies to x too (Grafana formats the x axis with
		-- the x field's display); x spans the data's exact range from 1000.
		expect(string.find(svg, ">1000 ", 1, true) ~= nil).toBe(true)
		expect((string.find(svg, ">500 ", 1, true))).toBeNil()
		expect(S.text(S.find(node, function(n)
			return n.p and n.p.role == "tern-grafana.legend"
		end))).toBe("powertorque")
	end)

	it("defaults x to the first number field", function()
		local panel = S.json(PANEL)
		panel.options.xField = nil
		local prep = Trend.prepare(panel, frames(), env)
		assert(prep, "prepared")
		expect(prep.x.name).toBe("rpm")
	end)

	it("shows Grafana's warnings", function()
		local f = frames()
		f[1].fields[1] = Frame.field("rpm", "number", { 4000, 3500, 3000, 2500, 2000, 1500, 1000 })
		expect(S.text((Trend.view(S.json(PANEL), f, env, { key = "t" })))).toBe("Values must be in ascending order")
		local two = { frames()[1], frames()[1] }
		expect(S.text((Trend.view(S.json(PANEL), two, env, { key = "t" })))).toBe(
			"Only one frame is supported, consider adding a join transformation"
		)
		local panel = S.json(PANEL)
		panel.options.xField = "speed"
		expect(S.text((Trend.view(panel, frames(), env, { key = "t" })))).toBe("Unable to find field: speed")
	end)

	-- showPoints auto: uPlot draws points when samples sit at least twice
	-- its default point diameter apart (7 samples over 600 px are).
	it("shows points on sparse data in auto mode", function()
		local panel = S.json(PANEL)
		panel.fieldConfig.defaults.custom.showPoints = "auto"
		local _, assets = Trend.view(panel, frames(), env, { key = "t", size = { w = 600, h = 300 } })
		local svg = (assets :: any).t.bytes
		expect(count(svg, 'stroke-width="5" stroke-linecap="round"')).toBe(2)
	end)

	it("rejects per-series stacking like the time series panel", function()
		local panel = S.json(PANEL)
		panel.fieldConfig.overrides = S.json([[ [{"matcher": {"id": "byName", "options": "power"},
			"properties": [{"id": "custom.stacking", "value": {"mode": "normal", "group": "A"}}]}] ]])
		local ok, why = Trend.supports(panel, env)
		expect(ok).toBe(false)
		expect(why).toBe("per-series stacking (custom.stacking override) is not supported")
	end)
end)

return nil
