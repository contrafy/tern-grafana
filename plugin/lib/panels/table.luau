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
--   reducer, or per-field custom.footer.reducers) adds a reduced row.
-- Grafana shows one frame at a time with a frame picker; Tern shows the
-- first and says how many more there are.

local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Gauge = require("./gauge")
local Grid = require("../render/grid")
local Json = require("./json")
local Reduce = require("./reduce")
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
	-- "color", "hidden") and, for lcd, the threshold bands.
	gauge_mode: string?,
	value_mode: string?,
	parts: { Gauge.Part }?,
	-- A filled background (the cell's own color-background or its row's
	-- applyToRow color): tone or palette class, and "basic" or "gradient".
	bg_tone: string?,
	bg_class: string?,
	bg_mode: string?,
	pills: { Pill }?,
}

export type Column = {
	head: string,
	numeric: boolean,
	item: Item,
	-- Gauge columns: the longest shown value in characters (0 with
	-- valueDisplayMode hidden), capped at MAX_VALUE_WIDTH.
	value_width: number?,
}

export type Table = {
	columns: { Column },
	rows: { { Cell } },
	footer: { string }?,
	-- Rows beyond the cap and frames beyond the first.
	more_rows: number,
	more_frames: number,
	-- Columns beyond the grid's limit.
	more_columns: number,
}

local M = {}

M.MAX_ROWS = 500

-- panels.css has tgp-gw-0 .. tgp-gw-<MAX_VALUE_WIDTH>.
M.MAX_VALUE_WIDTH = 24

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

-- A continuous scheme's colors along the field range up to `fill`, in
-- thirds (the schemes run through at most three hues).
local function schemeParts(item: Item, fill: number, disp: FieldConfig.Options): { Gauge.Part }
	local lo, hi = item.range_min or 0, item.range_max or 100
	local parts: { Gauge.Part } = {}
	for k = 0, 2 do
		local a = k / 3
		if a >= fill then
			break
		end
		local tone = FieldConfig.display(item, lo + (k + 0.5) / 3 * (hi - lo), disp).tone
		local base: string = Common.token(tone :: any)
		local token = if base ~= "" then base else "muted"
		local width = math.min((k + 1) / 3, fill) - a
		local last = parts[#parts]
		if last and last.token == token then
			last.value += width
		else
			table.insert(parts, { value = width, token = token })
		end
	end
	return parts
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

function M.build(panel: any, frames: { Frame }, env: Env, opts: Common.Options): Table
	-- Only the first frame becomes columns; the others still name and range
	-- its fields.
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "thresholds" }, true)
	local first = frames[1]
	local columns: { Column } = {}
	for _, item in items do
		if item.frame == first and not FieldConfig.hidden(item) then
			local align = item.config.custom.align
			local numeric = if align == "right"
				then true
				elseif align == "left" or align == "center" then false
				else item.field.type == "number"
			table.insert(columns, { head = item.name, numeric = numeric, item = item })
		end
	end
	local moreColumns = math.max(0, #columns - Grid.MAX_COLUMNS)
	while #columns > Grid.MAX_COLUMNS do
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
	local rows: { { Cell } } = {}
	for r = 1, math.min(n, M.MAX_ROWS) do
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
			if kind == "gauge" then
				cell.gauge_mode = co.mode or "gradient"
				cell.value_mode = co.value_mode or "text"
				-- gradient runs through the colors up to the value (BarGauge
				-- getBarGradient: threshold steps, or the continuous scheme),
				-- lcd lights cells in their band's color: both as bands.
				if cell.gauge_mode ~= "basic" then
					local fill = math.clamp(d.percent, 0, 1)
					if item.config.color_mode == "thresholds" then
						cell.parts = Gauge.bandParts(item, fill, d.tone)
					elseif string.sub(item.config.color_mode, 1, 11) == "continuous-" then
						cell.parts = schemeParts(item, fill, disp)
					end
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
	return {
		columns = columns,
		rows = rows,
		footer = footer,
		more_rows = math.max(0, n - M.MAX_ROWS),
		more_frames = math.max(0, #frames - 1),
		more_columns = moreColumns,
	}
end

-- BarGaugeCell: a horizontal bar gauge filling the cell, the value after
-- it (valueDisplayMode text: plain, color: in the value's color, hidden:
-- none). The wrapper gives the bar a width in the content-sized column; the
-- value box is `width` characters wide (getAlignmentFactor: the column's
-- longest value), so the bar shrinks first and the value is never cut.
local function gaugeNode(cell: Cell, width: number): Node
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
	local children: { Node } = { { k = "meter", p = p } }
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

local function cellNode(cell: Cell, width: number): Node
	local content = contentNode(cell, width)
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

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): Node
	local t = M.build(panel, frames, env, opts)
	if #t.columns == 0 or #t.rows == 0 then
		return ui.muted("No data", { key = opts.key })
	end
	local showHeader = Json.bool(env, Json.path(env, panel, "options", "showHeader")) ~= false
	local columns: { Grid.Column } = table.create(#t.columns)
	for i, c in t.columns do
		columns[i] = {
			head = if showHeader then c.head else "",
			numeric = c.numeric,
			-- Gauge columns do not shrink below the bar's minimum and the value.
			class = if c.value_width then "tgp-gcw-" .. c.value_width else nil,
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
			p = { tag = "div", class = "tgp-table" },
			c = { Grid.grid(opts.key .. ".grid", columns, gridRows, "tern-grafana.table") },
		},
	}
	local notes: { string } = {}
	if t.more_rows > 0 then
		table.insert(notes, string.format("%d more rows", t.more_rows))
	end
	if t.more_columns > 0 then
		table.insert(notes, string.format("%d more columns", t.more_columns))
	end
	if t.more_frames > 0 then
		table.insert(notes, string.format("%d more frames (showing the first)", t.more_frames))
	end
	if #notes > 0 then
		table.insert(children, ui.muted(table.concat(notes, ", "), { key = "more" }))
	end
	return ui.col(children, { key = opts.key, gap = "xs" })
end

return M
