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

-- Path data with every vertex accumulated to absolute coordinates, written
-- one command per segment as "%.1f" absolute path data ("M1.0 2.0L3.0
-- 4.0H5.0Z"). The renderer writes relative segments between vertices
-- rounded to 0.1 px, so the sums are kept in whole tenths: exact, no drift.
local ARGS = { M = 2, L = 2, H = 1, V = 1, C = 6, Z = 0 }
local function absolute(d: string): string
	local tokens: { any } = {}
	local i = 1
	while i <= #d do
		local c = string.sub(d, i, i)
		if string.match(c, "%a") then
			table.insert(tokens, c)
			i += 1
		elseif c == " " then
			i += 1
		else
			local s, e = string.find(d, "^%-?%d*%.?%d+", i)
			assert(s and e, "bad path number in " .. d)
			table.insert(tokens, math.floor((tonumber(string.sub(d, s, e)) :: number) * 10 + 0.5))
			i = e + 1
		end
	end
	local out: { string } = {}
	local function put(cmd: string, ...: number)
		local parts: { string } = {}
		for k, v in { ... } do
			parts[k] = string.format("%.1f", v / 10)
		end
		table.insert(out, cmd .. table.concat(parts, " "))
	end
	local x, y, sx, sy = 0, 0, 0, 0
	local cmd = "M"
	i = 1
	while i <= #tokens do
		if type(tokens[i]) == "string" then
			cmd = tokens[i]
			i += 1
			if string.upper(cmd) == "Z" then
				table.insert(out, "Z")
				x, y = sx, sy
				continue
			end
		end
		local up = string.upper(cmd)
		local ox, oy = if cmd == up then 0 else x, if cmd == up then 0 else y
		local a: { number } = table.move(tokens, i, i + ARGS[up] - 1, 1, {})
		i += ARGS[up]
		if up == "M" or up == "L" then
			x, y = ox + a[1], oy + a[2]
			put(up, x, y)
			if up == "M" then
				sx, sy = x, y
				cmd = if cmd == "m" then "l" else "L"
			end
		elseif up == "H" then
			x = ox + a[1]
			put("H", x)
		elseif up == "V" then
			y = oy + a[1]
			put("V", y)
		else
			put("C", ox + a[1], oy + a[2], ox + a[3], oy + a[4], ox + a[5], oy + a[6])
			x, y = ox + a[5], oy + a[6]
		end
	end
	return table.concat(out)
end

local function subpaths(d: string): number
	local _, n = string.gsub(absolute(d), "M", "")
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

	-- Each series is a line plus its points: uPlot shows points (auto) when
	-- samples are at least two point sizes apart, as 20 samples are here.
	it("gives series 1..n the palette classes tg-s1..tg-sn", function()
		local r = Svg.render(many(3, 20))
		expect(#paths(r.svg, "tg-s1")).toBe(2)
		expect(#paths(r.svg, "tg-s2")).toBe(2)
		expect(#paths(r.svg, "tg-s3")).toBe(2)
		expect(#paths(r.svg, "tg-s4")).toBe(0)
		expect(#paths(r.svg, "tg-line")).toBe(3)
		expect(#paths(r.svg, "tg-dots")).toBe(3)
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
		expect(#paths(r.svg, "tg-s10")).toBe(2)
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

-- Path data is relative (each vertex a delta from the previous one, rounded
-- positions only) to stay far under Tern's 256 KiB cap; the picture must not
-- move: every vertex lands exactly where its absolute "%.1f" position is.
describe("svg_timeseries.render path data", function()
	local Layout = require("../../../plugin/lib/render/layout")
	local render = (Svg.render :: any) :: (frames: { Frame.Frame }, options: any) -> Svg.Result
	local function at(r: Svg.Result, time: number, v: number): string
		local l = r.layout
		local x = math.clamp(Layout.xOfTime(l, time), l.plot_left, l.plot_right)
		local y = math.clamp(Layout.yOfValue(l, v), l.plot_top, l.plot_bottom)
		return string.format("%.1f %.1f", x, y)
	end
	local gappy = series(300, function(i)
		if i == 40 or (i >= 100 and i <= 120) or i == 199 or i == 201 then
			return NULL
		end
		return 1000 + 400 * math.sin(i / 13) + (i * 7919 % 13) * 3.37
	end)

	it("puts every line vertex and every lone dot at its absolute position", function()
		local r = render({ gappy }, { series = { { show_points = "auto" } } })
		local s = r.layout.series[1]
		local line: { string } = {}
		local dots: { string } = {}
		local run = 0
		for k, time in s.times do
			local v = Frame.finite(s.values[k])
			if v then
				local p = at(r, time, v)
				table.insert(line, (if run == 0 then "M" else "L") .. p)
				run += 1
			else
				if run == 1 then
					local p = string.match(line[#line], "^M(%S+)") :: string
					table.insert(line, "H" .. p)
					table.insert(dots, line[#line - 1] .. "H" .. p)
				end
				run = 0
			end
		end
		expect(absolute(paths(r.svg, "tg-line")[1])).toBe(table.concat(line))
		expect(absolute(paths(r.svg, "tg-dots")[1])).toBe(table.concat(dots))
	end)

	it("puts every smoothed and stepped vertex where absolute coordinates put it", function()
		for _, interp in { "stepAfter", "smooth" } do
			local r = render({ gappy }, { series = { { interpolation = interp } } })
			local s = r.layout.series[1]
			local d = absolute(paths(r.svg, "tg-line")[1])
			-- Each sample is a segment end: "H x V y" (stepAfter) or the last
			-- pair of a "C" (smooth), after the run's "M x y".
			local ends: { string } = {}
			for x, y in string.gmatch(d, "([%d%.]+)V([%d%.]+)") do
				table.insert(ends, (x :: string) .. " " .. (y :: string))
			end
			for x, y in string.gmatch(d, "C[%d%.]+ [%d%.]+ [%d%.]+ [%d%.]+ ([%d%.]+) ([%d%.]+)") do
				table.insert(ends, (x :: string) .. " " .. (y :: string))
			end
			local want: { string } = {}
			local run = 0
			for k, time in s.times do
				local v = Frame.finite(s.values[k])
				if v and run > 0 then
					table.insert(want, at(r, time, v))
				end
				run = if v then run + 1 else 0
			end
			expect(ends).toEqual(want)
		end
	end)
end)

describe("svg_timeseries.render scales", function()
	-- uPlot 1.6.32 rangeNum as UPlotScaleBuilder configures it (pad 0.1,
	-- soft 0 in mode 3): 3..97 pads to -6.4..106.4, rounds out to a tenth of
	-- the span's magnitude (-7..107), and the low end snaps to 0 because the
	-- padding crossed it. Ticks stay on nice steps inside: the top tick is
	-- 100, with headroom above it.
	it("pads the y axis above the data as uPlot's rangeNum does", function()
		local r = Svg.render({ series(5, function(i)
			return ({ 3, 97, 40, 12, 55 })[i]
		end) })
		expect(r.layout.y_min).toBe(0)
		expect(r.layout.y_max).toBe(107)
		local axis = (r.layout.axes :: { any })[1]
		expect(axis.max).toBe(107)
		expect(r.svg).toContain(">100<")
		expect(has(r.svg, ">110<")).toBe(false)
	end)

	-- The triangle 0,2,..,10,..,0: rangeNum pads 10 by 1 to 11, as
	-- Grafana's 0..11 axis. Whether 11 gets a label is the tick spacing
	-- (calculateSpace: 30 px, 15 px up to 150 px plots): a plot as tall as
	-- Grafana's 1000x500 render labels every unit to 11, a ~200 px one
	-- steps by 2 and labels 10 last, keeping the headroom.
	it("ranges a 0..10 series to 0..11 and labels ticks by plot height", function()
		local tri = series(11, function(i)
			return ({ 0, 2, 4, 6, 8, 10, 8, 6, 4, 2, 0 })[i]
		end)
		local function labels(height: number): { string }
			local r = Svg.render({ tri }, { width = 1000, height = height })
			expect(r.layout.y_min).toBe(0)
			expect(r.layout.y_max).toBe(11)
			local out: { string } = {}
			for text in string.gmatch(r.svg, 'text%-anchor="end">([^<]*)<') do
				table.insert(out, text)
			end
			return out
		end
		expect(labels(410)).toEqual({ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11" })
		expect(labels(230)).toEqual({ "0", "2", "4", "6", "8", "10" })
	end)

	-- rangeNum on flat 0 data (delta 1e-24) snaps both ends to the soft 0,
	-- and an empty range becomes 0..100: the line lies on the floor.
	it("puts an all-zero series on the floor of a 0..100 axis", function()
		local r = Svg.render({ series(5, function()
			return 0
		end) })
		expect(r.layout.y_min).toBe(0)
		expect(r.layout.y_max).toBe(100)
		local Layout = require("../../../plugin/lib/render/layout")
		expect(Layout.yOfValue(r.layout, 0)).toBe(r.layout.plot_bottom)
	end)

	-- UPlotScaleBuilder: decimals 0 rounds the padded range to whole numbers.
	-- 1.2..4.2 pads by 0.3 to 0.9..4.5 (a tenth of the span's magnitude).
	it("rounds the range out to whole numbers with decimals 0", function()
		local data = { series(3, function(i)
			return ({ 1.2, 4.2, 3 })[i]
		end) }
		local free = Svg.render(data)
		expect(free.layout.y_min).toBe(0.9)
		expect(free.layout.y_max).toBe(4.5)
		local r = Svg.render(data, { decimals = 0 })
		expect(r.layout.y_min).toBe(0)
		expect(r.layout.y_max).toBe(5)
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
			local onBase = has(absolute(d[1]), " " .. baseline .. "V")
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
	for _, y in string.gmatch(absolute(d), "([%d%.%-]+) ([%d%.%-]+)") do
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
		-- Each scale fits its own data: 4 MiB is not squeezed onto 0..104
		-- (10..95 padded by 8.5 rounds out to 1..104).
		expect(axes[1].max).toBe(104)
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

	-- UPlotScaleBuilder: a set soft bound is a mode-1 soft value: the scale
	-- ends exactly there while the data stay inside it, else uPlot's padded
	-- range (3..97 pads to -7..107, without the 0 snap a soft bound replaces).
	it("ends at soft min/max that hold the data, pads past ones that do not", function()
		local data = { series(5, values({ 3, 97, 40, 12, 55 })) }
		local function axis(style: Svg.SeriesStyle): any
			return (render(data, { series = { style } }).layout.axes :: { any })[1]
		end
		expect(axis({ soft_max = 200 }).max).toBe(200)
		expect(axis({ soft_max = 50 }).max).toBe(107)
		expect(axis({ soft_min = -50 }).min).toBe(-50)
		expect(axis({ soft_min = 20 }).min).toBe(-7)
		-- Centered zero: -97..97 padded by 19.4 rounds out to -120..120.
		local centered = axis({ centered_zero = true })
		expect(centered.min).toBe(-120)
		expect(centered.max).toBe(120)
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
		expect(absolute(d)).toBe(string.format("M%.1f %sL%.1f %s", r.layout.plot_left, y, r.layout.plot_right, y))
	end)
end)

-- The `<path>` element (whole tag) of the first path whose class list has
-- every class given.
local function tag(svg: string, ...: string): string?
	local want = { ... }
	for el in string.gmatch(svg, "<path [^>]*>") do
		local classes = string.match(el, 'class="([^"]*)"') or ""
		local ok = true
		for _, c in want do
			if not string.find(" " .. classes .. " ", " " .. c .. " ", 1, true) then
				ok = false
				break
			end
		end
		if ok then
			return el
		end
	end
	return nil
end

-- Each series is drawn with its own GraphFieldConfig
-- (packages/grafana-ui/src/components/uPlot/config/UPlotSeriesBuilder.ts):
-- an override that turns one series' fill off and dashes it must not leave
-- it solid and filled like the others.
describe("svg_timeseries.render per-series look (UPlotSeriesBuilder.ts)", function()
	local a = series(40, function(i)
		return 10 + i % 7
	end)
	local b = series(40, function(i)
		return 30 + i % 5
	end)

	it("draws each series' fill, line width and dash", function()
		local r = render({ a, b }, {
			series = {
				{ fill_opacity = 30, line_width = 1 },
				{ fill_opacity = 0, line_width = 2, dash = { 10, 10 } },
			},
		})
		expect(tag(r.svg, "tg-s1", "tg-area")).toContain('fill-opacity="0.30"')
		expect(tag(r.svg, "tg-s2", "tg-area")).toBeNil()
		local line2 = tag(r.svg, "tg-s2", "tg-line") :: string
		expect(line2).toContain('stroke-width="3"')
		expect(line2).toContain('stroke-dasharray="15 15"')
		expect(line2).toContain('stroke-linecap="butt"')
		local line1 = tag(r.svg, "tg-s1", "tg-line") :: string
		expect(line1).toContain('stroke-width="1.5"')
		expect(has(line1, "dasharray")).toBe(false)
		-- A dotted line rounds its caps; lineWidth 0 draws no line at all.
		local dotted = render({ a, b }, {
			series = { { dash = { 0, 10 }, dot = true } :: Svg.SeriesStyle, { line_width = 0 } :: Svg.SeriesStyle },
		})
		expect(tag(dotted.svg, "tg-s1", "tg-line")).toContain('stroke-linecap="round"')
		expect(tag(dotted.svg, "tg-s2", "tg-line")).toBeNil()
	end)

	-- uPlot's stepped and spline path builders.
	it("steps or smooths the line by lineInterpolation", function()
		local r = render({ a, b }, { series = { { interpolation = "stepAfter" }, { interpolation = "smooth" } } })
		local step = absolute(string.match(tag(r.svg, "tg-s1", "tg-line") :: string, ' d="([^"]*)"') :: string)
		expect(step).toContain("H")
		expect(has(step, "C")).toBe(false)
		local smooth = absolute(string.match(tag(r.svg, "tg-s2", "tg-line") :: string, ' d="([^"]*)"') :: string)
		expect(smooth).toContain("C")
		-- stepAfter holds a value to the next sample: the first move is
		-- horizontal (H), stepBefore's is vertical (V).
		local before = render({ a }, { series = { { interpolation = "stepBefore" } } })
		local d = absolute(string.match(tag(before.svg, "tg-s1", "tg-line") :: string, ' d="([^"]*)"') :: string)
		expect(string.match(d, "^M[%d%.]+ [%d%.]+(%a)")).toBe("V")
		expect(string.match(step, "^M[%d%.]+ [%d%.]+(%a)")).toBe("H")
	end)

	-- showPoints: always and never as set; auto shows points when samples
	-- are at least two point sizes apart (uPlot seriesPointsShow, space =
	-- 2 x size), else only lone samples between gaps (Grafana's filter).
	it("shows points always, never, or by density", function()
		expect(tag(render({ a }, { series = { { show_points = "never" } } }).svg, "tg-dots")).toBeNil()
		local always = tag(render(many(1, 2000), { series = { { show_points = "always" } } }).svg, "tg-dots")
		expect(always).toContain('stroke-width="7.5"')
		expect(tag(render({ a }, { series = { { show_points = "auto" } } }).svg, "tg-dots") ~= nil).toBe(true)
		expect(tag(render(many(1, 2000), { series = { {} } }).svg, "tg-dots")).toBeNil()
		local gappy = series(2000, function(i)
			return if i == 1000 then 5 elseif i > 990 and i < 1010 then NULL else 1
		end)
		local lone = tag(render({ gappy }, { series = { {} } }).svg, "tg-dots") :: string
		expect(subpaths(string.match(lone, ' d="([^"]*)"') :: string)).toBe(1)
		local bigger = tag(render({ a }, { series = { { show_points = "always", point_size = 10 } } }).svg, "tg-dots")
		expect(bigger).toContain('stroke-width="15"')
	end)

	-- spanNulls true joins every gap; a number joins gaps up to that many
	-- ms only (Grafana leaves longer ones broken).
	it("joins gaps by spanNulls, up to a threshold when it is a number", function()
		local holes = series(30, function(i)
			if i == 5 then
				return NULL
			elseif i >= 15 and i <= 20 then
				return NULL
			end
			return i
		end)
		local function runs(style: Svg.SeriesStyle): number
			local d =
				string.match(tag(render({ holes }, { series = { style } }).svg, "tg-line") :: string, ' d="([^"]*)"')
			return subpaths(d :: string)
		end
		expect(runs({ span_nulls = false })).toBe(3)
		expect(runs({ span_nulls = true })).toBe(1)
		-- One missing sample is a 30 s gap, six are 105 s.
		expect(runs({ span_nulls = 60000 })).toBe(2)
	end)

	-- fillBelowTo (TimeSeries/utils.ts): the fill runs down to the other
	-- series, at 35% when no fillOpacity is set.
	it("fills down to the fillBelowTo series", function()
		local r = render({ b, a }, { series = { { fill_below = 2 } :: Svg.SeriesStyle, {} :: Svg.SeriesStyle } })
		local area = tag(r.svg, "tg-s1", "tg-area") :: string
		expect(area).toContain('fill-opacity="0.35"')
		local Layout = require("../../../plugin/lib/render/layout")
		local zero = Layout.yOfValue(r.layout, 0)
		for _, y in ys(string.match(area, ' d="([^"]*)"') :: string) do
			expect(y < zero - 1).toBe(true)
		end
		expect(tag(r.svg, "tg-s2", "tg-area")).toBeNil()
	end)

	-- getOpacityGradientFn: the fill fades to nothing at the plot's bottom.
	it("fades an opacity-gradient fill through a mask", function()
		local r = render({ a }, { series = { { fill_opacity = 50, gradient = "opacity" } } })
		assertTernSafe(r.svg)
		local area = tag(r.svg, "tg-s1", "tg-area") :: string
		local id = string.match(area, 'mask="url%(#([^)]+)%)"')
		assert(id, "masked area")
		expect(r.svg).toContain('<mask id="' .. id .. '">')
		expect(r.svg).toContain('stop-opacity="0"')
		expect(has(render({ a }, { series = { { fill_opacity = 50 } } }).svg, "<mask")).toBe(false)
	end)

	-- scaleGradient (gradientFills.ts): the stops between the one at or
	-- below the scale's min and the first at or above its max, placed at
	-- their values; relative stops spread over the soft range when set.
	describe("scheme gradients", function()
		local five = series(5, function(i)
			return i
		end)
		local function gradient(r: any): (string, { number }, { string })
			local line = tag(r.svg, "tg-line") :: string
			local id = string.match(line, 'stroke="url%(#([^)]+)%)"') :: string
			local def = string.match(r.svg, '<linearGradient id="' .. id .. '"[^>]*>.-</linearGradient>') :: string
			local offsets: { number }, classes: { string } = {}, {}
			for o, c in string.gmatch(def, '<stop offset="([^"]+)" class="([^"]+)"') do
				table.insert(offsets, tonumber(o) :: number)
				table.insert(classes, c :: string)
			end
			return line, offsets, classes
		end

		it("paints a series wholly in the step at or below the scale's min", function()
			local r = render({ five }, {
				series = {
					{
						gradient = "scheme",
						scheme = {
							stops = {
								{ at = -math.huge, class = "tg-gt-success" },
								{ at = -10, class = "tg-gt-error" },
							},
							relative = false,
							discrete = true,
						},
					},
				},
			})
			assertTernSafe(r.svg)
			local line, offsets, classes = gradient(r)
			expect(classes).toEqual({ "tg-gt-error" })
			expect(offsets).toEqual({ 0 })
			-- The gradient, not the palette class, colors the line.
			expect((string.find(line, "tg-s1", 1, true))).toBeNil()
		end)

		it("spreads relative stops over the soft range", function()
			local r = render({ five }, {
				series = {
					{
						soft_min = 0,
						soft_max = 10,
						gradient = "scheme",
						scheme = {
							stops = {
								{ at = 0, class = "tg-gc1" },
								{ at = 0.5, class = "tg-gc2" },
								{ at = 1, class = "tg-gc3" },
							},
							relative = true,
							discrete = false,
						},
					},
				},
			})
			local _, offsets, classes = gradient(r)
			expect(classes).toEqual({ "tg-gc1", "tg-gc2", "tg-gc3" })
			expect(offsets).toEqual({ 0, 0.5, 1 })
		end)
	end)

	-- Bars: barWidthFactor of the slot, barAlignment -1/0/1 around the time,
	-- outlined with the line width, filled by fillOpacity; bars at the plot
	-- edges are cut to it (uPlot clips the plot).
	it("sizes and aligns bars per series", function()
		local five = series(5, function(i)
			return i
		end)
		-- x and width of the third (middle) bar.
		local function midX(style: Svg.SeriesStyle): (number, number)
			local r = render({ five }, { series = { style } })
			local d = absolute(string.match(tag(r.svg, "tg-line") :: string, ' d="([^"]*)"') :: string)
			local Layout = require("../../../plugin/lib/render/layout")
			local top = string.format("%.1f", Layout.yOfValue(r.layout, 3))
			for bx, y, right in string.gmatch(d, "M([%d%.]+) [%d%.]+V([%d%.]+)H([%d%.]+)") do
				if y == top then
					local x10 = math.floor((tonumber(bx) :: number) * 10 + 0.5)
					local r10 = math.floor((tonumber(right) :: number) * 10 + 0.5)
					return x10 / 10, (r10 - x10) / 10
				end
			end
			error("no bar for 3")
		end
		local cx, cw = midX({ draw = "bars", fill_opacity = 50 })
		local ax, aw = midX({ draw = "bars", bar_alignment = 1 })
		local bx = midX({ draw = "bars", bar_alignment = -1 })
		expect(math.abs(ax - (cx + cw / 2)) < 0.2).toBe(true)
		expect(math.abs(bx - (cx - cw / 2)) < 0.2).toBe(true)
		expect(aw).toBe(cw)
		local _, narrow = midX({ draw = "bars", bar_width_factor = 0.3 })
		expect(math.abs(narrow - cw / 2) < 0.2).toBe(true)
		local r = render({ five }, { series = { { draw = "bars" } } })
		local first = tonumber(string.match(tag(r.svg, "tg-line") :: string, ' d="M([%d%.]+)')) :: number
		expect(first).toBe(r.layout.plot_left)
		local filled = render({ five }, { series = { { draw = "bars", fill_opacity = 50 } } })
		expect(tag(filled.svg, "tg-bar")).toContain('fill-opacity="0.50"')
		expect(tag(render({ five }, { series = { { draw = "bars" } } }).svg, "tg-bar")).toBeNil()
	end)
end)
-- Recorded on dashboard tern-v08-tsbar (Grafana 13.3.0): SQL rows long
-- before the range and a monthly series whose first month precedes it.
describe("svg_timeseries.render samples beyond the range", function()
	local Fixtures = require("../../lib/fixtures")
	local Grafana = require("../../../plugin/lib/frame/grafana")
	local Support = require("../../lib/support")
	local json = require("../../lib/json")

	local function load(n: number): ({ Frame.Frame }, number, number)
		local base = "grafana/13.3.0/ds_query_v08_tsbar_" .. n
		local env = Support.env()
		local req = json.decode(Fixtures.read(base .. ".request.json"))
		local out: { Frame.Frame } = {}
		for _, r in Grafana.parseResults(json.decode(Fixtures.read(base .. ".json")), env) do
			assert(r.ok, "fixture query failed")
			for _, f in r.frames do
				table.insert(out, f)
			end
		end
		return out, tonumber(req.from) :: number, tonumber(req.to) :: number
	end

	it("ranges y over the samples in view, as uPlot does", function()
		local frames, from, to = load(1)
		local r = Svg.render(frames, { from_ms = from, to_ms = to, width = 1000, height = 400 })
		-- Grafana: 3.259 .. 3.271; the value 5 of rows years before stays out.
		expect(r.layout.y_min).toBe(3.259)
		expect(r.layout.y_max).toBe(3.271)
	end)

	it("enters the plot at the step a sample before the range holds", function()
		local frames, from, to = load(3)
		local style: Svg.SeriesStyle = { interpolation = "stepBefore", unit = "s" }
		local opts: Svg.Options = {
			from_ms = from,
			to_ms = to,
			width = 1000,
			height = 400,
			series = { style },
		}
		local r = Svg.render(frames, opts)
		local left = r.layout.plot_left
		local line = string.match(r.svg, 'class="tg%-s1 tg%-line"[^>]-d="([^"]+)"') :: string
		local x, y = string.match(line, "^M([%d%.]+) ([%d%.]+)")
		-- The line starts at the plot's left edge at the September value
		-- (stepBefore takes the next sample's value), not at August's.
		expect(tonumber(x)).toBe(math.floor(left * 10 + 0.5) / 10)
		local g = r.layout
		local want = g.plot_bottom - (60120 - g.y_min) / (g.y_max - g.y_min) * (g.plot_bottom - g.plot_top)
		expect(math.abs((tonumber(y) :: number) - want) < 0.1).toBe(true)
	end)
end)

return nil
