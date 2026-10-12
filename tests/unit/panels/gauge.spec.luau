--!strict
-- Gauge and bar gauge (public/app/plugins/panel/gauge and bargauge
-- panelcfg.cue; packages/grafana-ui Gauge/BarGauge) as Tern meters: the
-- fill is the value's percent of the field range (field/scale.ts), the
-- color its threshold step, gauge markers sit at the steps.
local t = require("../../lib/test")
local Gauge = require("../../../plugin/lib/panels/gauge")
local Registry = require("../../../plugin/lib/panels/registry")
local S = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env
local OPTS = { key = "g" }

for _, version in S.VERSIONS do
	describe("gauge on tern-panels, Grafana " .. version, function()
		-- Panel 7 "CPU utilisation": percentunit, min 0, max 1, steps green /
		-- yellow 0.7 / red 0.9, markers on. Fed the instant `up` vector.
		it("fills by percent of min..max in the step's tone", function()
			local meters = Gauge.meters(S.panel(version, 7), S.frames(version, "prom_instant"), env, OPTS, false)
			expect(#meters).toBe(6)
			expect(meters[1].value).toBe(1)
			expect(meters[1].label).toBe("100%")
			expect(meters[1].tone).toBe("error")
			-- Instance order of the capture: the `down` target is third.
			expect(meters[3].value).toBe(0)
			expect(meters[3].label).toBe("0%")
			expect(meters[3].tone).toBe("success")
		end)

		it("puts threshold markers at the steps inside the range", function()
			local meters = Gauge.meters(S.panel(version, 7), S.frames(version, "prom_instant"), env, OPTS, false)
			local marks = meters[1].marks
			assert(marks, "marks")
			expect(#marks).toBe(2)
			expect(marks[1].at).toBe(0.7)
			expect(marks[1].tone).toBe("warning")
			expect(marks[1].title).toBe("70%")
			expect(marks[2].at).toBe(0.9)
			expect(marks[2].tone).toBe("error")
			expect(meters[1].threshold_labels).toBeNil()
		end)

		it("lists threshold values with showThresholdLabels and drops markers when off", function()
			local panel = S.clone(S.panel(version, 7))
			panel.options.showThresholdLabels = true
			panel.options.showThresholdMarkers = false
			local m = Gauge.meters(panel, S.frames(version, "prom_instant"), env, OPTS, false)[1]
			expect(m.marks).toBeNil()
			expect(m.threshold_labels).toEqual({ "70%", "90%" })
		end)

		-- Without the newGauge toggle Grafana draws gauge/v1: a 270 degree
		-- arc in the value's color, markers as an outer ring.
		it("renders a v1 radial gauge per value as SVG", function()
			local node, assets = Gauge.view(S.panel(version, 7), S.frames(version, "prom_instant"), env, OPTS)
			local images = S.findAll(node, function(n)
				return n.k == "image"
			end)
			expect(#images).toBe(6)
			local svg = assets[images[1].p.asset].bytes
			expect(string.find(svg, "tgg-s-error", 1, true) ~= nil).toBe(true)
			expect(string.find(svg, ">100</text>", 1, true) ~= nil).toBe(true)
			local specs = Gauge.specs(S.panel(version, 7), S.frames(version, "prom_instant"), env, OPTS)
			expect(specs[1].style).toBe("v1")
			expect(specs[1].fill_to).toBe(1)
			expect(specs[1].text_tone).toBe("error")
			expect(specs[1].ring).toEqual({
				{ from = 0, to = 0.7, tone = "success" },
				{ from = 0.7, to = 0.9, tone = "warning" },
				{ from = 0.9, to = 1, tone = "error" },
			})
		end)
	end)

	describe("bar gauge on tern-panels, Grafana " .. version, function()
		-- Panel 8 "Up by job": gradient, horizontal, red base / green from 1.
		it("shows one bar per job in the value's tone", function()
			local meters = Gauge.meters(S.panel(version, 8), S.frames(version, "prom2_range"), env, OPTS, true)
			expect(#meters).toBe(6)
			expect(meters[1].title).toBe("alertmanager")
			expect(meters[1].label).toBe("1")
			expect(meters[1].value).toBe(1)
			expect(meters[1].tone).toBe("success")
			expect(meters[2].title).toBe("down")
			expect(meters[2].value).toBe(0)
			expect(meters[2].tone).toBe("error")
			expect(meters[1].parts).toBeNil()
			local node = Gauge.barView(S.panel(version, 8), S.frames(version, "prom2_range"), env, OPTS)
			expect(node.k).toBe("col")
			local bar = S.find(node, function(n)
				return n.k == "meter"
			end)
			expect(bar.p.style).toBe("bar")
		end)

		-- lcd colors each threshold band's cells; the band with the value
		-- takes the value's color.
		it("splits lcd bars into threshold bands", function()
			local panel = S.clone(S.panel(version, 8))
			panel.options.displayMode = "lcd"
			panel.fieldConfig.defaults.thresholds.steps = {
				{ color = "red" },
				{ color = "yellow", value = 0.5 },
				{ color = "green", value = 1 },
			}
			local m = Gauge.meters(panel, S.frames(version, "prom2_range"), env, OPTS, true)[1]
			expect(m.parts).toEqual({ { value = 0.5, token = "error" }, { value = 0.5, token = "success" } })
			local node = Gauge.barView(panel, S.frames(version, "prom2_range"), env, OPTS)
			local bar = S.find(node, function(n)
				return n.k == "meter"
			end)
			expect(bar.p.style).toBe("blocks")
		end)

		it("hides or uncolors the value per valueMode and the name per namePlacement", function()
			local panel = S.clone(S.panel(version, 8))
			panel.options.valueMode = "hidden"
			panel.options.namePlacement = "hidden"
			local m = Gauge.meters(panel, S.frames(version, "prom2_range"), env, OPTS, true)[1]
			expect(m.label).toBeNil()
			expect(m.title).toBeNil()
			panel.options.valueMode = "text"
			expect(Gauge.meters(panel, S.frames(version, "prom2_range"), env, OPTS, true)[1].label_tone).toBeNil()
		end)

		-- Panel 18 is the library panel "Tern library: up by job" (basic,
		-- vertical); the dashboard merges the model before asking.
		it("renders the resolved library panel", function()
			local ref = S.panel(version, 18)
			expect((Registry.supports(ref, env))).toBe(false)
			local panel = S.clone(S.libraryPanel(version))
			panel.id = ref.id
			panel.gridPos = ref.gridPos
			expect((Registry.supports(panel, env))).toBe(true)
			local node = Gauge.barView(panel, S.frames(version, "prom2_range"), env, OPTS)
			expect(node.k).toBe("row")
			expect(#S.findAll(node, function(n)
				return n.k == "meter"
			end)).toBe(6)
		end)
	end)
end

-- The no-query gauges of the contract (local://PANELS2.md): Grafana 12.4
-- with newGauge, fieldConfig noValue and min/max, options.neutral. The
-- placeholder value is numeric 0 with the noValue text
-- (createNoValuesFieldDisplay); the neutral value draws the bar 0..neutral
-- and the threshold gradient paints it.
local NO_QUERY = [[{
	"type": "gauge", "title": "No query", "pluginVersion": "12.4.0",
	"fieldConfig": {"defaults": {"color": {"mode": "thresholds"}, "decimals": 0, "min": 0, "max": 20,
		"noValue": "6", "thresholds": {"mode": "absolute", "steps": [
			{"color": "green", "value": null}, {"color": "#EAB839", "value": 1}, {"color": "red", "value": 1}]}},
		"overrides": []},
	"options": {"shape": "gauge", "neutral": 6, "barWidthFactor": 0.5, "barShape": "flat", "segmentCount": 1,
		"segmentSpacing": 0.3, "endpointMarker": "point", "effects": {"gradient": true}, "sparkline": true,
		"showThresholdMarkers": true, "showThresholdLabels": false, "textMode": "auto", "text": {},
		"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": true}}
}]]

local V2 = { key = "g", features = { newGauge = true }, size = { w = 600, h = 300 } }

describe("gauge without data (Grafana 12.4 newGauge)", function()
	it("shows the noValue text and draws the bar from 0 to the neutral value in the gradient's bands", function()
		local specs = Gauge.specs(S.json(NO_QUERY), {}, env, V2)
		expect(#specs).toBe(1)
		local g = specs[1]
		expect(g.style).toBe("gauge")
		expect(g.text).toBe("6")
		expect(g.fill_from).toBe(0)
		expect(g.fill_to).toBe(0.3)
		expect(g.bands).toEqual({ { from = 0, to = 0.05, tone = "success" }, { from = 0.05, to = 1, tone = "error" } })
		expect(g.ring).toEqual(g.bands)
		local node, assets = Gauge.view(S.json(NO_QUERY), {}, env, V2)
		local img = S.find(node, function(n)
			return n.k == "image"
		end)
		local svg = assets[img.p.asset].bytes
		-- The red run covers the bar from 1 to 6 of 0..20.
		expect(string.find(svg, 'class="tgg-s-error"', 1, true) ~= nil).toBe(true)
		expect(string.find(svg, ">6</text>", 1, true) ~= nil).toBe(true)
	end)

	it("clamps the neutral value to max: noValue 0 on 0..1 fills the whole arc", function()
		local panel = S.json(NO_QUERY)
		panel.fieldConfig.defaults.noValue = "0"
		panel.fieldConfig.defaults.max = 1
		panel.fieldConfig.defaults.thresholds.steps = { { color = "green", value = S.json("null") } }
		local g = Gauge.specs(panel, {}, env, V2)[1]
		expect(g.text).toBe("0")
		expect(g.fill_from).toBe(0)
		expect(g.fill_to).toBe(1)
		expect(g.bands).toEqual({ { from = 0, to = 1, tone = "success" } })
	end)

	it("is No data without a noValue (PanelDataErrorView)", function()
		local panel = S.json(NO_QUERY)
		panel.fieldConfig.defaults.noValue = nil
		local node, assets = Gauge.view(panel, {}, env, V2)
		expect(S.text(node)).toBe("No data")
		expect((next(assets))).toBeNil()
	end)

	it("migrates a gauge saved by the old gauge: no gradient, no sparkline", function()
		local panel = S.json(NO_QUERY)
		panel.options.shape = nil
		panel.pluginVersion = "11.6.0"
		local look = Gauge.look(panel, env, true)
		expect(look.gradient).toBe(false)
		expect(look.sparkline).toBe(false)
		expect(look.markers).toBe(true)
		local g = Gauge.specs(panel, {}, env, V2)[1]
		-- Without the gradient the bar is the value's color: the base step.
		expect(g.bands).toEqual({ { from = 0, to = 1, tone = "success" } })
	end)

	it("segments the bar and colors each filled segment by its own value", function()
		local panel = S.json(NO_QUERY)
		panel.options.segmentCount = 4
		-- The placeholder has no display processor: Grafana's fallback gray.
		local g = Gauge.specs(panel, {}, env, V2)[1]
		expect(g.segments).toBe(4)
		expect((g.segment_tone :: (number) -> string)(0.25)).toBe("neutral")
		-- A real value colors each segment by the step its start value is in.
		local frame = {
			fields = { { name = "v", type = "number", values = { 3 }, config = {} } },
		}
		local real = Gauge.specs(panel, { frame :: any }, env, V2)[1]
		local tone = real.segment_tone :: (number) -> string
		expect(tone(0)).toBe("success")
		expect(tone(0.25)).toBe("error")
	end)
end)

return nil
