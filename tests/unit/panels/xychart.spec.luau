--!strict
-- The XY chart panel (public/app/plugins/panel/xychart utils.ts prepSeries,
-- scatter.ts prepData) on the tern-all-panels XY chart (panel 21: csv
-- load,latency_ms in auto mapping).
local Frame = require("../../../plugin/lib/frame/types")
local S = require("./support")
local Xychart = require("../../../plugin/lib/panels/xychart")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local PANEL = [[{
	"id": 21, "type": "xychart", "title": "XY chart: latency vs load",
	"options": {"mapping": "auto", "series": [{}],
		"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom", "calcs": []}},
	"fieldConfig": {"defaults": {"color": {"mode": "palette-classic"},
		"custom": {"show": "points", "pointSize": {"fixed": 6}}}, "overrides": []}
}]]

local function frames(): { Frame.Frame }
	return {
		{
			refId = "A",
			fields = {
				Frame.field("load", "number", { 10, 20, 30, 40, 50, 60, 70, 80 }),
				Frame.field("latency_ms", "number", { 42, 45, 51, 60, 74, 95, 130, 190 }),
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

describe("xychart", function()
	it("maps the first number field to x and the rest to series", function()
		local list = Xychart.series(S.json(PANEL), frames(), env)
		expect(#list).toBe(1)
		expect(list[1].x.name).toBe("load")
		expect(list[1].y.name).toBe("latency_ms")
		expect(list[1].size_fixed).toBe(6)
		expect(list[1].class).toBe("tg-s1")
		expect(list[1].show_line).toBe(false)
	end)

	it("draws 6 px points and labels the axes with the field names", function()
		local node, assets = Xychart.view(S.json(PANEL), frames(), env, { key = "x", size = { w = 600, h = 300 } })
		local svg = (assets :: any).x.bytes
		-- 6 px circles at the 50% default fill with a full-color outline.
		expect(count(svg, '<g class="tg-s1" fill-opacity="0.50"')).toBe(1)
		expect(count(svg, 'r="3.0"/>')).toBe(8)
		expect(string.find(svg, ">load<", 1, true) ~= nil).toBe(true)
		expect(string.find(svg, ">latency_ms<", 1, true) ~= nil).toBe(true)
		expect(S.text(S.find(node, function(n)
			return n.p and n.p.role == "tern-grafana.legend"
		end))).toBe("latency_ms")
	end)

	-- Manual mapping with a size field: marker area grows linearly between
	-- pointSize min and max over the size values.
	it("scales markers by a size field in manual mapping", function()
		local panel = S.json(PANEL)
		panel.options.mapping = "manual"
		panel.options.series = S.json([[ [{
			"frame": {"matcher": {"id": "byIndex", "options": 0}},
			"x": {"matcher": {"id": "byName", "options": "load"}},
			"y": {"matcher": {"id": "byName", "options": "latency_ms"}},
			"size": {"matcher": {"id": "byName", "options": "load"}}
		}] ]])
		local list = Xychart.series(panel, frames(), env)
		expect(#list).toBe(1)
		assert(list[1].size, "size field")
		local _, assets = Xychart.view(panel, frames(), env, { key = "x" })
		local svg = (assets :: any).x.bytes
		-- Diameters 10 -> 5 px, 80 -> 100 px.
		expect(string.find(svg, 'r="2.5"/>', 1, true) ~= nil).toBe(true)
		expect(string.find(svg, 'r="50.0"/>', 1, true) ~= nil).toBe(true)
	end)

	it("colors points by a color field's thresholds", function()
		local panel = S.json(PANEL)
		panel.options.series = S.json([[ [{"color": {"matcher": {"id": "byName", "options": "err"}}}] ]])
		panel.fieldConfig.overrides = S.json(
			[[ [{"matcher": {"id": "byName", "options": "err"}, "properties": [
			{"id": "color", "value": {"mode": "thresholds"}},
			{"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 5}]}}]}] ]]
		)
		local f = frames()
		table.insert(f[1].fields, Frame.field("err", "number", { 0, 0, 0, 0, 9, 9, 9, 9 }))
		local list = Xychart.series(panel, f, env)
		-- In auto mode the color field is not also a series.
		expect(#list).toBe(1)
		local _, assets = Xychart.view(panel, f, env, { key = "x" })
		local svg = (assets :: any).x.bytes
		expect(string.find(svg, '<g class="tgp-fx tgp-success"', 1, true) ~= nil).toBe(true)
		expect(string.find(svg, '<g class="tgp-fx tgp-error"', 1, true) ~= nil).toBe(true)
	end)

	-- autoNameSeries trims the words every series name shares.
	it("trims common words from series names", function()
		local f: { Frame.Frame } = {
			{
				fields = {
					Frame.field("x", "number", { 1, 2 }),
					Frame.field("cpu a load", "number", { 1, 2 }),
					Frame.field("cpu b load", "number", { 3, 4 }),
				},
			},
		}
		local list = Xychart.series(S.json(PANEL), f, env)
		expect(list[1].name).toBe("a")
		expect(list[2].name).toBe("b")
		expect(list[2].class).toBe("tg-s2")
	end)

	it("draws lines for show lines", function()
		local panel = S.json(PANEL)
		panel.fieldConfig.defaults.custom.show = "lines"
		local _, assets = Xychart.view(panel, frames(), env, { key = "x" })
		local svg = (assets :: any).x.bytes
		expect(count(svg, 'class="tg-s1 tg-line" fill="none" stroke-width="2"')).toBe(1)
		expect(count(svg, "<circle")).toBe(0)
	end)

	it("reports pre-11.3 options as unsupported", function()
		local panel = S.json([[{"type": "xychart", "options": {"seriesMapping": "auto", "dims": {"frame": 0}}}]])
		local ok, why = Xychart.supports(panel, env)
		expect(ok).toBe(false)
		expect(why).toBe("the XY chart options from before Grafana 11.3 (seriesMapping, dims) are not supported")
	end)
end)

return nil
