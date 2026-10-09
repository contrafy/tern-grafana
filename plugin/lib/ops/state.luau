--!strict
-- The `ops` block: a Prometheus server's own health for one context, in
-- tabs. Targets (/api/v1/targets), Cardinality (/api/v1/status/tsdb), Info
-- (build, runtime, flags, config) and Rules, which belongs to the alerts
-- block and is only a link there. Each tab loads its endpoints the first
-- time it shows; `r` reloads the current tab. Rendering lives in ./view.

local Effect = require("../effect")
local Env = require("../env")
local Group = require("../alerts/group")
local Info = require("./info")
local Ops = require("../source/ops")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Targets = require("./targets")
local Tsdb = require("./tsdb")
local TransportTypes = require("../transport/types")

type Effect = Effect.Effect
type Msg = Effect.Msg
type Env = Env.Env
type Route = Route.Route
type QueryError = TransportTypes.QueryError

export type Tab = "targets" | "rules" | "cardinality" | "info"
export type Endpoint = "targets" | "tsdb" | "buildinfo" | "runtimeinfo" | "flags" | "config"

export type Slot = { loading: boolean, error: QueryError?, loaded_ms: number? }

export type TargetRow = { kind: "pool", pool: number } | { kind: "target", pool: number, target: Targets.Target }
export type CardRow = { list: Tsdb.ListName, index: number }

export type State = {
	contexts: { string },
	context: string?,
	route: Route?,
	-- Why nothing can load (no config, no metrics endpoint for the context).
	problem: string?,
	tab: Tab,
	gen: number,
	slots: { [Endpoint]: Slot },
	build: Info.Build?,
	runtime: Info.Runtime?,
	flags: { Info.Flag }?,
	config: Info.ConfigSummary?,
	config_yaml: string?,
	targets: Targets.Targets?,
	tsdb: Tsdb.Tsdb?,
	tsdb_limit: number,
	-- Filters targets and flags.
	filter_text: string,
	filter: Group.Filter,
	filter_error: string?,
	editing: string?,
	unhealthy_only: boolean,
	show_dropped: boolean,
	collapsed: { [string]: boolean },
	pools: { Targets.Pool },
	rows: { TargetRow },
	sel: number,
	-- Key of the target whose detail is open.
	detail: string?,
	-- Cardinality lists that are expanded; their entries are card_rows.
	open_lists: { [string]: boolean },
	card_rows: { CardRow },
	card_sel: number,
	note: string?,
}

local M = {}

M.TABS = table.freeze({ "targets", "rules", "cardinality", "info" } :: { Tab })

local TAB_ENDPOINTS: { [string]: { Endpoint } } = {
	targets = { "targets" },
	rules = {},
	cardinality = { "tsdb" },
	info = { "buildinfo", "runtimeinfo", "flags", "config" },
}

-- The endpoints a tab shows.
function M.endpoints(tab: Tab): { Endpoint }
	return TAB_ENDPOINTS[tab]
end

local EMPTY_FILTER: Group.Filter = { matchers = {}, words = {} }

local DEFAULT_OPEN_LISTS = { series_by_metric = true }

local function isTab(v: any): boolean
	return type(v) == "string" and TAB_ENDPOINTS[v] ~= nil
end

local function sortedContexts(env: Env): { string }
	local out: { string } = {}
	local cfg = env.config
	if cfg then
		for name in cfg.contexts do
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

local function path(e: Endpoint): string
	if e == "targets" then
		return Ops.TARGETS_PATH
	end
	return Ops.statusPath(e :: Ops.Status)
end

local function request(s: State, route: Route, e: Endpoint): TransportTypes.Request
	if e == "targets" then
		return Ops.targetsRequest(route)
	elseif e == "tsdb" then
		return Ops.tsdbRequest(route, s.tsdb_limit)
	end
	return Ops.statusRequest(route, e :: Ops.Status)
end

function M.deriveTargets(s: State)
	local t = s.targets
	s.pools = if t then Targets.pools(t, s.filter, s.unhealthy_only) else {}
	local rows: { TargetRow } = {}
	for pi, p in s.pools do
		table.insert(rows, { kind = "pool", pool = pi })
		if not s.collapsed[p.name] then
			for _, target in p.targets do
				table.insert(rows, { kind = "target", pool = pi, target = target })
			end
		end
	end
	s.rows = rows
	s.sel = math.clamp(s.sel, math.min(1, #rows), #rows)
	if s.detail then
		local found = false
		for _, r in rows do
			if r.kind == "target" and (r :: any).target.key == s.detail then
				found = true
				break
			end
		end
		if not found then
			s.detail = nil
		end
	end
end

function M.deriveCardinality(s: State)
	local rows: { CardRow } = {}
	local t = s.tsdb
	if t then
		for _, l in Tsdb.LISTS do
			if s.open_lists[l.name] then
				for i in Tsdb.list(t, l.name) do
					table.insert(rows, { list = l.name, index = i })
				end
			end
		end
	end
	s.card_rows = rows
	s.card_sel = math.clamp(s.card_sel, math.min(1, #rows), #rows)
end

local function fetch(s: State, e: Endpoint, effects: { Effect })
	local route = s.route
	if route == nil then
		return
	end
	local slot = s.slots[e]
	slot.loading = true
	table.insert(effects, {
		kind = "http",
		tag = string.format("%d:%s", s.gen, e),
		route = route,
		request = request(s, route, e),
	})
end

-- Loads the tab's endpoints that never answered (or all of them on `force`).
local function loadTab(s: State, effects: { Effect }, force: boolean)
	for _, e in M.endpoints(s.tab) do
		local slot = s.slots[e :: Endpoint]
		if not slot.loading and (force or slot.loaded_ms == nil and slot.error == nil) then
			fetch(s, e :: Endpoint, effects)
		end
	end
end

local function freshSlots(): { [Endpoint]: Slot }
	return {
		targets = { loading = false },
		tsdb = { loading = false },
		buildinfo = { loading = false },
		runtimeinfo = { loading = false },
		flags = { loading = false },
		config = { loading = false },
	}
end

-- Resolves the context's metrics route and starts over: buildinfo (the
-- header names the server) plus the current tab.
local function connect(s: State, env: Env, effects: { Effect })
	s.gen += 1
	s.slots = freshSlots()
	s.build, s.runtime, s.flags, s.config, s.config_yaml = nil, nil, nil, nil, nil
	s.targets, s.tsdb = nil, nil
	s.note = nil
	s.detail = nil
	s.route = nil
	local cfg = env.config
	if cfg == nil then
		s.problem = "No valid config: open Grafana: Settings or see docs/configuration.md."
	else
		local route, err = Route.route(cfg, s.context, "metrics")
		if route == nil then
			s.problem = (err :: Route.RouteError).message
		else
			s.problem = nil
			s.route = route
			s.context = route.context
		end
	end
	M.deriveTargets(s)
	M.deriveCardinality(s)
	if s.route == nil then
		return
	end
	fetch(s, "buildinfo", effects)
	loadTab(s, effects, false)
end

local function setFilter(s: State, text: string)
	local f, err = Group.parseFilter(text)
	s.filter_text = text
	if f then
		s.filter = f
		s.filter_error = nil
	else
		s.filter = EMPTY_FILTER
		s.filter_error = err
	end
	s.sel = 1
	M.deriveTargets(s)
end

local function linkParams(args: { string }): { [string]: string }
	local first = args[1]
	if first == nil or first == "" then
		return {}
	end
	local link = Scheme.decode(first)
	if link == nil or link.action ~= "ops" then
		return {}
	end
	return link.params
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local params = linkParams(args)
	local savedT = if type(saved) == "table" then saved else {}
	local s: State = {
		contexts = sortedContexts(env),
		context = nil,
		route = nil,
		problem = nil,
		tab = "targets",
		gen = 0,
		slots = freshSlots(),
		build = nil,
		runtime = nil,
		flags = nil,
		config = nil,
		config_yaml = nil,
		targets = nil,
		tsdb = nil,
		tsdb_limit = Tsdb.DEFAULT_LIMIT,
		filter_text = "",
		filter = EMPTY_FILTER,
		filter_error = nil,
		editing = nil,
		unhealthy_only = savedT.unhealthy_only == true,
		show_dropped = false,
		collapsed = {},
		pools = {},
		rows = {},
		sel = 1,
		detail = nil,
		open_lists = table.clone(DEFAULT_OPEN_LISTS),
		card_rows = {},
		card_sel = 1,
		note = nil,
	}
	s.context = params.context or (if type(savedT.context) == "string" then savedT.context else nil)
	if s.context and env.config and env.config.contexts[s.context :: string] == nil then
		s.context = nil
	end
	if params.view and isTab(params.view) then
		s.tab = params.view :: Tab
	elseif isTab(savedT.tab) then
		s.tab = savedT.tab
	end
	if type(savedT.tsdb_limit) == "number" and table.find(Tsdb.LIMITS, savedT.tsdb_limit) then
		s.tsdb_limit = savedT.tsdb_limit
	end
	if type(savedT.open_lists) == "table" then
		local open: { [string]: boolean } = {}
		for _, name in savedT.open_lists do
			if type(name) == "string" then
				open[name] = true
			end
		end
		s.open_lists = open
	end
	setFilter(s, if type(savedT.filter) == "string" then savedT.filter else "")
	local effects: { Effect } = {}
	connect(s, env, effects)
	return s, effects
end

local function store(s: State, e: Endpoint, data: any, env: Env)
	if e == "targets" then
		s.targets = Targets.normalize(data, env)
		M.deriveTargets(s)
	elseif e == "tsdb" then
		s.tsdb = Tsdb.normalize(data, env)
		M.deriveCardinality(s)
	elseif e == "buildinfo" then
		s.build = Info.build(data, env)
	elseif e == "runtimeinfo" then
		s.runtime = Info.runtime(data, env)
	elseif e == "flags" then
		s.flags = Info.flags(data, env)
	elseif e == "config" then
		local yaml = Info.configYaml(data, env)
		s.config_yaml = yaml
		s.config = if yaml then Info.configSummary(yaml) else nil
	end
end

-- A missing endpoint drops what an earlier answer showed (the server
-- changed under the context); any other failure keeps the last good data.
local function forget(s: State, e: Endpoint)
	if e == "targets" then
		s.targets = nil
		M.deriveTargets(s)
	elseif e == "tsdb" then
		s.tsdb = nil
		M.deriveCardinality(s)
	elseif e == "buildinfo" then
		s.build = nil
	elseif e == "runtimeinfo" then
		s.runtime = nil
	elseif e == "flags" then
		s.flags = nil
	elseif e == "config" then
		s.config, s.config_yaml = nil, nil
	end
end

local function answered(s: State, e: Endpoint, response: TransportTypes.Response, env: Env)
	local slot = s.slots[e]
	slot.loading = false
	local result = Ops.parse(response, env, path(e))
	if result.ok then
		slot.error = nil
		slot.loaded_ms = env.now_ms
		store(s, e, (result :: any).data, env)
	else
		local err: QueryError = (result :: any).error
		slot.error = err
		if err.kind == "unsupported" then
			slot.loaded_ms = nil
			forget(s, e)
		end
	end
end

local function switchTab(s: State, tab: Tab, effects: { Effect })
	if s.tab == tab then
		return
	end
	s.tab = tab
	s.note = nil
	loadTab(s, effects, false)
end

local function cycleTab(s: State, step: number, effects: { Effect })
	local i = table.find(M.TABS, s.tab) or 1
	switchTab(s, M.TABS[(i - 1 + step) % #M.TABS + 1], effects)
end

local function switchContext(s: State, env: Env, name: string, effects: { Effect })
	if name == s.context and s.route then
		return
	end
	s.context = name
	s.collapsed = {}
	s.sel = 1
	s.card_sel = 1
	connect(s, env, effects)
end

local function cycleContext(s: State, env: Env, step: number, effects: { Effect })
	local n = #s.contexts
	if n < 2 then
		return
	end
	local i = table.find(s.contexts, s.context or "") or 0
	switchContext(s, env, s.contexts[(i - 1 + step) % n + 1], effects)
end

function M.rulesLink(s: State): string?
	if s.context == nil then
		return nil
	end
	return Scheme.encode({ action = "alerts", params = { context = s.context :: string, view = "rules" }, vars = {} })
end

-- The Query block on the PromQL that breaks a cardinality entry down.
function M.drillLink(s: State, list: Tsdb.ListName, index: number): string?
	local t = s.tsdb
	local entry = if t then Tsdb.list(t, list)[index] else nil
	if entry == nil or s.context == nil then
		return nil
	end
	local expr = Tsdb.drillQuery(list, entry.name)
	if expr == nil then
		return nil
	end
	return Scheme.encode({
		action = "query",
		params = { context = s.context :: string, expr = expr, mode = "table" },
		vars = {},
	})
end

local function openRules(s: State, effects: { Effect })
	local target = M.rulesLink(s)
	if target then
		table.insert(effects, { kind = "open", target = target })
	end
end

local function drill(s: State, i: number, effects: { Effect })
	local row = s.card_rows[i]
	if row == nil then
		return
	end
	s.card_sel = i
	local target = M.drillLink(s, row.list, row.index)
	if target then
		table.insert(effects, { kind = "open", target = target })
	end
end

local function setLimit(s: State, step: number, effects: { Effect })
	local limit = Tsdb.stepLimit(s.tsdb_limit, step)
	if limit == s.tsdb_limit then
		return
	end
	s.tsdb_limit = limit
	fetch(s, "tsdb", effects)
end

local function toggleList(s: State, name: string)
	if s.open_lists[name] then
		s.open_lists[name] = nil
	else
		s.open_lists[name] = true
	end
	M.deriveCardinality(s)
end

local function togglePool(s: State, pi: number)
	local p = s.pools[pi]
	if p == nil then
		return
	end
	if s.collapsed[p.name] then
		s.collapsed[p.name] = nil
	else
		s.collapsed[p.name] = true
	end
	M.deriveTargets(s)
	for i, r in s.rows do
		if r.kind == "pool" and r.pool == pi then
			s.sel = i
			break
		end
	end
end

local function activateTarget(s: State)
	local r = s.rows[s.sel]
	if r == nil then
		return
	end
	if r.kind == "pool" then
		togglePool(s, r.pool)
	else
		local key = (r :: any).target.key
		s.detail = if s.detail == key then nil else key
	end
end

local function copyConfig(s: State, effects: { Effect })
	if s.config_yaml == nil then
		s.note = "The configuration has not loaded."
		return
	end
	table.insert(effects, { kind = "copy", text = s.config_yaml :: string })
	s.note = "Copied the configuration YAML."
end

-- View ids of the selected row (lib/ops/view keys: pool cards `p<i>` under
-- `pools` holding target rows `r<i>`; cardinality sections `l_<list>` holding
-- a grid `g` whose rows `e<i>` are `display: contents`, so their first cell
-- is what has a box to scroll to).
function M.selectionId(s: State): string?
	if s.tab == "targets" then
		local r = s.rows[s.sel]
		if r == nil then
			return nil
		end
		local card = string.format("main.pools.p%d", r.pool)
		return if r.kind == "pool" then card else string.format("%s.r%d", card, s.sel)
	elseif s.tab == "cardinality" then
		local r = s.card_rows[s.card_sel]
		if r == nil then
			return nil
		end
		return string.format("main.l_%s.g.0.e%d.0", r.list, s.card_sel)
	end
	return nil
end

local function move(s: State, delta: number, effects: { Effect })
	if s.tab == "targets" and #s.rows > 0 then
		s.sel = math.clamp(s.sel + delta, 1, #s.rows)
	elseif s.tab == "cardinality" and #s.card_rows > 0 then
		s.card_sel = math.clamp(s.card_sel + delta, 1, #s.card_rows)
	else
		return
	end
	local id = M.selectionId(s)
	if id then
		table.insert(effects, { kind = "reveal", id = id })
	end
end

local function activate(s: State, effects: { Effect })
	if s.tab == "targets" then
		activateTarget(s)
	elseif s.tab == "cardinality" then
		drill(s, s.card_sel, effects)
	elseif s.tab == "rules" then
		openRules(s, effects)
	end
end

local function startFilter(s: State, effects: { Effect })
	s.editing = s.filter_text
	table.insert(effects, { kind = "focus", id = "main.filter" })
end

local function editKey(s: State, key: any): boolean
	local text = s.editing :: string
	local name = key.name
	if name == "escape" then
		s.editing = nil
	elseif name == "enter" then
		s.editing = nil
		setFilter(s, text)
	elseif name == "backspace" then
		s.editing = string.sub(text, 1, -2)
	elseif name == "paste" and type(key.text) == "string" then
		s.editing = text .. string.gsub(key.text, "[%c]", " ")
	elseif key.ctrl and name == "u" then
		s.editing = ""
	elseif key.text and key.text ~= "" and not key.ctrl and not key.meta then
		s.editing = text .. key.text
	else
		return false
	end
	return true
end

local function normalKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	if key.ctrl or key.meta or key.alt then
		return false
	end
	local name = key.name
	local text = key.text
	-- A plain string: comparing the Tab union across elseif branches trips
	-- the type checker's refinement.
	local tab: string = s.tab
	if name == "tab" then
		cycleTab(s, if key.shift then -1 else 1, effects)
	elseif text == "1" or text == "2" or text == "3" or text == "4" then
		switchTab(s, M.TABS[tonumber(text) :: number], effects)
	elseif name == "down" or text == "j" then
		move(s, 1, effects)
	elseif name == "up" or text == "k" then
		move(s, -1, effects)
	elseif name == "home" then
		move(s, -math.huge, effects)
	elseif name == "end" then
		move(s, math.huge, effects)
	elseif name == "enter" or name == "space" then
		activate(s, effects)
	elseif name == "escape" then
		if s.detail then
			s.detail = nil
		elseif s.filter_text ~= "" then
			setFilter(s, "")
		else
			return false
		end
	elseif text == "/" and (tab == "targets" or tab == "info") then
		startFilter(s, effects)
	elseif text == "r" then
		loadTab(s, effects, true)
	elseif text == "c" then
		cycleContext(s, env, 1, effects)
	elseif text == "C" then
		cycleContext(s, env, -1, effects)
	elseif text == "u" and tab == "targets" then
		s.unhealthy_only = not s.unhealthy_only
		s.sel = 1
		M.deriveTargets(s)
	elseif text == "d" and tab == "targets" then
		s.show_dropped = not s.show_dropped
	elseif (text == "+" or text == "=") and tab == "cardinality" then
		setLimit(s, 1, effects)
	elseif text == "-" and tab == "cardinality" then
		setLimit(s, -1, effects)
	elseif text == "y" and tab == "info" then
		copyConfig(s, effects)
	else
		return false
	end
	return true
end

function M.key(s: State, key: any, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	local handled = if s.editing ~= nil then editKey(s, key) else normalKey(s, key, env, effects)
	return s, effects, handled
end

local function onAction(s: State, act: string, value: string?, env: Env, effects: { Effect })
	if act == "ctx" and value then
		if table.find(s.contexts, value) then
			switchContext(s, env, value, effects)
		end
	elseif act == "tab" and value then
		if isTab(value) then
			switchTab(s, value :: Tab, effects)
		end
	elseif act == "reload" then
		loadTab(s, effects, true)
	elseif act == "filter" then
		startFilter(s, effects)
	elseif act == "clear" then
		s.editing = nil
		setFilter(s, "")
	elseif act == "unhealthy" then
		s.unhealthy_only = not s.unhealthy_only
		s.sel = 1
		M.deriveTargets(s)
	elseif act == "dropped" then
		s.show_dropped = not s.show_dropped
	elseif act == "row" and value then
		local i = tonumber(value)
		if i and s.rows[i] then
			s.sel = i
			activateTarget(s)
		end
	elseif act == "drill" and value then
		local i = tonumber(value)
		if i then
			drill(s, i, effects)
		end
	elseif act == "limit" and value then
		setLimit(s, if value == "up" then 1 else -1, effects)
	elseif act == "rules" then
		openRules(s, effects)
	elseif act == "copy" then
		copyConfig(s, effects)
	end
end

function M.update(s: State, msg: Msg, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		local gen, e = string.match(msg.tag, "^(%d+):(.+)$")
		if gen == nil or tonumber(gen) ~= s.gen then
			return s, effects
		end
		local slot = s.slots[e :: Endpoint]
		if slot == nil or not slot.loading then
			return s, effects
		end
		answered(s, e :: Endpoint, msg.response, env)
	elseif msg.kind == "key" then
		local _, list = M.key(s, msg.key, env)
		return s, list
	elseif msg.kind == "event" then
		local ev: any = msg.ev
		if ev.ev == "action" and type(ev.act) == "string" then
			onAction(s, ev.act, ev.value, env, effects)
		elseif ev.ev == "toggle" and type(ev.id) == "string" then
			local pi = tonumber(string.match(ev.id, "%.p(%d+)$") or "")
			local list = string.match(ev.id, "%.l_([%w_]+)$")
			if pi then
				togglePool(s, pi)
			elseif list then
				toggleList(s, list)
			end
		end
	end
	return s, effects
end

function M.title(s: State): string?
	local base = if s.context then "Ops: " .. (s.context :: string) else "Ops"
	local t = s.targets
	if t then
		local down = Targets.counts(t).down
		if down > 0 then
			return string.format("%s (%d down)", base, down)
		end
	end
	return base
end

-- Only what to reopen with: never server data or credentials.
function M.save(s: State): any
	local open: { string } = {}
	for name in s.open_lists do
		table.insert(open, name)
	end
	table.sort(open)
	return {
		context = s.context,
		tab = s.tab,
		filter = s.filter_text,
		unhealthy_only = s.unhealthy_only,
		tsdb_limit = s.tsdb_limit,
		open_lists = open,
	}
end

return M
