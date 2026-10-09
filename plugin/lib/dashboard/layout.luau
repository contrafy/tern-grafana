--!strict
-- Grafana's 24-column grid as nested flex rows and columns. Tern blocks have
-- no usable pane size (always 80x24 cells), so panels are laid out by
-- fractions: a guillotine split of the gridPos rectangles into vertical
-- bands (panels whose y ranges overlap) and, inside a band, columns (panels
-- whose x ranges overlap), recursively. A stat stacked over a bar gauge next
-- to a tall time series stays stacked. Empty grid space becomes a gap node so
-- a panel at x=12 stays on the right half.

local M = {}

export type GridPos = { x: number, y: number, w: number, h: number }

export type Item = { key: string, grid: GridPos }

-- `basis` is the share of the parent's width (rows) or 1 (bands in a column).
export type Node =
	{ kind: "panel", key: string, basis: number, h: number }
	| { kind: "gap", basis: number }
	| { kind: "row", basis: number, children: { Node } }
	| { kind: "col", basis: number, children: { Node } }

M.COLUMNS = 24

type Group = { lo: number, hi: number, items: { Item } }

-- Groups items whose [lo, hi) intervals overlap, in increasing order.
local function groups(items: { Item }, lo: (Item) -> number, size: (Item) -> number): { Group }
	local sorted = table.clone(items)
	table.sort(sorted, function(a, b)
		if lo(a) ~= lo(b) then
			return lo(a) < lo(b)
		end
		return a.key < b.key
	end)
	local out: { Group } = {}
	local current: Group? = nil
	for _, it in sorted do
		local s, e = lo(it), lo(it) + size(it)
		if current and s < current.hi then
			table.insert(current.items, it)
			current.hi = math.max(current.hi, e)
		else
			current = { lo = s, hi = e, items = { it } }
			table.insert(out, current :: Group)
		end
	end
	return out
end

local function y(it: Item): number
	return it.grid.y
end
local function h(it: Item): number
	return it.grid.h
end
local function x(it: Item): number
	return it.grid.x
end
local function w(it: Item): number
	return it.grid.w
end

local columns: (items: { Item }, x0: number, x1: number, depth: number) -> { Node }

-- Vertical bands of `items` spanning [x0, x1); each band a row node.
local function bands(items: { Item }, x0: number, x1: number, depth: number): { Node }
	local out: { Node } = {}
	local bs = groups(items, y, h)
	if #bs == 1 and depth > 0 and #groups(items, x, w) == 1 then
		-- Neither direction splits (overlapping panels): plain reading order.
		local flat = table.clone(items)
		table.sort(flat, function(a, b)
			if a.grid.y ~= b.grid.y then
				return a.grid.y < b.grid.y
			end
			return a.grid.x < b.grid.x
		end)
		for _, it in flat do
			table.insert(out, { kind = "panel", key = it.key, basis = 1, h = it.grid.h })
		end
		return out
	end
	for _, b in bs do
		table.insert(out, { kind = "row", basis = 1, children = columns(b.items, x0, x1, depth + 1) })
	end
	return out
end

function columns(items: { Item }, x0: number, x1: number, depth: number): { Node }
	local span = math.max(1, x1 - x0)
	local out: { Node } = {}
	local cursor = x0
	local cs = groups(items, x, w)
	for _, c in cs do
		local lo, hi = math.max(c.lo, x0), math.min(c.hi, x1)
		if lo > cursor then
			table.insert(out, { kind = "gap", basis = (lo - cursor) / span })
		end
		local basis = math.max(0, hi - lo) / span
		if #c.items == 1 then
			local it = c.items[1]
			table.insert(out, { kind = "panel", key = it.key, basis = basis, h = it.grid.h })
		else
			table.insert(out, { kind = "col", basis = basis, children = bands(c.items, lo, hi, depth) })
		end
		cursor = math.max(cursor, hi)
	end
	return out
end

-- The bands of a section, top to bottom; each band is a row of columns.
function M.arrange(items: { Item }): { Node }
	if #items == 0 then
		return {}
	end
	return bands(items, 0, M.COLUMNS, 0)
end

-- Keys in reading order (band by band, left to right, top to bottom inside
-- stacked columns): the order Tab-like navigation follows.
function M.order(nodes: { Node }): { string }
	local out: { string } = {}
	local function walk(n: Node)
		if n.kind == "panel" then
			table.insert(out, n.key)
		elseif n.kind == "row" or n.kind == "col" then
			local children: { Node } = (n :: any).children
			for _, c in children do
				walk(c)
			end
		end
	end
	for _, n in nodes do
		walk(n)
	end
	return out
end

export type Direction = "left" | "right" | "up" | "down"

local function overlap(a0: number, a1: number, b0: number, b1: number): number
	return math.min(a1, b1) - math.max(a0, b0)
end

-- The panel the focus moves to from `key`, by grid geometry: left/right to
-- the nearest panel sharing rows, up/down to the nearest panel above/below
-- with the closest horizontal center. Nil when there is none.
function M.neighbor(items: { Item }, key: string, dir: Direction): string?
	local cur: Item? = nil
	for _, it in items do
		if it.key == key then
			cur = it
			break
		end
	end
	if cur == nil then
		return nil
	end
	local c = cur.grid
	local best: Item? = nil
	local bestScore = math.huge
	for _, it in items do
		if it.key == key then
			continue
		end
		local g = it.grid
		local score: number? = nil
		if dir == "left" or dir == "right" then
			if overlap(c.y, c.y + c.h, g.y, g.y + g.h) > 0 then
				local dist = if dir == "left" then c.x - (g.x + g.w) else g.x - (c.x + c.w)
				if dist >= 0 then
					score = dist * 1000 + math.abs(g.y - c.y)
				end
			end
		else
			local dist = if dir == "up" then c.y - (g.y + g.h) else g.y - (c.y + c.h)
			if dist >= 0 then
				local center = math.abs((g.x + g.w / 2) - (c.x + c.w / 2))
				score = dist * 1000 + center
			end
		end
		if score and score < bestScore then
			best, bestScore = it, score
		end
	end
	return if best then best.key else nil
end

return M
