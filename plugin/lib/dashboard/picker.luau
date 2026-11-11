--!strict
-- The dashboard machine's pickers: dashboard search, the variable list and
-- one variable's values (multi-value variables keep a working selection).
-- An ad hoc variable's picker lists its filters; adding or editing one goes
-- key, operator, value, with keys and values from the variable's
-- datasource (scenes' AdHocFiltersVariable _getKeys/_getValuesFor through
-- the Prometheus or Loki getTagKeys/getTagValues), and every finished
-- filter applies at once, as Grafana's `auto` apply mode does.

local Adhoc = require("./adhoc")
local Advance = require("./advance")
local Answers = require("./answers")
local Core = require("./core")
local Effect = require("../effect")
local Env = require("../env")
local Interpolate = require("./interpolate")
local Links = require("./links")
local Loki = require("../source/loki")
local Metrics = require("../source/metrics")
local Queries = require("./queries")
local Tbl = require("../tbl")
local Types = require("./types")
local Variables = require("./variables")

type Env = Env.Env
type Effect = Effect.Effect
type State = Types.State
type Picker = Types.Picker
type PickerItem = Types.PickerItem
type Variable = Variables.Variable

local M = {}

-- Variables picker item id of an annotation layer switch (variable names
-- have no colon).
M.LAYER_ID = "layer:"

local function matches(text: string, query: string): boolean
	return query == "" or string.find(string.lower(text), string.lower(query), 1, true) ~= nil
end

-- Ad hoc filters --------------------------------------------------------------------------

local function adhocSet(v: Variable): Adhoc.Set
	return v.adhoc :: Adhoc.Set
end

-- The variable's datasource instance (its interpolated reference, else the
-- default one).
local function adhocDatasource(s: State, v: Variable): Queries.Datasource?
	local key = Variables.datasourceUid(v, Core.scopeOf(s))
	if key then
		return Queries.findDatasource(s.settings.datasources, key)
	end
	local uid = Core.defaultDsUid(s)
	return if uid then Queries.findDatasource(s.settings.datasources, uid) else nil
end

-- The Prometheus expressions of the dashboard's queries on `uid`
-- (useQueriesAsFilterForOptions: getQueriesForVariables), in layout order.
local function datasourceExprs(s: State, uid: string, env: Env): { string }
	local out: { string } = {}
	local scope = Core.scopeOf(s)
	for _, sec in s.sections do
		for _, inst in sec.panels do
			if inst.clone ~= 0 then
				continue
			end
			local json = inst.panel.json
			local refs = Queries.resolve(json, scope, s.settings.datasources, env, s.settings.major)
			local ts = Env.value(env, json.targets)
			if refs == nil or type(ts) ~= "table" then
				continue
			end
			local i = 0
			for _, t in ts do
				if type(t) ~= "table" then
					continue
				end
				i += 1
				local ref = refs[i]
				local e = Env.value(env, t.expr)
				if ref and ref.uid == uid and type(e) == "string" and e ~= "" then
					table.insert(out, e)
				end
			end
		end
	end
	return out
end

-- The other filters a key or value list is narrowed by: for keys, every
-- filter but the edited key's plus the base filters; for values, every
-- filter on another key.
local function otherFilters(set: Adhoc.Set, key: string?, forKeys: boolean): { Adhoc.Filter }
	local out: { Adhoc.Filter } = {}
	for _, f in Adhoc.applied(set.filters) do
		if f.key ~= key then
			table.insert(out, f)
		end
	end
	if forKeys then
		for _, f in set.base_filters do
			table.insert(out, f)
		end
	end
	return out
end

local function listFailed(p: Picker, message: string)
	p.list, p.list_status, p.list_error = nil, "error", message
end

-- Starts loading the keys (step "key") or values (step "value") listed.
local function requestList(s: State, v: Variable, env: Env, effects: { Effect })
	local p = s.picker :: Picker
	local set = adhocSet(v)
	p.list, p.list_status, p.list_error = nil, "loading", nil
	s.picker_gen += 1
	p.list_gen = s.picker_gen
	local forKeys = p.step == "key"
	if forKeys and set.default_keys then
		local list: { Variables.Option } = {}
		for i, k in set.default_keys :: { Adhoc.Key } do
			list[i] = { text = k.text, value = k.value }
		end
		p.list, p.list_status = list, "ready"
		return
	end
	local route = s.route
	local ds = adhocDatasource(s, v)
	if route == nil or ds == nil then
		listFailed(p, "the variable's datasource is not known")
		return
	end
	local d = ds :: Queries.Datasource
	local r = s.range or { from_ms = env.now_ms - 3600000, to_ms = env.now_ms }
	local dsRoute = Core.datasourceRoute(route, d.uid)
	local others = otherFilters(set, if forKeys then (if p.edit then p.key else nil) else p.key, forKeys)
	local request
	if d.type == "prometheus" then
		local special = s.settings.features.prometheusSpecialCharsInLabelValues == true
		local match = Adhoc.promMatch(Adhoc.promMetrics(datasourceExprs(s, d.uid, env)), others, special)
		local opts = {
			match = if match
				then { Interpolate.replace(match, Core.scopeOf(s), { format = Interpolate.prometheus }) }
				else nil,
			from_ms = r.from_ms,
			to_ms = r.to_ms,
		}
		request = if forKeys
			then Metrics.labelsRequest(dsRoute, opts)
			else Metrics.labelValuesRequest(dsRoute, p.key :: string, opts)
	elseif d.type == "loki" then
		local opts = { from_ms = r.from_ms, to_ms = r.to_ms, query = Adhoc.lokiMatch(others) }
		request = if forKeys
			then Loki.labelsRequest(dsRoute, opts)
			else Loki.labelValuesRequest(dsRoute, p.key :: string, opts)
	else
		listFailed(p, string.format("%s %s are not listed natively", d.type, if forKeys then "keys" else "values"))
		return
	end
	table.insert(effects, Core.http(Core.tag("adhoc", s.gen, p.list_gen), route, request))
end

-- The answer to a key or value list: tag adhoc/<gen>/<list gen>.
function M.onList(s: State, parts: { string }, response: any, env: Env): boolean
	local p = s.picker
	if p == nil or p.list_gen == nil or tonumber(parts[3] or "") ~= p.list_gen then
		return false
	end
	local v = Variables.find(s.vars, p.name or "")
	if v == nil or v.adhoc == nil then
		return false
	end
	local result = Metrics.parseList(s.route :: any, response, env)
	if not result.ok then
		listFailed(p, (result :: any).error.message)
		return true
	end
	local values: { string } = (result :: any).values
	local list: { Variables.Option } = {}
	if p.step == "key" then
		-- getTagKeys leaves out the keys the other filters use, sorted.
		local used: { [string]: boolean } = {}
		for _, f in otherFilters(v.adhoc :: Adhoc.Set, if p.edit then p.key else nil, true) do
			used[f.key] = true
		end
		local keys: { string } = {}
		for _, k in values do
			if not used[k] then
				table.insert(keys, k)
			end
		end
		table.sort(keys)
		values = keys
	end
	for i, x in values do
		list[i] = { text = x, value = x }
	end
	p.list, p.list_status, p.list_error = list, "ready", nil
	return true
end

local function toFilters(s: State)
	local p = s.picker :: Picker
	p.step, p.edit, p.key, p.op = "filters", nil, nil, nil
	p.list, p.list_status, p.list_error, p.list_gen = nil, nil, nil, nil
	p.query, p.selected, p.chosen = "", nil, nil
end

local function applyFilters(s: State, v: Variable, filters: { Adhoc.Filter }, env: Env, effects: { Effect })
	local urls: { string } = table.create(#filters)
	for i, f in filters do
		urls[i] = Adhoc.toUrl(f)
	end
	Advance.selectVariable(s, v.name, urls, env, effects)
end

-- The edited filter is done: it replaces the one edited or joins the list.
local function commit(s: State, v: Variable, values: { string }, env: Env, effects: { Effect })
	local p = s.picker :: Picker
	local op = p.op or "="
	local f: Adhoc.Filter = {
		key = p.key :: string,
		operator = op,
		value = values[1] or "",
		values = if Adhoc.isMulti(op) then Tbl.copy(values) else nil,
	}
	local filters = Tbl.copy(adhocSet(v).filters)
	if p.edit and filters[p.edit] then
		filters[p.edit] = f
	else
		table.insert(filters, f)
	end
	toFilters(s)
	applyFilters(s, v, filters, env, effects)
end

local function adhocItems(s: State, p: Picker, v: Variable): { PickerItem }
	local set = adhocSet(v)
	local out: { PickerItem } = {}
	local step = p.step or "filters"
	if step == "filters" then
		for i, f in set.filters do
			local label = Adhoc.describe(f)
			if matches(label, p.query) then
				table.insert(out, { id = "f" .. i, label = label, detail = "edit" })
			end
		end
		if matches("Add filter", p.query) then
			table.insert(out, { id = "+", label = "+ Add filter" })
		end
		if #set.filters > 0 and matches("Remove all filters", p.query) then
			table.insert(out, { id = "-", label = "Remove all filters" })
		end
	elseif step == "op" then
		local ds = adhocDatasource(s, v)
		for _, o in Adhoc.operators(set, ds ~= nil and (ds :: Queries.Datasource).multi_value_filters == true) do
			if matches(o.value, p.query) or matches(o.description, p.query) then
				table.insert(out, { id = "o:" .. o.value, label = o.value, detail = o.description })
			end
		end
	else
		local prefix = if step == "key" then "k:" else "v:"
		if step == "key" and p.edit then
			table.insert(out, { id = "x", label = "Remove this filter" })
		end
		local exact = false
		for _, o in p.list or {} :: { Variables.Option } do
			if matches(o.text, p.query) then
				table.insert(out, { id = prefix .. o.value, label = o.text })
			end
			exact = exact or o.value == p.query
		end
		if set.allow_custom_value and p.query ~= "" and not exact then
			table.insert(out, {
				id = prefix .. p.query,
				label = p.query,
				detail = if step == "key" then "custom key" else "custom value",
			})
		end
	end
	return out
end

local function adhocPick(s: State, v: Variable, id: string, env: Env, effects: { Effect })
	local p = s.picker :: Picker
	local set = adhocSet(v)
	local step = p.step or "filters"
	if step == "filters" then
		if id == "-" then
			toFilters(s)
			applyFilters(s, v, {}, env, effects)
			return
		end
		local i = if id == "+" then nil else tonumber(string.match(id, "^f(%d+)$") or "")
		local f = if i then set.filters[i] else nil
		if id ~= "+" and f == nil then
			return
		end
		p.step, p.edit, p.query = "key", i, ""
		p.key = if f then f.key else nil
		p.op = if f then f.operator else nil
		p.selected = if f then "k:" .. f.key else nil
		requestList(s, v, env, effects)
	elseif step == "key" then
		if id == "x" then
			local filters = Tbl.copy(set.filters)
			if p.edit then
				table.remove(filters, p.edit)
			end
			toFilters(s)
			applyFilters(s, v, filters, env, effects)
			return
		end
		local key = string.match(id, "^k:(.*)$")
		if key == nil or key == "" then
			return
		end
		p.key, p.step, p.query = key, "op", ""
		p.selected = "o:" .. (p.op or "=")
	elseif step == "op" then
		local op = string.match(id, "^o:(.*)$")
		if op == nil then
			return
		end
		local edited = if p.edit then set.filters[p.edit] else nil
		p.op, p.step, p.query = op, "value", ""
		if Adhoc.isMulti(op) then
			p.chosen = if edited and Adhoc.isMulti(edited.operator) then Tbl.copy(edited.values or {}) else {}
			p.selected = nil
		else
			p.chosen = nil
			p.selected = if edited then "v:" .. edited.value else nil
		end
		requestList(s, v, env, effects)
	else
		local value = string.match(id, "^v:(.*)$")
		if value == nil then
			return
		end
		if p.chosen then
			local chosen = p.chosen :: { string }
			local idx = table.find(chosen, value)
			if idx then
				table.remove(chosen, idx)
			else
				table.insert(chosen, value)
			end
			return
		end
		if value ~= "" then
			commit(s, v, { value }, env, effects)
		end
	end
end

-- Escape in an ad hoc picker: back to the filter list (a one-of value
-- selection applies first); from the list, close.
local function adhocEscape(s: State, v: Variable, env: Env, effects: { Effect })
	local p = s.picker :: Picker
	if (p.step or "filters") == "filters" then
		s.picker = nil
	elseif p.step == "value" and p.chosen and #(p.chosen :: { string }) > 0 then
		commit(s, v, p.chosen :: { string }, env, effects)
	else
		toFilters(s)
	end
end

local function adhocVar(s: State): Variable?
	local p = s.picker
	if p == nil or p.kind ~= "var" then
		return nil
	end
	local v = Variables.find(s.vars, p.name or "")
	return if v and v.adhoc then v else nil
end

-- Pickers --------------------------------------------------------------------------------

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
	elseif p.kind == "links" then
		local links: { Types.PanelLink } = p.links or {}
		for i, l in links do
			if matches(l.title, p.query) then
				table.insert(out, { id = tostring(i), label = l.title, detail = l.url })
			end
		end
	elseif p.kind == "vars" then
		for _, v in s.vars do
			if v.hide < 2 and v.kind ~= "constant" and matches(v.label or v.name, p.query) then
				table.insert(out, { id = v.name, label = v.label or v.name, detail = Variables.display(v) })
			end
		end
		-- The annotation layer switches of the variable bar.
		for _, t in s.layers.toggles do
			if matches(t.name, p.query) then
				table.insert(out, {
					id = M.LAYER_ID .. t.name,
					label = t.name,
					detail = if t.on then "annotations on" else "annotations off",
				})
			end
		end
	else
		local v = Variables.find(s.vars, p.name or "")
		if v == nil then
			return out
		end
		if v.adhoc then
			return adhocItems(s, p, v)
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

-- Switches annotation layer `name` on or off (its variable bar toggle).
function M.toggleLayer(s: State, name: string, env: Env, effects: { Effect })
	for _, t in s.layers.toggles do
		if t.name == name then
			s.layer_on[name] = not t.on
			Advance.advance(s, env, false, effects)
			return
		end
	end
end

-- Grafana's panel links menu (VizPanelLinks with several links): a
-- picker of the links of panel `key`.
function M.openLinks(s: State, key: string, env: Env)
	local inst = Core.find(s, key)
	if inst == nil then
		return
	end
	s.picker = { kind = "links", name = key, query = "", links = Links.panelLinks(s, inst, env) }
end

function M.openVar(s: State, name: string)
	local v = Variables.find(s.vars, name)
	if v == nil or v.kind == "constant" or v.kind == "unsupported" then
		return
	end
	if v.adhoc then
		s.picker = { kind = "var", name = name, query = "", step = "filters" }
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
	s.layer_on = {}
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
	elseif p.kind == "links" then
		s.picker = nil
		Links.openPanelLink(s, id .. ":" .. (p.name or ""), env, effects)
	elseif p.kind == "vars" then
		if string.sub(id, 1, #M.LAYER_ID) == M.LAYER_ID then
			M.toggleLayer(s, string.sub(id, #M.LAYER_ID + 1), env, effects)
		else
			M.openVar(s, id)
		end
	else
		local v = Variables.find(s.vars, p.name or "")
		if v == nil then
			s.picker = nil
			return
		end
		if v.adhoc then
			adhocPick(s, v, id, env, effects)
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

-- The highlighted item, else the first.
local function current(s: State): string?
	local p = s.picker :: Picker
	local items = M.items(s)
	for _, it in items do
		if it.id == p.selected then
			return it.id
		end
	end
	return if items[1] then items[1].id else nil
end

function M.key(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local p = s.picker :: Picker
	local name = key.name
	local av = adhocVar(s)
	if av then
		if name == "escape" then
			adhocEscape(s, av, env, effects)
			return true
		elseif p.chosen and (name == "space" or name == "enter") then
			-- A one-of filter's values: space toggles, enter applies (the
			-- highlighted value joins an empty selection).
			local id = current(s)
			local chosen = p.chosen :: { string }
			if name == "space" or #chosen == 0 then
				if id then
					adhocPick(s, av, id, env, effects)
				end
			end
			if name == "enter" and #chosen > 0 then
				commit(s, av, chosen, env, effects)
			end
			return true
		end
	end
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
