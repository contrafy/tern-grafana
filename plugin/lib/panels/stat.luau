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
-- - orientation: horizontal lays values in a row, vertical in a column
--   (auto: a row);
-- - showPercentChange: the first-to-last change in percent, colored up
--   good (standard), up bad (inverted) or like the value (same_as_value).
-- Colors are tones (fieldconfig Display.tone).

local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Json = require("./json")
local Reduce = require("./reduce")
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
		if showChange and v.item then
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

local function tileNode(tile: Tile, key: string): Node
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
	local children: { Node } = {}
	if tile.title then
		table.insert(children, ui.text({ ui.span(tile.title :: string, "muted") }, { key = "t", truncate = "end" }))
	end
	local valueSpans: { ui.SpanLike } = { ui.span(tile.value, valueStyle) }
	if tile.change then
		table.insert(valueSpans, " ")
		table.insert(valueSpans, ui.span(tile.change :: string, Common.token((tile.change_tone or "neutral") :: any)))
	end
	table.insert(children, {
		k = "el",
		p = { tag = "div", key = "v", class = "tgp-stat-value" },
		c = { ui.text(valueSpans) },
	})
	if tile.spark then
		table.insert(children, tile.spark :: Node)
	end
	return { k = "el", p = { tag = "div", key = key, class = table.concat(classes, " ") }, c = children }
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): Node
	local tiles = M.tiles(panel, frames, env, opts)
	local nodes: { Node } = table.create(#tiles)
	for i, tile in tiles do
		nodes[i] = tileNode(tile, "s" .. i)
	end
	local orientation = Json.str(env, Json.path(env, panel, "options", "orientation")) or "auto"
	if orientation == "vertical" then
		return ui.col(nodes, { key = opts.key, gap = "xs", role = "tern-grafana.stat" })
	end
	return ui.row(nodes, { key = opts.key, gap = "xs", wrap = true, role = "tern-grafana.stat" })
end

return M
