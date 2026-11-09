--!strict
-- The dashboard machine's pickers: dashboard search, the variable list and
-- one variable's values (multi-value variables keep a working selection).

local Advance = require("./advance")
local Answers = require("./answers")
local Effect = require("../effect")
local Env = require("../env")
local Interpolate = require("./interpolate")
local Tbl = require("../tbl")
local Types = require("./types")
local Variables = require("./variables")

type Env = Env.Env
type Effect = Effect.Effect
type State = Types.State
type Picker = Types.Picker
type PickerItem = Types.PickerItem

local M = {}

local function matches(text: string, query: string): boolean
	return query == "" or string.find(string.lower(text), string.lower(query), 1, true) ~= nil
end

-- What the open picker lists, filtered by its query.
function M.items(s: State): { PickerItem }
	local p = s.picker
	local out: { PickerItem } = {}
	if p == nil then
		return out
	end
	if p.kind == "search" then
		for _, h in s.search.hits do
			table.insert(out, { id = h.uid, label = h.title, detail = h.folder })
		end
	elseif p.kind == "vars" then
		for _, v in s.vars do
			if v.hide < 2 and v.kind ~= "constant" and matches(v.label or v.name, p.query) then
				table.insert(out, { id = v.name, label = v.label or v.name, detail = Variables.display(v) })
			end
		end
	else
		local v = Variables.find(s.vars, p.name or "")
		if v == nil then
			return out
		end
		if v.kind == "textbox" then
			table.insert(out, { id = p.query, label = if p.query == "" then "(empty)" else p.query, detail = "set" })
			return out
		end
		if v.include_all and matches(Interpolate.ALL_TEXT, p.query) then
			table.insert(out, { id = Variables.ALL, label = Interpolate.ALL_TEXT })
		end
		for _, o in v.options do
			if matches(o.text, p.query) then
				table.insert(out, { id = o.value, label = o.text, detail = if o.text ~= o.value then o.value else nil })
			end
		end
	end
	return out
end

-- Picker items of a given kind regardless of what is open (used to know
-- whether `v` has anything to show).
function M.itemsFor(s: State, kind: "vars"): { PickerItem }
	local saved = s.picker
	s.picker = { kind = kind, query = "" }
	local out = M.items(s)
	s.picker = saved
	return out
end

function M.openVar(s: State, name: string)
	local v = Variables.find(s.vars, name)
	if v == nil or v.kind == "constant" or v.kind == "unsupported" then
		return
	end
	s.picker = {
		kind = "var",
		name = name,
		query = if v.kind == "textbox" then (v.values[1] or "") else "",
		selected = v.values[1],
		chosen = if v.multi then Tbl.copy(v.values) else nil,
	}
end

local function openDashboard(s: State, uid: string, effects: { Effect })
	s.picker = nil
	s.uid = uid
	s.link_vars = {}
	s.link_panel = nil
	s.from, s.to = nil, nil
	s.focus = nil
	s.expanded = false
	s.collapsed = {}
	Answers.startLoad(s, effects)
end

local function toggleChosen(p: Picker, id: string)
	local chosen = p.chosen or {}
	if id == Variables.ALL then
		p.chosen = { Variables.ALL }
		return
	end
	local idx = table.find(chosen, id)
	if idx then
		table.remove(chosen, idx)
	else
		local all = table.find(chosen, Variables.ALL)
		if all then
			table.remove(chosen, all)
		end
		table.insert(chosen, id)
	end
	p.chosen = chosen
end

-- Picks `id` in the open picker (enter or click).
function M.pick(s: State, id: string, env: Env, effects: { Effect })
	local p = s.picker
	if p == nil then
		return
	end
	if p.kind == "search" then
		openDashboard(s, id, effects)
	elseif p.kind == "vars" then
		M.openVar(s, id)
	else
		local v = Variables.find(s.vars, p.name or "")
		if v == nil then
			s.picker = nil
			return
		end
		if v.multi and v.kind ~= "textbox" then
			toggleChosen(p, id)
			return
		end
		s.picker = nil
		Advance.selectVariable(s, v.name, { id }, env, effects)
	end
end

local function applyChosen(s: State, env: Env, effects: { Effect })
	local p = s.picker
	if p == nil or p.kind ~= "var" then
		return
	end
	local chosen = p.chosen
	s.picker = nil
	if chosen and #chosen > 0 then
		Advance.selectVariable(s, p.name or "", chosen, env, effects)
	end
end

local function moveSelection(s: State, delta: number)
	local p = s.picker
	if p == nil then
		return
	end
	local items = M.items(s)
	if #items == 0 then
		return
	end
	local idx = 0
	for i, it in items do
		if it.id == p.selected then
			idx = i
			break
		end
	end
	idx = math.clamp(idx + delta, 1, #items)
	p.selected = items[idx].id
end

function M.key(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local p = s.picker :: Picker
	local name = key.name
	if name == "escape" then
		if p.kind == "search" and s.dashboard == nil then
			return false
		end
		if p.kind == "var" and p.chosen then
			applyChosen(s, env, effects)
		else
			s.picker = nil
		end
		return true
	elseif name == "up" then
		moveSelection(s, -1)
		return true
	elseif name == "down" then
		moveSelection(s, 1)
		return true
	elseif name == "enter" then
		local items = M.items(s)
		local id = p.selected
		local found = false
		for _, it in items do
			if it.id == id then
				found = true
				break
			end
		end
		if not found then
			id = if items[1] then items[1].id else nil
		end
		if p.kind == "var" and p.chosen then
			if key.ctrl or key.meta or id == nil then
				applyChosen(s, env, effects)
				return true
			end
			-- Enter applies; the highlighted option joins an empty working set.
			if #(p.chosen :: { string }) == 0 then
				toggleChosen(p, id :: string)
			end
			applyChosen(s, env, effects)
			return true
		end
		if id then
			M.pick(s, id, env, effects)
		end
		return true
	elseif name == "space" and p.kind == "var" and p.chosen then
		local id = p.selected or (M.items(s)[1] or {} :: any).id
		if id then
			toggleChosen(p, id)
		end
		return true
	elseif name == "backspace" then
		if p.query == "" then
			return false
		end
		p.query = string.sub(p.query, 1, utf8.offset(p.query, -1) - 1)
	elseif name == "paste" or (key.text and key.text ~= "" and not key.ctrl and not key.meta) then
		local text = string.gsub(key.text or "", "[%c]", "")
		p.query ..= text
	else
		return false
	end
	-- The query changed.
	p.selected = nil
	if p.kind == "search" then
		Answers.startSearch(s, p.query, effects)
	end
	return true
end

return M
