--!strict
-- The SVG must survive Tern's sanitizer and size cap (docs/sdk-capability-
-- matrix.md): colors only through classes (no var(), no style), at most
-- 256 KiB, and only element kinds Tern keeps.
local t = require("../../lib/test")
local Frame = require("../../../plugin/lib/frame/types")
local Svg = require("../../../plugin/lib/render/svg_timeseries")
local describe, it, expect = t.describe, t.it, t.expect

local NULL = Frame.NULL
local T0 = 1710000000000
local STEP = 15000

-- Elements Tern's SVG sanitizer keeps.
local ALLOWED = {
	svg = true,
	g = true,
	defs = true,
	linearGradient = true,
	stop = true,
	path = true,
	circle = true,
	line = true,
	rect = true,
	mask = true,
	text = true,
}

local function series(n: number, f: (i: number) -> any, labels: { [string]: string }?): Frame.Frame
	local times, values = table.create(n), table.create(n)
	for i = 1, n do
		times[i] = T0 + (i - 1) * STEP
		values[i] = f(i)
	end
	return Frame.timeSeries(labels or {}, times, values)
end

local function many(count: number, points: number): { Frame.Frame }
	local frames = {}
	for s = 1, count do
		table.insert(
			frames,
			series(points, function(i)
				return 1000 + 400 * math.sin(i / (37 + s)) + (i * 7919 % 13) * 3.3
			end, { __name__ = "m", instance = "host-" .. s })
		)
	end
	return frames
end

-- Balanced tags, only allowed elements; returns element counts.
local function checkXml(svg: string): { [string]: number }
	local stack: { string } = {}
	local counts: { [string]: number } = {}
	for closeTag, tagName, _, selfTag in string.gmatch(svg, "<(/?)([%w]+)([^>]-)(/?)>") do
		local close, name, selfClose = closeTag :: string, tagName :: string, selfTag :: string
		if not ALLOWED[name] then
			error("element not kept by Tern: " .. name)
		end
		if close == "/" then
			local open = table.remove(stack)
			if open ~= name then
				error(string.format("</%s> closes <%s>", name, tostring(open)))
			end
		else
			counts[name] = (counts[name] or 0) + 1
			if selfClose ~= "/" then
				table.insert(stack, name)
			end
		end
	end
	if #stack > 0 then
		error("unclosed <" .. stack[#stack] .. ">")
	end
	return counts
end

-- `d` of every path whose class list contains `class`.
local function paths(svg: string, class: string): { string }
	local out: { string } = {}
	for classes, d in string.gmatch(svg, '<path class="([^"]*)"[^>]-d="([^"]*)"') do
		for c in string.gmatch(classes :: string, "%S+") do
			if c == class then
				table.insert(out, d :: string)
				break
			end
		end
	end
	return out
end

local function subpaths(d: string): number
	local _, n = string.gsub(d, "M", "")
	return n
end

local function has(s: string, needle: string): boolean
	return string.find(s, needle, 1, true) ~= nil
end

local function assertTernSafe(svg: string)
	checkXml(svg)
	expect(has(svg, "var(")).toBe(false)
	expect(has(svg, "style=")).toBe(false)
	expect(has(svg, "<title")).toBe(false)
	-- No literal colors: everything comes from the plugin sheet.
	expect(has(svg, '="#')).toBe(false)
	expect(has(svg, '="rgb')).toBe(false)
end

describe("svg_timeseries.render output", function()
	it("is well-formed SVG Tern keeps, colored only through classes", function()
		local frames = many(3, 50)
		for _, opts in
			{
				{},
				{ fill_opacity = 20 },
				{ draw = "bars" },
				{ draw = "points" },
				{ stack = "normal", fill_opacity = 30 },
				{
					thresholds = { steps = { { value = NULL, color = "green" }, { value = 1200, color = "red" } } },
					threshold_style = "line+area",
				},
			} :: { Svg.Options }
		do
			local r = Svg.render(frames, opts)
			assertTernSafe(r.svg)
			expect(string.sub(r.svg, 1, 4)).toBe("<svg")
			expect(r.svg).toContain('viewBox="0 0 960 300"')
		end
	end)

	it("gives series 1..n the palette classes tg-s1..tg-sn", function()
		local r = Svg.render(many(3, 20))
		expect(#paths(r.svg, "tg-s1")).toBe(1)
		expect(#paths(r.svg, "tg-s2")).toBe(1)
		expect(#paths(r.svg, "tg-s3")).toBe(1)
		expect(#paths(r.svg, "tg-s4")).toBe(0)
		expect(#paths(r.svg, "tg-grid")).toBe(1)
		expect(r.svg).toContain('class="tg-label"')
		expect(r.layout.series[2].class).toBe("tg-s2")
	end)

	-- Tern shows a placeholder for anything over 262144 bytes.
	it("stays under the 256 KiB cap for 10 series x 5000 points in every draw style", function()
		local frames = many(10, 5000)
		for _, opts in
			{
				{},
				{ fill_opacity = 100 },
				{ draw = "bars" },
				{ draw = "points" },
				{ stack = "normal", fill_opacity = 50 },
			} :: { Svg.Options }
		do
			local r = Svg.render(frames, opts)
			expect(#r.svg <= Svg.CAP).toBe(true)
			expect(r.points > 10 * 100).toBe(true)
			expect(r.points < 10 * 5000).toBe(true)
			checkXml(r.svg)
		end
	end)

	it("never draws more samples per series than the point budget", function()
		local r = Svg.render(many(2, 3000), { point_budget = 100 })
		for _, s in r.layout.series do
			expect(#s.times <= 100).toBe(true)
		end
		expect(r.points <= 200).toBe(true)
	end)

	it("draws at most series_cap series and reports the rest as dropped", function()
		local r = Svg.render(many(12, 10))
		expect(r.dropped).toBe(2)
		expect(r.layout.dropped).toBe(2)
		expect(#r.layout.series).toBe(10)
		expect(#paths(r.svg, "tg-s10")).toBe(1)
		local capped = Svg.render(many(5, 10), { series_cap = 2 })
		expect(capped.dropped).toBe(3)
		expect(#capped.layout.series).toBe(2)
	end)

	it("says No data for an empty result", function()
		local r = Svg.render({})
		assertTernSafe(r.svg)
		expect(r.svg).toContain("No data")
		expect(r.dropped).toBe(0)
	end)
end)

describe("svg_timeseries.render nulls", function()
	local function withHole(): { Frame.Frame }
		return {
			series(10, function(i)
				if i == 4 or i == 5 then
					return NULL
				elseif i == 8 then
					return 0 / 0
				end
				return i
			end),
		}
	end

	-- A scrape outage must look like an outage, not a straight line across it.
	it("breaks the line at nulls and NaN in gap mode", function()
		local d = paths(Svg.render(withHole()).svg, "tg-line")
		expect(#d).toBe(1)
		expect(subpaths(d[1])).toBe(3)
	end)

	it("joins across nulls in connect mode", function()
		local d = paths(Svg.render(withHole(), { null_mode = "connect" }).svg, "tg-line")
		expect(subpaths(d[1])).toBe(1)
	end)

	it("keeps gaps after downsampling", function()
		local frames = {
			series(4000, function(i)
				return if i > 1500 and i <= 2500 then NULL else math.sin(i / 50)
			end),
		}
		local r = Svg.render(frames, { point_budget = 200 })
		expect(#r.layout.series[1].times <= 210).toBe(true)
		expect(subpaths(paths(r.svg, "tg-line")[1])).toBe(2)
	end)
end)

describe("svg_timeseries.render scales", function()
	it("fits the y axis around the full-resolution data on nice bounds", function()
		local r = Svg.render({ series(5, function(i)
			return ({ 3, 97, 40, 12, 55 })[i]
		end) })
		expect(r.layout.y_min).toBe(0)
		expect(r.layout.y_max).toBe(100)
	end)

	it("stacks normal series so the top series reaches the sum", function()
		local frames = {
			series(3, function()
				return 10
			end),
			series(3, function()
				return 30
			end),
		}
		local r = Svg.render(frames, { stack = "normal" })
		expect(r.layout.y_max >= 40).toBe(true)
		local flat = Svg.render(frames)
		expect(flat.layout.y_max < 40).toBe(true)
		-- The legend still reads each series' own values.
		expect(r.layout.series[2].values[1]).toBe(30)
	end)

	it("percent stacking spans 0..1 with percent labels", function()
		local frames = {
			series(3, function()
				return 1
			end),
			series(3, function()
				return 3
			end),
		}
		local r = Svg.render(frames, { stack = "percent" })
		expect(r.layout.y_min).toBe(0)
		expect(r.layout.y_max).toBe(1)
		expect(r.layout.unit).toBe("percentunit")
		expect(r.svg).toContain(">100%<")
	end)

	it("uses the query range as the time domain when given", function()
		local r = Svg.render(
			{ series(3, function(i)
				return i
			end) },
			{ from_ms = T0 - 60000, to_ms = T0 + 120000 }
		)
		expect(r.layout.t_from).toBe(T0 - 60000)
		expect(r.layout.t_to).toBe(T0 + 120000)
	end)

	it("formats y labels with the unit", function()
		local r = Svg.render({ series(3, function(i)
			return i * 1024 * 1024
		end) }, { unit = "bytes" })
		expect(r.svg).toContain(" MiB<")
	end)
end)

describe("svg_timeseries.render thresholds", function()
	local spec = { steps = { { value = NULL, color = "green" }, { value = 50, color = "red" } } }
	local frames = { series(5, function(i)
		return i * 20
	end) }

	it("draws threshold lines in tone classes", function()
		local r = Svg.render(frames, { thresholds = spec, threshold_style = "line" })
		expect(#paths(r.svg, "tg-th-error")).toBe(1)
		expect(has(r.svg, "tg-tharea")).toBe(false)
	end)

	it("shades threshold bands in area style", function()
		local r = Svg.render(frames, { thresholds = spec, threshold_style = "area" })
		expect(r.svg).toContain('class="tg-tharea tg-th-success"')
		expect(r.svg).toContain('class="tg-tharea tg-th-error"')
	end)

	it("draws nothing for thresholds when the style is off", function()
		local r = Svg.render(frames, { thresholds = spec })
		expect(has(r.svg, "tg-th")).toBe(false)
	end)
end)

describe("svg_timeseries.render stacked bars", function()
	-- Live Loki counts over a short step: each level has a sample only every
	-- fourth step. Drawn one bar per sample, the bars are thinner than a pixel
	-- and each sits on the baseline (its neighbours are missing at its time),
	-- so the four colors blend into fewer. Bucketed, every slot stacks all four.
	it("stacks sparse series in shared slots no thinner than MIN_BAR_PX", function()
		local frames = {}
		for k = 1, 4 do
			table.insert(
				frames,
				series(1800, function(i)
					return if i % 4 == k - 1 then 1 else NULL
				end, { level = "l" .. k })
			)
		end
		local r = Svg.render(frames, { draw = "bars", stack = "normal" })
		local plotW = r.layout.plot_right - r.layout.plot_left
		local slots = #r.layout.times
		expect(slots > 0).toBe(true)
		expect(plotW / slots >= Svg.MIN_BAR_PX - 0.5).toBe(true)
		local baseline = string.format("%.1f", r.layout.plot_bottom)
		for k = 1, 4 do
			local d = paths(r.svg, "tg-s" .. k)
			expect(#d).toBe(1)
			expect(subpaths(d[1])).toBe(slots)
			-- Only the first series starts at the baseline; the others sit on it.
			local onBase = has(d[1], " " .. baseline .. "V")
			expect(onBase).toBe(k == 1)
		end
		-- The legend still reads the samples as recorded.
		expect(r.layout.series[2].calcs.max).toBe(1)
	end)
end)

-- `count` exemplars spread over the first `points` samples.
local function exemplars(count: number, points: number): { any }
	local out = {}
	for k = 1, count do
		local i = (k - 1) * points // count + 1
		table.insert(out, {
			time_ms = T0 + (i - 1) * STEP,
			value = 1000 + k % 50,
			labels = { traceID = string.format("%032x", k) },
			series = {},
		})
	end
	return out
end

describe("svg_timeseries.render exemplars", function()
	it("draws in-range exemplars as one tg-exemplar path of diamonds over the lines", function()
		local ex = exemplars(20, 100)
		-- Outside the drawn range: not drawn, not counted.
		table.insert(ex, { time_ms = T0 - 3600000, value = 1, labels = {}, series = {} })
		local r = Svg.render(many(2, 100), { from_ms = T0, to_ms = T0 + 99 * STEP, exemplars = ex })
		assertTernSafe(r.svg)
		local marks = paths(r.svg, "tg-exemplar")
		expect(#marks).toBe(1)
		expect(subpaths(marks[1])).toBe(20)
		expect(#(r.layout.exemplars :: { any })).toBe(20)
		expect(r.layout.exemplars_dropped).toBe(0)
		-- Markers come after the series so they stay visible.
		expect(
			(string.find(r.svg, "tg-exemplar", 1, true) :: number) > (string.find(r.svg, "tg-line", 1, true) :: number)
		).toBe(true)
	end)

	it("caps markers at EXEMPLAR_CAP, thinned evenly over time, and counts the rest", function()
		local r = Svg.render(many(1, 1000), { exemplars = exemplars(1000, 1000) })
		local drawn = r.layout.exemplars :: { any }
		expect(#drawn).toBe(Svg.EXEMPLAR_CAP)
		expect(r.layout.exemplars_dropped).toBe(1000 - Svg.EXEMPLAR_CAP)
		expect(subpaths(paths(r.svg, "tg-exemplar")[1])).toBe(Svg.EXEMPLAR_CAP)
		expect(drawn[1].time_ms).toBe(T0)
		expect(drawn[#drawn].time_ms > T0 + 900 * STEP).toBe(true)
		for i = 2, #drawn do
			expect(drawn[i - 1].time_ms <= drawn[i].time_ms).toBe(true)
		end
	end)

	it("stays under the 256 KiB cap with 10 x 5000 points and a full set of markers", function()
		for _, opts in { {}, { fill_opacity = 100 }, { draw = "bars" } } :: { Svg.Options } do
			opts.exemplars = exemplars(5000, 5000)
			local r = Svg.render(many(10, 5000), opts)
			expect(#r.svg <= Svg.CAP).toBe(true)
			expect(#(r.layout.exemplars :: { any })).toBe(Svg.EXEMPLAR_CAP)
			checkXml(r.svg)
		end
	end)

	it("widens the value axis to the exemplars instead of pinning them to the edge", function()
		local ex = { { time_ms = T0 + STEP, value = 5000, labels = {}, series = {} } }
		local r = Svg.render(many(1, 10), { exemplars = ex })
		expect(r.layout.y_max >= 5000).toBe(true)
		-- Hard bounds still win.
		local capped = Svg.render(many(1, 10), { exemplars = ex, max = 2000 })
		expect(capped.layout.y_max).toBe(2000)
	end)

	it("draws no marker path without exemplars", function()
		local r = Svg.render(many(1, 10), {})
		expect(#paths(r.svg, "tg-exemplar")).toBe(0)
		expect(r.layout.exemplars).toBeNil()
	end)
end)

-- Svg.render taking option literals whose singleton strings the type
-- checker would widen.
local render = (Svg.render :: any) :: (frames: { Frame.Frame }, options: any) -> Svg.Result

-- Tick labels by anchor: "end" for left axes, "start" for right axes.
local function tickTexts(svg: string, anchor: string): { string }
	local out: { string } = {}
	for a, text in string.gmatch(svg, 'text%-anchor="(%a+)">([^<]*)</text>') do
		if a == anchor then
			table.insert(out, text :: string)
		end
	end
	return out
end

local function anyContains(list: { string }, needle: string): boolean
	for _, s in list do
		if has(s, needle) then
			return true
		end
	end
	return false
end

local function values(list: { number }): (i: number) -> number
	return function(i: number): number
		return list[i]
	end
end

-- y of every vertex of a path's `d`.
local function ys(d: string): { number }
	local out: { number } = {}
	for _, y in string.gmatch(d, "([%d%.%-]+) ([%d%.%-]+)") do
		table.insert(out, tonumber(y) :: number)
	end
	return out
end

-- Grafana's time series puts series on scales by buildScaleKey
-- (packages/grafana-ui/src/components/uPlot/internal.ts: unit, min/max, soft
-- min/max, placement, distribution, label) and gives each scale an axis
-- (public/app/core/components/TimeSeries/utils.ts preparePlotConfigBuilder;
-- UPlotConfigBuilder.addAxis: auto is left for the first axis, right after).
describe("svg_timeseries.render y scales", function()
	local pct = series(4, values({ 10, 40, 70, 95 }))
	local mem = series(4, values({ 1048576, 2097152, 3145728, 4194304 }))

	it("puts a series with another unit on its own scale with an axis on the right", function()
		local r = Svg.render({ pct, mem }, { series = { { unit = "percent" }, { unit = "bytes" } } })
		local axes = r.layout.axes :: { any }
		expect(#axes).toBe(2)
		expect(axes[1].side).toBe("left")
		expect(axes[2].side).toBe("right")
		expect(r.layout.series[1].axis).toBe(1)
		expect(r.layout.series[2].axis).toBe(2)
		-- Each scale fits its own data: 4 MiB is not squeezed onto 0..100.
		expect(axes[1].max).toBe(100)
		expect(axes[2].max >= 4194304 and axes[2].max < 8388608).toBe(true)
		expect(anyContains(tickTexts(r.svg, "end"), "%")).toBe(true)
		expect(anyContains(tickTexts(r.svg, "start"), " MiB")).toBe(true)
		expect(anyContains(tickTexts(r.svg, "end"), "MiB")).toBe(false)
		expect(r.layout.plot_right < 960 - 12).toBe(true)
		-- Both series peak at the top of their own scale.
		local top1 = math.min(table.unpack(ys(paths(r.svg, "tg-s1")[1])))
		local top2 = math.min(table.unpack(ys(paths(r.svg, "tg-s2")[1])))
		expect(math.abs(top1 - top2) < 40).toBe(true)
		assertTernSafe(r.svg)
	end)

	it("keeps series whose scale key matches on one scale", function()
		local r = render({ pct, pct }, { series = { { unit = "percent" }, { unit = "percent" } } })
		expect(#(r.layout.axes :: { any })).toBe(1)
		expect(#tickTexts(r.svg, "start")).toBe(0)
		-- A different min is a different scale, as in buildScaleKey.
		local split = render({ pct, pct }, { series = { { unit = "percent" }, { unit = "percent", min = 0 } } })
		expect(#(split.layout.axes :: { any })).toBe(2)
	end)

	it("places axes as configured: auto goes left after a right axis, hidden draws no axis", function()
		local rightFirst: { Svg.SeriesStyle } = { { unit = "percent", placement = "right" }, { unit = "bytes" } }
		local r = render({ pct, mem }, { series = rightFirst })
		local axes = r.layout.axes :: { any }
		expect(axes[1].side).toBe("right")
		expect(axes[2].side).toBe("left")
		local hidden = render(
			{ pct, mem },
			{ series = { { unit = "percent" }, { unit = "bytes", placement = "hidden" } } }
		)
		local h = hidden.layout.axes :: { any }
		expect(h[2].side).toBe("hidden")
		expect(#tickTexts(hidden.svg, "start")).toBe(0)
		expect(anyContains(tickTexts(hidden.svg, "end"), "MiB")).toBe(false)
		expect(hidden.layout.plot_right).toBe(960 - 12)
		-- The hidden scale still fits its series.
		expect(h[2].max >= 4194304).toBe(true)
		local both = render(
			{ pct, mem },
			{ series = { { unit = "percent", placement = "left" }, { unit = "bytes", placement = "left" } } }
		)
		local b = both.layout.axes :: { any }
		expect(b[2].side).toBe("left")
		expect(b[2].x1).toBe(b[1].x0)
		expect(both.layout.plot_left).toBe(b[1].x1)
	end)

	it("draws an axis label rotated beside its axis (custom.axisLabel)", function()
		local r = render(
			{ pct, mem },
			{ series = { { unit = "percent", label = "busy" }, { unit = "bytes", label = "traffic" } } }
		)
		expect(r.svg).toContain('transform="rotate(-90 ')
		expect(r.svg).toContain('transform="rotate(90 ')
		expect(r.svg).toContain(">busy<")
		expect(r.svg).toContain(">traffic<")
		assertTernSafe(r.svg)
	end)

	-- UPlotScaleBuilder: a soft bound is a value the scale reaches at least.
	it("widens to soft min/max but never narrows the data's range", function()
		local data = { series(5, values({ 3, 97, 40, 12, 55 })) }
		local function axis(style: Svg.SeriesStyle): any
			return (render(data, { series = { style } }).layout.axes :: { any })[1]
		end
		expect(axis({ soft_max = 200 }).max).toBe(200)
		expect(axis({ soft_max = 50 }).max).toBe(100)
		expect(axis({ soft_min = -50 }).min).toBe(-50)
		expect(axis({ soft_min = 20 }).min).toBe(0)
		local centered = axis({ centered_zero = true })
		expect(centered.min).toBe(-100)
		expect(centered.max).toBe(100)
	end)

	-- getStackingGroups: the stack key holds the scale and stacking.group.
	it("stacks per scale and per stacking group", function()
		local ten, thirty, five =
			series(3, function()
				return 10
			end), series(3, function()
				return 30
			end), series(3, function()
				return 5
			end)
		local r = render({ ten, thirty, five }, {
			series = {
				{ unit = "a", stack = "normal" },
				{ unit = "a", stack = "normal" },
				{ unit = "b", stack = "normal" },
			},
		})
		local axes = r.layout.axes :: { any }
		expect(axes[1].max >= 40).toBe(true)
		expect(axes[2].max < 10).toBe(true)
		local groups = render({ ten, thirty }, {
			series = { { stack = "normal", stack_group = "A" }, { stack = "normal", stack_group = "B" } },
		})
		expect(groups.layout.y_max < 40).toBe(true)
	end)

	-- uPlot rangeLog with whole magnitudes, ticks at the powers of the base.
	it("draws log scales over whole magnitudes, decades equally spaced", function()
		local r = render(
			{ series(4, values({ 1, 10, 100, 1000 })) },
			{ series = { { distribution = { type = "log", log = 10 } } } }
		)
		local axis = (r.layout.axes :: { any })[1]
		expect(axis.distr).toBe("log")
		expect(axis.min).toBe(1)
		expect(axis.max).toBe(1000)
		local labels = tickTexts(r.svg, "end")
		for _, want in { "1", "10", "100", "1000" } do
			expect(table.find(labels, want) ~= nil).toBe(true)
		end
		local Layout = require("../../../plugin/lib/render/layout")
		local d1 = Layout.yOfValue(r.layout, 1) - Layout.yOfValue(r.layout, 10)
		local d2 = Layout.yOfValue(r.layout, 100) - Layout.yOfValue(r.layout, 1000)
		expect(math.abs(d1 - d2) < 0.01).toBe(true)
		-- A log scale cannot place 0: the line starts at the first positive.
		local gap = render(
			{ series(3, values({ 0, 10, 100 })) },
			{ series = { { distribution = { type = "log", log = 10 } } } }
		)
		local d = paths(gap.svg, "tg-line")[1]
		expect(subpaths(d)).toBe(1)
		expect(#ys(d)).toBe(2)
	end)

	it("draws symlog scales through zero with signed powers", function()
		local r = render(
			{ series(3, values({ -1000, 0, 1000 })) },
			{ series = { { distribution = { type = "symlog", log = 10, linear_threshold = 1 } } } }
		)
		local axis = (r.layout.axes :: { any })[1]
		expect(axis.distr).toBe("symlog")
		expect(axis.min).toBe(-1000)
		expect(axis.max).toBe(1000)
		local labels = tickTexts(r.svg, "end")
		expect(table.find(labels, "0") ~= nil).toBe(true)
		expect(table.find(labels, "1000") ~= nil).toBe(true)
		expect(table.find(labels, "-1000") ~= nil).toBe(true)
		local Layout = require("../../../plugin/lib/render/layout")
		local mid = (r.layout.plot_top + r.layout.plot_bottom) / 2
		expect(math.abs(Layout.yOfValue(r.layout, 0) - mid) < 0.01).toBe(true)
	end)

	it("stays under the 256 KiB cap with 10 x 5000 points on several scales", function()
		local frames = many(10, 5000)
		local styles: { Svg.SeriesStyle } = {}
		for i = 1, 10 do
			styles[i] = {
				unit = ({ "short", "bytes", "s" })[i % 3 + 1],
				stack = if i % 2 == 0 then "normal" else "none",
				transform = if i == 3 then "negative-Y" else nil,
				distribution = if i % 3 == 1 then { type = "log", log = 10 } else nil,
			}
		end
		for _, draw in { "line", "bars" } :: { Svg.Draw } do
			local r = render(frames, { series = styles, draw = draw, fill_opacity = 30 })
			expect(#r.svg <= Svg.CAP).toBe(true)
			expect(#(r.layout.axes :: { any }) >= 3).toBe(true)
			checkXml(r.svg)
		end
	end)
end)

-- preparePlotData2 (uPlot/utils.ts): negative-Y negates a series before
-- stacking; the Constant path builder (TimeSeries/utils.ts) draws the first
-- value from the range's start to its end. Tooltips and legends read the
-- field's own values, so the layout keeps them.
describe("svg_timeseries.render transforms", function()
	it("draws negative-Y series below zero with negative ticks, keeping their own values", function()
		local rx = series(4, values({ 10, 20, 40, 50 }))
		local tx = series(4, values({ 10, 20, 40, 50 }))
		local r = render({ rx, tx }, { series = { { unit = "Bps" }, { unit = "Bps", transform = "negative-Y" } } })
		expect(#(r.layout.axes :: { any })).toBe(1)
		expect(r.layout.y_min <= -50).toBe(true)
		expect(r.layout.y_max >= 50).toBe(true)
		local negative = 0
		for _, label in tickTexts(r.svg, "end") do
			if string.match(label, "^%-%d+ B/s$") then
				negative += 1
			end
		end
		expect(negative >= 2).toBe(true)
		local Layout = require("../../../plugin/lib/render/layout")
		local zero = Layout.yOfValue(r.layout, 0)
		for _, y in ys(paths(r.svg, "tg-s2")[1]) do
			expect(y > zero).toBe(true)
		end
		expect(r.layout.series[2].values[4]).toBe(50)
		expect(r.layout.series[2].calcs.max).toBe(50)
	end)

	-- A negated series stacks downwards in its own group (getStackDirection).
	it("stacks negative-Y series down, apart from the upward stack", function()
		local function flat(v: number): Frame.Frame
			return series(3, function()
				return v
			end)
		end
		local r = render({ flat(10), flat(30), flat(20) }, {
			series = {
				{ stack = "normal", transform = "negative-Y" } :: Svg.SeriesStyle,
				{ stack = "normal", transform = "negative-Y" } :: Svg.SeriesStyle,
				{ stack = "normal" } :: Svg.SeriesStyle,
			},
		})
		expect(r.layout.y_min <= -40).toBe(true)
		expect(r.layout.y_max >= 20 and r.layout.y_max < 40).toBe(true)
	end)

	it("draws a constant series as its first value across the time range", function()
		local r = render({
			series(4, values({ 1, 2, 3, 4 })),
			series(4, function(i)
				return ({ NULL, 7, 9, 3 } :: { any })[i]
			end),
		}, { from_ms = T0 - 60000, to_ms = T0 + 120000, series = { {}, { transform = "constant" } } })
		local d = paths(r.svg, "tg-s2")[1]
		expect(subpaths(d)).toBe(1)
		local Layout = require("../../../plugin/lib/render/layout")
		local y = string.format("%.1f", Layout.yOfValue(r.layout, 7))
		expect(d).toBe(string.format("M%.1f %sL%.1f %s", r.layout.plot_left, y, r.layout.plot_right, y))
	end)
end)
return nil
