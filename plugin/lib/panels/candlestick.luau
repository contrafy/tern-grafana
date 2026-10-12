--!strict
-- The candlestick panel (public/app/plugins/panel/candlestick: fields.ts
-- prepareCandlestickFields, CandlestickPanel.tsx, utils.ts drawMarkers,
-- panelcfg.cue) drawn by lib/render/svg_xy:
-- - data: one frame sorted by time, or all frames outer-joined on time;
-- - fields: options.fields open/high/low/close/volume by name, else by
--   default names (open|o, high|h|max, low|l|min, close|c, volume|v);
--   without open and close the first number field is open; a missing close
--   is the next open, a missing open the previous close; high and low fall
--   back to open; mode volume drops high/low, mode candles drops volume;
-- - mode candles+volume|candles|volume; candleStyle candles|ohlcbars;
--   colorStrategy open-close (close vs open) or close-close (close vs the
--   previous close; rising candles hollow); colors up/down/flat (flat
--   counts as up, except the first candle in close-close);
-- - geometry as drawMarkers: bodies 60% of the closest candle spacing,
--   wicks 2 px (1 px under 12 px bodies); volume bars in the bottom
--   seventh (their scale is 0..7x the largest volume) at the volume
--   field's fillOpacity (default 50%);
-- - includeAllFields draws every other number field as a line; without
--   price or volume to draw, every field is drawn as a time series.
-- More candles than the plot can separate (3 px apart) merge into OHLC
-- buckets (first open, highest high, lowest low, last close, summed
-- volume), which is how the chart reads at that width anyway.

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local SvgKit = require("../render/svg_kit")
local SvgXY = require("../render/svg_xy")
local Thresholds = require("../units/thresholds")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

M.types = { "candlestick" }

M.WIDTH = 960
M.HEIGHT = 300
-- Narrowest candle spacing drawn before candles merge, px.
M.MIN_SPACING = 3

local DEFAULTS: { [string]: { string } } = {
	open = { "open", "o" },
	high = { "high", "h", "max" },
	low = { "low", "l", "min" },
	close = { "close", "c" },
	volume = { "volume", "v" },
}
local KEYS = { "open", "high", "low", "close", "volume" }

function M.supports(panel: any, env: Env): (boolean, string?)
	local why = Charts.unsupportedLegend(panel, env)
	if why then
		return false, why
	end
	return true, nil
end

export type Fields = {
	time: Item,
	open: Item?,
	high: Item?,
	low: Item?,
	close: Item?,
	volume: Item?,
	-- Derived open/close values (next open, previous close).
	open_values: { any }?,
	close_values: { any }?,
	-- Every plotted field (mapped ones, or all with includeAllFields).
	fields: { Item },
	items: { Item },
}

local function findField(items: { Item }, key: string, name: string?): Item?
	local found = Charts.findItem(items, name)
	if found then
		return found
	end
	for _, item in items do
		if item.field.type ~= "number" then
			continue
		end
		local lower = string.lower(item.name)
		for _, d in DEFAULTS[key] do
			if lower == d or item.field.name == d then
				return item
			end
		end
	end
	return nil
end

-- prepareCandlestickFields.
function M.fields(panel: any, frames: { Frame }, env: Env): Fields?
	if #frames == 0 then
		return nil
	end
	local aligned = if #frames == 1 then Charts.sortByTime(frames[1]) else Charts.joinByTime(frames)
	local items = FieldConfig.resolve(panel, { aligned }, env, { color_mode = "palette-classic" })
	local time: Item? = nil
	local graphable: { Item } = {}
	for _, item in items do
		if item.field.type == "time" then
			time = time or item
		elseif item.field.type == "number" then
			table.insert(graphable, item)
		end
	end
	if time == nil then
		return nil
	end
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local map = Json.obj(env, options.fields)
	local mode = Json.str(env, options.mode) or "candles+volume"
	local out: Fields = { time = time :: Item, fields = {}, items = items }
	local used: { Item } = {}
	local function use(item: Item?)
		if item and not table.find(used, item) then
			table.insert(used, item)
		end
	end
	for _, key in KEYS do
		local f = findField(graphable, key, Json.str(env, map[key]));
		(out :: any)[key] = f
		use(f)
	end
	if out.open == nil and out.close == nil then
		out.open = graphable[1]
		use(out.open)
	end
	if out.open and out.close == nil and map.close == nil then
		local src = (out.open :: Item).field.values
		local values: { any } = table.create(#src)
		for i = 1, #src do
			values[i] = src[math.min(i + 1, #src)]
		end
		out.close_values = values
	end
	if out.close and out.open == nil and map.open == nil then
		local src = (out.close :: Item).field.values
		local values: { any } = table.create(#src)
		for i = 1, #src do
			values[i] = src[math.max(i - 1, 1)]
		end
		out.open_values = values
	end
	if out.high == nil and map.high == nil then
		out.high = out.open
	end
	if out.low == nil and map.low == nil then
		out.low = out.open
	end
	if mode == "volume" then
		out.high, out.low = nil, nil
	elseif mode == "candles" then
		out.volume = nil
	end
	if Json.bool(env, options.includeAllFields) == true then
		out.fields = graphable
	else
		local fields: { Item } = {}
		for _, key in KEYS do
			local f = (out :: any)[key]
			if f and not table.find(fields, f) then
				table.insert(fields, f)
			end
		end
		out.fields = fields
	end
	return out
end

local function valuesOf(item: Item?, derived: { any }?): { any }?
	if derived then
		return derived
	end
	return if item then item.field.values else nil
end

type Candle = { t: number, o: number, h: number, l: number, c: number, v: number? }

-- OHLC buckets of `per` consecutive candles.
local function merge(candles: { Candle }, per: number): { Candle }
	if per <= 1 then
		return candles
	end
	local out: { Candle } = {}
	for i = 1, #candles, per do
		local last = math.min(i + per - 1, #candles)
		local first = candles[i]
		local b: Candle = { t = candles[(i + last) // 2].t, o = first.o, h = first.h, l = first.l, c = candles[last].c }
		local vol: number? = nil
		for j = i, last do
			local c = candles[j]
			b.h = math.max(b.h, c.h)
			b.l = math.min(b.l, c.l)
			if c.v then
				vol = (vol or 0) + (c.v :: number)
			end
		end
		b.v = vol
		table.insert(out, b)
	end
	return out
end

local function toneClassOf(name: string?): string
	return Charts.toneClass(Thresholds.tone(name))
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	if not Common.hasData(frames) then
		return Common.noData(panel, env, opts.key), {}
	end
	local f = M.fields(panel, frames, env)
	if f == nil then
		return Charts.message(opts.key, "Data does not have a time field"), {}
	end
	local fx = f :: Fields
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local mode = Json.str(env, options.mode) or "candles+volume"
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local from, to = Charts.range(opts)
	local times = fx.time.field.values
	local openV = valuesOf(fx.open, fx.open_values)
	local closeV = valuesOf(fx.close, fx.close_values)
	local highV = valuesOf(fx.high, nil)
	local lowV = valuesOf(fx.low, nil)
	local volV = valuesOf(fx.volume, nil)
	local drawPrice = mode ~= "volume" and highV ~= nil and lowV ~= nil and openV ~= nil and closeV ~= nil
	local drawVolume = volV ~= nil and mode ~= "candles"

	local candles: { Candle } = {}
	if drawPrice or drawVolume then
		for r, t in times do
			if type(t) ~= "number" then
				continue
			end
			local o = Frame.finite(if openV then openV[r] else nil)
			local c = Frame.finite(if closeV then closeV[r] else nil)
			local v = Frame.finite(if volV then volV[r] else nil)
			if drawPrice then
				local h = Frame.finite((highV :: { any })[r])
				local l = Frame.finite((lowV :: { any })[r])
				if o and c and h and l then
					table.insert(candles, { t = t, o = o, h = h, l = l, c = c, v = v })
				end
			elseif v then
				table.insert(candles, { t = t, o = o or 0, h = 0, l = 0, c = c or 0, v = v })
			end
		end
	end

	local colors = Json.obj(env, options.colors)
	local upClass = toneClassOf(Json.str(env, colors.up) or "green")
	local downClass = toneClassOf(Json.str(env, colors.down) or "red")
	local flatClass = toneClassOf(Json.str(env, colors.flat) or "gray")
	local closeClose = Json.str(env, options.colorStrategy) == "close-close"
	local ohlcBars = Json.str(env, options.candleStyle) == "ohlcbars"

	local plotW = W - 60
	local lo, hi = from, to
	if lo == nil or hi == nil then
		local a, b = math.huge, -math.huge
		for _, c in candles do
			a, b = math.min(a, c.t), math.max(b, c.t)
		end
		lo, hi = lo or a, hi or b
	end
	local span = math.max(1, (hi :: number) - (lo :: number))
	-- Closest spacing in px, then merge until candles are MIN_SPACING apart.
	local gap = math.huge
	for i = 2, #candles do
		local d = candles[i].t - candles[i - 1].t
		if d > 0 then
			gap = math.min(gap, d)
		end
	end
	local colPx = if gap == math.huge then plotW / 2 else gap / span * plotW
	if colPx < M.MIN_SPACING and #candles > 1 then
		local per = math.ceil(M.MIN_SPACING / math.max(colPx, 1e-9))
		candles = merge(candles, per)
		colPx *= per
	end
	local barW = math.max(1, math.floor(0.6 * colPx + 0.5))
	local stick = if barW <= 12 then 1 else 2
	local half = barW // 2

	local groups: { [string]: { SvgXY.Rect } } = { up = {}, down = {}, flat = {} }
	-- Hollow bodies (close-close, rising) keep their direction's color as an
	-- outline.
	local hollow: { [string]: { SvgXY.Rect } } = { up = {}, down = {}, flat = {} }
	local vgroups: { [string]: { SvgXY.Rect } } = { up = {}, down = {}, flat = {} }
	local maxVol = 0
	for i, c in candles do
		local inter = if i == 1 then 0 elseif c.c > candles[i - 1].c then 1 elseif c.c < candles[i - 1].c then -1 else 0
		local intra = if c.c > c.o then 1 elseif c.c < c.o then -1 else 0
		local dir = if closeClose then inter else intra
		local flatAsUp = not (closeClose and i == 1)
		local key = if dir > 0 then "up" elseif dir < 0 then "down" elseif flatAsUp then "up" else "flat"
		if drawVolume and c.v then
			maxVol = math.max(maxVol, c.v :: number)
			table.insert(vgroups[key], { x0 = c.t, w = barW, y0 = 0, y1 = c.v :: number })
		end
		if drawPrice then
			table.insert(groups[key], { x0 = c.t, w = stick, y0 = c.l, y1 = c.h })
			if ohlcBars then
				table.insert(groups[key], { x0 = c.t, w = half, dx = -half / 2, y0 = c.o, y1 = c.o })
				table.insert(groups[key], { x0 = c.t, w = half, dx = half / 2, y0 = c.c, y1 = c.c })
			elseif closeClose and intra >= 0 then
				table.insert(hollow[key], { x0 = c.t, w = barW, y0 = c.o, y1 = c.c })
			else
				table.insert(groups[key], { x0 = c.t, w = barW, y0 = c.o, y1 = c.c })
			end
		end
	end
	local classOf = { up = upClass, down = downClass, flat = flatClass }
	local rects: { SvgXY.Rects } = {}
	local volAlpha = 0.5
	if fx.volume then
		local fo = (fx.volume :: Item).config.custom.fillOpacity
		-- `if (fillOpacity)`: 0 keeps the 50% default.
		if type(fo) == "number" and fo ~= 0 then
			volAlpha = fo / 100
		end
	end
	for _, key in { "up", "down", "flat" } do
		if #vgroups[key] > 0 then
			table.insert(rects, {
				class = classOf[key],
				rects = vgroups[key],
				y2 = drawPrice,
				opacity = volAlpha,
			})
		end
	end
	for _, key in { "up", "down", "flat" } do
		if #groups[key] > 0 then
			table.insert(rects, { class = classOf[key], rects = groups[key], min_h = stick })
		end
	end
	for _, key in { "up", "down", "flat" } do
		if #hollow[key] > 0 then
			table.insert(rects, { class = classOf[key], rects = hollow[key], outline = stick })
		end
	end

	-- Lines: every other field with includeAllFields, or everything when
	-- there is neither price nor volume to draw.
	local lines: { SvgXY.Line } = {}
	local legendItems: { Item } = {}
	local legendClasses: { string } = {}
	local xs: { number } = {}
	local keep: { number } = {}
	for r, t in times do
		if type(t) == "number" then
			table.insert(xs, t)
			table.insert(keep, r)
		end
	end
	local mapped: { [Item]: boolean } = {}
	for _, key in KEYS do
		local item = (fx :: any)[key]
		if item then
			mapped[item] = true
		end
	end
	for k, item in fx.fields do
		local class = FieldConfig.paletteClass(k)
		table.insert(legendItems, item)
		table.insert(legendClasses, class)
		local asLine = not (drawPrice or drawVolume) or not mapped[item]
		if asLine and not FieldConfig.hidden(item) then
			local ys: { any } = table.create(#keep)
			for j, r in keep do
				local v = item.field.values[r]
				ys[j] = if v == nil then Frame.NULL else v
			end
			table.insert(lines, Charts.graphLine(item, class, xs, ys, plotW))
		end
	end

	local priceItem = fx.open or fx.close or fx.fields[1]
	local cfg = if priceItem then priceItem.config else FieldConfig.defaults(panel, env)
	local yUnit, yDecimals = cfg.unit, cfg.decimals
	if not drawPrice and drawVolume and fx.volume then
		yUnit, yDecimals = (fx.volume :: Item).config.unit, (fx.volume :: Item).config.decimals
	end
	local side, label, softMin, softMax, grid = Charts.yAxis(cfg)
	local thresholdMode = Json.str(env, Json.path(env, cfg.custom.thresholdsStyle, "mode"))
	local result = SvgXY.render({
		width = W,
		height = H,
		x_time = true,
		offset_min = opts.offset_min,
		x_min = from,
		x_max = to,
		x_pad = if from == nil and gap ~= math.huge then gap / 2 else nil,
		y_unit = yUnit,
		y_decimals = yDecimals,
		y_min = cfg.min,
		y_max = cfg.max,
		y_zero = not drawPrice and drawVolume,
		y_soft_min = softMin,
		y_soft_max = softMax,
		y_side = side,
		y_label = label,
		y2_max = if drawPrice and maxVol > 0 then maxVol * 7 else nil,
		grid = grid,
		thresholds = cfg.thresholds,
		threshold_style = SvgKit.thresholdStyle(thresholdMode),
		rects = rects,
		lines = lines,
	})
	local chart, assets = Charts.image(
		opts.key,
		result.svg,
		W,
		H,
		Charts.alt(panel, env, "Candlestick chart"),
		"tern-grafana.candlestick"
	)
	local legend = Charts.legendOptions(panel, env)
	local legendNode: Node? = nil
	if legend.show then
		local rows: { Charts.Row } = {}
		for k, item in legendItems do
			if not Charts.hiddenFromLegend(item) then
				table.insert(rows, Charts.calcRow(item, legendClasses[k], legend.calcs, opts))
			end
		end
		legendNode = Charts.calcLegend(opts.key .. ".legend", rows, legend)
	end
	return Charts.compose(opts.key, chart, legendNode, legend.placement), assets
end

return M
