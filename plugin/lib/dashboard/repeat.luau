--!strict
-- Repeated panels and rows, as Grafana's dashboard scene lays them out
-- (transformSaveModelToScene buildGridItemForPanel, DashboardGridItem
-- performRepeat, DashboardGridItemRenderer, SceneGridLayout on
-- react-grid-layout): a panel repeated horizontally becomes one grid item
-- the full 24 columns wide holding its copies in min(n, maxPerRow) columns
-- (maxPerRow defaults to 4) and ceil(n / maxPerRow) lines; vertically the
-- item keeps the panel's x and width and stacks the n copies. The item
-- grows by the extra lines, panels below it move down by as much, and the
-- grid then compacts vertically, so a panel beside a repeated one (same y)
-- ends up under all of its copies. A repeated row copies its whole section
-- per value. Each copy carries the value as a single-valued scoped
-- variable, so `$job` in a copy is that one job, not the alternation of all
-- of them.

local Interpolate = require("./interpolate")
local Model = require("./model")
local Variables = require("./variables")
local Tbl = require("../tbl")

type Panel = Model.Panel
type Row = Model.Row
type Scope = Interpolate.Scope

local M = {}

M.DEFAULT_MAX_PER_ROW = 4
M.COLUMNS = 24

export type Instance = {
	-- Unique in the dashboard; also the asset key prefix ("p2", "p3.2", "r5.2/p6").
	key: string,
	-- The panel with its laid-out gridPos (json untouched).
	panel: Panel,
	-- Repeat values in effect (single-valued); empty without repeats.
	scoped: Scope,
	-- 0 for the panel itself, n for its n-th extra copy.
	clone: number,
}

export type SectionInstance = {
	key: string,
	row: Row?,
	scoped: Scope,
	panels: { Instance },
}

type Values = { values: { string }, texts: { string }, var: Variables.Variable }

local function valuesOf(vars: { Variables.Variable }, name: string): Values?
	local v = Variables.find(vars, name)
	if v == nil then
		return nil
	end
	local values = Variables.expanded(v)
	if #values == 0 then
		return nil
	end
	return { values = values, texts = Variables.expandedTexts(v), var = v }
end

local function scopedValue(vals: Values, i: number): Interpolate.Var
	return {
		values = { vals.values[i] },
		texts = { vals.texts[i] or vals.values[i] },
		multi = vals.var.multi,
		include_all = vals.var.include_all,
		single = true,
		name = vals.var.name,
		query = vals.var.query_model,
	}
end

local function withGrid(p: Panel, x: number, y: number, w: number, h: number): Panel
	local copy = Tbl.copy(p)
	copy.grid = { x = x, y = y, w = w, h = h }
	return copy
end

-- One grid item: a panel, or a repeated panel with room for its copies.
type Item = {
	panel: Panel,
	index: number,
	x: number,
	y: number,
	w: number,
	h: number,
	r: Model.Repeat?,
	vals: Values?,
	n: number,
	per_row: number,
}

local function byPosition(a: Item, b: Item): boolean
	if a.y ~= b.y then
		return a.y < b.y
	elseif a.x ~= b.x then
		return a.x < b.x
	end
	return a.index < b.index
end

local function collision(placed: { Item }, it: Item): Item?
	for _, o in placed do
		if it.x < o.x + o.w and o.x < it.x + it.w and it.y < o.y + o.h and o.y < it.y + it.h then
			return o
		end
	end
	return nil
end

-- react-grid-layout's correctBounds and vertical compact: items in
-- reading order float up as far as the items before them allow, never
-- above `floor` (the section's row header).
local function compact(items: { Item }, floor: number)
	for _, it in items do
		it.w = math.min(it.w, M.COLUMNS)
		it.x = math.max(0, math.min(it.x, M.COLUMNS - it.w))
	end
	table.sort(items, byPosition)
	local placed: { Item } = {}
	local bottom = floor
	for _, it in items do
		it.y = math.max(floor, math.min(bottom, it.y))
		while it.y > floor and collision(placed, it) == nil do
			it.y -= 1
		end
		it.y = math.max(it.y, floor)
		local hit = collision(placed, it)
		while hit do
			it.y = hit.y + hit.h
			hit = collision(placed, it)
		end
		table.insert(placed, it)
		bottom = math.max(bottom, it.y + it.h)
	end
end

-- Expands the panels of one section whose grid starts at `floor`.
local function expandPanels(
	panels: { Panel },
	vars: { Variables.Variable },
	prefix: string,
	scope: Scope,
	floor: number
): { Instance }
	local items: { Item } = table.create(#panels)
	for i, p in panels do
		local g, r = p.grid, p.repeat_by
		local vals = if r then valuesOf(vars, r.var) else nil
		table.insert(items, {
			panel = p,
			index = i,
			x = g.x,
			y = g.y,
			w = if r and r.direction == "h" then M.COLUMNS else g.w,
			h = g.h,
			r = r,
			vals = vals,
			n = if vals then #vals.values else 1,
			per_row = if r then r.max_per_row or M.DEFAULT_MAX_PER_ROW else 1,
		})
	end
	table.sort(items, byPosition)
	for _, it in items do
		local r = it.r
		if r == nil then
			continue
		end
		local lines = if r.direction == "v" then it.n else math.ceil(it.n / it.per_row)
		local grow = (lines - 1) * it.h
		if grow > 0 then
			for _, o in items do
				if o.y > it.y then
					o.y += grow
				end
			end
			it.h += grow
		end
	end
	compact(items, floor)
	local out: { Instance } = {}
	for _, it in items do
		local p, r, vals = it.panel, it.r, it.vals
		local ph = p.grid.h
		if r == nil or vals == nil then
			table.insert(out, {
				key = prefix .. "p" .. p.id,
				panel = withGrid(p, it.x, it.y, it.w, ph),
				scoped = scope,
				clone = 0,
			})
			continue
		end
		local cols = math.min(it.n, it.per_row)
		for i = 1, it.n do
			local s = Tbl.copy(scope)
			s[r.var] = scopedValue(vals, i)
			local grid = if r.direction == "v"
				then withGrid(p, it.x, it.y + (i - 1) * ph, it.w, ph)
				else withGrid(
					p,
					((i - 1) % cols) * (M.COLUMNS / cols),
					it.y + (i - 1) // cols * ph,
					M.COLUMNS / cols,
					ph
				)
			table.insert(out, {
				key = prefix .. "p" .. p.id .. (if i > 1 then "." .. (i - 1) else ""),
				panel = grid,
				scoped = s,
				clone = i - 1,
			})
		end
	end
	return out
end

-- Every section and panel the dashboard shows for the current selection.
function M.expand(d: Model.Dashboard, vars: { Variables.Variable }): { SectionInstance }
	local out: { SectionInstance } = {}
	for i, s in d.sections do
		local row = s.row
		local key = if row then "r" .. row.id else "s" .. i
		local floor = if row then row.grid.y + row.grid.h else 0
		local r = if row then row.repeat_by else nil
		local vals = if r then valuesOf(vars, r.var) else nil
		if r == nil or vals == nil then
			table.insert(
				out,
				{ key = key, row = row, scoped = {}, panels = expandPanels(s.panels, vars, "", {}, floor) }
			)
			continue
		end
		for j = 1, #vals.values do
			local scope: Scope = { [r.var] = scopedValue(vals, j) }
			local sk = if j > 1 then key .. "." .. (j - 1) else key
			local prefix = if j > 1 then sk .. "/" else ""
			table.insert(
				out,
				{ key = sk, row = row, scoped = scope, panels = expandPanels(s.panels, vars, prefix, scope, floor) }
			)
		end
	end
	return out
end

-- Finds an instance by key.
function M.find(sections: { SectionInstance }, key: string): (Instance?, SectionInstance?)
	for _, s in sections do
		for _, inst in s.panels do
			if inst.key == key then
				return inst, s
			end
		end
	end
	return nil, nil
end

return M
