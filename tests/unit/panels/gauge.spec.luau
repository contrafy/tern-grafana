--!strict
-- Gauge and bar gauge (public/app/plugins/panel/gauge and bargauge
-- panelcfg.cue; packages/grafana-ui Gauge/RadialGauge/BarGauge) as SVGs:
-- the fill is the value's percent of the field range (field/scale.ts),
-- painted in the exact color Grafana resolves (each threshold step's own
-- color, a fixed color per row), the gauge's threshold ring shows every
-- step's color.
local t = require("../../lib/test")
local Gauge = require("../../../plugin/lib/panels/gauge")
local Registry = require("../../../plugin/lib/panels/registry")
local SvgBarGauge = require("../../../plugin/lib/render/svg_bargauge")
local Thresholds = require("../../../plugin/lib/units/thresholds")
local TsGradient = require("../../../plugin/lib/render/ts_gradient")
local S = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env
local OPTS = { key = "g" }

local function class(name: string): string
	return TsGradient.stopClass(Thresholds.color(name))
end

local function has(s: string, part: string): boolean
	return string.find(s, part, 1, true) ~= nil
end

-- Instance order of each prom_instant capture: the first gauge reading 1
-- (up) and the `down` target.
local UP = { ["11.6.16"] = 1, ["12.4.12"] = 1, ["13.3.0"] = 2 }
local DOWN = { ["11.6.16"] = 3, ["12.4.12"] = 3, ["13.3.0"] = 1 }

for _, version in S.VERSIONS do
	describe("gauge on tern-panels, Grafana " .. version, function()
		-- Panel 7 "CPU utilisation": percentunit, min 0, max 1, steps green /
		-- yellow 0.7 / red 0.9, markers on. Fed the instant `up` vector.
		it("fills by percent of min..max in the value's step color", function()
			local specs = Gauge.specs(S.panel(version, 7), S.frames(version, "prom_instant"), env, OPTS)
			expect(#specs).toBe(6)
			local up, down = specs[UP[version]], specs[DOWN[version]]
			expect(up.fill_to).toBe(1)
			expect((up.text or "") .. (up.suffix or "")).toBe("100%")
			expect(up.text_class).toBe(class("red"))
			expect(down.fill_to).toBe(0)
			expect(down.text_class).toBe(class("green"))
		end)

		-- Without the newGauge toggle Grafana draws gauge/v1: a 270 degree
		-- arc in the value's color, markers as an outer ring.
		it("renders a v1 radial gauge per value with a ring of the steps' colors", function()
			local node, assets = Gauge.view(S.panel(version, 7), S.frames(version, "prom_instant"), env, OPTS)
			local images = S.findAll(node, function(n)
				return n.k == "image"
			end)
			expect(#images).toBe(6)
			local svg = assets[images[UP[version]].p.asset].bytes
			expect(has(svg, 'class="' .. class("red") .. ' tg-line"')).toBe(true)
			expect(has(svg, ">100</text>")).toBe(true)
			local specs = Gauge.specs(S.panel(version, 7), S.frames(version, "prom_instant"), env, OPTS)
			expect(specs[UP[version]].style).toBe("v1")
			expect(specs[UP[version]].ring).toEqual({
				{ from = 0, to = 0.7, class = class("green") },
				{ from = 0.7, to = 0.9, class = class("yellow") },
				{ from = 0.9, to = 1, class = class("red") },
			})
		end)

		it("labels min, the steps and max with showThresholdLabels and drops the ring when off", function()
			local panel = S.clone(S.panel(version, 7))
			panel.options.showThresholdLabels = true
			panel.options.showThresholdMarkers = false
			local g = Gauge.specs(panel, S.frames(version, "prom_instant"), env, OPTS)[1]
			expect(g.ring).toBeNil()
			local texts: { string } = {}
			for _, l in (g.labels or {}) :: { any } do
				table.insert(texts, l.text)
			end
			expect(texts).toEqual({ "0%", "70%", "90%", "100%" })
		end)
	end)

	describe("bar gauge on tern-panels, Grafana " .. version, function()
		-- Panel 8 "Up by job": gradient, horizontal, red base / green from 1.
		it("draws one bar per job in its step's color, the gradient blending in the reached steps", function()
			local bars, o = Gauge.barSpecs(S.panel(version, 8), S.frames(version, "prom2_range"), env, OPTS, 480, 200)
			expect(#bars).toBe(6)
			expect(o.vertical).toBe(false)
			expect(bars[1].title).toBe("alertmanager")
			expect(bars[1].text).toBe("1")
			expect(bars[1].fill).toBe(1)
			expect(bars[1].class).toBe(class("green"))
			-- getBarGradient: red, red halfway to the green step, green at the
			-- value.
			expect(bars[1].gradient).toEqual({
				{ at = 0, class = class("red") },
				{ at = 0.5, class = class("red") },
				{ at = 1, class = class("green") },
			})
			expect(bars[2].title).toBe("down")
			expect(bars[2].fill).toBe(0)
			expect(bars[2].class).toBe(class("red"))
			local node, assets = Gauge.barView(S.panel(version, 8), S.frames(version, "prom2_range"), env, OPTS)
			expect(node.k).toBe("image")
			local svg = (assets :: any).g.bytes
			expect(has(svg, "<linearGradient")).toBe(true)
			expect(has(svg, ">alertmanager</text>")).toBe(true)
		end)

		-- lcd lights each cell up to the value in the color of the cell's own
		-- value.
		it("colors lcd cells by their own value", function()
			local panel = S.clone(S.panel(version, 8))
			panel.options.displayMode = "lcd"
			panel.fieldConfig.defaults.thresholds.steps = {
				{ color = "red" },
				{ color = "yellow", value = 0.5 },
				{ color = "green", value = 1 },
			}
			local bars = Gauge.barSpecs(panel, S.frames(version, "prom2_range"), env, OPTS, 480, 200)
			local cell = bars[1].cell_class :: (number) -> string
			expect(cell(0)).toBe(class("red"))
			expect(cell(0.5)).toBe(class("yellow"))
			expect(cell(1)).toBe(class("green"))
		end)

		it("hides or uncolors the value per valueMode and the name per namePlacement", function()
			local panel = S.clone(S.panel(version, 8))
			panel.options.valueMode = "hidden"
			panel.options.namePlacement = "hidden"
			local bars, o = Gauge.barSpecs(panel, S.frames(version, "prom2_range"), env, OPTS, 480, 200)
			local svg = SvgBarGauge.render(bars, o)
			expect(has(svg, ">alertmanager</text>")).toBe(false)
			expect(has(svg, ">1</text>")).toBe(false)
			panel.options.valueMode = "text"
			panel.options.namePlacement = "auto"
			bars, o = Gauge.barSpecs(panel, S.frames(version, "prom2_range"), env, OPTS, 480, 200)
			expect(has(SvgBarGauge.render(bars, o), 'class="tgg-text" x')).toBe(true)
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
			local bars, o = Gauge.barSpecs(panel, S.frames(version, "prom2_range"), env, OPTS, 480, 200)
			expect(o.vertical).toBe(true)
			expect(o.mode).toBe("basic")
			expect(#bars).toBe(6)
		end)
	end)
end

-- The user's "Case Priority" pattern: basic bars, one fixed color per row
-- by name override. Grafana paints each bar in its row's color at 35% with
-- a solid edge and the value large in that color.
local CASES = [[{
	"type": "bargauge", "title": "Case Priority",
	"options": {"displayMode": "basic", "orientation": "horizontal", "valueMode": "color", "namePlacement": "auto",
		"showUnfilled": true, "sizing": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}},
	"fieldConfig": {"defaults": {"color": {"mode": "thresholds"},
		"thresholds": {"mode": "percentage", "steps": [{"color": "green", "value": 0}]}},
		"overrides": [
			{"matcher": {"id": "byName", "options": "Priority 1"}, "properties": [{"id": "color", "value": {"fixedColor": "#e32626", "mode": "fixed"}}]},
			{"matcher": {"id": "byName", "options": "Priority 2"}, "properties": [{"id": "color", "value": {"fixedColor": "#8741f0", "mode": "fixed"}}]}
		]}
}]]

describe("bar gauge with fixed colors per row", function()
	it("paints each bar and its value in the row's own color", function()
		local frame = {
			fields = {
				{ name = "Priority 1", type = "number", values = { 3 }, config = {} },
				{ name = "Priority 2", type = "number", values = { 201 }, config = {} },
			},
		}
		local panel = S.json(CASES)
		local bars, o = Gauge.barSpecs(panel, { frame :: any }, env, OPTS, 1000, 268)
		expect(bars[1].class).toBe(TsGradient.fixedClass("#e32626"))
		expect(bars[2].class).toBe(TsGradient.fixedClass("#8741f0"))
		expect(bars[1].class ~= bars[2].class).toBe(true)
		local svg = SvgBarGauge.render(bars, o)
		expect(has(svg, 'class="' .. bars[2].class .. ' tg-bar"')).toBe(true)
		expect(has(svg, 'fill-opacity="0.35"')).toBe(true)
		-- Two bars fill the panel: thick bars, the value far above 14 px.
		local size =
			tonumber(string.match(svg, 'font%-size="([%d.]+)" text%-anchor="end" dominant%-baseline="central">201<'))
		expect(size ~= nil and (size :: number) > 40).toBe(true)
	end)
end)

-- The user's weather gauges: thresholds super-light-purple, super-light-blue,
-- blue, green, semi-dark-green, dark-yellow, semi-dark-orange, light-red,
-- red, semi-dark-red over 0..130. Grafana's ring shows every step's color.
local WEATHER = [[{
	"type": "gauge", "title": "Houston, TX", "pluginVersion": "13.1.0",
	"options": {"shape": "gauge", "showThresholdMarkers": true, "showThresholdLabels": false, "sparkline": false,
		"effects": {"gradient": false}, "barWidthFactor": 0.5, "textMode": "auto",
		"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}},
	"fieldConfig": {"defaults": {"color": {"mode": "thresholds"}, "min": 0, "max": 130, "unit": "fahrenheit",
		"thresholds": {"mode": "absolute", "steps": [
			{"color": "green", "value": 0}, {"color": "super-light-purple", "value": 0},
			{"color": "super-light-blue", "value": 32}, {"color": "blue", "value": 50},
			{"color": "green", "value": 60}, {"color": "semi-dark-green", "value": 70},
			{"color": "dark-yellow", "value": 80}, {"color": "semi-dark-orange", "value": 90},
			{"color": "light-red", "value": 100}, {"color": "red", "value": 110},
			{"color": "semi-dark-red", "value": 120}]}}, "overrides": []}
}]]

describe("gauge threshold ring", function()
	it("shows every step's own color around the arc and colors the value by its step", function()
		local frame = { fields = { { name = "temp", type = "number", values = { 59.7 }, config = {} } } }
		local v2 = { key = "g", features = { newGauge = true }, size = { w = 600, h = 300 } }
		local g = Gauge.specs(S.json(WEATHER), { frame :: any }, env, v2)[1]
		local ring = g.ring
		assert(ring, "ring")
		expect(#ring).toBe(10)
		local want = {
			"super-light-purple",
			"super-light-blue",
			"blue",
			"green",
			"semi-dark-green",
			"dark-yellow",
			"semi-dark-orange",
			"light-red",
			"red",
			"semi-dark-red",
		}
		for i, name in want do
			expect(ring[i].class).toBe(class(name))
		end
		-- 59.7 is in the blue step (50..60): the bar is blue.
		expect(g.bands).toEqual({ { from = 0, to = 1, class = class("blue") } })
	end)
end)

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
		expect(g.bands).toEqual({
			{ from = 0, to = 0.05, class = class("green") },
			{ from = 0.05, to = 1, class = class("red") },
		})
		expect(g.ring).toEqual(g.bands)
		local node, assets = Gauge.view(S.json(NO_QUERY), {}, env, V2)
		local img = S.find(node, function(n)
			return n.k == "image"
		end)
		local svg = assets[img.p.asset].bytes
		-- The red run covers the bar from 1 to 6 of 0..20.
		expect(string.find(svg, 'class="' .. class("red") .. ' tg-line"', 1, true) ~= nil).toBe(true)
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
		expect(g.bands).toEqual({ { from = 0, to = 1, class = class("green") } })
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
		expect(g.bands).toEqual({ { from = 0, to = 1, class = class("green") } })
	end)

	it("segments the bar and colors each filled segment by its own value", function()
		local panel = S.json(NO_QUERY)
		panel.options.segmentCount = 4
		-- The placeholder has no display processor: Grafana's fallback gray.
		local g = Gauge.specs(panel, {}, env, V2)[1]
		expect(g.segments).toBe(4)
		expect((g.segment_class :: (number) -> string)(0.25)).toBe("tgp-fx tgp-neutral")
		-- A real value colors each segment by the step its start value is in.
		local frame = {
			fields = { { name = "v", type = "number", values = { 3 }, config = {} } },
		}
		local real = Gauge.specs(panel, { frame :: any }, env, V2)[1]
		local segment = real.segment_class :: (number) -> string
		expect(segment(0)).toBe(class("green"))
		expect(segment(0.25)).toBe(class("red"))
	end)
end)

return nil
