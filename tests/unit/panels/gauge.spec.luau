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

		it("renders rings", function()
			local node = Gauge.view(S.panel(version, 7), S.frames(version, "prom_instant"), env, OPTS, false)
			local ring = S.find(node, function(n)
				return n.k == "meter"
			end)
			expect(ring.p.style).toBe("ring")
			expect(ring.p.tone).toBe("error")
			expect(ring.p.label[1].t).toBe("100%")
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
			local node = Gauge.view(S.panel(version, 8), S.frames(version, "prom2_range"), env, OPTS, true)
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
			local node = Gauge.view(panel, S.frames(version, "prom2_range"), env, OPTS, true)
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
			local node = Gauge.view(panel, S.frames(version, "prom2_range"), env, OPTS, true)
			expect(node.k).toBe("row")
			expect(#S.findAll(node, function(n)
				return n.k == "meter"
			end)).toBe(6)
		end)
	end)
end

return nil
