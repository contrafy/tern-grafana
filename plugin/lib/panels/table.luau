--!strict
-- The table panel (public/app/plugins/panel/table: panelcfg.cue,
-- TableNG/TableRT cells) over lib/render/grid. Frames arrive transformed
-- (lib/panels/transform: the Prometheus format=table merge, organize,
-- filterFieldsByName), so columns are the frame's visible fields:
-- - headers are field display names (renames and displayName overrides);
-- - cells go through the display processor (unit, decimals, mappings,
--   time fields as dates);
-- - custom.cellOptions.type (or legacy custom.displayMode): color-text
--   colors the value, color-background tints the cell, gauge draws a meter
--   (lcd as blocks), anything else is text; custom.align and
--   custom.hidden apply;
-- - options.sortBy sorts rows; the footer (options.footer.show with its
--   reducer, or per-field custom.footer.reducers) adds a reduced row.
-- Grafana shows one frame at a time with a frame picker; Tern shows the
-- first and says how many more there are.

local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Grid = require("../render/grid")
local Json = require("./json")
local Reduce = require("./reduce")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node
type Item = FieldConfig.Item

export type Cell = {
	text: string,
	-- "auto", "color-text", "color-background", "gauge".
	kind: string,
	tone: string,
	percent: number,
	-- gauge sub-mode: "basic", "gradient", "lcd".
	gauge_mode: string?,
}

export type Column = { head: string, numeric: boolean, item: Item }

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

local LEGACY: { [string]: string } = {
	["color-background"] = "color-background",
	["color-background-solid"] = "color-background",
	["color-text"] = "color-text",
	["gradient-gauge"] = "gauge",
	["lcd-gauge"] = "gauge",
	["basic"] = "gauge",
}

local function cellKind(item: Item): (string, string?)
	local custom = item.config.custom
	local opts = custom.cellOptions
	if type(opts) == "table" and type(opts.type) == "string" then
		local kind = opts.type
		if kind == "color-text" or kind == "color-background" then
			return kind, nil
		elseif kind == "gauge" then
			return "gauge", if type(opts.mode) == "string" then opts.mode else "gradient"
		end
		return "auto", nil
	end
	local legacy = custom.displayMode
	if type(legacy) == "string" and LEGACY[legacy] then
		local kind = LEGACY[legacy]
		local mode = if legacy == "lcd-gauge" then "lcd" elseif legacy == "basic" then "basic" else "gradient"
		return kind, if kind == "gauge" then mode else nil
	end
	return "auto", nil
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
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "thresholds" })
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
	local disp = { theme = opts.theme, offset_min = opts.offset_min }
	local rows: { { Cell } } = {}
	for r = 1, math.min(n, M.MAX_ROWS) do
		local idx = order[r]
		local cells: { Cell } = table.create(#columns)
		for c, col in columns do
			local d = FieldConfig.display(col.item, col.item.field.values[idx], disp)
			local kind, gaugeMode = cellKind(col.item)
			cells[c] = {
				text = FieldConfig.joined(d),
				kind = kind,
				tone = d.tone,
				percent = d.percent,
				gauge_mode = gaugeMode,
			}
		end
		table.insert(rows, cells)
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

local function cellNode(cell: Cell): Node
	if cell.kind == "gauge" then
		local p: { [string]: any } = {
			value = math.clamp(if cell.percent == cell.percent then cell.percent else 0, 0, 1),
			style = if cell.gauge_mode == "lcd" then "blocks" else "bar",
			size = "sm",
			label = cell.text,
			tone = if cell.tone == "neutral" then "muted" else cell.tone,
		}
		return { k = "meter", p = p }
	elseif cell.kind == "color-text" then
		local token = Common.token(cell.tone :: any)
		return Grid.text(cell.text, if token ~= "" then token else nil)
	elseif cell.kind == "color-background" then
		return {
			k = "el",
			p = { tag = "div", class = "tgp-bg " .. Common.toneClass(cell.tone :: any) },
			c = { Grid.text(cell.text) },
		}
	end
	return Grid.text(cell.text)
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): Node
	local t = M.build(panel, frames, env, opts)
	if #t.columns == 0 or #t.rows == 0 then
		return ui.muted("No data", { key = opts.key })
	end
	local showHeader = Json.bool(env, Json.path(env, panel, "options", "showHeader")) ~= false
	local columns: { Grid.Column } = table.create(#t.columns)
	for i, c in t.columns do
		columns[i] = { head = if showHeader then c.head else "", numeric = c.numeric }
	end
	local gridRows: { Grid.Row } = table.create(#t.rows)
	for r, row in t.rows do
		local cells: { Node } = table.create(#row)
		for c, cell in row do
			cells[c] = cellNode(cell)
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
	local children: { Node } = { Grid.grid(opts.key .. ".grid", columns, gridRows, "tern-grafana.table") }
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
