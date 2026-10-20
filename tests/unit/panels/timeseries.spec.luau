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
			expect(count(assets.p.bytes, "tgp-fx tgp-accent tg-line")).toBe(1)
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

-- Per-series units and stacking are drawn (second axis, stacks per scale);
-- only unknown legend reducers stay on the ladder. The trend panel, drawn by
-- svg_xy on one scale, keeps rejecting them.
describe("timeseries support", function()
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
	local units = {
		fieldConfig = {
			defaults = { unit = "short" },
			overrides = {
				{ matcher = { id = "byName", options = "a" }, properties = { { id = "unit", value = "bytes" } } },
			},
		},
	}

	it("draws per-series units and stacking, rejects unknown legend calcs", function()
		expect(Timeseries.unsupported(stacking, env)).toBeNil()
		expect(Timeseries.unsupported(units, env)).toBeNil()
		local legend = { options = { legend = { calcs = { "mean", "allValues" } } } }
		expect(Timeseries.unsupported(legend, env)).toBe("legend reducer allValues is not supported")
	end)

	it("keeps single-axis panels off per-series units and stacking", function()
		expect(Timeseries.singleAxisUnsupported(stacking, env)).toBe(
			"per-series stacking (custom.stacking override) is not supported"
		)
		expect(Timeseries.singleAxisUnsupported(units, env)).toBe(
			"a per-series unit override (second y axis) is not supported"
		)
	end)
end)

-- Text of the SVG tick labels anchored `anchor` ("end": left axes,
-- "start": right axes).
local function ticks(svg: string, anchor: string): { string }
	local out: { string } = {}
	for a, text in string.gmatch(svg, 'text%-anchor="(%a+)">([^<]*)</text>') do
		if a == anchor then
			table.insert(out, text :: string)
		end
	end
	return out
end

for _, version in S.VERSIONS do
	describe("timeseries axes on tern-panels, Grafana " .. version, function()
		-- A unit override gives "idle" its own scale (buildScaleKey). It is
		-- the first series, so its axis takes the left and the other modes'
		-- axis goes right (addAxis auto placement); negative-Y draws it below
		-- zero with negative ticks, and the legend keeps its own positive
		-- values in its unit.
		it("draws a per-series unit on its own axis and negative-Y below zero", function()
			local panel = S.clone(S.panel(version, 2))
			panel.fieldConfig.overrides = {
				{
					matcher = { id = "byName", options = "idle" },
					properties = {
						{ id = "unit", value = "percentunit" },
						{ id = "custom.transform", value = "negative-Y" },
						{ id = "custom.axisLabel", value = "idle share" },
					},
				},
			}
			local frames = S.refFrames(version, "prom_range", "A")
			local node, assets = Timeseries.view(panel, frames, env, { key = "p" })
			local svg = assets.p.bytes
			local left = ticks(svg, "end")
			expect(#left > 0).toBe(true)
			local negative = 0
			for _, label in left do
				expect(string.sub(label, -1)).toBe("%")
				if string.sub(label, 1, 1) == "-" then
					negative += 1
				end
			end
			expect(negative > 0).toBe(true)
			local right = ticks(svg, "start")
			expect(#right > 0).toBe(true)
			for _, label in right do
				expect((string.find(label, "%", 1, true))).toBeNil()
			end
			expect(svg).toContain(">idle share<")
			local legend = S.text(S.find(node, function(n)
				return n.p and n.p.key == "p.legend"
			end))
			expect(string.find(legend, "idle%d[%d%.]*%%") ~= nil).toBe(true)
			expect((string.find(legend, "idle-", 1, true))).toBeNil()
		end)

		-- byValue (fieldValueMatcher.ts) evaluated on the panel's frames:
		-- series that are all zero leave the legend (Grafana's hideZero).
		it("hides all-zero series from the legend through a byValue override", function()
			local panel = S.clone(S.panel(version, 2))
			panel.options.legend.displayMode = "list"
			panel.fieldConfig.overrides = {
				{
					matcher = { id = "byValue", options = { reducer = "allIsZero", op = "gte", value = 0 } },
					properties = { { id = "custom.hideFrom", value = { legend = true, tooltip = true, viz = false } } },
				},
			}
			local frames = S.refFrames(version, "prom_range", "A")
			local zero = 0
			for _, f in frames do
				for _, field in f.fields do
					if field.type == "number" then
						local all = true
						for _, v in field.values do
							if v ~= 0 then
								all = false
							end
						end
						zero += if all then 1 else 0
					end
				end
			end
			local node, assets = Timeseries.view(panel, frames, env, { key = "p" })
			local rows = S.findAll(
				S.find(node, function(n)
					return n.p and n.p.key == "p.legend"
				end),
				function(n)
					return n.p and type(n.p.class) == "string" and string.find(n.p.class, "tg-swatch", 1, true) ~= nil
				end
			)
			expect(zero > 0).toBe(true)
			expect(#rows).toBe(8 - zero)
			-- Still drawn: hideFrom.viz is false.
			expect(count(assets.p.bytes, "tg-line")).toBe(8)
		end)
	end)
end

-- The `<path>` tag of the first path whose class list has every class.
local function pathTag(svg: string, ...: string): string?
	local want = { ... }
	for el in string.gmatch(svg, "<path [^>]*>") do
		local classes = " " .. (string.match(el, 'class="([^"]*)"') or "") .. " "
		local ok = true
		for _, c in want do
			ok = ok and string.find(classes, " " .. c .. " ", 1, true) ~= nil
		end
		if ok then
			return el
		end
	end
	return nil
end

for _, version in S.VERSIONS do
	describe("timeseries per-series draw config on tern-panels, Grafana " .. version, function()
		-- Panel 2 fills every mode at 10%. An override turning one series'
		-- fill off, widening and dashing its line (UPlotSeriesBuilder.ts
		-- lineWidth/lineStyle, getFill) must draw exactly that.
		it("draws an override's fillOpacity, lineWidth and lineStyle on its series only", function()
			local panel = S.clone(S.panel(version, 2))
			panel.fieldConfig.overrides = {
				{
					matcher = { id = "byRegexp", options = "/^idle$/" },
					properties = {
						{ id = "custom.fillOpacity", value = 0 } :: any,
						{ id = "custom.lineWidth", value = 2 } :: any,
						{ id = "custom.lineStyle", value = { fill = "dash", dash = { 10, 10 } } } :: any,
					},
				},
			}
			local frames = S.refFrames(version, "prom_range", "A")
			local _, assets = Timeseries.view(panel, frames, env, { key = "p" })
			local svg = assets.p.bytes
			expect(count(svg, "tg-area")).toBe(7)
			local items = require("../../../plugin/lib/panels/fieldconfig").resolve(panel, frames, env)
			local idleClass: string? = nil
			for _, item in items do
				if item.name == "idle" then
					idleClass = "tg-s" .. tostring(Timeseries.paletteIndexes(frames)[item.field])
				end
			end
			local line = pathTag(svg, idleClass :: string, "tg-line") :: string
			expect(line).toContain('stroke-width="3"')
			expect(line).toContain('stroke-dasharray="15 15"')
			expect(pathTag(svg, idleClass :: string, "tg-area")).toBeNil()
		end)
	end)
end

-- Ladder reasons for what the class-colored SVG cannot draw.
describe("timeseries gradient modes (UPlotSeriesBuilder.ts getFill)", function()
	local function panel(mode: string, colorMode: string?): any
		return {
			type = "timeseries",
			fieldConfig = {
				defaults = { color = { mode = colorMode or "palette-classic" }, custom = { gradientMode = mode } },
				overrides = {},
			},
		}
	end

	it("draws none and opacity, refuses hue and by-value scheme", function()
		expect(Timeseries.unsupported(panel("none"), env)).toBeNil()
		expect(Timeseries.unsupported(panel("opacity"), env)).toBeNil()
		expect(Timeseries.unsupported(panel("hue"), env)).toBe(
			"custom.gradientMode hue (a hue-shifted fill) is not drawn natively"
		)
		expect(Timeseries.unsupported(panel("scheme"), env)).toBe(
			"custom.gradientMode scheme (series colored by value) is not drawn natively"
		)
		-- Scheme with a fixed color falls through to a plain fill.
		expect(Timeseries.unsupported(panel("scheme", "fixed"), env)).toBeNil()
		local over = panel("none")
		over.fieldConfig.overrides = {
			{
				matcher = { id = "byName", options = "a" },
				properties = { { id = "custom.gradientMode", value = "hue" } },
			},
		}
		expect(Timeseries.unsupported(over, env)).toBe(
			"override custom.gradientMode hue (a hue-shifted fill) is not drawn natively"
		)
	end)
end)

-- setClassicPaletteIdxs (public/app/plugins/panel/timeseries/utils.ts):
-- classic palette positions count number fields of graphable frames in
-- frame order, hidden series included, each frame's first field skipped.
describe("timeseries palette positions (setClassicPaletteIdxs)", function()
	local Frame = require("../../../plugin/lib/frame/types")
	local a = Frame.timeSeries({ s = "a" }, { 0, 1000 }, { 1, 2 })
	local b = Frame.timeSeries({ s = "b" }, { 0, 1000 }, { 3, 4 })
	local c = Frame.timeSeries({ s = "c" }, { 0, 1000 }, { 5, 6 })
	local noTime: Frame.Frame = { fields = { Frame.field("n", "number", { 1 }) } }

	it("counts graphable frames only, in frame order", function()
		local idx = Timeseries.paletteIndexes({ a, noTime, b, c })
		expect(idx[a.fields[2]]).toBe(1)
		expect(idx[b.fields[2]]).toBe(2)
		expect(idx[c.fields[2]]).toBe(3)
		expect(idx[noTime.fields[1]]).toBeNil()
	end)

	-- A hidden series keeps its palette slot, so the others keep their
	-- colors when it is hidden.
	it("keeps the colors of the series after a hidden one", function()
		local panel = {
			type = "timeseries",
			fieldConfig = {
				defaults = { color = { mode = "palette-classic" } },
				overrides = {
					{
						matcher = { id = "byName", options = "a" },
						properties = {
							{ id = "custom.hideFrom", value = { viz = true, legend = true, tooltip = true } },
						},
					},
				},
			},
			options = { legend = { showLegend = true, displayMode = "list" } },
		}
		local _, assets = Timeseries.view(panel, { a, b, c }, env, { key = "p" })
		local svg = assets.p.bytes
		expect(pathTag(svg, "tg-s1", "tg-line")).toBeNil()
		expect(pathTag(svg, "tg-s2", "tg-line") ~= nil).toBe(true)
		expect(pathTag(svg, "tg-s3", "tg-line") ~= nil).toBe(true)
	end)
end)

return nil
