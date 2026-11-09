--!strict
-- The treemap panel (marcusolsson-treemap-panel 2.1.1: TreemapPanel.tsx,
-- treemap.ts, TreemapTile.tsx, module.ts) drawn by lib/render/svg_treemap:
-- - per frame a view of its fields (matched by field name): text =
--   options.textField else the first string field, size = sizeField else
--   the first number field, color = colorByField else the first number
--   field, groupBy = groupByField, labels = labelFields; frames missing
--   text, size or color are left out, and with none left the panel shows
--   its "Configure your query" wizard;
-- - the hierarchy: per row the path frame name, group value (when truthy),
--   then the label split by the text field's custom.separator (a trailing
--   separator dropped); a leading "All" is dropped, rows repeating a path
--   keep the first, and a single top-level child collapses into the root;
-- - d3's layout (lib/panels/treemap_layout) with the panel's tiling, round,
--   paddingInner 4, paddingOuter 4, paddingTop 27, values summed and
--   sorted descending, over the panel's content box;
-- - a leaf (a row) is filled with its color field's display color, the hex
--   Grafana fills it with (display(value).color) as its Grafana color class
--   (lib/render/ts_gradient: thresholds, including percentage ones,
--   mappings, fixed colors, continuous schemes; a named color takes its
--   light shade under the light theme) or its palette class; other nodes
--   are groups at 5% of the text color; a tile shows its name when it fits
--   (measured text + 20 px wide, more than 30 px tall);
-- - Grafana's tooltip (name, formatted size, label badges) and the click
--   menu of the size field's data links are an overlay over the image: one
--   element per leaf with the tooltip as its title whose click opens the
--   first data link in the browser pane (the dashboard's `dlink` action).
--   Links interpolate `${__data.fields.<name|index>}`,
--   `${__data.name|refId}`, `${__value.raw|numeric|text}`,
--   `${__field.name|labels.<k>}` and `${__series.name}` URI-encoded, then
--   the dashboard's variables; paths resolve against the Grafana's URL
--   (Grafana's <base href> makes "d/uid" mean "/d/uid").

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Html = require("./html")
local Interpolate = require("../dashboard/interpolate")
local Json = require("./json")
local Url = require("../url")
local Layout = require("./treemap_layout")
local Stat = require("./stat")
local SvgTreemap = require("../render/svg_treemap")
local Thresholds = require("../units/thresholds")
local TsGradient = require("../render/ts_gradient")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

M.types = { "marcusolsson-treemap-panel" }

M.WIDTH = 1000
M.HEIGHT = 340
-- Grafana's panel chrome around the content box (measured on 12.4 and 13.3
-- d-solo renders): a 40 px title header and a 1 px border on every side.
M.HEADER_PX = 40
M.BORDER_PX = 1
M.PADDING_INNER = 4
M.PADDING_OUTER = 4
M.PADDING_TOP = 27
-- TreemapTile margins: a label fits when its width plus left and right
-- margins is under the tile's width and top plus bottom under its height.
M.LABEL_MARGIN_X = 20
M.LABEL_MARGIN_Y = 30

M.WIZARD = "Configure your query: define a data source query that returns at least the following fields: "
	.. "Tile label (string), Tile size (number)."

function M.supports(panel: any, env: Env): (boolean, string?)
	local why = FieldConfig.unsupported(panel, env)
	if why then
		return false, why
	end
	local tiling = Json.str(env, Json.path(env, panel, "options", "tiling"))
	if tiling and tiling ~= "" and not Layout.isTiling(tiling) then
		return false, string.format("tiling %s is not supported", tiling)
	end
	return true, nil
end

-- Frames ------------------------------------------------------------------------

export type View = {
	frame: Frame,
	-- Every field of the frame, resolved.
	items: { Item },
	text: Item,
	size: Item,
	color: Item,
	group: Item?,
	labels: { Item },
}

-- An option naming a field; "" or absent means the default.
local function fieldOption(env: Env, options: any, key: string): string?
	local s = Json.str(env, options[key])
	return if s and s ~= "" then s else nil
end

local function byName(items: { Item }, name: string): Item?
	for _, it in items do
		if it.field.name == name then
			return it
		end
	end
	return nil
end

local function byType(items: { Item }, kind: string): Item?
	for _, it in items do
		if it.field.type == kind then
			return it
		end
	end
	return nil
end

-- The frames the panel can draw, as views of their fields.
function M.views(panel: any, frames: { Frame }, env: Env): { View }
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local textName = fieldOption(env, options, "textField")
	local sizeName = fieldOption(env, options, "sizeField")
	local colorName = fieldOption(env, options, "colorByField")
	local groupName = Json.str(env, options.groupByField)
	local labelNames: { string } = {}
	for _, n in Json.list(env, options.labelFields) do
		if type(n) == "string" then
			table.insert(labelNames, n)
		end
	end
	local byFrame: { [number]: { Item } } = {}
	for _, it in FieldConfig.resolve(panel, frames, env) do
		local list = byFrame[it.frame_index]
		if list == nil then
			list = {}
			byFrame[it.frame_index] = list
		end
		table.insert(list, it)
	end
	local out: { View } = {}
	for fi, frame in frames do
		local items = byFrame[fi] or {}
		local text = if textName then byName(items, textName) else byType(items, "string")
		local size = if sizeName then byName(items, sizeName) else byType(items, "number")
		local color = if colorName then byName(items, colorName) else byType(items, "number")
		if text == nil or size == nil or color == nil then
			continue
		end
		local labels: { Item } = {}
		for _, n in labelNames do
			local it = byName(items, n)
			if it then
				table.insert(labels, it)
			end
		end
		table.insert(out, {
			frame = frame,
			items = items,
			text = text,
			size = size,
			color = color,
			group = if groupName then byName(items, groupName) else nil,
			labels = labels,
		})
	end
	return out
end

-- Hierarchy ---------------------------------------------------------------------

-- What a leaf carries: its view and row.
export type Leaf = { view: View, row: number }

local function jsString(v: any): string
	if type(v) == "number" then
		if v ~= v then
			return "NaN"
		elseif v == math.floor(v) and math.abs(v) < 1e21 then
			return string.format("%d", v)
		end
		return tostring(v)
	elseif v == nil or v == Frame.NULL then
		return ""
	end
	return tostring(v)
end

local function jsTruthy(v: any): boolean
	if v == nil or v == Frame.NULL or v == false or v == "" then
		return false
	elseif type(v) == "number" then
		return v ~= 0 and v == v
	end
	return true
end

-- `d.value ?? 0` read as d3's `+value || 0`.
local function sizeOf(v: any): number
	local n = if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
	if n == nil or n ~= n then
		return 0
	end
	return n
end

-- String.prototype.split with a string separator ("" splits characters).
local function split(s: string, sep: string): { string }
	if sep == "" then
		local out: { string } = {}
		for _, c in utf8.codes(s) do
			table.insert(out, utf8.char(c))
		end
		return out
	end
	local out: { string } = {}
	local pos = 1
	while true do
		local a, b = string.find(s, sep, pos, true)
		if a == nil then
			table.insert(out, string.sub(s, pos))
			return out
		end
		table.insert(out, string.sub(s, pos, a - 1))
		pos = (b :: number) + 1
	end
end

-- The tree treemap.ts buildHierarchy makes of the views.
function M.hierarchy(views: { View }): Layout.Input
	local root: Layout.Input = { name = "All" }
	-- Children by name per node (insertPath finds the first of a name).
	local index: { [Layout.Input]: { [string]: Layout.Input } } = {}
	local function insertPath(node: Layout.Input, path: { string }, at: number, value: number, leaf: Leaf)
		local kids = node.children
		if kids == nil then
			kids = {}
			node.children = kids
		end
		if at > #path then
			return
		end
		local names = index[node]
		if names == nil then
			names = {}
			index[node] = names
		end
		local name = path[at]
		local child = names[name]
		if child == nil then
			local c: Layout.Input = { name = name }
			if at == #path then
				c.value = value
				c.data = leaf
			end
			names[name] = c
			table.insert(kids :: { Layout.Input }, c)
			child = c
		end
		insertPath(child :: Layout.Input, path, at + 1, value, leaf)
	end
	for _, v in views do
		local sep = v.text.config.custom.separator
		local separator = if type(sep) == "string" then sep else nil
		-- endsWith(undefined) tests for the text "undefined".
		local suffix = separator or "undefined"
		local sizes = v.size.field.values
		local groups = if v.group then v.group.field.values else nil
		for row, raw in v.text.field.values do
			local label = jsString(raw)
			if #suffix <= #label and string.sub(label, #label - #suffix + 1) == suffix then
				label = string.sub(label, 1, #label - #suffix)
			end
			local path: { string } = { v.frame.name or "" }
			if groups and jsTruthy(groups[row]) then
				table.insert(path, jsString(groups[row]))
			end
			if separator then
				for _, part in split(label, separator) do
					table.insert(path, part)
				end
			else
				table.insert(path, label)
			end
			insertPath(root, path, if path[1] == root.name then 2 else 1, sizeOf(sizes[row]), { view = v, row = row })
		end
	end
	local top = root.children
	if top and #top == 1 then
		return { name = "All", children = top[1].children }
	end
	return root
end

-- Data links --------------------------------------------------------------------

export type Link = { title: string, url: string }

-- The size field's data links (getLinks): the defaults' links, replaced by
-- each matching override's.
local function linksOf(panel: any, env: Env, item: Item, frames: { Frame }): { any }
	local links = Json.list(env, Json.path(env, panel, "fieldConfig", "defaults", "links"))
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		local match = FieldConfig.matcherFor(env, Json.path(env, o, "matcher"))
		if match and match(item.field, item.frame, frames) then
			for _, p in Json.list(env, Json.path(env, o, "properties")) do
				if Json.str(env, Json.path(env, p, "id")) == "links" then
					links = Json.list(env, Json.path(env, p, "value"))
				end
			end
		end
	end
	return links
end

-- getFieldDisplayValuesProxy: a field by name, display name, index, then
-- config displayName.
local function fieldOf(view: View, key: string): Item?
	for _, it in view.items do
		if it.field.name == key then
			return it
		end
	end
	for _, it in view.items do
		if it.name == key then
			return it
		end
	end
	local n = tonumber(key)
	if n and view.items[n + 1] then
		return view.items[n + 1]
	end
	for _, it in view.items do
		if it.config.display_name == key then
			return it
		end
	end
	return nil
end

local function fieldKey(path: string): string?
	return string.match(path, "^fields%.(.+)$")
		or string.match(path, "^fields%[(%d+)%]$")
		or string.match(path, '^fields%["(.-)"%]$')
		or string.match(path, "^fields%['(.-)'%]$")
end

-- The data macros of one tile.
local function macros(leaf: Leaf, dopts: FieldConfig.Options): (string, string?) -> Interpolate.Var?
	local v, row = leaf.view, leaf.row
	return function(name: string, path: string?): Interpolate.Var?
		if name == "__data" and path then
			if path == "name" then
				return Interpolate.value(v.frame.name or "")
			elseif path == "refId" then
				return Interpolate.value(v.frame.refId or "")
			end
			local key = fieldKey(path)
			local it = if key then fieldOf(v, key) else nil
			if it then
				return Interpolate.value(FieldConfig.joined(FieldConfig.display(it, it.field.values[row], dopts)))
			end
		elseif name == "__value" then
			local raw = v.size.field.values[row]
			if path == "raw" then
				return Interpolate.value(jsString(raw))
			end
			local d = FieldConfig.display(v.size, raw, dopts)
			if path == "numeric" then
				return Interpolate.value(jsString(d.numeric or 0 / 0))
			elseif path == "text" then
				return Interpolate.value(d.text)
			end
		elseif name == "__field" and path then
			if path == "name" then
				return Interpolate.value(v.size.name)
			end
			local label = string.match(path, "^labels%.(.+)$")
			if label then
				local labels = v.size.field.labels
				return Interpolate.value(if labels then labels[label] or "" else "")
			end
		elseif name == "__series" and path == "name" then
			return Interpolate.value(v.frame.name or "")
		end
		return nil
	end
end

local function joinValues(values: { string }): string
	return table.concat(values, ",")
end

local function uriEncode(values: { string }): string
	return Url.percentEncode(table.concat(values, ","))
end

-- A link URL as the browser opens it: Grafana's <base href> resolves a
-- relative path against the Grafana's root; only http(s) and the like
-- survive (sanitizeUrl).
local function resolveUrl(url: string, base: string?): string?
	local u = string.gsub(url, "\n", "")
	if not string.match(u, "^%a[%w+.-]*:") and string.sub(u, 1, 1) ~= "/" then
		u = "/" .. u
	end
	return Html.resolve(u, base)
end

-- The tile's data links, interpolated.
function M.links(panel: any, env: Env, leaf: Leaf, frames: { Frame }, opts: Common.Options): { Link }
	local out: { Link } = {}
	local raw = linksOf(panel, env, leaf.view.size, frames)
	if #raw == 0 then
		return out
	end
	local dopts: FieldConfig.Options = { theme = opts.theme, offset_min = opts.offset_min, now_ms = env.now_ms }
	local macro = macros(leaf, dopts)
	local replace = opts.replace
	for _, l in raw do
		local url = Json.str(env, Json.path(env, l, "url"))
		if url == nil or url == "" then
			continue
		end
		local href = Interpolate.replace(url, {}, { format = uriEncode, macro = macro })
		local title = Interpolate.replace(Json.str(env, Json.path(env, l, "title")) or "", {}, {
			format = joinValues,
			macro = macro,
		})
		if replace then
			href, title = replace(href), replace(title)
		end
		local resolved = resolveUrl(href, opts.base_url)
		if resolved then
			table.insert(out, { title = if title ~= "" then title else resolved, url = resolved })
		end
	end
	return out
end

-- Tiles -------------------------------------------------------------------------

-- A leaf's tooltip and link over the image.
export type Hit = { x0: number, y0: number, x1: number, y1: number, title: string, href: string? }

-- The panel's content box: its Grafana size under its header, held to the
-- Tern card's height.
function M.size(panel: any, env: Env, opts: Common.Options): (number, number)
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	if opts.size then
		local title = Json.str(env, Json.path(env, panel, "title")) or ""
		W -= 2 * M.BORDER_PX
		H -= 2 * M.BORDER_PX + (if title ~= "" then M.HEADER_PX else 0)
	end
	if opts.card_height then
		H = math.min(H, opts.card_height)
	end
	return math.max(1, math.floor(W)), math.max(1, math.floor(H))
end

local function fits(label: string, w: number, h: number): boolean
	return Stat.textEm(label) * SvgTreemap.FONT + M.LABEL_MARGIN_X < w and M.LABEL_MARGIN_Y < h
end

-- The class of the color Grafana fills a leaf with: a fixed color keeps a
-- literal hex in both themes, a continuous scheme interpolates its colors.
local function leafClass(item: FieldConfig.Item, d: FieldConfig.Display, opts: Common.Options): string
	if d.class then
		return d.class
	end
	local cfg = item.config
	local mode = cfg.color_mode
	local fixed = cfg.fixed_color
	if (mode == "fixed" or mode == "shades") and fixed and d.color == Thresholds.color(fixed, opts.theme) then
		return TsGradient.fixedClass(fixed, opts.theme)
	elseif string.sub(mode, 1, 11) == "continuous-" and d.color == "" then
		local c = TsGradient.schemeColor(mode, d.percent, opts.theme)
		if c then
			return TsGradient.stopClass(c, opts.theme)
		end
	end
	if d.color ~= "" then
		return TsGradient.stopClass(d.color, opts.theme)
	end
	return Charts.toneClass(d.tone)
end

-- The drawn tiles and the leaves' hits for a W x H content box.
function M.tiles(
	panel: any,
	views: { View },
	frames: { Frame },
	env: Env,
	opts: Common.Options,
	W: number,
	H: number
): ({ SvgTreemap.Tile }, { Hit })
	local tiling = Json.str(env, Json.path(env, panel, "options", "tiling")) or "treemapSquarify"
	local laid = Layout.layout(M.hierarchy(views), W, H, {
		tiling = tiling,
		round = true,
		padding_inner = M.PADDING_INNER,
		padding_top = M.PADDING_TOP,
		padding_right = M.PADDING_OUTER,
		padding_bottom = M.PADDING_OUTER,
		padding_left = M.PADDING_OUTER,
	})
	local dopts: FieldConfig.Options = { theme = opts.theme, offset_min = opts.offset_min, now_ms = env.now_ms }
	local tiles: { SvgTreemap.Tile } = {}
	local hits: { Hit } = {}
	for i = 2, #laid do
		local t = laid[i]
		local name = t.input.name
		local w, h = t.x1 - t.x0, t.y1 - t.y0
		local label = if fits(name, w, h) then name else nil
		local leaf = t.input.data :: Leaf?
		if leaf == nil then
			table.insert(tiles, { x0 = t.x0, y0 = t.y0, x1 = t.x1, y1 = t.y1, label = label })
			continue
		end
		local v, row = leaf.view, leaf.row
		local sizeText = FieldConfig.joined(FieldConfig.display(v.size, v.size.field.values[row], dopts))
		local color = FieldConfig.display(v.color, v.color.field.values[row], dopts)
		table.insert(tiles, {
			x0 = t.x0,
			y0 = t.y0,
			x1 = t.x1,
			y1 = t.y1,
			class = leafClass(v.color, color, opts),
			label = label,
		})
		if w <= 0 or h <= 0 then
			continue
		end
		local lines = { name, sizeText }
		local badges: { string } = {}
		for _, it in v.labels do
			table.insert(badges, FieldConfig.joined(FieldConfig.display(it, it.field.values[row], dopts)))
		end
		if #badges > 0 then
			table.insert(lines, table.concat(badges, "  "))
		end
		local links = M.links(panel, env, leaf, frames, opts)
		for _, l in links do
			table.insert(lines, l.title)
		end
		table.insert(hits, {
			x0 = t.x0,
			y0 = t.y0,
			x1 = t.x1,
			y1 = t.y1,
			title = table.concat(lines, "\n"),
			href = if links[1] then links[1].url else nil,
		})
	end
	return tiles, hits
end

-- Overlay -----------------------------------------------------------------------

-- Hits along one axis in groups no tile crosses (a guillotine cut between
-- each), with each group's extent.
local function groupsAlong(hits: { Hit }, x: boolean): { { hits: { Hit }, lo: number, hi: number } }
	local sorted = table.clone(hits)
	table.sort(sorted, function(a: Hit, b: Hit): boolean
		if x then
			return a.x0 < b.x0
		end
		return a.y0 < b.y0
	end)
	local out: { { hits: { Hit }, lo: number, hi: number } } = {}
	local cur: { hits: { Hit }, lo: number, hi: number }? = nil
	for _, h in sorted do
		local lo, hi = if x then h.x0 else h.y0, if x then h.x1 else h.y1
		if cur and lo < cur.hi then
			table.insert(cur.hits, h)
			cur.hi = math.max(cur.hi, hi)
		else
			local g = { hits = { h }, lo = lo, hi = hi }
			table.insert(out, g)
			cur = g
		end
	end
	return out
end

local function spacer(key: string, basis: number): Node
	return { k = "el", p = { tag = "div", key = key, basis = basis, grow = 0, shrink = 0 } }
end

-- The hits inside the box as nested rows and columns whose bases are the
-- box's fractions (tiles sit apart by the padding, so gaps are spacers);
-- nil when they cannot be cut apart (never for d3's tilings).
local function region(hits: { Hit }, x0: number, y0: number, x1: number, y1: number, basis: number, key: string): Node?
	for _, x in { true, false } do
		local lo, hi = if x then x0 else y0, if x then x1 else y1
		local span = hi - lo
		local groups = groupsAlong(hits, x)
		if #groups == 1 and groups[1].lo <= lo and groups[1].hi >= hi then
			continue
		end
		local children: { Node } = {}
		local at = lo
		for i, g in groups do
			if g.lo > at then
				table.insert(children, spacer("s" .. i, (g.lo - at) / span))
			end
			local child = if x
				then region(g.hits, g.lo, y0, g.hi, y1, (g.hi - g.lo) / span, "n" .. i)
				else region(g.hits, x0, g.lo, x1, g.hi, (g.hi - g.lo) / span, "n" .. i)
			table.insert(children, child or spacer("n" .. i, (g.hi - g.lo) / span))
			at = g.hi
		end
		return {
			k = if x then "row" else "col",
			p = { key = key, basis = basis, grow = 0, shrink = 0, align = "stretch" },
			c = children,
		}
	end
	if #hits ~= 1 then
		return nil
	end
	local h = hits[1]
	return {
		k = "el",
		p = {
			tag = "div",
			key = key,
			basis = basis,
			grow = 0,
			shrink = 0,
			class = if h.href then "tgp-tm-hit tgp-tm-link" else "tgp-tm-hit",
			title = h.title,
			actions = if h.href then { click = "dlink=" .. Url.percentEncode(h.href :: string) } else nil,
		},
	}
end

-- The image overlay of the hits over a W x H image.
function M.overlay(hits: { Hit }, W: number, H: number): Node?
	if #hits == 0 then
		return nil
	end
	local inner = region(hits, 0, 0, W, H, 1, "tm")
	if inner == nil then
		return nil
	end
	return { k = "row", p = { key = "tmo", grow = 1, align = "stretch" }, c = { inner } }
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local views = M.views(panel, frames, env)
	if #views == 0 then
		return ui.muted(M.WIZARD, { key = opts.key }), {}
	end
	local W, H = M.size(panel, env, opts)
	local tiles, hits = M.tiles(panel, views, frames, env, opts, W, H)
	local chart, assets = Charts.image(
		opts.key,
		SvgTreemap.render(tiles, W, H),
		W,
		H,
		Charts.alt(panel, env, "Treemap"),
		"tern-grafana.treemap"
	)
	local over = M.overlay(hits, W, H)
	if over then
		(chart :: any).c = { over }
	end
	return chart, assets
end

return M
