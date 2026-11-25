--!strict
-- Chart legend: one row per drawn series with its palette swatch, display
-- name and either reduction calcs (full-resolution, nulls and NaN skipped)
-- or, while the keyboard cursor is on, each series' value at the cursor,
-- formatted in the series' own unit. Series hidden from the legend
-- (custom.hideFrom.legend) skip the calcs rows, those hidden from the
-- tooltip skip the cursor read-out.

local Cursor = require("./cursor")
local Format = require("../units/format")
local Grid = require("./grid")
local Layout = require("./layout")
local Range = require("../time/range")
local ui = require("../ui")

type Layout = Layout.Layout
type Node = ui.Node

export type Calc = "last" | "min" | "max" | "mean"
export type Mode = "list" | "table"

export type Options = {
	mode: Mode?,
	-- Default: {"last"} in list mode, last/min/max/mean in table mode.
	calcs: { Calc }?,
	-- Cursor time; replaces the calcs with the value at the cursor.
	cursor: number?,
	offset_min: Range.Offset?,
	key: string?,
}

export type Row = { class: string, name: string, values: { string } }

local M = {}

local HEADS: { [string]: string } = { last = "Last *", min = "Min", max = "Max", mean = "Mean" }

M.NO_VALUE = "-"

-- A value in its series' own unit (a second axis has its own; a percent
-- stack's axis reads percent but its values keep their unit), else the
-- chart's.
local function text(v: number?, s: Layout.DrawnSeries, layout: Layout): string
	if v == nil then
		return M.NO_VALUE
	end
	if s.axis ~= nil then
		return Format.text(v, s.unit, s.decimals)
	end
	return Format.text(v, layout.unit, layout.decimals)
end

function M.calcsFor(opts: Options?): { Calc }
	local o: Options = opts or {}
	if o.calcs then
		return o.calcs
	end
	local tableCalcs: { Calc } = { "last", "min", "max", "mean" }
	local listCalcs: { Calc } = { "last" }
	return if o.mode == "table" then tableCalcs else listCalcs
end

-- Column heads after the name, and one row per drawn series.
function M.rows(layout: Layout, opts: Options?): ({ string }, { Row })
	local o: Options = opts or {}
	local rows: { Row } = table.create(#layout.series)
	if o.cursor then
		-- The tooltip's series: custom.hideFrom.tooltip leaves it out.
		for i, r in Cursor.read(layout, o.cursor) do
			local s = layout.series[i]
			if not s.hide_tooltip then
				table.insert(rows, { class = r.class, name = r.name, values = { text(r.value, s, layout) } })
			end
		end
		return { "Value" }, rows
	end
	local calcs = M.calcsFor(o)
	local heads: { string } = table.create(#calcs)
	for i, c in calcs do
		heads[i] = HEADS[c]
	end
	for _, s in layout.series do
		if s.hide_legend then
			continue
		end
		local values: { string } = table.create(#calcs)
		for k, c in calcs do
			values[k] = text((s.calcs :: any)[c], s, layout)
		end
		table.insert(rows, { class = s.class, name = s.name, values = values })
	end
	return heads, rows
end

function M.swatch(class: string): Node
	return { k = "el", p = { tag = "span", class = "tg-swatch " .. class } }
end

-- Tern's px for rowsNode, measured in a dashboard card, so a chart can
-- leave its legend room: list entries (swatch, name, values with their
-- `heads` labels) wrap across `width` onto 16 px lines 10 px apart; a
-- table is a 22 px header and 21 px rows.
M.LINE_PX = 16
M.LINE_GAP_PX = 10
M.ENTRY_GAP_PX = 12
M.SWATCH_PX = 14
M.CHAR_PX = 8
M.TABLE_HEAD_PX = 22
M.TABLE_ROW_PX = 21

-- A list entry's value `v` under calc heading `head`: VizLegendStatsList
-- prints every stat as "<Title>: <value>" (lodash capitalize of the
-- reducer's name, so "Last *" stays "Last *").
local function labeled(head: string?, v: string): string
	if head == nil or head == "" then
		return v
	end
	return string.upper(string.sub(head, 1, 1)) .. string.lower(string.sub(head, 2)) .. ": " .. v
end

function M.height(rows: { Row }, mode: Mode, width: number, heads: { string }?): number
	if #rows == 0 then
		return 0
	elseif mode == "table" then
		return M.TABLE_HEAD_PX + #rows * M.TABLE_ROW_PX
	end
	local h = heads or {}
	local lines, x = 1, 0
	for _, r in rows do
		local chars = utf8.len(r.name) or #r.name
		for k, v in r.values do
			local s = labeled(h[k], v)
			chars += 1 + (utf8.len(s) or #s)
		end
		local w = M.SWATCH_PX + chars * M.CHAR_PX
		if x > 0 and x + M.ENTRY_GAP_PX + w > width then
			lines += 1
			x = w
		else
			x += (if x > 0 then M.ENTRY_GAP_PX else 0) + w
		end
	end
	return lines * M.LINE_PX + (lines - 1) * M.LINE_GAP_PX
end

-- VizLayout caps a bottom legend at 35% of the viz and scrolls the rest
-- (ScrollContainer). The class (panels.css tgp-lgcap-l<n>, -t<n>) that
-- cuts a legend of `rows` across `width` after the whole list lines or
-- table rows fitting `maxPx` and scrolls the rest; nil when it fits.
M.CAP_MAX = 12

function M.capClass(rows: { Row }, mode: Mode, width: number, maxPx: number, heads: { string }?): string?
	if M.height(rows, mode, width, heads) <= maxPx then
		return nil
	elseif mode == "table" then
		local n = math.floor((maxPx - M.TABLE_HEAD_PX) / M.TABLE_ROW_PX)
		return "tgp-lgcap-t" .. math.clamp(n, 1, M.CAP_MAX)
	end
	local n = math.floor((maxPx + M.LINE_GAP_PX) / (M.LINE_PX + M.LINE_GAP_PX))
	return "tgp-lgcap-l" .. math.clamp(n, 1, M.CAP_MAX)
end

-- VizLegend rows under `key`: a wrapping list (name, then each value in
-- bold after its `heads` label, as VizLegendStatsList) or a table with a
-- column per value heading. Shared by every panel legend (lib/panels/charts).
function M.rowsNode(key: string, rows: { Row }, heads: { string }, mode: Mode): Node
	if mode == "table" then
		local columns: { Grid.Column } = { { head = "Name" } }
		for _, h in heads do
			table.insert(columns, { head = h, numeric = true })
		end
		local gridRows: { Grid.Row } = table.create(#rows)
		for i, r in rows do
			local cells: { Node | string } = {
				{ k = "row", p = { gap = "xs", align = "center" }, c = { M.swatch(r.class), Grid.text(r.name) } },
			}
			for _, v in r.values do
				table.insert(cells, v)
			end
			gridRows[i] = { key = "s" .. i, cells = cells }
		end
		return Grid.grid(key, columns, gridRows, "tern-grafana.legend")
	end
	local entries: { Node } = table.create(#rows)
	for i, r in rows do
		local spans: { ui.Span } = { { t = r.name } }
		for k, v in r.values do
			local head = heads[k]
			if head and head ~= "" then
				local label = labeled(head, "")
				table.insert(spans, { t = " " .. string.sub(label, 1, -2) })
			end
			table.insert(spans, { t = " " .. v, s = "strong" })
		end
		entries[i] = {
			k = "row",
			p = { key = "s" .. i, gap = "xs", align = "center" },
			c = { M.swatch(r.class), { k = "text", p = { spans = spans } } },
		}
	end
	return { k = "row", p = { key = key, gap = "md", wrap = true, role = "tern-grafana.legend" }, c = entries }
end

function M.view(layout: Layout, opts: Options?): Node
	local o: Options = opts or {}
	local key = o.key or "legend"
	local heads, rows = M.rows(layout, o)
	local children: { Node } = {}
	if o.cursor then
		table.insert(children, ui.muted(Range.formatMs(o.cursor, o.offset_min), { key = "at" }))
	end
	if o.mode == "table" then
		table.insert(children, M.rowsNode(key .. ".t", rows, heads, "table"))
	else
		table.insert(children, M.rowsNode(key .. ".l", rows, if o.cursor then {} else heads, "list"))
	end
	if layout.dropped > 0 then
		table.insert(
			children,
			ui.muted(string.format("%d more series not shown (chart size limit)", layout.dropped), { key = "dropped" })
		)
	end
	return { k = "col", p = { key = key, gap = "xs" }, c = children }
end

return M
