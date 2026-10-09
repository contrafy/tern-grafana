--!strict
-- The time series panel (public/app/plugins/panel/timeseries/panelcfg.cue,
-- packages/grafana-schema GraphFieldConfig, fieldColor.ts
-- getFieldSeriesColor) mapped onto lib/render/svg_timeseries.
local t = require("../../lib/test")
local S = require("./support")
local Timeseries = require("../../../plugin/lib/panels/timeseries")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local LAST_IDLE = { ["11.6.16"] = "9.62", ["12.4.12"] = "9.45" }

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

for _, version in S.VERSIONS do
	describe("timeseries on tern-panels, Grafana " .. version, function()
		-- Panel 2 "CPU by mode": line, fillOpacity 10, unit short, spanNulls
		-- false, thresholds off.
		it("maps draw style, fill, unit and null handling to the renderer", function()
			local o = Timeseries.renderOptions(S.panel(version, 2), env, { key = "p" })
			expect(o.draw).toBe("line")
			expect(o.fill_opacity).toBe(10)
			expect(o.unit).toBe("short")
			expect(o.null_mode).toBe("gap")
			expect(o.stack).toBe("none")
			expect(o.threshold_style).toBe("off")
			expect(o.thresholds).toBeNil()
		end)

		-- Panel 3 "Memory (stacked)": stacking normal, thresholds as lines.
		it("stacks and draws threshold lines as configured", function()
			local o = Timeseries.renderOptions(S.panel(version, 3), env, { key = "p" })
			expect(o.stack).toBe("normal")
			expect(o.threshold_style).toBe("line")
			expect(o.unit).toBe("bytes")
			assert(o.thresholds, "thresholds")
			expect(o.thresholds.steps[2].value).toBe(4294967296)
		end)

		-- Panel 4: thresholdsStyle line+area, decimals 2.
		it("keeps line+area thresholds and fixed decimals", function()
			local o = Timeseries.renderOptions(S.panel(version, 4), env, { key = "p" })
			expect(o.threshold_style).toBe("line+area")
			expect(o.decimals).toBe(2)
		end)

		-- options.legend: table mode with lastNotNull and max, per series.
		it("renders the SVG asset and a legend table with the panel's calcs", function()
			local node, assets = Timeseries.view(S.panel(version, 2), S.frames(version, "prom_range"), env, {
				key = "p2",
				from_ms = 1791577000000,
				to_ms = 1791577908000,
			})
			local svg = assets.p2
			assert(svg, "svg asset")
			expect(svg.mime).toBe("image/svg+xml")
			-- 8 CPU modes + sum(up) from refId B.
			expect(count(svg.bytes, "tg-line")).toBe(9)
			local legend = S.text(S.find(node, function(n)
				return n.p and n.p.key == "p2.legend"
			end))
			expect(string.find(legend, "Last *", 1, true) ~= nil).toBe(true)
			expect(string.find(legend, "Max", 1, true) ~= nil).toBe(true)
			expect(string.find(legend, "idle" .. LAST_IDLE[version] .. "9.69", 1, true) ~= nil).toBe(true)
		end)

		-- A fixed-color override paints that series (and its swatch) in the
		-- color's tone; other series keep the palette.
		it("paints fixed-color overrides on the series and its swatch", function()
			local panel = S.clone(S.panel(version, 4))
			panel.fieldConfig.overrides[1].matcher.options = "user"
			local node, assets = Timeseries.view(panel, S.refFrames(version, "prom_range", "A"), env, { key = "p" })
			expect(count(assets.p.bytes, "tgp-fx tgp-accent")).toBe(1)
			local swatches = S.findAll(node, function(n)
				return n.p and type(n.p.class) == "string" and string.find(n.p.class, "tg-swatch", 1, true) ~= nil
			end)
			expect(#swatches).toBe(8)
			local fixed = 0
			for _, s in swatches do
				if string.find(s.p.class, "tgp-accent", 1, true) then
					fixed += 1
				end
			end
			expect(fixed).toBe(1)
		end)

		-- By-value color modes color a series by its last value's threshold.
		it("colors a thresholds-mode series by its last value", function()
			local panel = S.clone(S.panel(version, 2))
			panel.fieldConfig.defaults.color = { mode = "thresholds" }
			local _, assets = Timeseries.view(panel, S.refFrames(version, "prom_range", "A"), env, { key = "p" })
			-- idle (~9.5) is past the red step at 4; the other modes are green.
			-- Lines and their fill areas both carry the series color.
			expect(count(assets.p.bytes, "tgp-fx tgp-error tg-line")).toBe(1)
			expect(count(assets.p.bytes, "tgp-fx tgp-success tg-line")).toBe(7)
			expect(count(assets.p.bytes, "tgp-fx tgp-error tg-area")).toBe(1)
		end)

		it("hides series with custom.hideFrom.viz", function()
			local panel = S.clone(S.panel(version, 2))
			panel.fieldConfig.overrides = {
				{
					matcher = { id = "byRegexp", options = "/^(irq|nice|steal)$/" },
					properties = { { id = "custom.hideFrom", value = { viz = true, legend = true, tooltip = true } } },
				},
			}
			local _, assets = Timeseries.view(panel, S.refFrames(version, "prom_range", "A"), env, { key = "p" })
			expect(count(assets.p.bytes, "tg-line")).toBe(5)
		end)

		-- With the keyboard cursor on, the legend reads values at the cursor.
		it("switches the legend to cursor read-out", function()
			local frames = S.refFrames(version, "prom_range", "A")
			local cursor = frames[1].fields[1].values[30]
			local node = Timeseries.view(S.panel(version, 2), frames, env, { key = "p", cursor = cursor })
			local legend = S.text(S.find(node, function(n)
				return n.p and n.p.key == "p.legend"
			end))
			expect(string.find(legend, "Value", 1, true) ~= nil).toBe(true)
		end)

		it("hides the legend when showLegend is false", function()
			local panel = S.clone(S.panel(version, 2))
			panel.options.legend.showLegend = false
			local node = Timeseries.view(panel, S.refFrames(version, "prom_range", "A"), env, { key = "p" })
			expect(S.find(node, function(n)
				return n.p and n.p.key == "p.legend"
			end)).toBeNil()
		end)
	end)
end

describe("timeseries support", function()
	it("rejects per-series stacking, second-axis units and unknown legend calcs", function()
		local stacking = {
			fieldConfig = {
				defaults = { unit = "short" },
				overrides = {
					{
						matcher = { id = "byName", options = "a" },
						properties = { { id = "custom.stacking", value = { mode = "none", group = "B" } } },
					},
				},
			},
		}
		expect(Timeseries.unsupported(stacking, env)).toBe(
			"per-series stacking (custom.stacking override) is not supported"
		)
		local units = {
			fieldConfig = {
				defaults = { unit = "short" },
				overrides = {
					{ matcher = { id = "byName", options = "a" }, properties = { { id = "unit", value = "bytes" } } },
				},
			},
		}
		expect(Timeseries.unsupported(units, env)).toBe("a per-series unit override (second y axis) is not supported")
		local legend = { options = { legend = { calcs = { "mean", "allValues" } } } }
		expect(Timeseries.unsupported(legend, env)).toBe("legend reducer allValues is not supported")
	end)
end)

return nil
