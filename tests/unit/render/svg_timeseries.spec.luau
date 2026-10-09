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

return nil
