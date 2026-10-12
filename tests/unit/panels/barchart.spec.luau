--!strict
-- The bar chart panel (public/app/plugins/panel/barchart utils.ts
-- prepSeries/prepConfig, bars.ts, BarChartPanel.tsx) on the tern-all-panels
-- bar chart (panel 18: TestData csv_content, stacked).
local Barchart = require("../../../plugin/lib/panels/barchart")
local Frame = require("../../../plugin/lib/frame/types")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

-- Panel 18 as provisioned in dev/grafana/dashboards/tern-all-panels.json.
local PANEL = [[{
	"id": 18, "type": "barchart", "title": "Bar chart: status codes by service",
	"options": {
		"orientation": "auto", "xField": "service", "stacking": "normal", "groupWidth": 0.7, "barWidth": 0.9,
		"showValue": "auto", "xTickLabelRotation": 0,
		"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom", "calcs": []}
	},
	"fieldConfig": {"defaults": {"color": {"mode": "palette-classic"},
		"custom": {"fillOpacity": 80, "lineWidth": 1, "gradientMode": "none"}}, "overrides": []}
}]]

-- TestData csv_content "service,2xx,4xx,5xx".
local function frames(): { Frame.Frame }
	return {
		{
			refId = "A",
			fields = {
				Frame.field("service", "string", { "checkout", "payments", "frontend", "search" }),
				Frame.field("2xx", "number", { 120, 45, 310, 75 }),
				Frame.field("4xx", "number", { 8, 3, 21, 0 }),
				Frame.field("5xx", "number", { 2, 6, 1, 0 }),
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

local WIDE = { key = "p", size = { w = 600, h = 300 } }

describe("barchart", function()
	it("takes xField as the categories and every other number field as a series", function()
		local prep = Barchart.prepare(S.json(PANEL), frames(), env)
		assert(prep, "prepared")
		expect(prep.x.name).toBe("service")
		expect(#prep.series).toBe(3)
		expect(prep.series[3].name).toBe("5xx")
	end)

	-- Stacking swaps groupWidth and barWidth (bars.ts getConfig), and auto
	-- orientation goes horizontal only when the panel is taller than wide.
	it("maps stacking, widths and orientation like Grafana", function()
		local prep = Barchart.prepare(S.json(PANEL), frames(), env)
		assert(prep, "prepared")
		local o = Barchart.renderOptions(S.json(PANEL), prep, env, WIDE)
		expect(o.stacking).toBe("normal")
		expect(o.group_width).toBe(0.9)
		expect(o.bar_width).toBe(0.7)
		expect(o.horizontal).toBe(false)
		expect(o.fill_opacity).toBe(0.8)
		local tall = Barchart.renderOptions(S.json(PANEL), prep, env, { key = "p", size = { w = 200, h = 400 } })
		expect(tall.horizontal).toBe(true)
	end)

	-- A lone series with nothing hidden uses barWidth as its group width
	-- and fills it ("Use bar width when only one field").
	it("widens a single series to barWidth", function()
		local panel = S.json(PANEL)
		panel.options.stacking = "none"
		local f = frames()
		f[1].fields = { f[1].fields[1], f[1].fields[2] }
		local prep = Barchart.prepare(panel, f, env)
		assert(prep, "prepared")
		local o = Barchart.renderOptions(panel, prep, env, WIDE)
		expect(o.group_width).toBe(0.9)
		expect(o.bar_width).toBe(1)
	end)

	it("draws one palette path per series with category labels and a legend", function()
		local node, assets = Barchart.view(S.json(PANEL), frames(), env, WIDE)
		local svg = (assets :: any).p.bytes
		expect(count(svg, 'class="tg-s1 tg-bar"')).toBe(1)
		expect(count(svg, 'class="tg-s3 tg-bar"')).toBe(1)
		-- fillOpacity 80 leaves a full-color outline at lineWidth 1.
		expect(count(svg, "tg-line")).toBe(3)
		expect(string.find(svg, ">frontend<", 1, true) ~= nil).toBe(true)
		expect(#svg <= 262144).toBe(true)
		local legend = S.text(S.find(node, function(n)
			return n.p and n.p.role == "tern-grafana.legend"
		end))
		expect(legend).toBe("2xx4xx5xx")
	end)

	-- Percent stacking: the value axis is 0..100% and labels are each
	-- value's share of its category.
	it("stacks to percent with share labels", function()
		local panel = S.json(PANEL)
		panel.options.stacking = "percent"
		panel.options.showValue = "always"
		local _, assets = Barchart.view(panel, frames(), env, WIDE)
		local svg = (assets :: any).p.bytes
		expect(string.find(svg, ">100%<", 1, true) ~= nil).toBe(true)
		-- frontend: 310 of 332.
		expect(string.find(svg, ">93.4%<", 1, true) ~= nil).toBe(true)
	end)

	it("colors bars by the colorByField values", function()
		local panel = S.json(PANEL)
		panel.options.colorByField = "level"
		panel.fieldConfig.overrides = S.json(
			[[ [{"matcher": {"id": "byName", "options": "level"},
			"properties": [{"id": "color", "value": {"mode": "thresholds"}},
			{"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 1}]}}]}] ]]
		)
		local f = frames()
		f[1].fields = { f[1].fields[1], f[1].fields[2], Frame.field("level", "number", { 0, 1, 0, 1 }) }
		local prep = Barchart.prepare(panel, f, env)
		assert(prep, "prepared")
		local o = Barchart.renderOptions(panel, prep, env, WIDE)
		local classes = o.series[1].classes
		assert(classes, "per bar classes")
		expect(classes[1]).toBe("tgp-fx tgp-success")
		expect(classes[2]).toBe("tgp-fx tgp-error")
	end)

	it("reports Grafana's warnings in place of the chart", function()
		local f: { Frame.Frame } = { { fields = { Frame.field("n", "number", { 1, 2 }) } } }
		local node = Barchart.view(S.json(PANEL), f, env, WIDE)
		expect(S.text(node)).toBe("Bar charts require a string or time field")
		local g: { Frame.Frame } = { { fields = { Frame.field("s", "string", { "a" }) } } }
		local panel = S.json(PANEL)
		panel.options.xField = nil
		expect(S.text((Barchart.view(panel, g, env, WIDE)))).toBe("No numeric fields found")
	end)

	-- Several time frames join on time; display names stay per frame.
	it("joins time frames before charting", function()
		local panel = S.json(PANEL)
		panel.options.xField = nil
		local f: { Frame.Frame } = {
			{
				name = "A",
				fields = { Frame.field("Time", "time", { 1000, 2000 }), Frame.field("Value", "number", { 1, 2 }) },
			},
			{
				name = "B",
				fields = { Frame.field("Time", "time", { 2000, 3000 }), Frame.field("Value", "number", { 5, 6 }) },
			},
		}
		local prep = Barchart.prepare(panel, f, env)
		assert(prep, "prepared")
		expect(#prep.x.field.values).toBe(3)
		expect(prep.series[1].name).toBe("A")
		expect(prep.series[2].name).toBe("B")
		expect(Frame.isNull(prep.series[2].field.values[1])).toBe(true)
	end)

	it("keeps a very wide category set under the SVG cap", function()
		local names, values = {}, {}
		for i = 1, 20000 do
			names[i] = "category-" .. i
			values[i] = i
		end
		local f: { Frame.Frame } = {
			{ fields = { Frame.field("c", "string", names), Frame.field("v", "number", values) } },
		}
		local panel = S.json(PANEL)
		panel.options.xField = nil
		local node, assets = Barchart.view(panel, f, env, WIDE)
		expect(#(assets :: any).p.bytes <= 262144).toBe(true)
		expect(string.find(S.text(node), "more categories not shown", 1, true) ~= nil).toBe(true)
	end)
end)

return nil
