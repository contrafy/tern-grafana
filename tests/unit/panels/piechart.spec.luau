--!strict
-- The pie chart panel (public/app/plugins/panel/piechart PieChartPanel.tsx,
-- PieChart.tsx, fieldDisplay.ts setIndexForPaletteColor) on the
-- tern-all-panels pie (panel 17: TestData csv_content).
local Frame = require("../../../plugin/lib/frame/types")
local Piechart = require("../../../plugin/lib/panels/piechart")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

-- Panel 17 as provisioned in dev/grafana/dashboards/tern-all-panels.json.
local PANEL = [[{
	"id": 17, "type": "piechart", "title": "Pie chart: requests by service",
	"options": {
		"pieType": "donut", "displayLabels": ["percent"],
		"legend": {"showLegend": true, "displayMode": "table", "placement": "right", "values": ["value", "percent"]},
		"reduceOptions": {"values": true, "calcs": ["lastNotNull"], "fields": ""}
	},
	"fieldConfig": {"defaults": {"unit": "reqps", "color": {"mode": "palette-classic"}}, "overrides": []}
}]]

-- TestData csv_content "service,requests": a string and a number field.
local function frames(): { Frame.Frame }
	return {
		{
			refId = "A",
			fields = {
				Frame.field("service", "string", { "checkout", "payments", "frontend", "search" }),
				Frame.field("requests", "number", { 120, 45, 310, 75 }),
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

describe("piechart", function()
	-- All values: one slice per row named by the row's string field, each
	-- row the next palette color, then sorted descending (the default).
	it("slices every row with its own palette color, largest first", function()
		local entries = Piechart.entries(S.json(PANEL), frames(), env, { key = "p" })
		expect(#entries).toBe(4)
		expect(entries[1].name).toBe("frontend")
		expect(entries[1].class).toBe("tg-s3")
		expect(entries[2].name).toBe("checkout")
		expect(entries[2].class).toBe("tg-s1")
		expect(entries[4].name).toBe("payments")
		expect(entries[4].class).toBe("tg-s2")
	end)

	it("keeps the data order with sort none", function()
		local panel = S.json(PANEL)
		panel.options.sort = "none"
		local entries = Piechart.entries(panel, frames(), env, { key = "p" })
		expect(entries[1].name).toBe("checkout")
		expect(entries[3].name).toBe("frontend")
	end)

	-- displayLabels percent: share of the total at the field's decimals (0).
	it("draws a donut with percent labels and a value/percent legend table", function()
		local node, assets = Piechart.view(S.json(PANEL), frames(), env, { key = "p", size = { w = 480, h = 300 } })
		local svg = (assets :: any).p.bytes
		expect(count(svg, "tg-bar")).toBe(4)
		-- A donut slice closes along its inner arc: two arcs per slice.
		expect(count(svg, "A")).toBe(8)
		expect(string.find(svg, ">56%<", 1, true) ~= nil).toBe(true)
		expect(string.find(svg, ">8%<", 1, true) ~= nil).toBe(true)
		expect(#svg <= 262144).toBe(true)
		local legend = S.text(S.find(node, function(n)
			return n.p and n.p.role == "tern-grafana.legend"
		end))
		expect(string.find(legend, "frontend", 1, true) ~= nil).toBe(true)
		expect(string.find(legend, "310 req/s", 1, true) ~= nil).toBe(true)
		expect(string.find(legend, "56%", 1, true) ~= nil).toBe(true)
		-- placement right: chart and legend side by side.
		expect(S.find(node, function(n)
			return n.k == "row" and n.p and n.p.key == "p.body"
		end) ~= nil).toBe(true)
	end)

	-- Reduced mode: one slice per number field, palette by field.
	it("reduces each field with the panel's calcs when values is off", function()
		local panel = S.json(PANEL)
		panel.options.reduceOptions.values = false
		panel.options.reduceOptions.calcs = { "sum" }
		local f: { Frame.Frame } = {
			{
				fields = {
					Frame.field("Time", "time", { 1, 2 }),
					Frame.field("a", "number", { 1, 2 }),
					Frame.field("b", "number", { 10, 20 }),
				},
			},
		}
		local entries = Piechart.entries(panel, f, env, { key = "p" })
		expect(#entries).toBe(2)
		expect(entries[1].name).toBe("b")
		expect(entries[1].value).toBe(30)
		expect(entries[2].value).toBe(3)
	end)

	it("hides legend rows marked hideFrom.legend and keeps their slices", function()
		local panel = S.json(PANEL)
		panel.options.reduceOptions.values = false
		panel.fieldConfig.overrides = S.json([[ [{"matcher": {"id": "byName", "options": "requests"},
			"properties": [{"id": "custom.hideFrom", "value": {"legend": true, "viz": false, "tooltip": false}}]}] ]])
		local node, assets = Piechart.view(panel, frames(), env, { key = "p" })
		expect(count((assets :: any).p.bytes, "tg-bar")).toBe(1)
		local legend = S.find(node, function(n)
			return n.p and n.p.role == "tern-grafana.legend"
		end)
		expect((string.find(S.text(legend), "requests", 1, true))).toBeNil()
	end)

	-- PanelDataErrorView: the defaults' noValue, else "No data".
	it("shows the noValue text without data", function()
		local panel = S.json(PANEL)
		panel.fieldConfig.defaults.noValue = "nothing yet"
		local node = Piechart.view(panel, {}, env, { key = "p" })
		expect(S.text(node)).toBe("nothing yet")
	end)

	it("supports only computable reducers", function()
		local panel = S.json(PANEL)
		panel.options.reduceOptions.values = false
		panel.options.reduceOptions.calcs = { "nope" }
		local ok, why = Piechart.supports(panel, env)
		expect(ok).toBe(false)
		expect(why).toBe("reducer nope is not supported")
	end)
end)

return nil
