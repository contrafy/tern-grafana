--!strict
-- The `compat` block ("Grafana: Compatibility"): which rung every panel of
-- every dashboard of a context would take in the Dashboard block, and why.
--
-- A scan reads Grafana's frontend settings (renderer, datasource catalog)
-- and pages through /api/search?type=dash-db up to `compat.max_dashboards`,
-- then loads the dashboards CONCURRENCY at a time, each with its library
-- panels (fetched once per scan, shared by the dashboards using them), and
-- decides their panels with lib/compat/analyze. Only GETs: the scan never
-- changes anything. A restored block waits for `r` instead of rescanning a
-- whole stack on every Tern start. Rendering lives in ./view.

local Analyze = require("./analyze")
local CompatConfig = require("./config")
local Effect = require("../effect")
local Env = require("../env")
local GrafanaSource = require("../source/grafana")
local Markdown = require("./markdown")
local Model = require("../dashboard/model")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Search = require("../dashboard/search")
local TransportTypes = require("../transport/types")

type Effect = Effect.Effect
type Msg = Effect.Msg
type Env = Env.Env
type Route = Route.Route

local M = {}

-- Dashboards loading at once.
M.CONCURRENCY = 4
-- Search hits per page (Grafana's search caps a page at 5000).
M.PAGE_SIZE = 1000
-- Report rows shown at once; the filter narrows the rest.
M.MAX_ROWS = 600

export type Phase = "idle" | "scanning" | "done" | "error"

export type Row = { kind: "dash", dash: number } | { kind: "panel", dash: number, panel: number }

type Pending = { uid: string, dashboard: Model.Dashboard, waiting: { [string]: boolean } }

type Library = { done: boolean, model: { [string]: any }? }

export type State = {
	contexts: { string },
	context: string?,
	route: Route?,
	problem: string?,
	max: number,
	gen: number,
	phase: Phase,
	error: string?,
	settings: Analyze.Settings?,
	hits: { Search.Hit },
	found: number,
	search_done: boolean,
	capped: boolean,
	-- Index of the next hit to load.
	next_hit: number,
	inflight: number,
	results: { [number]: Analyze.DashResult },
	finished: number,
	pending: { [number]: Pending },
	libraries: { [string]: Library },
	started_ms: number?,
	finished_ms: number?,
	filter_text: string,
	editing: string?,
	show_native: boolean,
	rows: { Row },
	-- Rows matching the filter (rows holds at most MAX_ROWS of them).
	matched: number,
	sel: number,
	note: string?,
}

local function grafanaContexts(env: Env): { string }
	local out: { string } = {}
	local cfg = env.config
	if cfg then
		for name, c in cfg.contexts do
			if c.grafana then
				table.insert(out, name)
			end
		end
	end
	table.sort(out)
	return out
end

local function tag(s: State, ...: any): string
	local parts = { "c", tostring(s.gen) }
	for _, p in { ... } do
		table.insert(parts, tostring(p))
	end
	return table.concat(parts, "/")
end

function M.searchRequest(page: number): TransportTypes.Request
	return {
		method = "GET",
		path = "/api/search",
		query = { { "type", "dash-db" }, { "limit", tostring(M.PAGE_SIZE) }, { "page", tostring(page) } },
	}
end

-- Results in search order (dashboards still loading are skipped).
function M.ordered(s: State): { Analyze.DashResult }
	local out: { Analyze.DashResult } = {}
	for i = 1, #s.hits do
		local r = s.results[i]
		if r then
			table.insert(out, r)
		end
	end
	return out
end

local function lower(s: string): string
	return string.lower(s)
end

local function has(text: string?, q: string): boolean
	return text ~= nil and string.find(lower(text :: string), q, 1, true) ~= nil
end

local function panelMatches(p: Analyze.PanelResult, q: string): boolean
	return has(p.title, q) or has(p.type, q) or has(p.mode, q) or has(p.blocker, q) or has(p.row, q)
end

-- The visible rows: every dashboard with its non-native panels (native ones
-- too with `n`), narrowed by the filter (dashboard title, folder, uid, or a
-- panel's title, type, rung, reason, row).
function M.derive(s: State)
	local q = lower(s.filter_text)
	local rows: { Row } = {}
	local matched = 0
	local function add(r: Row)
		matched += 1
		if #rows < M.MAX_ROWS then
			table.insert(rows, r)
		end
	end
	for i = 1, #s.hits do
		local r = s.results[i]
		if r == nil then
			continue
		end
		local dashHit = q == "" or has(r.title, q) or has(r.folder, q) or has(r.uid, q)
		local panelRows: { Row } = {}
		for j, p in r.panels do
			if p.mode == "native" and not s.show_native then
				continue
			end
			if dashHit or panelMatches(p, q) then
				table.insert(panelRows, { kind = "panel", dash = i, panel = j })
			end
		end
		if dashHit or #panelRows > 0 then
			add({ kind = "dash", dash = i })
			for _, pr in panelRows do
				add(pr)
			end
		end
	end
	s.rows = rows
	s.matched = matched
	s.sel = math.clamp(s.sel, 1, math.max(1, #rows))
end

local function finish(s: State)
	if s.phase == "scanning" and s.search_done and s.finished >= #s.hits and s.settings ~= nil then
		s.phase = "done"
	end
end

local function fail(s: State, message: string)
	s.phase = "error"
	s.error = message
	s.gen += 1
end

local function record(s: State, index: number, panels: { Analyze.PanelResult }, err: string?)
	local hit = s.hits[index]
	s.results[index] = Analyze.result(hit.uid, hit.title, hit.folder, panels, err)
	s.finished += 1
	s.inflight -= 1
end

-- Loads dashboards until CONCURRENCY are in flight; needs the settings
-- (every decision reads the datasource catalog).
local function pump(s: State, effects: { Effect })
	local route = s.route
	if route == nil or s.settings == nil or s.phase ~= "scanning" then
		return
	end
	while s.inflight < M.CONCURRENCY and s.next_hit <= #s.hits do
		local i = s.next_hit
		s.next_hit += 1
		s.inflight += 1
		table.insert(effects, {
			kind = "http",
			tag = tag(s, "d", i),
			route = route,
			request = Model.request(s.hits[i].uid),
		})
	end
	finish(s)
end

local function analyzePending(s: State, index: number, env: Env)
	local p = s.pending[index]
	if p == nil or next(p.waiting) ~= nil then
		return
	end
	s.pending[index] = nil
	local settings = s.settings :: Analyze.Settings
	local ok, panels = pcall(Analyze.panels, p.dashboard, settings, env)
	if ok then
		record(s, index, panels, nil)
	else
		record(s, index, {}, "analysis failed: " .. Effect.firstLine(panels))
	end
end

local function onDashboard(s: State, index: number, response: TransportTypes.Response, env: Env, effects: { Effect })
	if s.hits[index] == nil or s.results[index] or s.pending[index] then
		return
	end
	local d, err = Model.parseResponse(response, env)
	if d == nil then
		record(s, index, {}, err or "the dashboard could not be loaded")
		return
	end
	local dash = d :: Model.Dashboard
	local p: Pending = { uid = dash.uid, dashboard = dash, waiting = {} }
	s.pending[index] = p
	local route = s.route :: Route
	for _, uid in Model.libraryRefs(dash) do
		local lib = s.libraries[uid]
		if lib and lib.done then
			Model.applyLibrary(dash, uid, lib.model, env)
		else
			p.waiting[uid] = true
			if lib == nil then
				s.libraries[uid] = { done = false, model = nil }
				table.insert(
					effects,
					{ kind = "http", tag = tag(s, "l", uid), route = route, request = Model.libraryRequest(uid) }
				)
			end
		end
	end
	analyzePending(s, index, env)
end

local function onLibrary(s: State, uid: string, response: TransportTypes.Response, env: Env)
	local lib = s.libraries[uid]
	if lib == nil or lib.done then
		return
	end
	local model = Model.parseLibrary(response, env)
	lib.done, lib.model = true, model
	local waiting: { number } = {}
	for index, p in s.pending do
		if p.waiting[uid] then
			table.insert(waiting, index)
		end
	end
	table.sort(waiting)
	for _, index in waiting do
		local p = s.pending[index]
		Model.applyLibrary(p.dashboard, uid, model, env)
		p.waiting[uid] = nil
		analyzePending(s, index, env)
	end
end

local function onSearch(s: State, page: number, response: TransportTypes.Response, env: Env, effects: { Effect })
	local hits, err = Search.parse(response, env)
	if hits == nil then
		fail(s, "dashboard search failed: " .. (err or "unknown error"))
		return
	end
	local list = hits :: { Search.Hit }
	s.found += #list
	for _, h in list do
		if #s.hits >= s.max then
			s.capped = true
			break
		end
		table.insert(s.hits, h)
	end
	if s.capped or #list < M.PAGE_SIZE then
		s.search_done = true
	else
		table.insert(effects, {
			kind = "http",
			tag = tag(s, "s", page + 1),
			route = s.route :: Route,
			request = M.searchRequest(page + 1),
		})
	end
	pump(s, effects)
end

local function onSettings(s: State, response: TransportTypes.Response, env: Env, effects: { Effect })
	local settings, err = Analyze.settings(s.route :: Route, response, env)
	if settings == nil then
		fail(s, "Grafana's frontend settings could not be read: " .. (err or "unknown error"))
		return
	end
	s.settings = settings
	pump(s, effects)
end

local function resolveRoute(s: State, env: Env): boolean
	s.route = nil
	local cfg = env.config
	if cfg == nil then
		s.problem = "No valid config: open Grafana: Settings or see docs/configuration.md."
		return false
	end
	local route, err = Route.route(cfg, s.context, "dashboards")
	if route == nil then
		s.problem = if err then err.message else "no Grafana endpoint"
		return false
	end
	s.problem = nil
	s.route = route
	s.context = route.context
	return true
end

local function reset(s: State)
	s.gen += 1
	s.phase = "idle"
	s.error = nil
	s.settings = nil
	s.hits = {}
	s.found = 0
	s.search_done = false
	s.capped = false
	s.next_hit = 1
	s.inflight = 0
	s.results = {}
	s.finished = 0
	s.pending = {}
	s.libraries = {}
	s.started_ms, s.finished_ms = nil, nil
	s.sel = 1
	s.note = nil
	M.derive(s)
end

local function scan(s: State, env: Env, effects: { Effect })
	reset(s)
	if not resolveRoute(s, env) then
		return
	end
	local route = s.route :: Route
	s.phase = "scanning"
	s.started_ms = env.now_ms
	table.insert(
		effects,
		{ kind = "http", tag = tag(s, "fs"), route = route, request = GrafanaSource.frontendSettingsRequest(route) }
	)
	table.insert(effects, { kind = "http", tag = tag(s, "s", 1), route = route, request = M.searchRequest(1) })
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local savedT = if type(saved) == "table" then saved else {}
	local s: State = {
		contexts = grafanaContexts(env),
		context = nil,
		route = nil,
		problem = nil,
		max = CompatConfig.read(env.config).max_dashboards,
		gen = 0,
		phase = "idle",
		error = nil,
		settings = nil,
		hits = {},
		found = 0,
		search_done = false,
		capped = false,
		next_hit = 1,
		inflight = 0,
		results = {},
		finished = 0,
		pending = {},
		libraries = {},
		started_ms = nil,
		finished_ms = nil,
		filter_text = if type(savedT.filter) == "string" then savedT.filter else "",
		editing = nil,
		show_native = savedT.show_native == true,
		rows = {},
		matched = 0,
		sel = 1,
		note = nil,
	}
	local ctx = if type(args[1]) == "string" and args[1] ~= "" then args[1] else savedT.context
	if type(ctx) == "string" and table.find(s.contexts, ctx) then
		s.context = ctx
	end
	local effects: { Effect } = {}
	if saved == nil then
		scan(s, env, effects)
	else
		resolveRoute(s, env)
		M.derive(s)
	end
	return s, effects
end

-- Links ---------------------------------------------------------------------

local function encode(action: string, params: { [string]: string }): string?
	local ok = Scheme.validate({ action = action, params = params, vars = {} })
	return if ok then Scheme.encode(ok) else nil
end

function M.dashboardLink(s: State, r: Analyze.DashResult, panel: Analyze.PanelResult?): string?
	local ctx = s.context
	if ctx == nil then
		return nil
	end
	local params: { [string]: string } = { context = ctx :: string, uid = r.uid }
	if panel then
		params.panel = tostring(panel.id)
	end
	return encode("dashboard", params)
end

function M.panelLink(s: State, r: Analyze.DashResult, panel: Analyze.PanelResult): string?
	local ctx = s.context
	if ctx == nil then
		return nil
	end
	return encode("panel", { context = ctx :: string, uid = r.uid, panel = tostring(panel.id) })
end

-- Keys and events -----------------------------------------------------------

function M.selectionId(s: State): string?
	return if s.rows[s.sel] then string.format("main.list.r%d", s.sel) else nil
end

local function move(s: State, delta: number, effects: { Effect })
	if #s.rows == 0 then
		return
	end
	s.sel = math.clamp(s.sel + delta, 1, #s.rows)
	local id = M.selectionId(s)
	if id then
		table.insert(effects, { kind = "reveal", id = id })
	end
end

local function open(target: string?, effects: { Effect })
	if target then
		table.insert(effects, { kind = "open", target = target :: string })
	end
end

-- enter: a dashboard row opens the dashboard, a panel row the Panel block.
local function activate(s: State, index: number, effects: { Effect })
	local row = s.rows[index]
	if row == nil then
		return
	end
	s.sel = index
	local r = s.results[row.dash]
	if r == nil then
		return
	end
	if row.kind == "panel" then
		open(M.panelLink(s, r, r.panels[(row :: any).panel]), effects)
	else
		open(M.dashboardLink(s, r, nil), effects)
	end
end

-- d: the selected row's dashboard, with a panel row's panel expanded.
local function openDashboard(s: State, effects: { Effect })
	local row = s.rows[s.sel]
	local r = if row then s.results[row.dash] else nil
	if row == nil or r == nil then
		return
	end
	local panel = if row.kind == "panel" then r.panels[(row :: any).panel] else nil
	open(M.dashboardLink(s, r, panel), effects)
end

function M.markdown(s: State, env: Env): string?
	if s.settings == nil or s.context == nil then
		return nil
	end
	local settings = s.settings :: Analyze.Settings
	local results = M.ordered(s)
	return Markdown.report({
		context = s.context :: string,
		version = settings.version,
		renderer = settings.renderer,
		found = s.found,
		max = s.max,
		capped = s.capped,
		partial = s.phase == "scanning",
		at_ms = env.now_ms,
	}, results, Analyze.summarize(results))
end

local function copy(s: State, env: Env, effects: { Effect })
	local text = M.markdown(s, env)
	if text == nil then
		s.note = "Nothing to copy yet."
		return
	end
	table.insert(effects, { kind = "copy", text = text :: string })
	s.note = if s.phase == "scanning"
		then "Copied the report so far as Markdown (the scan is still running)."
		else "Copied the report as Markdown."
end

local function setFilter(s: State, text: string)
	s.filter_text = text
	s.sel = 1
	M.derive(s)
end

local function switchContext(s: State, env: Env, name: string, effects: { Effect })
	if name == s.context and s.route then
		return
	end
	s.context = name
	scan(s, env, effects)
end

local function cycleContext(s: State, env: Env, step: number, effects: { Effect })
	local n = #s.contexts
	if n < 2 then
		return
	end
	local i = table.find(s.contexts, s.context or "") or 0
	switchContext(s, env, s.contexts[(i - 1 + step) % n + 1], effects)
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
	if name == "down" or text == "j" then
		move(s, 1, effects)
	elseif name == "up" or text == "k" then
		move(s, -1, effects)
	elseif name == "home" then
		move(s, -math.huge, effects)
	elseif name == "end" then
		move(s, math.huge, effects)
	elseif name == "pagedown" then
		move(s, 20, effects)
	elseif name == "pageup" then
		move(s, -20, effects)
	elseif name == "enter" then
		activate(s, s.sel, effects)
	elseif text == "d" then
		openDashboard(s, effects)
	elseif text == "/" then
		startFilter(s, effects)
	elseif name == "escape" then
		if s.filter_text == "" then
			return false
		end
		setFilter(s, "")
	elseif text == "n" then
		s.show_native = not s.show_native
		M.derive(s)
	elseif text == "m" then
		copy(s, env, effects)
	elseif text == "r" then
		scan(s, env, effects)
	elseif text == "c" then
		cycleContext(s, env, 1, effects)
	elseif text == "C" then
		cycleContext(s, env, -1, effects)
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
	elseif act == "row" and value then
		local i = tonumber(value)
		if i then
			activate(s, i, effects)
		end
	elseif act == "filter" then
		startFilter(s, effects)
	elseif act == "clear" then
		s.editing = nil
		setFilter(s, "")
	elseif act == "native" then
		s.show_native = not s.show_native
		M.derive(s)
	elseif act == "markdown" then
		copy(s, env, effects)
	elseif act == "scan" then
		scan(s, env, effects)
	end
end

local function onHttp(s: State, t: string, response: TransportTypes.Response, env: Env, effects: { Effect })
	local gen, rest = string.match(t, "^c/(%d+)/(.*)$")
	if gen == nil or tonumber(gen) ~= s.gen or s.phase ~= "scanning" then
		return
	end
	local r = rest :: string
	if r == "fs" then
		onSettings(s, response, env, effects)
	elseif string.sub(r, 1, 2) == "s/" then
		onSearch(s, tonumber(string.sub(r, 3)) or 1, response, env, effects)
	elseif string.sub(r, 1, 2) == "d/" then
		local index = tonumber(string.sub(r, 3))
		if index then
			onDashboard(s, index, response, env, effects)
			pump(s, effects)
		end
	elseif string.sub(r, 1, 2) == "l/" then
		onLibrary(s, string.sub(r, 3), response, env)
		pump(s, effects)
	end
	if (s.phase :: Phase) == "done" and s.finished_ms == nil then
		s.finished_ms = env.now_ms
	end
	M.derive(s)
end

function M.update(s: State, msg: Msg, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		onHttp(s, msg.tag, msg.response, env, effects)
	elseif msg.kind == "key" then
		local _, list = M.key(s, msg.key, env)
		return s, list
	elseif msg.kind == "event" then
		local ev: any = msg.ev
		if ev.ev == "action" and type(ev.act) == "string" then
			onAction(s, ev.act, ev.value, env, effects)
		end
	end
	return s, effects
end

function M.title(s: State): string?
	local base = if s.context then "Compatibility: " .. (s.context :: string) else "Compatibility"
	if s.phase == "scanning" then
		return string.format("%s (%d/%d)", base, s.finished, #s.hits)
	end
	return base
end

-- What to reopen with: never server data.
function M.save(s: State): any
	return { context = s.context, filter = s.filter_text, show_native = s.show_native }
end

return M
