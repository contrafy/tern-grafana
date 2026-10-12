--!strict
-- The heatmap panel (heatmap/fields.ts prepareHeatmapData, utils.ts,
-- palettes.ts; calculateHeatmap/heatmap.ts; grafana-prometheus
-- result_transformer.ts) on tern-all-panels panel 23: a Prometheus
-- `format: heatmap` query of span latency buckets, Oranges scheme, unit s.
local ColorScheme = require("../../../plugin/lib/render/color_scheme")
local Frame = require("../../../plugin/lib/frame/types")
local Heatmap = require("../../../plugin/lib/panels/heatmap")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local function allPanels(version: string, id: number): any
	local doc = S.decode("grafana/" .. version .. "/dashboard_tern_all_panels.json")
	for _, p in doc.dashboard.panels do
		if p.id == id then
			return p
		end
	end
	error("no panel " .. id)
end

local function range(version: string, id: number): { from_ms: number, to_ms: number }
	local r = S.decode("grafana/" .. version .. "/ds_query_all_panels_" .. id .. ".request.json")
	return { from_ms = tonumber(r.from) :: number, to_ms = tonumber(r.to) :: number }
end

for _, version in S.VERSIONS do
	describe("heatmap " .. version, function()
		-- The Prometheus frontend sorts the cumulative `le` series and
		-- subtracts each from the next; the panel then draws ordinal
		-- buckets labeled in the y axis unit, "0 s" under the first.
		it("de-accumulates Prometheus le buckets into ordinal rows", function()
			local frames = S.frames(version, "all_panels_23")
			local d = Heatmap.dense(allPanels(version, 23), frames, env)
			assert(d, "dense")
			expect(d.warning).toBeNil()
			expect(d.y_kind).toBe("ordinal")
			expect(d.y_layout).toBe("le")
			local labels = d.y_labels :: { string }
			expect(#labels).toBe(#frames)
			expect(labels[1]).toBe("2 ms")
			expect(labels[#labels]).toBe("+Inf")
			expect(d.y_min_label).toBe("0 s")
			-- Per column the buckets add up to the +Inf (total) series.
			local inf: Frame.Frame? = nil
			for _, f in frames do
				local fl = f.fields[2].labels
				if fl and fl.le == "+Inf" then
					inf = f
				end
			end
			assert(inf, "+Inf series")
			local total = (inf :: Frame.Frame).fields[2].values
			local n = #labels
			local checked = 0
			for c = 1, #d.cols do
				local sum = 0
				for r = 1, n do
					local v = d.counts[(c - 1) * n + r]
					expect(v >= 0).toBe(true)
					sum += v
				end
				if type(total[c]) == "number" and total[c] > 0 then
					expect(math.abs(sum - total[c]) < 1e-6).toBe(true)
					checked += 1
				end
			end
			expect(checked > 0).toBe(true)
		end)

		it("draws filled cells, bucket labels and the color scale", function()
			local _, assets = Heatmap.view(allPanels(version, 23), S.frames(version, "all_panels_23"), env, {
				key = "hm",
				size = { w = 1000, h = 460 },
				time = range(version, 23),
			})
			local svg = (assets :: any).hm.bytes
			expect(#svg <= 262144).toBe(true)
			expect(string.find(svg, ">+Inf<", 1, true) ~= nil).toBe(true)
			expect(string.find(svg, ">0 s<", 1, true) ~= nil).toBe(true)
			expect(string.find(svg, '<path fill="#', 1, true) ~= nil).toBe(true)
			-- The scale bar runs dark to light (Oranges inverts on dark).
			expect(string.find(svg, 'fill="#7f2704"/>', 1, true) ~= nil).toBe(true)
		end)
	end)
end

describe("heatmap colors", function()
	-- quantizeScheme: Oranges inverts on dark themes, reverse flips again.
	it("quantizes schemes and inverts them per theme", function()
		local dark = ColorScheme.palette({ scheme = "Oranges", steps = 5 }, true)
		expect(#dark).toBe(5)
		expect(dark[1]).toBe("#7f2704")
		expect(dark[5]).toBe("#fff5eb")
		local light = ColorScheme.palette({ scheme = "Oranges", steps = 5 }, false)
		expect(light[1]).toBe("#fff5eb")
		local rev = ColorScheme.palette({ scheme = "Oranges", steps = 5, reverse = true }, true)
		expect(rev[1]).toBe("#fff5eb")
	end)

	-- d3-scale-chromatic 3.1 values at t = 0, .25, .5, .75, 1.
	it("matches the d3 interpolators", function()
		local oracle: { [string]: { string } } = {
			Turbo = { "#23171b", "#26bce1", "#95fb51", "#ff821d", "#900c00" },
			Cividis = { "#002051", "#3c4d6e", "#7f7c75", "#bbaf71", "#fdea45" },
			Viridis = { "#440154", "#3b528b", "#21918c", "#5ec962", "#fde725" },
			Magma = { "#000004", "#51127c", "#b73779", "#fc8961", "#fcfdbf" },
			Warm = { "#6e40aa", "#d23ea7", "#ff5e63", "#efa72f", "#aff05b" },
			Cool = { "#6e40aa", "#417de0", "#1ac7c2", "#40f373", "#aff05b" },
			Cubehelix = { "#000000", "#16534c", "#a07949", "#c7b3ed", "#ffffff" },
			Rainbow = { "#6e40aa", "#ff5e63", "#aff05b", "#1ac7c2", "#6e40aa" },
			Sinebow = { "#ff4040", "#7fee11", "#00bfbf", "#7f11ee", "#ff4040" },
			Spectral = { "#9e0142", "#f88e53", "#fbf8b0", "#89cfa5", "#5e4fa2" },
			Oranges = { "#fff5eb", "#fdcea0", "#fb8d3d", "#d54b04", "#7f2704" },
			YlOrRd = { "#ffffcc", "#fed676", "#fd893c", "#e11e20", "#800026" },
		}
		for name, want in oracle do
			local fn = ColorScheme.interpolator(name)
			assert(fn, name)
			for i, w in want do
				expect(name .. " " .. (fn :: any)((i - 1) / 4)).toBe(name .. " " .. w)
			end
		end
	end)

	-- valuesToFills and boundedMinMax: filtered values do not stretch the
	-- range; out of range values take the end colors.
	it("maps counts onto the palette within the filtered range", function()
		local lo, hi = Heatmap.bounds({ 0, 2, 4, 10 }, nil, nil, 1e-9, math.huge)
		expect(lo).toBe(2)
		expect(hi).toBe(10)
		expect(Heatmap.fill(2, 64, lo, hi)).toBe(1)
		expect(Heatmap.fill(10, 64, lo, hi)).toBe(64)
		expect(Heatmap.fill(6, 64, lo, hi)).toBe(33)
	end)
end)

describe("heatmap calculate", function()
	-- calculateHeatmapFromData: x buckets of the given duration across the
	-- panel range, y buckets of the given size, counts of raw samples.
	it("buckets raw series by size", function()
		local panel = S.json(
			[[{"type": "heatmap", "options": {"calculate": true,
			"calculation": {"xBuckets": {"mode": "size", "value": "1m"}, "yBuckets": {"mode": "size", "value": "10"}}}}]]
		)
		local times, values = {}, {}
		for i = 0, 119 do
			table.insert(times, i * 1000)
			table.insert(values, i % 30)
		end
		local f: { Frame.Frame } = {
			{ fields = { Frame.field("Time", "time", times), Frame.field("v", "number", values) } },
		}
		local d = Heatmap.dense(panel, f, env, 0, 119000)
		assert(d, "dense")
		expect(#d.cols).toBe(2)
		expect(#d.rows).toBe(3)
		expect(d.rows[1][1]).toBe(0)
		expect(d.rows[1][2]).toBe(10)
		-- Each minute holds every value 0..29 twice: 20 per 10-wide bucket.
		expect(d.counts[1]).toBe(20)
		expect(d.counts[6]).toBe(20)
	end)

	it("uses log buckets with a split", function()
		local panel = S.json([[{"type": "heatmap", "options": {"calculate": true,
			"calculation": {"xBuckets": {"mode": "size", "value": "1m"},
				"yBuckets": {"mode": "size", "value": "1", "scale": {"type": "log", "log": 2}}}}}]])
		local f: { Frame.Frame } = {
			{ fields = { Frame.field("Time", "time", { 0, 1000, 2000 }), Frame.field("v", "number", { 1, 3, 8 }) } },
		}
		local d = Heatmap.dense(panel, f, env, 0, 59000)
		assert(d, "dense")
		expect(d.y_kind).toBe("log")
		expect(#d.rows).toBe(4)
		expect(d.rows[2][1]).toBe(2)
		expect(d.counts[2]).toBe(1)
		expect(d.counts[4]).toBe(1)
	end)
end)

return nil
