--!strict
-- The stat panel (public/app/plugins/panel/stat: StatPanel.tsx, panelcfg.cue;
-- packages/grafana-ui/src/components/BigValue). One big value per field
-- display value (lib/panels/values) with:
-- - colorMode: value (the number in its color), background /
--   background_solid (the tile in its color), none;
-- - graphMode area: a sparkline of the field under the value;
-- - textMode: auto (value only when it is the panel's single value or
--   when the panel has a title and no displayName, else value and name),
--   value, value_and_name, name, none;
-- - orientation: horizontal stacks the values (each full width), vertical
--   lays them side by side, auto fills a grid (VizRepeater autoGrid);
-- - showPercentChange: the first-to-last change in percent, colored up
--   good (standard), up bad (inverted) or like the value (same_as_value).
-- Colors are tones (fieldconfig Display.tone). With the panel's gridPos
-- size (opts.size) the value, title and percent change are sized the way
-- BigValue sizes them (see Sizing below).

local Assets = require("../render/assets")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Json = require("./json")
local Reduce = require("./reduce")
local SvgKit = require("../render/svg_kit")
local Values = require("./values")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

export type Tile = {
	title: string?,
	value: string,
	tone: string,
	-- "value", "background", "background_solid" or "none".
	color_mode: string,
	spark: Node?,
	-- Formatted percent change and its tone.
	change: string?,
	change_tone: string?,
}

-- Font sizes in px for one value box (BigValueLayout), nil when unsized.
export type Fit = {
	value_px: number,
	title_px: number,
	change_px: number,
	-- Title and value side by side (the wide layouts).
	wide: boolean,
	-- justifyMode center, or auto without a title.
	center: boolean,
}

local M = {}

local function textMode(panel: any, env: Env, count: number): string
	local mode = Json.str(env, Json.path(env, panel, "options", "textMode")) or "auto"
	local title = Json.str(env, Json.path(env, panel, "title")) or ""
	local displayName = Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "displayName"))
	if mode == "auto" and ((displayName ~= nil and displayName ~= "") or title == "") then
		mode = "value_and_name"
	end
	if mode == "auto" then
		return if count == 1 then "value" else "value_and_name"
	end
	return mode
end

-- The tiles a stat panel shows, before layout.
function M.tiles(panel: any, frames: { Frame }, env: Env, opts: Common.Options): { Tile }
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "thresholds" })
	local graph = Json.str(env, Json.path(env, panel, "options", "graphMode")) or "area"
	local colorMode = Json.str(env, Json.path(env, panel, "options", "colorMode")) or "value"
	local showChange = Json.bool(env, Json.path(env, panel, "options", "showPercentChange")) == true
	local changeMode = Json.str(env, Json.path(env, panel, "options", "percentChangeColorMode")) or "standard"
	local values = Values.values(
		panel,
		items,
		env,
		{ sparkline = graph ~= "none", theme = opts.theme, offset_min = opts.offset_min }
	)
	local mode = textMode(panel, env, #values)
	local tiles: { Tile } = {}
	for i, v in values do
		local d = v.display
		local text = FieldConfig.joined(d)
		local tile: Tile = {
			title = if mode == "value_and_name" then v.title else nil,
			value = if mode == "name" then v.title elseif mode == "none" then "" else text,
			tone = d.tone,
			color_mode = colorMode,
		}
		if v.spark and v.item then
			local item = v.item :: FieldConfig.Item
			tile.spark = Common.spark(
				opts.key .. ".spark" .. i,
				v.spark.values,
				v.spark.times,
				if colorMode == "none" then nil else d.tone,
				item.config.min,
				item.config.max
			)
		end
		if showChange and v.item and not v.placeholder then
			local item = v.item :: FieldConfig.Item
			local pc = Reduce.reduce(item.field.values, "diffperc", item.field.type, item.config.null_mode)
			if type(pc) == "number" and pc == pc then
				local up = pc >= 0
				local sign = if up then "+" else "-"
				tile.change = sign .. Format.text(math.abs(pc), "percent", 2)
				if changeMode == "same_as_value" then
					tile.change_tone = d.tone
				elseif pc == 0 then
					tile.change_tone = "neutral"
				elseif (changeMode == "inverted") == up then
					tile.change_tone = "error"
				else
					tile.change_tone = "success"
				end
			end
		end
		table.insert(tiles, tile)
	end
	return tiles
end

-- Sizing ----------------------------------------------------------------------
-- Grafana's BigValue fits its text to each value's box: VizRepeater gives
-- every value a box (packages/grafana-ui/src/components/VizRepeater/
-- VizRepeater.tsx, autoGrid with utils/squares.ts calculateGridDimensions,
-- itemSpacing 3), BigValueLayout.tsx buildLayout picks a wide or stacked
-- layout and calculateFontSize (utils/measureText.ts) the largest size that
-- fits the box's width and height, every value aligned to the longest
-- (getDisplayValueAlignmentFactors). The px come from the panel's Grafana
-- size (opts.size) with the height bounded by the Tern card's height cap.
-- The value is drawn as an SVG of that size that shrinks to a narrower tile
-- (valueSvg): Tern's style sheets have no container units and the plugin
-- has no reliable pane width. Title and percent change snap to size classes
-- (panels2.css tgp-stat-fs<N>).

local LINE_HEIGHT = 1.2
local MAX_TITLE_SIZE = 30
local ITEM_SPACING = 3
-- PanelChrome: a 32 px header when the panel has a title; 8 px padding.
local HEADER_PX = 32
local PANEL_PADDING_PX = 8
-- The Tern tile's padding (panels.css .tgp-stat: 6 px 8 px) and the row
-- Tern's spark chart takes under the value.
M.TILE_PAD_X = 16
M.TILE_PAD_Y = 12
M.SPARK_PX = 34

-- Font size classes, px (panels2.css tgp-stat-fs<N>).
M.FONT_SIZES = table.freeze({
	10,
	11,
	12,
	13,
	14,
	15,
	16,
	18,
	20,
	22,
	24,
	26,
	28,
	30,
	32,
	36,
	40,
	44,
	48,
	52,
	56,
	60,
	64,
	72,
	80,
	88,
	96,
	104,
	112,
	120,
	128,
	144,
	160,
	176,
	192,
	208,
	224,
	240,
	256,
	288,
	320,
	352,
	384,
	416,
	448,
	480,
	512,
})

-- calculateFontSize's measureText(text, 14).width / 14 per character: the
-- value is SVG text in the sans UI font (about 0.55 em a character, close to
-- Grafana's Inter); its textLength pins the drawn width to this estimate,
-- so a wider real font is narrowed rather than overflowing.
M.TEXT_EM = 0.55

function M.textEm(text: string): number
	return (utf8.len(text) or #text) * M.TEXT_EM
end

-- calculateFontSize: the largest size that fits width and height.
local function fontSize(text: string, width: number, height: number, maxSize: number?): number
	local byWidth = width / (M.textEm(text) * 14 + 2) * 14
	local optimal = math.min(height / LINE_HEIGHT, byWidth)
	return math.min(optimal, maxSize or optimal)
end

export type FitInput = {
	-- One value's box in px.
	w: number,
	h: number,
	-- The longest value and title text of the panel ("" / nil when not shown).
	value: string,
	title: string?,
	spark: boolean,
	change: boolean,
	-- options.text.valueSize / titleSize / percentSize.
	value_size: number?,
	title_size: number?,
	percent_size: number?,
	justify: string?,
}

-- BigValueLayout's font sizes for one box (buildLayout and its four layouts).
function M.fit(i: FitInput): Fit
	local w, h = math.max(i.w, 1), math.max(i.h, 1)
	local pad = if h > 100 then 12 else 8
	local maxW, maxH = math.max(w - pad * 2, 1), math.max(h - pad * 2, 1)
	local titlePx, valuePx = i.title_size or 0, i.value_size or 0
	local alignTitle = if i.title_size then "" else (i.title or "")
	local alignValue = if i.value_size then "" else i.value
	local wide = w / h > 2.5
	local function value(width: number, height: number)
		if alignValue ~= "" then
			valuePx = fontSize(alignValue, width, height)
		end
	end
	local function title(width: number, height: number)
		if alignTitle ~= "" then
			titlePx = fontSize(alignTitle, width, height, MAX_TITLE_SIZE)
		end
	end
	if wide and h > 50 and i.spark then
		-- WideWithChartLayout.
		title(maxW * 0.6, maxH * 0.4)
		value(maxW * 0.4, maxH * 0.5)
	elseif wide then
		-- WideNoChartLayout.
		value(maxW * (if alignTitle ~= "" then 0.3 else 1), maxH * (if i.change then 0.75 else 1))
		title(maxW * 0.6, maxH)
		if alignTitle ~= "" then
			titlePx = math.min(valuePx * 0.7, titlePx)
		end
	else
		-- StackedWithChartLayout / StackedWithNoChartLayout.
		local chart = h > 100 and i.spark
		title(maxW, h * 0.15)
		local titleH = if alignTitle ~= "" then titlePx * LINE_HEIGHT else 0
		if chart then
			value(maxW, maxH - h * 0.25 - titleH)
		else
			value(maxW, (maxH - titleH) * (if i.change then 0.75 else 1))
		end
		if alignTitle ~= "" then
			titlePx = math.min(valuePx * 0.7, titlePx)
		end
	end
	return {
		value_px = math.max(valuePx, 0),
		title_px = math.max(titlePx, 0),
		change_px = i.percent_size or math.max(valuePx / 2.5, 12),
		wide = wide,
		center = i.justify == "center" or (i.title or "") == "",
	}
end

-- The largest size class not above `px` (the smallest class below it), so
-- a snapped size still fits the box it was computed for.
function M.sizeClass(px: number): number
	local best = M.FONT_SIZES[1]
	for _, s in M.FONT_SIZES do
		if s <= px then
			best = s
		end
	end
	return best
end

-- The boxes VizRepeater gives `n` values in a w x h content area:
-- (columns, box width, box height).
function M.grid(n: number, w: number, h: number, orientation: string): (number, number, number)
	if n <= 1 then
		return 1, w, h
	elseif orientation == "horizontal" then
		return 1, w, (h + ITEM_SPACING) / n - ITEM_SPACING
	elseif orientation == "vertical" then
		return n, w / n - ITEM_SPACING + ITEM_SPACING / n, h
	end
	-- squares.ts calculateGridDimensions.
	local function sizeOfChild(pw: number, ph: number): number
		local parts = math.ceil(math.sqrt(n * pw / ph))
		if math.floor(parts * ph / pw) * parts < n then
			return ph / math.ceil(parts * ph / pw)
		end
		return pw / parts
	end
	local square = math.max(sizeOfChild(w, h), sizeOfChild(h, w))
	local xCount = math.max(math.floor(w / square), 1)
	local yCount = math.ceil(n / xCount)
	xCount = math.ceil(n / yCount)
	return xCount, w / xCount - ITEM_SPACING + ITEM_SPACING / xCount, h / yCount - ITEM_SPACING + ITEM_SPACING / yCount
end

-- The panel's fit for its tiles, from opts.size; nil without a size.
local function panelFit(panel: any, env: Env, tiles: { Tile }, opts: Common.Options): (Fit?, number)
	local size = opts.size
	if size == nil or #tiles == 0 then
		return nil, 1
	end
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local hasTitle = (Json.str(env, Json.path(env, panel, "title")) or "") ~= ""
	local spark = false
	for _, t in tiles do
		spark = spark or t.spark ~= nil
	end
	-- Grafana's panel content box, its height bounded by what the Tern card
	-- body has under the card's height cap (less the tile's padding and
	-- Tern's sparkline row). The width needs no bound: the value is an SVG
	-- that scales down to the tile (tileNode); Tern's cx.cols is not a
	-- reliable pane width (it is not updated when the pane resizes).
	local w = size.w - PANEL_PADDING_PX * 2
	local h = size.h - (if hasTitle then HEADER_PX else 0) - PANEL_PADDING_PX * 2
	if opts.card_height then
		h = math.min(h, opts.card_height - M.TILE_PAD_Y - (if spark then M.SPARK_PX else 0))
	end
	local orientation = Json.str(env, options.orientation) or "auto"
	local cols, bw, bh = M.grid(#tiles, math.max(w, 1), math.max(h, 1), orientation)
	local value, title = "", ""
	local change = false
	for _, t in tiles do
		if #t.value > #value then
			value = t.value
		end
		if t.title and #t.title > #title then
			title = t.title
		end
		change = change or t.change ~= nil
	end
	local text = Json.obj(env, options.text)
	local positive = function(v: any): number?
		local n = Json.num(env, v)
		return if n and n > 0 then n else nil
	end
	return M.fit({
		w = bw,
		h = bh,
		-- textMode none aligns to "1" (getTextValues).
		value = if value ~= "" then value else "1",
		title = if title ~= "" then title else nil,
		spark = spark,
		change = change,
		value_size = positive(text.valueSize),
		title_size = positive(text.titleSize),
		percent_size = positive(text.percentSize),
		justify = Json.str(env, options.justifyMode),
	}),
		cols
end

local function fsClass(px: number): string
	return "tgp-stat-fs" .. M.sizeClass(px)
end

-- Fill class of the value text in the SVG (panels2.css .tgg-*): the tone for
-- colorMode value, the page color on a solid background, else the text color.
local function valueFill(tile: Tile): string
	local token = Common.token(tile.tone :: any)
	if tile.color_mode == "value" and token ~= "" then
		return "tgg-f-" .. tile.tone
	elseif tile.color_mode == "background_solid" then
		return "tgp-stat-on-solid"
	end
	return "tgg-text"
end

-- The fitted value as an SVG image of Grafana's size: its viewBox is tight
-- around one line of text (textLength pins the width whatever the font), so
-- Tern scales it down to a narrower tile instead of wrapping it, and the
-- image's max height keeps it at Grafana's size in a wider one.
function M.valueSvg(text: string, px: number, fill: string): (string, number, number)
	local size = math.max(math.floor(px + 0.5), 1)
	local w = math.max(math.ceil(M.textEm(text) * size), 1)
	local h = math.ceil(size * LINE_HEIGHT)
	local svg = string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" class="tgg">'
			.. '<text class="%s" x="%s" y="%s" font-size="%d" font-weight="500" text-anchor="middle" '
			.. 'textLength="%d" lengthAdjust="spacingAndGlyphs">%s</text></svg>',
		w,
		h,
		w,
		h,
		fill,
		tostring(w / 2),
		-- The baseline that centers a cap-height line in the box (Tern's SVG
		-- drops dominant-baseline).
		tostring(math.floor(h / 2 + size * 0.36 + 0.5)),
		size,
		w,
		SvgKit.escape(text)
	)
	return svg, w, h
end

-- Tern's text line, px: image max heights are given in lines.
local LINE_PX = 16

local function tileNode(tile: Tile, key: string, fit: Fit?, assetKey: string, assets: Assets.Assets): Node
	local token = Common.token(tile.tone :: any)
	local valueStyle = "strong"
	local classes = { "tgp-stat" }
	if tile.color_mode == "value" and token ~= "" then
		valueStyle = "strong " .. token
	elseif tile.color_mode == "background" then
		table.insert(classes, "tgp-bg " .. Common.toneClass(tile.tone :: any))
	elseif tile.color_mode == "background_solid" then
		table.insert(classes, "tgp-bgs " .. Common.toneClass(tile.tone :: any))
	end
	local valueClass, titleClass, changeClass = "tgp-stat-value", "tgp-stat-title", "tgp-stat-change"
	local lineClass = "tgp-stat-line"
	if fit then
		table.insert(classes, "tgp-stat-fit")
		titleClass ..= " " .. fsClass(fit.title_px)
		changeClass ..= " " .. fsClass(fit.change_px)
		if fit.wide then
			lineClass ..= " tgp-stat-wide"
		end
		if fit.center then
			lineClass ..= " tgp-stat-center"
		end
	end
	local line: { Node } = {}
	if tile.title then
		table.insert(line, {
			k = "el",
			p = { tag = "div", key = "t", class = titleClass },
			c = { ui.text({ ui.span(tile.title :: string, "muted") }, { truncate = "end" }) },
		})
	end
	local value: Node
	if fit and tile.value ~= "" then
		local svg, w, h = M.valueSvg(tile.value, fit.value_px, valueFill(tile))
		assets[assetKey] = { mime = Assets.SVG, bytes = svg }
		-- Rounded up: the max height never cuts the image below its own size.
		local lines = math.max(1, math.ceil(h / LINE_PX))
		value = {
			k = "image",
			p = { key = "i", asset = assetKey, w = w, h = h, alt = tile.value, max = { h = lines .. "lines" } },
		}
	else
		value = ui.text({ ui.span(tile.value, valueStyle) })
	end
	table.insert(line, { k = "el", p = { tag = "div", key = "v", class = valueClass }, c = { value } })
	if tile.change then
		local tone = Common.token((tile.change_tone or "neutral") :: any)
		table.insert(line, {
			k = "el",
			p = { tag = "div", key = "c", class = changeClass },
			c = { ui.text({ ui.span(tile.change :: string, tone) }) },
		})
	end
	local children: { Node } = { { k = "el", p = { tag = "div", key = "l", class = lineClass }, c = line } }
	if tile.spark then
		table.insert(children, tile.spark :: Node)
	end
	return { k = "el", p = { tag = "div", key = key, class = table.concat(classes, " ") }, c = children }
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets)
	local tiles = M.tiles(panel, frames, env, opts)
	local fit, cols = panelFit(panel, env, tiles, opts)
	local assets: Assets.Assets = {}
	local nodes: { Node } = table.create(#tiles)
	for i, tile in tiles do
		nodes[i] = tileNode(tile, "s" .. i, fit, opts.key .. ".v" .. i, assets)
	end
	if fit then
		-- VizRepeater's boxes: `cols` per row (panels2.css tgp-stat-g1..24).
		local class = "tgp-stat-grid tgp-stat-g" .. math.clamp(cols, 1, 24)
		local grid = { k = "el", p = { tag = "div", key = "g", class = class }, c = nodes }
		return ui.col({ grid }, { key = opts.key, gap = "xs", role = "tern-grafana.stat" }), assets
	end
	local orientation = Json.str(env, Json.path(env, panel, "options", "orientation")) or "auto"
	if orientation == "horizontal" then
		return ui.col(nodes, { key = opts.key, gap = "xs", role = "tern-grafana.stat" }), assets
	end
	return ui.row(nodes, { key = opts.key, gap = "xs", wrap = true, role = "tern-grafana.stat" }), assets
end

return M
