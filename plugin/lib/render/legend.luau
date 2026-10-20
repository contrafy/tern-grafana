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
	offset_min: number?,
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

local function swatch(class: string): Node
	return { k = "el", p = { tag = "span", class = "tg-swatch " .. class } }
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
		local columns: { Grid.Column } = { { head = "Name" } }
		for _, h in heads do
			table.insert(columns, { head = h, numeric = true })
		end
		local gridRows: { Grid.Row } = table.create(#rows)
		for i, r in rows do
			local cells: { Node } = {
				{ k = "row", p = { gap = "xs", align = "center" }, c = { swatch(r.class), Grid.text(r.name) } },
			}
			for _, v in r.values do
				table.insert(cells, Grid.text(v))
			end
			gridRows[i] = { key = "s" .. i, cells = cells }
		end
		table.insert(children, Grid.grid(key .. ".t", columns, gridRows, "tern-grafana.legend"))
	else
		local entries: { Node } = table.create(#rows)
		for i, r in rows do
			local spans = { { t = r.name } }
			if #r.values > 0 then
				table.insert(spans, { t = " " .. table.concat(r.values, " "), s = "strong" })
			end
			entries[i] = {
				k = "row",
				p = { key = "s" .. i, gap = "xs", align = "center" },
				c = { swatch(r.class), { k = "text", p = { spans = spans } } },
			}
		end
		table.insert(children, {
			k = "row",
			p = { key = key .. ".l", gap = "md", wrap = true, role = "tern-grafana.legend" },
			c = entries,
		})
	end
	if layout.dropped > 0 then
		table.insert(
			children,
			ui.muted(
				string.format("%d more series not shown (chart limit %d)", layout.dropped, #layout.series),
				{ key = "dropped" }
			)
		)
	end
	return { k = "col", p = { key = key, gap = "xs" }, c = children }
end

return M
