--!strict
-- Panels linked to Grafana-managed rules must show the state Grafana's panel
-- header shows (a red broken heart while firing), and time series must draw
-- the dashboard's annotation layers (alert state history included) where
-- Grafana draws them, or a firing panel looks healthy in Tern.
local AlertStates = require("../../../plugin/lib/dashboard/alert_states")
local Annotations = require("../../../plugin/lib/dashboard/annotations")
local SvgAnnotations = require("../../../plugin/lib/render/svg_annotations")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env()

-- Typed references only: string references resolve through the dashboard's
-- datasources (lib/dashboard/layers, specs in annotation_layers.spec).
local function typeOf(raw: any): string?
	return if type(raw) == "table" then raw.type else nil
end

local function builtIn(): Annotations.Def
	return Annotations.defs({ Annotations.BUILT_IN }, env, {}, typeOf)[1]
end

describe("alert states (AlertStatesDataLayer)", function()
	for _, version in S.VERSIONS do
		-- TernGrafanaAlwaysFiring is linked to tern-panels panel 2 (rules.yml).
		it("reads the firing rule linked to panel 2 on Grafana " .. version, function()
			local states = assert(AlertStates.parse(S.response(S.grafana(version, "alerting_prom_rules.json")), env))
			expect(states[2]).toBe("alerting")
			expect((AlertStates.icon(states[2] :: string))).toBe(AlertStates.HEART_BREAK)
		end)
	end

	it("keeps the most severe state per panel; inactive is ok with a green heart", function()
		local body = [[{"status":"success","data":{"groups":[{"rules":[
			{"type":"alerting","state":"inactive","annotations":{"__panelId__":"2"}},
			{"type":"alerting","state":"pending","annotations":{"__panelId__":"2"}},
			{"type":"alerting","state":"inactive","annotations":{"__panelId__":"4"}},
			{"type":"recording","state":"firing","annotations":{"__panelId__":"4"}},
			{"type":"alerting","state":"firing","annotations":{"__panelId__":""}}]}]}}]]
		local states = assert(AlertStates.parse(S.body(200, body), env))
		expect(states[2]).toBe("pending")
		expect(states[4]).toBe("ok")
		local glyph, style = AlertStates.icon("ok")
		expect(glyph).toBe(AlertStates.HEART)
		expect(style).toBe("icon success")
	end)

	it("applies only while the range ends now", function()
		expect(AlertStates.applies("now")).toBe(true)
		expect(AlertStates.applies("now-1h")).toBe(false)
	end)

	it("shows nothing after a failed request", function()
		expect((AlertStates.parse(S.body(403, '{"message":"forbidden"}'), env))).toBe(nil)
	end)
end)

describe("annotation layers", function()
	it("adds Grafana's built-in layer and runs only enabled Grafana and Prometheus layers", function()
		local defs = Annotations.defs({
			{ name = "off", enable = false, datasource = { type = "prometheus", uid = "p" }, expr = "up" },
			{
				name = "Firing",
				enable = true,
				iconColor = "red",
				datasource = { type = "prometheus", uid = "p" },
				expr = "ALERTS",
				step = "60s",
			},
			{ name = "Loki", enable = true, datasource = { type = "loki", uid = "l" } },
		}, env, {}, typeOf)
		expect(#defs).toBe(2)
		expect(defs[1].name).toBe("Annotations & Alerts")
		expect(defs[2].kind).toBe("prometheus")
		expect((defs[2].panel :: any).targets[1].interval).toBe("60s")
	end)

	-- Grafana 13 alert state history: the dev firing rule's transition and a
	-- seeded deploy annotation, both on tern-panels panel 2.
	it("colors alert state changes by their new state, other annotations by iconColor", function()
		local events =
			assert(Annotations.parse(builtIn(), S.response(S.grafana("13.3.1", "annotations_dashboard.json")), env))
		local colors: { [string]: boolean } = {}
		for _, e in events do
			colors[e.color] = true
			expect(e.panel_id).toBe(2)
		end
		expect(colors.red).toBe(true)
		expect(colors[SvgAnnotations.DEFAULT_COLOR]).toBe(true)
	end)

	-- Grafana Cloud's state history (timeEnd null; Pending, Normal,
	-- Recovering, "Normal (NoData)") as the user's linked panel gets it.
	it("draws state history without an end as points; unmatched states keep iconColor", function()
		local body = [=[[
			{"panelId":2,"newState":"Pending","time":1000,"timeEnd":null},
			{"panelId":2,"newState":"Normal","time":2000,"timeEnd":null},
			{"panelId":2,"newState":"Recovering","time":3000,"timeEnd":null},
			{"panelId":2,"newState":"Normal (NoData)","time":4000,"timeEnd":null},
			{"panelId":0,"time":5000,"timeEnd":6000}]]=]
		local events = assert(Annotations.parse(builtIn(), S.body(200, body), env))
		expect(events[1].color).toBe("yellow")
		expect(events[2].color).toBe("green")
		expect(events[3].color).toBe(SvgAnnotations.DEFAULT_COLOR)
		expect(events[4].color).toBe(SvgAnnotations.DEFAULT_COLOR)
		expect(events[1].end_ms).toBe(nil)
		expect(events[5].end_ms).toBe(6000)
		local layers = { { def = builtIn(), events = events } }
		expect(#Annotations.marks(layers, 2)).toBe(5)
		-- Panel 0 shows everywhere; the others only on panel 2.
		expect(#Annotations.marks(layers, 3)).toBe(1)
	end)

	-- Grafana 12 and 13 answer null for a dashboard-wide annotation: once
	-- another annotation has a panel id, it shows on no panel (render checked).
	it("hides a dashboard-wide annotation without a panel id next to panel annotations", function()
		local events = assert(
			Annotations.parse(
				builtIn(),
				S.body(200, '[{"panelId":3,"time":1000},{"panelId":null,"time":2000,"timeEnd":3000}]'),
				env
			)
		)
		local layers = { { def = builtIn(), events = events } }
		expect(#Annotations.marks(layers, 1)).toBe(0)
		local alone = assert(Annotations.parse(builtIn(), S.body(200, '[{"panelId":null,"time":2000}]'), env))
		expect(#Annotations.marks({ { def = builtIn(), events = alone } }, 1)).toBe(1)
	end)

	it("applies a layer's panel filter", function()
		local def = Annotations.defs({
			Annotations.BUILT_IN,
			{
				name = "f",
				enable = true,
				datasource = { type = "prometheus", uid = "p" },
				expr = "x",
				filter = { exclude = true, ids = { 1 } },
			},
		}, env, {}, typeOf)[2]
		local layers = { { def = def, events = { { time_ms = 1, color = "red" } } } }
		expect(#Annotations.marks(layers, 1)).toBe(0)
		expect(#Annotations.marks(layers, 2)).toBe(1)
	end)

	-- processEvents: samples above 0 at most one step apart are one region.
	it("merges Prometheus samples into regions by the executed step", function()
		local def = Annotations.defs({
			{
				name = "p",
				enable = true,
				iconColor = "red",
				datasource = { type = "prometheus", uid = "p" },
				expr = "x",
			},
		}, env, {}, typeOf)[1]
		local frame: any = {
			meta = { executedQueryString = "Expr: x\nStep: 1m0s" },
			fields = {
				{ name = "Time", type = "time", values = { 0, 60000, 120000, 300000, 600000 } },
				{ name = "Value", type = "number", values = { 1, 1, 1, 0, 1 } },
			},
		}
		local events = Annotations.promEvents(def, { frame })
		expect(#events).toBe(2)
		expect(events[1].time_ms).toBe(0)
		expect(events[1].end_ms).toBe(120000)
		expect(events[2].end_ms).toBe(nil)
		expect(Annotations.stepMs("Step: 1h0m0s")).toBe(3600000)
		expect(Annotations.stepMs(nil)).toBe(60000)
	end)
end)

describe("svg annotations", function()
	local box = { t_from = 0, t_to = 1000, left = 0, right = 100, top = 0, bottom = 50, scale = 1 }

	it("draws dashed lines, a region fill and markers under the plot", function()
		local out: { string } = {}
		SvgAnnotations.draw(
			out,
			SvgAnnotations.layer({
				{ time_ms = 500, color = "red", lane = 0 },
				{ time_ms = 100, end_ms = 300, color = "rgba(0, 211, 255, 1)", lane = 0 },
				{ time_ms = 2000, color = "red", lane = 0 },
			}, nil),
			box
		)
		local svg = table.concat(out)
		expect(string.find(svg, 'stroke-dasharray="5 5"', 1, true) ~= nil).toBe(true)
		expect(
			string.find(
				svg,
				'class="tg-anno tg-area" x="10.0" y="0.0" width="20.0" height="50.0" fill-opacity="0.1"',
				1,
				true
			) ~= nil
		).toBe(true)
		-- The out-of-range point draws neither a line nor a marker.
		expect((string.find(svg, "M200", 1, true))).toBe(nil)
		expect(string.find(svg, 'd="M50.0 50.0l5.0 5.0h-10.0Z"', 1, true) ~= nil).toBe(true)
	end)

	it("draws only markers when regions are switched off", function()
		local out: { string } = {}
		SvgAnnotations.draw(
			out,
			SvgAnnotations.layer({ { time_ms = 500, color = "red", lane = 0 } }, { regions = { opacity = 0 } }),
			box
		)
		local svg = table.concat(out)
		expect((string.find(svg, "stroke-dasharray", 1, true))).toBe(nil)
		expect(string.find(svg, "l5.0 5.0", 1, true) ~= nil).toBe(true)
	end)
end)

return nil
