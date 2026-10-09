--!strict
-- Moving the cursor must only move the overlay: the image keeps the same
-- asset bytes (so no new blob), and the overlay sits where the SVG drew
-- that time.
local t = require("../../lib/test")
local Assets = require("../../../plugin/lib/render/assets")
local ChartView = require("../../../plugin/lib/render/chart_view")
local Cursor = require("../../../plugin/lib/render/cursor")
local Frame = require("../../../plugin/lib/frame/types")
local Svg = require("../../../plugin/lib/render/svg_timeseries")
local describe, it, expect = t.describe, t.it, t.expect

local function result(): Svg.Result
	return Svg.render({ Frame.timeSeries({ job = "a" }, { 0, 10, 20 }, { 1, 2, 3 }) })
end

describe("ChartView.view", function()
	it("references the SVG by asset key and ships the bytes as an asset", function()
		local r = result()
		local node, assets = ChartView.view(r, { key = "q" })
		local image = (node.c :: { any })[1]
		expect(image.k).toBe("image")
		expect(image.p.asset).toBe("q")
		expect(image.p.w).toBe(960)
		expect(image.p.h).toBe(300)
		expect(assets.q.mime).toBe(Assets.SVG)
		expect(assets.q.bytes).toBe(r.svg)
	end)

	it("places the cursor line after a spacer as wide as the cursor's fraction", function()
		local r = result()
		local node, assets = ChartView.view(r, { cursor = 10 })
		local image = (node.c :: { any })[1]
		local row = image.c[1]
		expect(row.k).toBe("row")
		expect(row.p.grow).toBe(1)
		expect(row.c[1].p.basis).toBe(Cursor.fraction(r.layout, 10))
		expect(row.c[2].p.class).toBe("tg-cursor")
		local _, noCursor = ChartView.view(r)
		expect(assets.chart.bytes).toBe(noCursor.chart.bytes)
	end)

	it("draws no overlay without a cursor or outside the time range", function()
		local r = result()
		local a = ChartView.view(r)
		expect(((a.c :: { any })[1]).c).toBeNil()
		local b = ChartView.view(r, { cursor = 1000 })
		expect(((b.c :: { any })[1]).c).toBeNil()
	end)

	it("omits the legend on request", function()
		local node = ChartView.view(result(), { show_legend = false })
		expect(#(node.c :: { any })).toBe(1)
	end)
end)

return nil
