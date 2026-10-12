--!strict
-- The candlestick panel (public/app/plugins/panel/candlestick fields.ts
-- prepareCandlestickFields, utils.ts drawMarkers) on the tern-all-panels
-- candlestick options (panel 22: candles+volume, open-close, green/red).
local Candlestick = require("../../../plugin/lib/panels/candlestick")
local Frame = require("../../../plugin/lib/frame/types")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local PANEL = [[{
	"id": 22, "type": "candlestick", "title": "Candlestick: Prometheus RSS",
	"options": {"legend": {"showLegend": true, "displayMode": "list", "placement": "bottom", "calcs": []},
		"mode": "candles+volume", "candleStyle": "candles", "colorStrategy": "open-close",
		"colors": {"up": "green", "down": "red"}, "includeAllFields": false,
		"fields": {"open": "open", "high": "high", "low": "low", "close": "close", "volume": "volume"}},
	"fieldConfig": {"defaults": {"custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 10},
		"color": {"mode": "palette-classic"}, "unit": "bytes"}, "overrides": []}
}]]

local T0 = 1791570000000

-- Three candles: up (10 -> 12), down (12 -> 11), flat (11 -> 11).
local function frames(): { Frame.Frame }
	return {
		{
			fields = {
				Frame.field("Time", "time", { T0, T0 + 60000, T0 + 120000 }),
				Frame.field("open", "number", { 10, 12, 11 }),
				Frame.field("high", "number", { 13, 12.5, 11.5 }),
				Frame.field("low", "number", { 9, 10.5, 10.8 }),
				Frame.field("close", "number", { 12, 11, 11 }),
				Frame.field("volume", "number", { 100, 300, 200 }),
			},
		},
	}
end

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

local OPTS = { key = "c", size = { w = 600, h = 300 }, time = { from_ms = T0 - 60000, to_ms = T0 + 180000 } }

describe("candlestick", function()
	it("maps the configured OHLCV fields", function()
		local f = Candlestick.fields(S.json(PANEL), frames(), env)
		assert(f and f.open and f.close and f.high and f.low and f.volume, "all mapped")
		expect(f.open.name).toBe("open")
		expect(f.volume.name).toBe("volume")
		expect(#f.fields).toBe(5)
	end)

	-- Default names (o/h/l/c/v, max/min) find fields without options.fields.
	it("finds fields by their default names", function()
		local panel = S.json(PANEL)
		panel.options.fields = nil
		local f = frames()
		f[1].fields[3] = Frame.field("max", "number", { 13, 12.5, 11.5 })
		f[1].fields[4] = Frame.field("min", "number", { 9, 10.5, 10.8 })
		local m = Candlestick.fields(panel, f, env)
		assert(m and m.high and m.low, "mapped")
		expect(m.high.name).toBe("max")
		expect(m.low.name).toBe("min")
	end)

	-- One number field: it is open, close is the next open, high/low open.
	it("derives close from the next open when only one value field exists", function()
		local panel = S.json(PANEL)
		panel.options.fields = nil
		local f: { Frame.Frame } = {
			{ fields = { Frame.field("Time", "time", { 1, 2, 3 }), Frame.field("price", "number", { 5, 7, 6 }) } },
		}
		local m = Candlestick.fields(panel, f, env)
		assert(m and m.open, "mapped")
		expect(m.open.name).toBe("price")
		assert(m.close_values, "derived close")
		expect(m.close_values[1]).toBe(7)
		expect(m.close_values[3]).toBe(6)
		expect(m.high).toBe(m.open)
	end)

	-- open-close: up in the up color, down in the down color, flat counts
	-- as up; volume bars on their own scale at the volume field's
	-- fillOpacity (10 from the defaults; 50% only without one).
	it("colors candles and volume by direction", function()
		local node, assets = Candlestick.view(S.json(PANEL), frames(), env, OPTS)
		local svg = (assets :: any).c.bytes
		expect(count(svg, 'class="tgp-fx tgp-success tg-bar" fill-opacity="1.00"')).toBe(1)
		expect(count(svg, 'class="tgp-fx tgp-error tg-bar" fill-opacity="1.00"')).toBe(1)
		expect(count(svg, 'tg-bar" fill-opacity="0.10"')).toBe(2)
		expect(string.find(svg, " B<", 1, true) ~= nil).toBe(true)
		expect(#svg <= 262144).toBe(true)
		expect(S.text(S.find(node, function(n)
			return n.p and n.p.role == "tern-grafana.legend"
		end))).toBe("openhighlowclosevolume")
	end)

	it("drops volume in candles mode and price in volume mode", function()
		local panel = S.json(PANEL)
		panel.options.mode = "candles"
		local _, assets = Candlestick.view(panel, frames(), env, OPTS)
		expect(count((assets :: any).c.bytes, 'fill-opacity="0.10"')).toBe(0)
		panel.options.mode = "volume"
		local _, vol = Candlestick.view(panel, frames(), env, OPTS)
		local svg = (vol :: any).c.bytes
		expect(count(svg, 'fill-opacity="1.00"')).toBe(0)
		expect(count(svg, 'fill-opacity="0.10"')).toBe(2)
		panel.fieldConfig.defaults.custom.fillOpacity = nil
		local _, half = Candlestick.view(panel, frames(), env, OPTS)
		expect(count((half :: any).c.bytes, 'fill-opacity="0.50"')).toBe(2)
	end)

	-- close-close: rising closes are hollow (outlined), the first candle
	-- has no previous close and is flat.
	it("outlines rising candles with close-close", function()
		local panel = S.json(PANEL)
		panel.options.colorStrategy = "close-close"
		panel.options.mode = "candles"
		local _, assets = Candlestick.view(panel, frames(), env, OPTS)
		local svg = (assets :: any).c.bytes
		-- Candle 1 (open < close) and 3 (open == close) are hollow.
		expect(count(svg, "tg-line")).toBe(2)
		expect(string.find(svg, "tgp-muted", 1, true) ~= nil or string.find(svg, "tgp-neutral", 1, true) ~= nil).toBe(
			true
		)
	end)

	-- Thousands of candles merge into OHLC buckets the plot can separate.
	it("merges dense candles and stays under the SVG cap", function()
		local n = 20000
		local times, o, h, l, c = {}, {}, {}, {}, {}
		for i = 1, n do
			times[i] = T0 + i * 1000
			o[i], h[i], l[i], c[i] = i, i + 2, i - 2, i + 1
		end
		local f: { Frame.Frame } = {
			{
				fields = {
					Frame.field("Time", "time", times),
					Frame.field("open", "number", o),
					Frame.field("high", "number", h),
					Frame.field("low", "number", l),
					Frame.field("close", "number", c),
				},
			},
		}
		local _, assets = Candlestick.view(S.json(PANEL), f, env, { key = "c", size = { w = 900, h = 300 } })
		local svg = (assets :: any).c.bytes
		expect(#svg <= 262144).toBe(true)
		-- A body per merged candle: well under one per input row.
		expect(count(svg, "Z") < 1000).toBe(true)
	end)

	it("needs a time field", function()
		local f: { Frame.Frame } = { { fields = { Frame.field("open", "number", { 1 }) } } }
		expect(S.text((Candlestick.view(S.json(PANEL), f, env, OPTS)))).toBe("Data does not have a time field")
	end)
end)

return nil
