--!strict
-- Repeated panels and rows, as Grafana lays them out (DashboardModel
-- repeatPanel / repeatRow): a panel repeated horizontally gets one copy per
-- selected value, `max(24 / n, 24 / maxPerRow)` columns wide (maxPerRow
-- defaults to 4), wrapping onto new lines from x = 0; vertically each copy
-- sits under the previous one. Panels below a repeat move down by the space
-- the copies take. A repeated row copies its whole section per value. Each
-- copy carries the value as a single-valued scoped variable, so `$job` in a
-- copy is that one job, not the alternation of all of them.

local Interpolate = require("./interpolate")
local Model = require("./model")
local Variables = require("./variables")

type Panel = Model.Panel
type Row = Model.Row
type Scope = Interpolate.Scope

local M = {}

M.DEFAULT_MAX_PER_ROW = 4

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
	}
end

local function withGrid(p: Panel, x: number, y: number, w: number, h: number): Panel
	local copy = table.clone(p)
	copy.grid = { x = x, y = y, w = w, h = h }
	return copy
end

-- Expands the panels of one section; returns instances and how far later
-- panels moved down.
local function expandPanels(panels: { Panel }, vars: { Variables.Variable }, prefix: string, scope: Scope): { Instance }
	local out: { Instance } = {}
	-- (y threshold, shift) pairs from repeats above.
	local shifts: { { at: number, by: number } } = {}
	local function shifted(y: number): number
		local by = 0
		for _, s in shifts do
			if y >= s.at then
				by += s.by
			end
		end
		return y + by
	end
	for _, p in panels do
		local g = p.grid
		local baseY = shifted(g.y)
		local r = p.repeat_by
		local vals = if r then valuesOf(vars, r.var) else nil
		if r == nil or vals == nil then
			table.insert(
				out,
				{ key = prefix .. "p" .. p.id, panel = withGrid(p, g.x, baseY, g.w, g.h), scoped = scope, clone = 0 }
			)
			continue
		end
		local n = #vals.values
		local extra = 0
		if r.direction == "v" then
			for i = 1, n do
				local s = table.clone(scope)
				s[r.var] = scopedValue(vals, i)
				table.insert(out, {
					key = prefix .. "p" .. p.id .. (if i > 1 then "." .. (i - 1) else ""),
					panel = withGrid(p, g.x, baseY + (i - 1) * g.h, g.w, g.h),
					scoped = s,
					clone = i - 1,
				})
			end
			extra = (n - 1) * g.h
		else
			local perRow = r.max_per_row or M.DEFAULT_MAX_PER_ROW
			local w = math.max(24 / n, 24 / perRow)
			local x, y = 0, baseY
			for i = 1, n do
				local s = table.clone(scope)
				s[r.var] = scopedValue(vals, i)
				table.insert(out, {
					key = prefix .. "p" .. p.id .. (if i > 1 then "." .. (i - 1) else ""),
					panel = withGrid(p, x, y, w, g.h),
					scoped = s,
					clone = i - 1,
				})
				x += w
				if x + w > 24 + 1e-9 and i < n then
					x = 0
					y += g.h
				end
			end
			extra = y - baseY
		end
		if extra > 0 then
			table.insert(shifts, { at = g.y + g.h, by = extra })
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
		local r = if row then row.repeat_by else nil
		local vals = if r then valuesOf(vars, r.var) else nil
		if r == nil or vals == nil then
			table.insert(out, { key = key, row = row, scoped = {}, panels = expandPanels(s.panels, vars, "", {}) })
			continue
		end
		for j = 1, #vals.values do
			local scope: Scope = { [r.var] = scopedValue(vals, j) }
			local sk = if j > 1 then key .. "." .. (j - 1) else key
			local prefix = if j > 1 then sk .. "/" else ""
			table.insert(
				out,
				{ key = sk, row = row, scoped = scope, panels = expandPanels(s.panels, vars, prefix, scope) }
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
