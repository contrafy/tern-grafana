--!strict
-- A table as a CSS grid of `el` divs (tern-kube's lens grid): Tern's `table`
-- node has no row actions, so rows are `display: contents` divs that keep a
-- click action while their cells align across rows. Plain tables, not
-- builders: a legend or result table can be hundreds of nodes.

local ui = require("../ui")

type Node = ui.Node

-- `class` is added to the column's header and cells.
export type Column = { head: string, numeric: boolean?, class: string? }
export type Row = { key: string, cells: { Node }, action: string? }

local M = {}

-- tern-grafana.css defines tg-cols-1 .. tg-cols-<MAX_COLUMNS>; panels.css
-- defines the table panel's (tgp-table) up to its own, wider limit.
M.MAX_COLUMNS = 16

-- A plain text cell.
function M.text(s: string, style: string?): Node
	return { k = "text", p = { spans = { if style then { t = s, s = style } else { t = s } } } }
end

function M.grid(key: string, columns: { Column }, rows: { Row }, role: string?, maxColumns: number?): Node
	local n = math.min(#columns, maxColumns or M.MAX_COLUMNS)
	local cellClass: { string } = table.create(n)
	local children: { Node } = table.create(n + #rows)
	for i = 1, n do
		local col = columns[i]
		local base = if col.numeric then "tg-c tg-num" else "tg-c"
		local head = if col.numeric then "tg-h tg-num" else "tg-h"
		if col.class then
			base ..= " " .. col.class
			head ..= " " .. col.class
		end
		cellClass[i] = base
		children[i] = { k = "el", p = { tag = "div", key = "h" .. i, class = head, text = col.head } }
	end
	for _, row in rows do
		local cells: { Node } = table.create(n)
		for i = 1, n do
			local cell = row.cells[i]
			cells[i] = { k = "el", p = { tag = "div", class = cellClass[i] }, c = if cell then { cell } else nil }
		end
		local p: { [string]: any } = { tag = "div", key = row.key, class = "tg-r" }
		if row.action then
			p.class = "tg-r tg-click"
			p.actions = { click = row.action }
		end
		table.insert(children, { k = "el", p = p, c = cells })
	end
	return {
		k = "el",
		p = { tag = "div", key = key, class = "tg-wrap" },
		c = {
			{ k = "el", p = { tag = "div", class = "tg-table tg-cols-" .. n, role = role }, c = children },
		},
	}
end

return M
