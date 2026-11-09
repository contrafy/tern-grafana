--!strict
-- The time series panel (public/app/plugins/panel/timeseries/panelcfg.cue,
-- packages/grafana-schema GraphFieldConfig, fieldColor.ts
-- getFieldSeriesColor) mapped onto lib/render/svg_timeseries.
local t = require("../../lib/test")
local S = require("./support")
local Timeseries = require("../../../plugin/lib/panels/timeseries")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

-- The idle series' legend Last * / Max per prom_range capture, the end of
-- the 15m window each was captured in, and a sample near its middle (the
-- 13.3.0 stack had run only ~7m: 29 samples instead of 61).
local LAST_IDLE = { ["11.6.16"] = "9.62", ["12.4.12"] = "9.45", ["13.3.0"] = "9.48" }
local MAX_IDLE = { ["11.6.16"] = "9.69", ["12.4.12"] = "9.69", ["13.3.0"] = "9.58" }
local TO_MS = { ["11.6.16"] = 1791577908000, ["12.4.12"] = 1791577908000, ["13.3.0"] = 1794239763000 }
local MID_SAMPLE = { ["11.6.16"] = 30, ["12.4.12"] = 30, ["13.3.0"] = 15 }

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
				from_ms = TO_MS[version] - 908000,
				to_ms = TO_MS[version],
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
			expect(string.find(legend, "idle" .. LAST_IDLE[version] .. MAX_IDLE[version], 1, true) ~= nil).toBe(true)
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
			local cursor = frames[1].fields[1].values[MID_SAMPLE[version]]
			local node = Timeseries.view(S.panel(version, 2), frames, env, { key = "p", cursor = cursor })
			local legend = S.text(S.find(node, function(n)
				return n.p and n.p.key == "p.legend"
			end))
			expect(string.find(legend, "Value", 1, true) ~= nil).toBe(true)
		end)

		-- An expanded panel redraws on every cursor key: the chart under the
		-- cursor is the same render, while new data or options draw anew.
		it("draws the chart once across cursor moves and again for new data", function()
			local frames = S.refFrames(version, "prom_range", "A")
			local times = frames[1].fields[1].values
			local panel = S.panel(version, 2)
			local _, first = Timeseries.view(panel, frames, env, { key = "memo", cursor = times[2] })
			local _, moved = Timeseries.view(panel, frames, env, { key = "memo", cursor = times[3] })
			expect(rawequal(first.memo.bytes, moved.memo.bytes)).toBe(true)
			local changed = S.clone(frames)
			local values = changed[1].fields[2].values
			values[#values] = 1000
			local _, fresh = Timeseries.view(panel, changed, env, { key = "memo", cursor = times[3] })
			expect(fresh.memo.bytes ~= first.memo.bytes).toBe(true)
			local _, wider = Timeseries.view(panel, frames, env, { key = "memo", cursor = times[3], width = 500 })
			expect(wider.memo.bytes ~= first.memo.bytes).toBe(true)
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

-- gradientMode hue and scheme (UPlotSeriesBuilder getLineColor/getFill,
-- gradientFills.ts): line and fill share one gradient whose stops are
-- classes; Grafana's colors come from tinycolor and the named palette.
describe("timeseries gradient modes", function()
	local Frame = require("../../../plugin/lib/frame/types")
	local TsGradient = require("../../../plugin/lib/render/ts_gradient")
	-- 0..10 over a minute: thresholds at 4 and 8 fall inside the plot.
	local times, values = {}, {}
	for i = 1, 11 do
		times[i] = (i - 1) * 6000
		values[i] = i - 1
	end
	local frames = { Frame.timeSeries({ s = "a" }, times, values) }
	local function panel(mode: string, color: any, thresholds: any?): any
		return {
			type = "timeseries",
			fieldConfig = {
				defaults = {
					color = color,
					thresholds = thresholds,
					custom = { gradientMode = mode, fillOpacity = 30 },
				},
				overrides = {},
			},
		}
	end
	-- The stop colors of the gradient a path's `attr` references: hex for
	-- tg-gc classes, the class otherwise.
	local function stops(svg: string, tag: string, attr: string): { string }
		local id = string.match(tag, attr .. '="url%(#([^)]+)%)"') :: string
		local body = string.match(svg, '<linearGradient id="' .. id .. '"[^>]*>(.-)</linearGradient>') :: string
		local out: { string } = {}
		for class in string.gmatch(body, 'class="([^"]+)"') do
			local n = tonumber(string.match(class, "^tg%-gc(%d+)$"))
			table.insert(out, if n then TsGradient.STOPS[n] else class)
		end
		return out
	end

	it("draws hue and scheme natively", function()
		for _, mode in { "hue", "scheme" } do
			expect(Timeseries.unsupported(panel(mode, { mode = "palette-classic" }), env)).toBeNil()
		end
	end)

	-- getHueGradientFn on green #73bf69: tinycolor's saturate/spin/brighten/
	-- lighten top and spin/darken bottom (darkened again in the dark theme).
	it("hue-shifts the series color down the plot, per theme", function()
		local p = panel("hue", { mode = "palette-classic" })
		for theme, want in { light = { "#9af3ae", "#8ab757" }, dark = { "#9af3ae", "#719a42" } } do
			local _, assets = Timeseries.view(p, frames, env, { key = "p", theme = theme :: any })
			local svg = assets.p.bytes
			local line = pathTag(svg, "tg-line") :: string
			expect(stops(svg, line, "stroke")).toEqual(want)
			-- The class color would beat the gradient attribute.
			expect(pathTag(svg, "tg-s1", "tg-line")).toBeNil()
			local area = pathTag(svg, "tg-area") :: string
			expect(stops(svg, area, "fill")).toEqual(want)
			expect(area).toContain('fill-opacity="0.30"')
		end
	end)

	it("hue-shifts a fixed color", function()
		local _, assets = Timeseries.view(
			panel("hue", { mode = "fixed", fixedColor = "#f2495c" }),
			frames,
			env,
			{ key = "p", theme = "light" }
		)
		local svg = assets.p.bytes
		expect(stops(svg, pathTag(svg, "tg-line") :: string, "stroke")).toEqual({ "#ffa688", "#f03196" })
	end)

	-- Absolute thresholds: hard edges at the steps' values in their tones,
	-- from the scale's min (0) to the last step below its max (8, the
	-- scale reaching 10).
	it("draws threshold steps as hard stops at their values", function()
		local th = {
			mode = "absolute",
			steps = {
				{ value = Frame.NULL, color = "green" },
				{ value = 4, color = "orange" },
				{ value = 8, color = "red" },
			},
		}
		local _, assets = Timeseries.view(panel("scheme", { mode = "thresholds" }, th), frames, env, { key = "p" })
		local svg = assets.p.bytes
		local line = pathTag(svg, "tg-line") :: string
		expect(stops(svg, line, "stroke")).toEqual({
			"tg-gt-success",
			"tg-gt-success",
			"tg-gt-warning",
			"tg-gt-warning",
			"tg-gt-error",
		})
		local id = string.match(line, 'stroke="url%(#([^)]+)%)"') :: string
		local def = string.match(svg, '<linearGradient id="' .. id .. '"[^>]*>.-</linearGradient>') :: string
		local offsets: { number } = {}
		for o in string.gmatch(def, 'offset="([^"]+)"') do
			-- Stops sit on whole pixels (scaleGradient rounds valToPos).
			table.insert(offsets, math.floor((tonumber(o) :: number) * 20 + 0.5) / 20)
		end
		expect(offsets).toEqual({ 0, 0.5, 0.5, 1, 1 })
	end)

	-- Continuous schemes spread their colors evenly over the data range.
	it("runs a continuous scheme through its colors", function()
		local _, assets = Timeseries.view(
			panel("scheme", { mode = "continuous-GrYlRd" }),
			frames,
			env,
			{ key = "p", theme = "light" }
		)
		local svg = assets.p.bytes
		local area = pathTag(svg, "tg-area") :: string
		expect(stops(svg, area, "fill")).toEqual({ "#56a64b", "#f2cc0c", "#e02f44" })
	end)

	-- Scheme with a fixed color falls through to a plain fill.
	it("draws scheme with a fixed color plainly", function()
		local _, assets =
			Timeseries.view(panel("scheme", { mode = "fixed", fixedColor = "red" }), frames, env, { key = "p" })
		local svg = assets.p.bytes
		expect((string.find(svg, "linearGradient", 1, true))).toBeNil()
		expect(pathTag(svg, "tgp-error", "tg-line") ~= nil).toBe(true)
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
