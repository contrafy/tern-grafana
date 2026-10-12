--!strict
-- The histogram panel (HistogramPanel.tsx; grafana-data transformers/
-- histogram.ts buildHistogram, getHistogramFields, joinHistograms) on the
-- tern-all-panels histogram (panel 19: bucketCount 20, unit ms).
local Frame = require("../../../plugin/lib/frame/types")
local Histogram = require("../../../plugin/lib/panels/histogram")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local PANEL = [[{
	"id": 19, "type": "histogram", "title": "Histogram: latency distribution",
	"options": {"bucketCount": 20, "bucketOffset": 0, "combine": false,
		"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom", "calcs": []}},
	"fieldConfig": {"defaults": {"unit": "ms", "color": {"mode": "palette-classic"},
		"custom": {"fillOpacity": 80, "lineWidth": 1}}, "overrides": []}
}]]

-- A time series with the values 0..100 (step 1).
local function walk(name: string, from: number, to: number): Frame.Frame
	local times, values = {}, {}
	for v = from, to do
		table.insert(times, 1000 * v)
		table.insert(values, v)
	end
	return { name = name, fields = { Frame.field("Time", "time", times), Frame.field(name, "number", values) } }
end

describe("histogram", function()
	-- range 100 / 20 buckets = 5; the first size above that (and no smaller
	-- than the closest values, 1) is 10. 100 lands in its own bucket.
	it("picks Grafana's bucket size from bucketCount", function()
		local h = Histogram.histogram(S.json(PANEL), { walk("lat", 0, 100) }, env)
		assert(h, "histogram")
		expect(h.bucket_size).toBe(10)
		expect(#h.x_min).toBe(11)
		expect(h.x_min[1]).toBe(0)
		expect(h.x_max[1]).toBe(10)
		expect(h.counts[1].values[1]).toBe(10)
		expect(h.counts[1].values[11]).toBe(1)
		expect(h.x_unit).toBe("ms")
	end)

	it("honors bucketSize and bucketOffset", function()
		local panel = S.json(PANEL)
		panel.options.bucketSize = 25
		panel.options.bucketOffset = 5
		local h = Histogram.histogram(panel, { walk("lat", 0, 100) }, env)
		assert(h, "histogram")
		-- 0..4 fall in [-20, 5).
		expect(h.x_min[1]).toBe(-20)
		expect(h.counts[1].values[1]).toBe(5)
		expect(h.x_min[2]).toBe(5)
		expect(h.counts[1].values[2]).toBe(25)
	end)

	-- Several series share one bucket grid (missing buckets count 0);
	-- combine folds them into one "Count".
	it("aligns series on shared buckets and combines them on request", function()
		local f = { walk("a", 0, 9), walk("b", 50, 59) }
		local panel = S.json(PANEL)
		panel.options.bucketSize = 10
		local h = Histogram.histogram(panel, f, env)
		assert(h, "histogram")
		expect(#h.counts).toBe(2)
		expect(h.counts[1].values[1]).toBe(10)
		expect(h.counts[2].values[1]).toBe(0)
		panel.options.combine = true
		local c = Histogram.histogram(panel, f, env)
		assert(c, "combined")
		expect(#c.counts).toBe(1)
		expect(c.counts[1].name).toBe("Count")
		expect(c.counts[1].values[2]).toBe(10)
	end)

	-- A single frame with explicit buckets is drawn as it is.
	it("draws pre-bucketed xMin/xMax frames as given", function()
		local f: { Frame.Frame } = {
			{
				fields = {
					Frame.field("xMin", "number", { 0, 1, 2 }),
					Frame.field("xMax", "number", { 1, 2, 3 }),
					Frame.field("count", "number", { 4, 9, 2 }),
				},
			},
		}
		local h = Histogram.histogram(S.json(PANEL), f, env)
		assert(h, "histogram")
		expect(h.bucket_size).toBeNil()
		expect(h.counts[1].values[2]).toBe(9)
		-- xMax alone: xMin is guessed one bucket below.
		local g: { Frame.Frame } = {
			{ fields = { Frame.field("xMax", "number", { 10, 20 }), Frame.field("count", "number", { 1, 2 }) } },
		}
		local h2 = Histogram.histogram(S.json(PANEL), g, env)
		assert(h2, "histogram")
		expect(h2.x_min[1]).toBe(0)
	end)

	it("renders bucket bars with the source unit on the x axis", function()
		local node, assets = Histogram.view(S.json(PANEL), { walk("lat", 0, 100) }, env, {
			key = "h",
			size = { w = 600, h = 300 },
		})
		local svg = (assets :: any).h.bytes
		expect(string.find(svg, 'class="tg-s1 tg-bar"', 1, true) ~= nil).toBe(true)
		expect(string.find(svg, 'class="tg-s1 tg-line"', 1, true) ~= nil).toBe(true)
		expect(string.find(svg, " ms<", 1, true) ~= nil).toBe(true)
		expect(#svg <= 262144).toBe(true)
		expect(S.text(S.find(node, function(n)
			return n.p and n.p.role == "tern-grafana.legend"
		end))).toBe("lat")
	end)

	it("nulls count as the field's numeric noValue", function()
		local panel = S.json(PANEL)
		panel.fieldConfig.defaults.noValue = "0"
		panel.options.bucketSize = 10
		local f: { Frame.Frame } = {
			{
				fields = {
					Frame.field("Time", "time", { 1, 2, 3 }),
					Frame.field("v", "number", { 15, Frame.NULL, 16 }),
				},
			},
		}
		local h = Histogram.histogram(panel, f, env)
		assert(h, "histogram")
		expect(h.x_min[1]).toBe(0)
		expect(h.counts[1].values[1]).toBe(1)
		expect(h.counts[1].values[2]).toBe(2)
	end)
end)

return nil
