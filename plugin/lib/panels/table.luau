--!strict
-- The table panel (public/app/plugins/panel/table: panelcfg.cue; grafana-ui
-- Table/TableNG cells/renderers.tsx) over lib/render/grid. Frames arrive
-- transformed (lib/panels/transform: the Prometheus format=table merge,
-- organize, filterFieldsByName), so columns are the frame's visible fields:
-- - headers are field display names (renames and displayName overrides);
-- - cells go through the display processor (unit, decimals, mappings,
--   time fields as dates; object values as JSON);
-- - custom.cellOptions (a legacy custom.displayMode wins, migrated as
--   getCellOptions does) picks the cell: color-text colors the value,
--   color-background fills the cell (mode basic or gradient, applyToRow
--   fills the row), gauge is BarGaugeCell (mode basic/gradient/lcd,
--   valueDisplayMode text by default, color or hidden), pill splits the
--   value into colored tags, markdown renders it, json-view prints it;
--   pill and markdown fall back to auto off string fields as in Grafana.
--   sparkline, image, data-links, actions and custom cells ladder
--   (`unsupported`). custom.align and custom.hidden apply;
-- - options.sortBy sorts rows; the footer (options.footer.show with its
--   reducer, or per-field custom.footer.reducers) adds a reduced row;
-- - columns are sized as TableNG does by the server's table.autoColumnWidths
--   flag: custom.width exactly; the others, with the flag on, to their
--   content (at least custom.minWidth, at most 400px; a gauge column 150px)
--   without shrinking, so a wide table scrolls sideways instead of
--   squeezing, sharing the leftover width when no column has a fixed width;
--   with it off, sharing the width evenly, at least custom.minWidth or 150px;
-- - field data links (links, from the frame or fieldConfig) draw the cell
--   as a link that opens the first one in the browser pane;
-- - options.enablePagination (footer.enablePagination before Grafana 12.2)
--   pages rows with usePaginatedRows' page size for the panel's Grafana
--   height and cellHeight; the pager flips pages (`tpage`).
-- - several frames: TablePanel shows one, options.frameIndex (0-based) or
--   the one picked in the frame selector under it (`tframe`), else the
--   first; the selector names each frame (getFrameDisplayName).

local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Gauge = require("./gauge")
local Grid = require("../render/grid")
local Html = require("./html")
local Interpolate = require("../dashboard/interpolate")
local Json = require("./json")
local Reduce = require("./reduce")
local TsGradient = require("../render/ts_gradient")
local Url = require("../url")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node
type Item = FieldConfig.Item

export type Pill = { text: string, class: string }

export type Cell = {
	text: string,
	-- "auto", "color-text", "color-background", "gauge", "pill", "markdown",
	-- "json-view".
	kind: string,
	tone: string,
	-- Palette color modes: the series class (tg-s1..tg-s10).
	class: string?,
	percent: number,
	-- gauge: mode ("basic", "gradient", "lcd"), valueDisplayMode ("text",
	-- "color", "hidden"), for lcd the threshold bands and for gradient the
	-- bar's color runs (getBarGradient).
	gauge_mode: string?,
	value_mode: string?,
	parts: { Gauge.Part }?,
	segments: { Segment }?,
	-- A filled background (the cell's own color-background or its row's
	-- applyToRow color): tone or palette class, and "basic" or "gradient".
	bg_tone: string?,
	bg_class: string?,
	bg_mode: string?,
	pills: { Pill }?,
	-- The first data link's URL (resolved against the Grafana's base URL).
	href: string?,
}

-- One run of a gradient bar: `width` of the filled part (0..1), fading
-- from one color stop class (lib/render/ts_gradient stopClass) to another.
export type Segment = { width: number, from: string, to: string }

export type Column = {
	head: string,
	numeric: boolean,
	item: Item,
	-- Gauge columns: the longest shown value in characters (0 with
	-- valueDisplayMode hidden), capped at MAX_VALUE_WIDTH.
	value_width: number?,
	-- custom.width and custom.minWidth in px.
	width: number?,
	min_width: number?,
}

export type Pager = {
	-- 1-based page, page count, rows per page and rows in all pages.
	page: number,
	pages: number,
	size: number,
	total: number,
}

export type Table = {
	columns: { Column },
	rows: { { Cell } },
	footer: { string }?,
	-- Rows beyond the cap.
	more_rows: number,
	-- The frame shown (1-based) and every frame's display name, when there
	-- are several.
	frame: number,
	frame_names: { string }?,
	-- Columns beyond the grid's limit.
	more_columns: number,
	pager: Pager?,
}

local M = {}

M.MAX_ROWS = 500
-- Columns drawn (panels.css tgp-table tg-cols-1..48); TableNG draws every
-- column and scrolls sideways, as tg-wrap does.
M.MAX_COLUMNS = 48

-- panels.css has tgp-gw-0 .. tgp-gw-<MAX_VALUE_WIDTH>.
M.MAX_VALUE_WIDTH = 24

-- panels.css has tgp-cw-5 .. tgp-cw-<MAX_WIDTH_CLASS> (custom.width) and
-- tgp-cmin-5 .. (custom.minWidth), in 10px steps.
M.MAX_WIDTH_CLASS = 80

-- TableNG COLUMN.DEFAULT_WIDTH: an auto column's floor when the columns
-- share the width (table.autoColumnWidths off).
M.DEFAULT_WIDTH = 150

-- Cell types drawn natively; the others ladder with their reason.
local UNSUPPORTED: { [string]: string } = {
	sparkline = "sparkline",
	image = "image",
	["data-links"] = "data-links",
	actions = "actions",
	custom = "custom",
}

-- migrateTableDisplayModeToCellOptions.
local LEGACY: { [string]: { type: string, mode: string? } } = {
	["basic"] = { type = "gauge", mode = "basic" },
	["gradient-gauge"] = { type = "gauge", mode = "gradient" },
	["lcd-gauge"] = { type = "gauge", mode = "lcd" },
	["color-background"] = { type = "color-background", mode = "gradient" },
	["color-background-solid"] = { type = "color-background", mode = "basic" },
	["custom"] = { type = "auto" },
}

type CellOptions = { type: string, mode: string?, value_mode: string?, apply_to_row: boolean }

-- getCellOptions: a legacy displayMode wins over cellOptions.
local function cellOptions(item: Item): CellOptions
	local custom = item.config.custom
	local legacy = custom.displayMode
	if type(legacy) == "string" and legacy ~= "" then
		local m = LEGACY[legacy]
		return if m
			then { type = m.type, mode = m.mode, apply_to_row = false }
			else { type = legacy, apply_to_row = false }
	end
	local opts = custom.cellOptions
	if type(opts) ~= "table" or type(opts.type) ~= "string" then
		return { type = "auto", apply_to_row = false }
	end
	return {
		type = opts.type,
		mode = if type(opts.mode) == "string" then opts.mode else nil,
		value_mode = if type(opts.valueDisplayMode) == "string" then opts.valueDisplayMode else nil,
		apply_to_row = opts.applyToRow == true,
	}
end

-- The cell type a field draws as (getCellRenderer): pill and markdown only
-- take string fields (pill also `other` fields holding arrays); object
-- fields in auto print as JSON.
local function cellKind(item: Item, opts: CellOptions): string
	local t = opts.type
	local fieldType = item.field.type
	if t == "pill" then
		if fieldType == "string" then
			return "pill"
		end
		if fieldType == "other" then
			for _, v in item.field.values do
				if type(v) == "table" and v[1] ~= nil then
					return "pill"
				end
			end
		end
		return "auto"
	elseif t == "markdown" then
		return if fieldType == "string" then "markdown" else "auto"
	elseif t == "color-text" or t == "color-background" or t == "gauge" or t == "json-view" then
		return t
	end
	return if fieldType == "other" then "json-view" else "auto"
end

-- Panel-level reason a table is not drawn natively: a cell type from the
-- field config defaults or any override (custom.cellOptions or a legacy
-- custom.displayMode).
function M.unsupported(panel: any, env: Env): string?
	local function check(t: string?): string?
		if t and UNSUPPORTED[t] then
			return string.format("table cell type %s is not supported", UNSUPPORTED[t])
		end
		return nil
	end
	local custom = Json.path(env, panel, "fieldConfig", "defaults", "custom")
	local why = check(Json.str(env, Json.path(env, custom, "displayMode")))
		or check(Json.str(env, Json.path(env, custom, "cellOptions", "type")))
	if why then
		return why
	end
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		for _, p in Json.list(env, Json.path(env, o, "properties")) do
			local id = Json.str(env, Json.path(env, p, "id"))
			local value = Json.path(env, p, "value")
			why = if id == "custom.cellOptions"
				then check(Json.str(env, Json.path(env, value, "type")))
				elseif id == "custom.displayMode" then check(Json.str(env, value))
				else nil
			if why then
				return why
			end
		end
	end
	return nil
end

-- string-hash (the npm package getColorByStringHash uses): djb2 with xor,
-- over UTF-16 code units from the end, as an unsigned 32-bit number.
local function stringHash(s: string): number
	local codes: { number } = {}
	local ok = pcall(function()
		for _, c in utf8.codes(s) do
			if c >= 0x10000 then
				local v = c - 0x10000
				table.insert(codes, 0xD800 + bit32.rshift(v, 10))
				table.insert(codes, 0xDC00 + bit32.band(v, 0x3FF))
			else
				table.insert(codes, c)
			end
		end
	end)
	if not ok then
		codes = { string.byte(s, 1, -1) }
	end
	local h = 5381
	for i = #codes, 1, -1 do
		h = bit32.bxor((h * 33) % 4294967296, codes[i])
	end
	return h
end

-- Grafana's classicColors (namedColorsPalette.ts); panels.css has
-- tgp-pill-0 .. tgp-pill-55 with getTextColorForBackground text.
M.CLASSIC_COLORS = 56

-- getPillColors: mappings color the pill, a fixed color too; palette modes
-- hash the pill over the series palette, everything else (thresholds, the
-- table default) over classicColors.
local function pillClass(item: Item, d: FieldConfig.Display, text: string): string
	local mode = item.config.color_mode
	if #item.config.mappings > 0 or mode == "fixed" or mode == "shades" then
		return "tgp-cbg " .. Common.toneClass(d.tone)
	elseif mode == "palette-classic" or mode == "palette-classic-by-name" then
		return "tgp-cbg " .. FieldConfig.paletteClass(stringHash(text) % FieldConfig.PALETTE + 1)
	end
	return "tgp-pill-" .. tostring(stringHash(text) % M.CLASSIC_COLORS)
end

-- inferPills: arrays as they are, "[...]" strings as JSON, otherwise split
-- on commas.
local function inferPills(env: Env, value: any): { any }
	if value == nil or value == Frame.NULL or value == "" then
		return {}
	end
	if type(value) == "table" then
		local out = {}
		for _, v in value do
			if v ~= Frame.NULL and v ~= env.null then
				table.insert(out, if type(v) == "string" then string.match(v, "^%s*(.-)%s*$") :: string else v)
			end
		end
		return out
	end
	local s = if type(value) == "string" then value else tostring(value)
	if string.sub(s, 1, 1) == "[" then
		local ok, decoded = pcall(env.decode, s)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	local out = {}
	s = string.match(s, "^%s*(.-)%s*$") :: string
	local from = 1
	while true do
		local a, b = string.find(s, "%s*,%s*", from)
		if not a then
			table.insert(out, string.sub(s, from))
			break
		end
		table.insert(out, string.sub(s, from, a - 1))
		from = (b :: number) + 1
	end
	return out
end

-- JSON with the spacing JSON.stringify(v, null, ' ') shows on one line:
-- "{ "a": 1, "b": [ 1, 2 ] }", empty containers as "{}" and "[]".
local function spaced(json: string): string
	local out: { string } = {}
	local i, n = 1, #json
	while i <= n do
		local ch = string.sub(json, i, i)
		if ch == '"' then
			local j = i + 1
			while j <= n do
				local cj = string.sub(json, j, j)
				if cj == "\\" then
					j += 2
				elseif cj == '"' then
					break
				else
					j += 1
				end
			end
			table.insert(out, string.sub(json, i, j))
			i = j + 1
		elseif ch == "{" or ch == "[" then
			local close = if ch == "{" then "}" else "]"
			local k = string.find(json, "[^%s]", i + 1)
			if k and string.sub(json, k, k) == close then
				table.insert(out, ch .. close)
				i = k + 1
			else
				table.insert(out, ch .. " ")
				i += 1
			end
		elseif ch == "}" or ch == "]" then
			table.insert(out, " " .. ch)
			i += 1
		elseif ch == "," or ch == ":" then
			table.insert(out, ch .. " ")
			i += 1
		elseif string.find(ch, "%s") then
			i += 1
		else
			table.insert(out, ch)
			i += 1
		end
	end
	return table.concat(out)
end

-- displayJsonValue: objects and arrays as JSON, text that parses as JSON
-- re-printed, anything else as displayed.
local function jsonText(env: Env, value: any, displayed: string): string
	if type(value) == "table" and value ~= Frame.NULL then
		return spaced(env.encode(value))
	end
	local ok, decoded = pcall(env.decode, displayed)
	if ok and decoded ~= nil then
		return spaced(displayed)
	end
	return displayed
end

type Stop = { at: number, class: string }

-- Runs between CSS gradient stops (positions ascending, 0..1).
local function runs(stops: { Stop }): { Segment }
	local out: { Segment } = {}
	for j = 1, #stops - 1 do
		local a, b = stops[j], stops[j + 1]
		if b.at > a.at then
			table.insert(out, { width = b.at - a.at, from = a.class, to = b.class })
		end
	end
	return out
end

-- getBarGradient over the filled part (`fill` of the bar): thresholds keep
-- the base color, then fade into each passed step's color from halfway
-- between the step positions, reaching the last at the bar's end; a
-- continuous scheme spans the whole bar and is cut at the fill. Other
-- color modes draw the value's color (nil).
local function gradientSegments(item: Item, numeric: number?, fill: number, theme: any): { Segment }?
	local mode = item.config.color_mode
	if fill <= 0 then
		return nil
	end
	if mode == "thresholds" then
		local t = item.config.thresholds
		local lo, hi = item.range_min or 0, item.range_max or 100
		local percentage = t.mode == "percentage"
		local passed: { Stop } = {}
		local last = 0
		for i, step in t.steps do
			local class = TsGradient.stopClass(step.color, theme)
			if i == 1 then
				table.insert(passed, { at = 0, class = class })
				continue
			end
			local sv = step.value
			if type(sv) ~= "number" then
				continue
			end
			local at = if percentage then sv / 100 elseif hi > lo then (sv - lo) / (hi - lo) else 0
			local threshold = if percentage then lo + (hi - lo) * at else sv
			if numeric == nil or numeric < threshold then
				break
			end
			table.insert(passed, { at = math.clamp((at - (at - last) / 2) / fill, 0, 1), class = class })
			last = at
		end
		if #passed == 0 then
			return nil
		end
		-- "c0, c0 q1, c1 q2, ..., cN": each color holds until the next offset.
		local stops: { Stop } = { { at = 0, class = passed[1].class } }
		for j = 2, #passed do
			table.insert(stops, { at = math.max(passed[j].at, stops[#stops].at), class = passed[j - 1].class })
		end
		table.insert(stops, { at = 1, class = passed[#passed].class })
		return runs(stops)
	elseif string.sub(mode, 1, 11) == "continuous-" then
		local stops: { Stop } = {}
		for k = 0, 3 do
			local x = fill * k / 3
			local color = TsGradient.schemeColor(mode, x, theme)
			if color == nil then
				return nil
			end
			table.insert(stops, { at = k / 3, class = TsGradient.stopClass(color, theme) })
		end
		return runs(stops)
	end
	return nil
end

-- Data links -------------------------------------------------------------------

-- A field's data links (getLinks): the frame's own, else the defaults',
-- replaced by each matching override's.
local function fieldLinks(panel: any, env: Env, item: Item, frames: { Frame }): { any }
	local own = item.field.config and (item.field.config :: any).links
	local links = if type(own) == "table" and #own > 0
		then own
		else Json.list(env, Json.path(env, panel, "fieldConfig", "defaults", "links"))
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

-- getFieldDisplayValuesProxy: a field of the row by name, display name,
-- index, then config displayName.
local function rowField(items: { Item }, key: string): Item?
	for _, it in items do
		if it.field.name == key then
			return it
		end
	end
	for _, it in items do
		if it.name == key then
			return it
		end
	end
	local n = tonumber(key)
	if n and items[n + 1] then
		return items[n + 1]
	end
	for _, it in items do
		if it.config.display_name == key then
			return it
		end
	end
	return nil
end

local function jsString(v: any): string
	if type(v) == "number" then
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return tostring(v)
	end
	return if v == nil or Frame.isNull(v) then "" else tostring(v)
end

-- The data macros (`${__data.fields.x}`, `${__value.raw|numeric|text}`,
-- `${__field.name}`, `${__series.name}`, `${__data.name|refId}`) of one cell.
local function cellMacro(
	item: Item,
	items: { Item },
	row: number,
	disp: FieldConfig.Options
): (string, string?) -> Interpolate.Var?
	return function(name: string, path: string?): Interpolate.Var?
		if name == "__data" and path then
			if path == "name" then
				return Interpolate.value(item.frame.name or "")
			elseif path == "refId" then
				return Interpolate.value(item.frame.refId or "")
			end
			local key = string.match(path, "^fields%.(.+)$")
				or string.match(path, "^fields%[(%d+)%]$")
				or string.match(path, '^fields%["(.-)"%]$')
				or string.match(path, "^fields%['(.-)'%]$")
			local it = if key then rowField(items, key) else nil
			if it then
				return Interpolate.value(FieldConfig.joined(FieldConfig.display(it, it.field.values[row], disp)))
			end
		elseif name == "__value" then
			local raw = item.field.values[row]
			if path == "raw" then
				return Interpolate.value(jsString(raw))
			end
			local d = FieldConfig.display(item, raw, disp)
			if path == "numeric" then
				return Interpolate.value(jsString(d.numeric or 0 / 0))
			elseif path == "text" or path == nil then
				return Interpolate.value(d.text)
			end
		elseif name == "__field" and path == "name" then
			return Interpolate.value(item.name)
		elseif name == "__series" and path == "name" then
			return Interpolate.value(item.frame.name or "")
		end
		return nil
	end
end

local URI = Interpolate.named("uriencode")

-- The cell's first data link as the browser opens it (getDataLinkUIModel:
-- the URL `uriencode`d, Grafana's <base href> resolving a relative path).
local function cellHref(
	link: any,
	env: Env,
	macro: (string, string?) -> Interpolate.Var?,
	opts: Common.Options
): string?
	local url = Json.str(env, Json.path(env, link, "url"))
	if url == nil or url == "" then
		return nil
	end
	local href = Interpolate.replace(url, {}, { format = URI, macro = macro })
	if opts.replace then
		href = opts.replace(href)
	end
	href = string.gsub(href, "\n", "")
	if not string.match(href, "^%a[%w+.-]*:") and string.sub(href, 1, 1) ~= "/" then
		href = "/" .. href
	end
	return Html.resolve(href, opts.base_url)
end

-- Pagination --------------------------------------------------------------------

-- TableNG's row heights per options.cellHeight (sm by default), its header
-- and pagination chrome, and the panel chrome above the table (header and
-- padding) in px.
local ROW_PX: { [string]: number } = { sm = 36, md = 42, lg = 48 }
local HEADER_PX = 36
local PAGER_PX = 38
local PANEL_CHROME_PX = 40

-- usePaginatedRows: rows that fit the panel's Grafana height, at least one.
function M.pageSize(panel: any, env: Env, heightPx: number): number
	local cell = Json.str(env, Json.path(env, panel, "options", "cellHeight")) or "sm"
	local header = if Json.bool(env, Json.path(env, panel, "options", "showHeader")) == false then 0 else HEADER_PX
	local area = heightPx - PANEL_CHROME_PX - header - PAGER_PX
	return math.max(1, math.floor(area / (ROW_PX[cell] or ROW_PX.sm)))
end

local function paginated(panel: any, env: Env): boolean
	local own = Json.bool(env, Json.path(env, panel, "options", "enablePagination"))
	if own ~= nil then
		return own
	end
	return Json.bool(env, Json.path(env, panel, "options", "footer", "enablePagination")) == true
end

local function compare(a: any, b: any): boolean
	local na, nb = Frame.isNull(a), Frame.isNull(b)
	if na or nb then
		-- Missing values sort last ascending.
		return nb and not na
	end
	if type(a) == "number" and type(b) == "number" then
		return a < b
	end
	return tostring(a) < tostring(b)
end

-- getFrameDisplayName(frame) without an index: its name, its one value
-- field's display name, else all of them joined.
local function frameName(frame: Frame): string
	if frame.name and frame.name ~= "" then
		return frame.name
	end
	local names: { string } = {}
	for _, f in frame.fields do
		if f.type ~= "time" then
			table.insert(names, FieldConfig.displayName(f, frame))
		end
	end
	if #names > 0 or #frame.fields > 0 then
		return table.concat(names, ", ")
	end
	return if frame.refId and frame.refId ~= "" then "Series (" .. frame.refId .. ")" else "Series (undefined)"
end

-- getCurrentFrameIndex: the picked frame, else options.frameIndex when it
-- names a frame past the first, else the first.
function M.frameIndex(panel: any, frames: { Frame }, env: Env, opts: Common.Options): number
	local picked = opts.frame
	if picked and picked >= 1 and picked <= #frames then
		return picked
	end
	local option = Json.num(env, Json.path(env, panel, "options", "frameIndex"))
	if option and option > 0 and option < #frames and option == math.floor(option) then
		return option + 1
	end
	return 1
end

function M.build(panel: any, frames: { Frame }, env: Env, opts: Common.Options): Table
	-- Only the shown frame becomes columns; the others still name and range
	-- its fields.
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "thresholds" }, true)
	local index = M.frameIndex(panel, frames, env, opts)
	local first = frames[index]
	local columns: { Column } = {}
	-- Every field of the shown frame, hidden ones too: `${__data.fields.x}`.
	local frameItems: { Item } = {}
	for _, item in items do
		if item.frame ~= first then
			continue
		end
		table.insert(frameItems, item)
		if not FieldConfig.hidden(item) then
			local custom = item.config.custom
			local align = custom.align
			local numeric = if align == "right"
				then true
				elseif align == "left" or align == "center" then false
				else item.field.type == "number"
			local width = if type(custom.width) == "number" and custom.width > 0 then custom.width else nil
			local minWidth = if type(custom.minWidth) == "number" and custom.minWidth > 0 then custom.minWidth else nil
			table.insert(
				columns,
				{ head = item.name, numeric = numeric, item = item, width = width, min_width = minWidth }
			)
		end
	end
	local moreColumns = math.max(0, #columns - M.MAX_COLUMNS)
	while #columns > M.MAX_COLUMNS do
		table.remove(columns)
	end
	local n = 0
	for _, c in columns do
		n = math.max(n, #c.item.field.values)
	end
	local order: { number } = table.create(n)
	for i = 1, n do
		order[i] = i
	end
	-- sortBy: the first entry whose display name is a column.
	for _, s in Json.list(env, Json.path(env, panel, "options", "sortBy")) do
		local name = Json.str(env, Json.path(env, s, "displayName"))
		local desc = Json.bool(env, Json.path(env, s, "desc")) == true
		local col: Column? = nil
		for _, c in columns do
			if c.head == name then
				col = c
				break
			end
		end
		if col then
			local values = (col :: Column).item.field.values
			table.sort(order, function(x: number, y: number): boolean
				local a, b = values[x], values[y]
				if desc then
					a, b = b, a
				end
				if compare(a, b) then
					return true
				elseif compare(b, a) then
					return false
				end
				return x < y
			end)
			break
		end
	end
	local disp: FieldConfig.Options = { theme = opts.theme, offset_min = opts.offset_min, now_ms = env.now_ms }
	local cellOpts: { CellOptions } = table.create(#columns)
	local kinds: { string } = table.create(#columns)
	-- getApplyToRowBgFn: the first color-background field with applyToRow
	-- fills its rows' auto and color-text cells.
	local rowCol: number? = nil
	for c, col in columns do
		cellOpts[c] = cellOptions(col.item)
		kinds[c] = cellKind(col.item, cellOpts[c])
		if rowCol == nil and kinds[c] == "color-background" and cellOpts[c].apply_to_row then
			rowCol = c
		end
	end
	local links: { any? } = table.create(#columns)
	for c, col in columns do
		links[c] = fieldLinks(panel, env, col.item, frames)[1]
	end
	local pager: Pager? = nil
	local firstRow, lastRow = 1, math.min(n, M.MAX_ROWS)
	if paginated(panel, env) and opts.size and n > 0 then
		local size = M.pageSize(panel, env, opts.size.h)
		local pages = math.max(1, math.ceil(n / size))
		local page = math.clamp(opts.page or 1, 1, pages)
		pager = { page = page, pages = pages, size = size, total = n }
		firstRow, lastRow = (page - 1) * size + 1, math.min(n, page * size)
	end
	local rows: { { Cell } } = {}
	for r = firstRow, lastRow do
		local idx = order[r]
		local cells: { Cell } = table.create(#columns)
		for c, col in columns do
			local item = col.item
			local value = item.field.values[idx]
			local d = FieldConfig.display(item, value, disp)
			local kind = kinds[c]
			if kind == "json-view" then
				d.text = jsonText(env, value, FieldConfig.joined(d))
				d.prefix, d.suffix = "", ""
			elseif type(value) == "table" and value ~= Frame.NULL then
				d.text = env.encode(value)
			end
			local co = cellOpts[c]
			local cell: Cell = {
				text = FieldConfig.joined(d),
				kind = kind,
				tone = d.tone,
				class = d.class,
				percent = d.percent,
			}
			local link = links[c]
			if link then
				cell.href = cellHref(link, env, cellMacro(item, frameItems, idx, disp), opts)
			end
			if kind == "gauge" then
				cell.gauge_mode = co.mode or "gradient"
				cell.value_mode = co.value_mode or "text"
				local fill = math.clamp(if d.percent == d.percent then d.percent else 0, 0, 1)
				if cell.gauge_mode == "gradient" then
					cell.segments = gradientSegments(item, d.numeric, fill, opts.theme)
				elseif cell.gauge_mode == "lcd" and item.config.color_mode == "thresholds" then
					-- lcd lights cells in their threshold band's color.
					cell.parts = Gauge.bandParts(item, fill, d.tone)
				end
			elseif kind == "color-background" then
				cell.bg_tone, cell.bg_class, cell.bg_mode = d.tone, d.class, co.mode or "gradient"
			elseif kind == "pill" then
				local pills: { Pill } = {}
				for _, v in inferPills(env, value) do
					local pd = FieldConfig.display(item, v, disp)
					local text = FieldConfig.joined(pd)
					table.insert(pills, { text = text, class = pillClass(item, pd, text) })
				end
				cell.pills = pills
			end
			cells[c] = cell
		end
		if rowCol then
			local src = cells[rowCol :: number]
			for _, cell in cells do
				if cell.kind ~= "pill" and cell.kind ~= "color-background" then
					cell.bg_tone, cell.bg_class, cell.bg_mode = src.bg_tone, src.bg_class, src.bg_mode
				end
			end
		end
		table.insert(rows, cells)
	end
	for c, col in columns do
		if kinds[c] == "gauge" then
			local width = 0
			for _, row in rows do
				local cell = row[c]
				if cell.value_mode ~= "hidden" then
					width = math.max(width, utf8.len(cell.text) or #cell.text)
				end
			end
			col.value_width = math.min(width, M.MAX_VALUE_WIDTH)
		end
	end
	-- Footer: the panel-wide reducer (options.footer) or per-field reducers.
	local footerOpts = Json.obj(env, Json.path(env, panel, "options", "footer"))
	local panelReducer: string? = nil
	if Json.bool(env, footerOpts.show) == true then
		local r = Json.list(env, footerOpts.reducer)[1]
		panelReducer = if type(r) == "string" then r else nil
	end
	local footerFields = Json.list(env, footerOpts.fields)
	local footer: { string }? = nil
	for c, col in columns do
		if col.item.field.type ~= "number" then
			continue
		end
		-- A field's own footer reducers (Grafana 12) win over the panel's,
		-- which apply to options.footer.fields (all number fields when empty).
		local reducer: string? = nil
		local own = col.item.config.custom.footer
		if type(own) == "table" and type(own.reducers) == "table" and type(own.reducers[1]) == "string" then
			reducer = own.reducers[1]
		elseif panelReducer and (#footerFields == 0 or table.find(footerFields, col.head) ~= nil) then
			reducer = panelReducer
		end
		if reducer == nil then
			continue
		end
		local f: { string } = footer or table.create(#columns, "")
		if Reduce.supports(reducer) then
			local v = Reduce.reduce(col.item.field.values, reducer, col.item.field.type, col.item.config.null_mode)
			f[c] = FieldConfig.joined(FieldConfig.display(col.item, v, disp))
		else
			f[c] = "-"
		end
		footer = f
	end
	local names: { string }? = nil
	if #frames > 1 then
		local list: { string } = table.create(#frames)
		for i, f in frames do
			list[i] = frameName(f)
		end
		names = list
	end
	return {
		columns = columns,
		rows = rows,
		footer = footer,
		more_rows = if pager then 0 else math.max(0, n - M.MAX_ROWS),
		frame = index,
		frame_names = names,
		more_columns = moreColumns,
		pager = pager,
	}
end

-- A gradient bar (BarGauge gradient mode): the filled part a row of runs,
-- each fading between two stop classes (tgp-gseg carries the first color
-- down to its tgp-gseg-to child as --tgp-from), the rest the empty track.
local function gradientBar(cell: Cell): Node
	local fill = math.clamp(if cell.percent == cell.percent then cell.percent else 0, 0, 1)
	local fills: { Node } = {}
	local segs: { Segment } = cell.segments or {}
	for i, s in segs do
		local width = if i == #segs then " tgp-gseg-last" else " tgp-w-" .. math.floor(s.width * 100 + 0.5)
		fills[i] = {
			k = "el",
			p = { tag = "div", key = "s" .. i, class = "tgp-gseg " .. s.from .. width },
			c = { { k = "el", p = { tag = "div", class = "tgp-gseg-to " .. s.to } } },
		}
	end
	return {
		k = "el",
		p = { tag = "div", key = "m", class = "tgp-gbar" },
		c = {
			{ k = "el", p = { tag = "div", class = "tgp-gfill tgp-w-" .. math.floor(fill * 100 + 0.5) }, c = fills },
		},
	}
end

-- BarGaugeCell: a horizontal bar gauge filling the cell, the value after
-- it (valueDisplayMode text: plain, color: in the value's color, hidden:
-- none). The wrapper gives the bar a width in the content-sized column; the
-- value box is `width` characters wide (getAlignmentFactor: the column's
-- longest value), so the bar shrinks first and the value is never cut.
local function gaugeNode(cell: Cell, width: number): Node
	local bar: Node
	if cell.segments then
		bar = gradientBar(cell)
	else
		local p: { [string]: any } = {
			key = "m",
			value = math.clamp(if cell.percent == cell.percent then cell.percent else 0, 0, 1),
			style = if cell.gauge_mode == "lcd" then "blocks" else "bar",
			size = "sm",
			grow = 1,
		}
		if cell.parts then
			p.parts = cell.parts
		else
			-- `neutral` would yield to the accent default; Grafana's fallback is gray.
			p.tone = if cell.tone == "neutral" then "muted" else cell.tone
		end
		bar = { k = "meter", p = p }
	end
	local children: { Node } = { bar }
	if cell.value_mode ~= "hidden" then
		local token = if cell.value_mode == "color" then Common.token(cell.tone :: any) else ""
		table.insert(children, {
			k = "el",
			p = { tag = "div", key = "v", class = "tgp-gc-v tgp-gw-" .. width },
			c = { Grid.text(cell.text, if token ~= "" then token else nil) },
		})
	end
	return { k = "el", p = { tag = "div", class = "tgp-gc" }, c = children }
end

local function contentNode(cell: Cell, width: number): Node
	if cell.kind == "gauge" then
		return gaugeNode(cell, width)
	elseif cell.kind == "pill" then
		local list: { Pill } = cell.pills or {}
		local pills: { Node } = table.create(#list)
		for i, pill in list do
			pills[i] = {
				k = "el",
				p = { tag = "span", key = "p" .. i, class = "tgp-pill " .. pill.class, text = pill.text },
			}
		end
		return { k = "el", p = { tag = "div", class = "tgp-pills" }, c = pills }
	elseif cell.kind == "markdown" then
		return { k = "el", p = { tag = "div", class = "tgp-cmd" }, c = { { k = "md", p = { text = cell.text } } } }
	elseif cell.kind == "json-view" then
		return Grid.text(cell.text, "mono")
	elseif cell.kind == "color-text" then
		if cell.class then
			return { k = "el", p = { tag = "span", class = cell.class :: string, text = cell.text } }
		end
		local token = Common.token(cell.tone :: any)
		return Grid.text(cell.text, if token ~= "" then token else nil)
	end
	return Grid.text(cell.text)
end

-- The content in a box at most MAX_AUTO_WIDTH wide (tgp-cv): an auto
-- column is as wide as its widest box. A data link makes the box a link
-- that opens it on click.
local function cellNode(cell: Cell, width: number): Node
	local box: { [string]: any } = { tag = "div", class = "tgp-cv" }
	if cell.href then
		box.class = "tgp-cv tgp-dlink"
		box.title = cell.href
		box.actions = { click = "dlink=" .. Url.percentEncode(cell.href :: string) }
	end
	local content: Node = { k = "el", p = box, c = { contentNode(cell, width) } }
	if cell.bg_tone == nil then
		return content
	end
	-- getCellColorInlineStyles: the color, or a 120deg gradient from a
	-- darker, hue-rotated copy of it, with contrasting text.
	local class = "tgp-cbg "
		.. (cell.bg_class or Common.toneClass(cell.bg_tone :: any))
		.. (if cell.bg_mode == "basic" then "" else " tgp-cbg-grad")
	return { k = "el", p = { tag = "div", class = class }, c = { content } }
end

-- The page buttons Grafana's Pagination shows: all up to 8 pages, else
-- seven around the current one with the first or last behind an ellipsis
-- (0 marks the ellipsis).
function M.pageButtons(page: number, pages: number): { number }
	local out: { number } = {}
	if pages <= 8 then
		for i = 1, pages do
			table.insert(out, i)
		end
		return out
	end
	if page < 5 then
		for i = 1, 7 do
			table.insert(out, i)
		end
		table.insert(out, 0)
		table.insert(out, pages)
	elseif page > pages - 4 then
		table.insert(out, 1)
		table.insert(out, 0)
		for i = pages - 6, pages do
			table.insert(out, i)
		end
	else
		table.insert(out, 1)
		table.insert(out, 0)
		for i = page - 2, page + 2 do
			table.insert(out, i)
		end
		table.insert(out, 0)
		table.insert(out, pages)
	end
	return out
end

-- The pager under a paginated table: previous, the page buttons, next and
-- "first - last of total rows"; buttons send `tpage=<page>:<panel key>`.
local function pagerNode(p: Pager, key: string): Node
	local function button(id: string, label: string, target: number?, class: string): Node
		local props: { [string]: any } = { tag = "span", key = id, class = "tgp-pg-b " .. class, text = label }
		if target then
			props.actions = { click = "tpage=" .. target .. ":" .. key }
		end
		return { k = "el", p = props }
	end
	local children: { Node } = {
		button("prev", "<", if p.page > 1 then p.page - 1 else nil, if p.page > 1 then "" else "tgp-pg-off"),
	}
	for i, n in M.pageButtons(p.page, p.pages) do
		if n == 0 then
			table.insert(children, { k = "el", p = { tag = "span", key = "e" .. i, class = "tgp-pg-e", text = "..." } })
		else
			table.insert(children, button("p" .. n, tostring(n), n, if n == p.page then "tgp-pg-on" else ""))
		end
	end
	table.insert(
		children,
		button("next", ">", if p.page < p.pages then p.page + 1 else nil, if p.page < p.pages then "" else "tgp-pg-off")
	)
	local first = (p.page - 1) * p.size + 1
	local last = math.min(p.total, p.page * p.size)
	table.insert(children, {
		k = "el",
		p = {
			tag = "span",
			key = "sum",
			class = "tgp-pg-sum",
			text = string.format("%d - %d of %d rows", first, last, p.total),
		},
	})
	return { k = "el", p = { tag = "div", key = "pager", class = "tgp-pager" }, c = children }
end

-- TablePanel's frame Select under the table: the shown frame's name, and
-- the previous and next frames; clicks send `tframe=<frame>:<panel key>`.
local function frameSelect(names: { string }, current: number, key: string): Node
	local function step(id: string, label: string, target: number): Node
		local on = target >= 1 and target <= #names
		local props: { [string]: any } =
			{ tag = "span", key = id, class = "tgp-pg-b" .. (if on then "" else " tgp-pg-off"), text = label }
		if on then
			props.actions = { click = "tframe=" .. target .. ":" .. key }
		end
		return { k = "el", p = props }
	end
	local box: Node = {
		k = "el",
		p = {
			tag = "span",
			key = "cur",
			class = "tgp-fsel-v",
			text = names[current],
			title = string.format("frame %d of %d", current, #names),
			actions = { click = "tframe=" .. (current % #names + 1) .. ":" .. key },
		},
	}
	return {
		k = "el",
		p = { tag = "div", key = "fsel", class = "tgp-fsel" },
		c = { step("fprev", "<", current - 1), box, step("fnext", ">", current + 1) },
	}
end

-- No frame with fields is PanelDataErrorView; a frame with fields and no
-- rows (say after filterByValue) keeps its header over Grafana 13's
-- EmptyTablePlaceholder: the field defaults' noValue, else "No rows".
function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): Node
	local t = M.build(panel, frames, env, opts)
	if #t.columns == 0 then
		if t.frame_names == nil then
			return Common.noData(panel, env, opts.key)
		end
		return ui.col({
			Common.noData(panel, env, "nodata"),
			frameSelect(t.frame_names :: { string }, t.frame, opts.key),
		}, { key = opts.key })
	end
	local showHeader = Json.bool(env, Json.path(env, panel, "options", "showHeader")) ~= false
	local columns: { Grid.Column } = table.create(#t.columns)
	-- Grafana 13's TableNG sizes columns by the server's OpenFeature flag
	-- table.autoColumnWidths (useColWidths): on, computeContentAwareColWidths
	-- (tgp-fit: every auto column as wide as its content, a gauge column the
	-- graphical default of 150px, growing into the leftover width when no
	-- column has a fixed width, tgp-grow); off (the default, and every
	-- Grafana before 13), computeColWidths (tgp-even: the auto columns share
	-- the width left by the custom.width ones, each at least custom.minWidth,
	-- else 150px, their text cut short).
	local aware = opts.features ~= nil and (opts.features :: { [string]: boolean })["table.autoColumnWidths"] == true
	local grow = true
	for i, c in t.columns do
		if c.width then
			grow = false
		end
		local classes: { string } = {}
		if c.width then
			table.insert(classes, "tgp-cw-" .. math.clamp(math.floor(c.width / 10 + 0.5), 5, M.MAX_WIDTH_CLASS))
		elseif c.min_width or not aware then
			local floor = c.min_width or M.DEFAULT_WIDTH
			table.insert(classes, "tgp-cmin-" .. math.clamp(math.floor(floor / 10 + 0.5), 5, M.MAX_WIDTH_CLASS))
		end
		columns[i] = {
			head = if showHeader then c.head else "",
			numeric = c.numeric,
			class = if #classes > 0 then table.concat(classes, " ") else nil,
		}
	end
	local gridRows: { Grid.Row } = table.create(#t.rows)
	for r, row in t.rows do
		local cells: { Node } = table.create(#row)
		for c, cell in row do
			cells[c] = cellNode(cell, t.columns[c].value_width or 0)
		end
		gridRows[r] = { key = "r" .. r, cells = cells }
	end
	if t.footer then
		local cells: { Node } = {}
		for c, text in t.footer :: { string } do
			cells[c] = Grid.text(text, "strong")
		end
		table.insert(gridRows, { key = "footer", cells = cells })
	end
	local children: { Node } = {
		{
			k = "el",
			p = {
				tag = "div",
				class = if not aware
					then "tgp-table tgp-even"
					elseif grow then "tgp-table tgp-fit tgp-grow"
					else "tgp-table tgp-fit",
			},
			c = { Grid.grid(opts.key .. ".grid", columns, gridRows, "tern-grafana.table", M.MAX_COLUMNS) },
		},
	}
	if #t.rows == 0 then
		local text = Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "noValue")) or "No rows"
		table.insert(children, { k = "el", p = { tag = "div", key = "empty", class = "tgp-table-empty", text = text } })
	end
	if t.pager then
		table.insert(children, pagerNode(t.pager :: Pager, opts.key))
	end
	local notes: { string } = {}
	if t.more_rows > 0 then
		table.insert(notes, string.format("%d more rows", t.more_rows))
	end
	if t.more_columns > 0 then
		table.insert(notes, string.format("%d more columns", t.more_columns))
	end
	if #notes > 0 then
		table.insert(children, ui.muted(table.concat(notes, ", "), { key = "more" }))
	end
	if t.frame_names then
		table.insert(children, frameSelect(t.frame_names :: { string }, t.frame, opts.key))
	end
	return ui.col(children, { key = opts.key, gap = "xs" })
end

return M
