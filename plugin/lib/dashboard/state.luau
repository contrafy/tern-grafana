--!strict
-- The dashboard block (`tern-grafana.dashboard`, B2) and, with `solo` set,
-- the panel block (B3, lib/dashboard/panel_state.luau): a pure state machine
-- run by plugin/block_runner.luau.
--
-- Loading: the dashboard JSON and Grafana's frontend settings (renderer,
-- datasource catalog, feature toggles) are fetched together; library panels
-- next; then the variables in dependency order, each query variable once
-- everything it references has settled; then every visible panel down its
-- ladder rung: native panels query /api/ds/query (one body per panel, over
-- the panel's own time range, lib/dashboard/panel_time) unless their module
-- needs no query, and send their module's own requests (Grafana API or
-- external GETs); PNG panels ask the image renderer, browser panels wait
-- for the user. Live panels (a module `liveMs`, e.g. the clock) share one
-- timer at the smallest period among the panels shown that redraws them
-- without querying. Every request carries a tag with a generation, and an
-- answer whose generation is stale is dropped.
-- Block `init` only fetches: opening panes and other one-shot effects follow
-- user events, because Tern re-runs init on restore and plugin reloads.

local Cursor = require("../render/cursor")
local DashConfig = require("./config")
local Effect = require("../effect")
local Env = require("../env")
local FrameProm = require("../frame/prom")
local GrafanaSource = require("../source/grafana")
local GrafanaUrl = require("../links/grafana_url")
local Http = require("../transport/http")
local Handoff = require("../investigate/handoff")
local Interpolate = require("./interpolate")
local Jumps = require("../query/jumps")
local InvestigateSubject = require("../investigate/subject")
local Ladder = require("./ladder")
local Layout = require("./layout")
local Model = require("./model")
local Queries = require("./queries")
local PanelTime = require("./panel_time")
local QueryOptions = require("../query/options")
local Range = require("../time/range")
local Registry = require("../panels/registry")
local RenderPng = require("./render_png")
local Repeat = require("./repeat")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Search = require("./search")
local Shared = require("../time/shared")
local SvgTimeseries = require("../render/svg_timeseries")
local TimeRange = require("../query/timerange")
local Variables = require("./variables")
local Tbl = require("../tbl")

type Env = Env.Env
type Effect = Effect.Effect
type Msg = Effect.Msg
type Route = Route.Route

local M = {}

M.PNG_CACHE = 24
M.SEARCH_LIMIT = Search.LIMIT

export type PanelStatus = "idle" | "loading" | "ready" | "error"

export type PanelState = {
	status: PanelStatus,
	decision: Ladder.Decision,
	-- Identity of the last query sent (queries + range), to skip repeats.
	signature: string?,
	gen: number,
	data: Queries.PanelData?,
	error: string?,
	-- PNG cache key of the picture shown (the previous one stays up while a
	-- refreshed render is pending).
	png: string?,
	-- PNG cache key the panel wants now.
	png_want: string?,
	-- The panel's range after timeFrom/timeShift and its header info.
	time: PanelTime.Override?,
	-- Module requests: parsed answers by request tag, the identity of the
	-- last batch sent, its generation, the request tag of each index, and a
	-- counter bumped by every answer (view memo).
	extra: { [string]: any }?,
	extra_sig: string?,
	req_gen: number,
	req_tags: { string },
	extra_gen: number,
	-- The module's live redraw period, nil when not live.
	live_ms: number?,
}

export type Picker = {
	kind: "search" | "vars" | "var",
	-- The variable a "var" picker edits.
	name: string?,
	query: string,
	selected: string?,
	-- Working selection of a multi-value variable.
	chosen: { string }?,
}

export type SearchState = {
	gen: number,
	status: "loading" | "ready" | "error",
	hits: { Search.Hit },
	error: string?,
}

export type Settings = {
	status: "loading" | "ready" | "error",
	renderer: boolean?,
	datasources: { Queries.Datasource },
	-- Grafana's frontend feature toggles that are on.
	features: { [string]: boolean },
	error: string?,
}

export type Phase = "search" | "loading" | "ready" | "error"

export type State = {
	-- Panel block: the one panel id it shows.
	solo: number?,
	context: string?,
	route: Route?,
	org: string?,
	uid: string?,
	-- `var-` values from the link, applied once the dashboard loads.
	link_vars: { [string]: { string } },
	-- Panel to open expanded (link `panel`).
	link_panel: number?,
	-- Range as Grafana strings; nil until the dashboard default applies.
	from: string?,
	to: string?,
	range: Range.Range?,
	phase: Phase,
	error: string?,
	gen: number,
	dashboard: Model.Dashboard?,
	vars: { Variables.Variable },
	vars_error: string?,
	var_gen: number,
	settings: Settings,
	-- The signed-in Grafana user's login (`${__user.login}`); nil until known.
	user: { status: "loading" | "ready" | "error", login: string? },
	cfg: DashConfig.Settings,
	sections: { Repeat.SectionInstance },
	collapsed: { [string]: boolean },
	panels: { [string]: PanelState },
	-- Visible panel keys in reading order.
	order: { string },
	focus: string?,
	expanded: boolean,
	cursor: number?,
	pngs: { [string]: string },
	png_order: { string },
	png_tags: { [string]: string },
	png_gen: number,
	-- Why a render failed, by cache key; a refresh or range change makes a new key.
	png_errors: { [string]: string },
	-- The renderer said it is busy (429/503): no render until the retry tick.
	png_wait: boolean,
	png_backoff_ms: number,
	-- Bumped by every refresh: part of the PNG cache key.
	refresh_gen: number,
	-- Generation of the auto-refresh timer; older ticks are dropped.
	timer_gen: number,
	refresh_ms: number?,
	auto: boolean,
	picker: Picker?,
	search: SearchState,
	updated_ms: number?,
	-- View id of each panel card in the grid, recorded by the view, so a
	-- focus move can scroll the card into view.
	card_ids: { [string]: string },
	-- Logs panels whose label toggle (`l`) overrides the panel's showLabels.
	labels: { [string]: boolean },
	-- View memo (lib/dashboard/view.luau): rendered native panels by key.
	memo: { [string]: any },
	-- Selected exemplar of the focused time series (single view): index
	-- into SvgTimeseries.drawnExemplars of its data, and the cursor time `x`
	-- cycling began at.
	exemplar: number?,
	ex_anchor: number?,
	-- Config query.exemplars and query.exemplar_trace_label.
	exemplars_on: boolean,
	trace_label: string?,
	-- Shared time range and cursor (key S).
	sync: Shared.Sync,
	-- Live redraw timer: its generation, period and tick count.
	live_gen: number,
	live_ms: number?,
	live_tick: number,
}

local function newState(env: Env): State
	local queryOptions = QueryOptions.read(if env.config then env.config.query else nil)
	return {
		solo = nil,
		context = nil,
		route = nil,
		org = nil,
		uid = nil,
		link_vars = {},
		link_panel = nil,
		from = nil,
		to = nil,
		range = nil,
		phase = "loading",
		error = nil,
		gen = 0,
		dashboard = nil,
		vars = {},
		vars_error = nil,
		var_gen = 0,
		settings = { status = "loading", renderer = nil, datasources = {}, features = {} },
		user = { status = "loading" },
		cfg = DashConfig.read(env.config),
		sections = {},
		collapsed = {},
		panels = {},
		order = {},
		focus = nil,
		expanded = false,
		cursor = nil,
		pngs = {},
		png_order = {},
		png_tags = {},
		png_gen = 0,
		png_errors = {},
		png_wait = false,
		png_backoff_ms = 0,
		refresh_gen = 0,
		timer_gen = 0,
		refresh_ms = nil,
		auto = true,
		picker = nil,
		search = { gen = 0, status = "ready", hits = {} },
		updated_ms = nil,
		labels = {},
		card_ids = {},
		memo = {},
		exemplar = nil,
		ex_anchor = nil,
		exemplars_on = queryOptions.exemplars,
		trace_label = queryOptions.exemplar_trace_label,
		sync = Shared.new("dashboard", env.now_ms, false),
		live_gen = 0,
		live_ms = nil,
		live_tick = 0,
	}
end

-- Tags --------------------------------------------------------------------------

local function tag(...: any): string
	local parts = { ... }
	for i, p in parts do
		parts[i] = tostring(p)
	end
	return table.concat(parts, "/")
end

local function http(t: string, route: Route, request: any): Effect
	return { kind = "http", tag = t, route = route, request = request }
end

-- Range ----------------------------------------------------------------------------

local function resolveRange(s: State, env: Env)
	local r = Range.resolve(s.from or "now-6h", s.to or "now", { now_ms = env.now_ms })
	if r then
		s.range = r
	end
end

local function rangeCtx(s: State): Variables.ScopeContext?
	local r = s.range
	return if r then { from_ms = r.from_ms, to_ms = r.to_ms } else nil
end

-- Routes -------------------------------------------------------------------------

-- Grafana's datasource proxy for one datasource uid (variable queries).
local function datasourceRoute(base: Route, uid: string): Route
	return {
		context = base.context,
		signal = "metrics",
		via = "datasource",
		endpoint_name = base.endpoint_name,
		endpoint = base.endpoint,
		datasource_uid = uid,
	}
end

function M.browserBase(s: State): string?
	local route = s.route
	if route == nil then
		return nil
	end
	local e = route.endpoint
	return (string.gsub(e.browser_url or (e.url .. e.path_prefix), "/+$", ""))
end

local function orgId(s: State): number?
	local o = tonumber(s.org or "")
	if o then
		return o
	end
	return if s.route then s.route.endpoint.org_id else nil
end

-- Variables ------------------------------------------------------------------------

local function scopeOf(s: State): Interpolate.Scope
	return Variables.scope(s.vars, rangeCtx(s))
end

local function defaultDsUid(s: State): string?
	for _, ds in s.settings.datasources do
		if ds.is_default then
			return ds.uid
		end
	end
	return nil
end

local function builtinScope(s: State): Interpolate.Scope
	local r = s.range or { from_ms = 0, to_ms = 0 }
	local d = s.dashboard
	return Interpolate.builtins({
		from_ms = r.from_ms,
		to_ms = r.to_ms,
		dashboard_title = if d then d.title else nil,
		dashboard_uid = if d then d.uid else nil,
		org_id = orgId(s),
		user_login = s.user.login,
	})
end

-- Resolves datasource variables and starts every query variable whose
-- references have settled. Datasource variables need the frontend settings.
local function advanceVariables(s: State, env: Env, effects: { Effect })
	local route = s.route
	if route == nil then
		return
	end
	local progressed = true
	while progressed do
		progressed = false
		local scope = scopeOf(s)
		for _, v in Variables.ready(s.vars) do
			if v.kind == "datasource" then
				if s.settings.status == "loading" then
					continue
				end
				local options, err = Variables.datasourceOptions(v, s.settings.datasources, scope)
				if err then
					Variables.setError(v, err)
				else
					Variables.setOptions(v, options)
					Variables.normalizeDatasource(v)
				end
				progressed = true
				break
			end
			local fetch, err = Variables.fetchFor(v, scope, builtinScope(s))
			local uid = Variables.datasourceUid(v, scope) or defaultDsUid(s)
			if fetch == nil then
				Variables.setError(v, err or "unsupported variable query")
				progressed = true
				break
			end
			if uid == nil then
				if s.settings.status == "loading" then
					continue
				end
				Variables.setError(v, "no datasource for this variable")
				progressed = true
				break
			end
			s.var_gen += 1
			v.status = "loading"
			local r = s.range or { from_ms = env.now_ms - 3600000, to_ms = env.now_ms }
			table.insert(
				effects,
				http(
					tag("var", s.gen, s.var_gen, v.name),
					route,
					Variables.request(fetch, datasourceRoute(route, uid), r)
				)
			)
		end
	end
end

-- Panels -----------------------------------------------------------------------------

local function panelState(s: State, key: string): PanelState
	local ps = s.panels[key]
	if ps == nil then
		ps = {
			status = "idle",
			decision = { mode = "native" },
			gen = 0,
			req_gen = 0,
			req_tags = {},
			extra_gen = 0,
		}
		s.panels[key] = ps
	end
	return ps :: PanelState
end

function M.panelScope(s: State, inst: Repeat.Instance): Interpolate.Scope
	local scope = scopeOf(s)
	if next(inst.scoped) ~= nil then
		scope = Interpolate.merge(scope, inst.scoped)
	end
	return scope
end

function M.ladderContext(s: State, scope: Interpolate.Scope): Ladder.Context
	return {
		supports = Registry.supports,
		renderer_available = if s.settings.status == "loading" then nil else s.settings.renderer == true,
		scope = scope,
		datasources = s.settings.datasources,
	}
end

-- `var-` values for Grafana URLs of one panel instance: the dashboard's
-- selection with the instance's repeat values.
function M.instanceVars(s: State, inst: Repeat.Instance?): { [string]: { string } }
	local vars = Variables.urlValues(s.vars)
	if inst then
		for name, v in inst.scoped do
			vars[name] = Tbl.copy(v.values)
		end
	end
	return vars
end

function M.pngSpec(s: State, inst: Repeat.Instance): RenderPng.Spec?
	local d = s.dashboard
	if d == nil then
		return nil
	end
	local w, h = RenderPng.size(if s.solo or s.expanded then 24 else inst.panel.grid.w, inst.panel.grid.h)
	return {
		uid = d.uid,
		slug = d.slug,
		panel_id = inst.panel.id,
		org_id = orgId(s),
		from = s.from or d.time.from,
		to = s.to or d.time.to,
		width = w,
		height = h,
		tz = RenderPng.tz(d.timezone),
		theme = s.cfg.render_theme,
		vars = M.instanceVars(s, inst),
	}
end

local function pngKey(s: State, spec: RenderPng.Spec): string
	return RenderPng.cacheKey(spec) .. "\31" .. s.refresh_gen
end

local function rememberPng(s: State, key: string, bytes: string)
	if s.pngs[key] == nil then
		table.insert(s.png_order, key)
	end
	s.pngs[key] = bytes
	while #s.png_order > M.PNG_CACHE do
		local old = table.remove(s.png_order, 1) :: string
		s.pngs[old] = nil
	end
end

-- `range`: the panel's own range (panel_time), else the dashboard's.
local function queryContext(s: State, scope: Interpolate.Scope, env: Env, range: Range.Range?): Queries.Context
	local r = range or s.range or { from_ms = env.now_ms - 3600000, to_ms = env.now_ms }
	local d = s.dashboard
	return {
		scope = scope,
		from_ms = r.from_ms,
		to_ms = r.to_ms,
		max_points = s.cfg.max_points,
		datasources = s.settings.datasources,
		dashboard_uid = if d then d.uid else nil,
		dashboard_title = if d then d.title else nil,
		org_id = orgId(s),
		user_login = s.user.login,
		exemplars = s.exemplars_on,
	}
end

-- The panel's time range after its timeFrom/timeShift.
function M.panelTime(s: State, inst: Repeat.Instance, env: Env): PanelTime.Override
	local d = s.dashboard
	local r = s.range or { from_ms = env.now_ms - 3600000, to_ms = env.now_ms }
	local parent: PanelTime.Parent = {
		from = s.from or (if d then d.time.from else "now-6h"),
		to = s.to or (if d then d.time.to else "now"),
		range = r,
	}
	local scope = M.panelScope(s, inst)
	return PanelTime.apply(inst.panel.json, parent, { now_ms = env.now_ms }, function(text: string): string
		return Interpolate.replace(text, scope, { format = Interpolate.text })
	end)
end

M.EXTERNAL_TIMEOUT_MS = 10000

-- Where a module request goes: dashboards, annotations and alerts to the
-- dashboard's Grafana API (Grafana's own panels read it there); external
-- to the absolute URL in request.path, without credentials.
local function requestRoute(s: State, signal: string, request: any): (Route?, any)
	local base = s.route
	if base == nil then
		return nil, request
	end
	if signal == "external" then
		local origin, rest = string.match(request.path or "", "^(https?://[^/?#]+)(.*)$")
		if origin == nil then
			return nil, request
		end
		local r = Tbl.copy(request)
		r.path = if rest == "" then "/" else rest
		return {
			context = base.context,
			signal = "dashboards",
			via = "direct",
			endpoint_name = "grafana",
			endpoint = {
				url = origin :: string,
				auth = { type = "none" },
				headers = {},
				path_prefix = "",
				timeout_ms = M.EXTERNAL_TIMEOUT_MS,
			},
		},
			r
	end
	if signal ~= "dashboards" and signal ~= "annotations" and signal ~= "alerts" then
		return nil, request
	end
	return {
		context = base.context,
		signal = signal :: any,
		via = "grafana",
		endpoint_name = "grafana",
		endpoint = base.endpoint,
	},
		request
end

-- Sends the module's requests when they changed (or on refresh).
local function advanceRequests(
	s: State,
	inst: Repeat.Instance,
	ps: PanelState,
	env: Env,
	force: boolean,
	effects: { Effect }
)
	local d = s.dashboard :: Model.Dashboard
	local range = (ps.time :: PanelTime.Override).range
	local list = Registry.requests(inst.panel.json, {
		time = { from_ms = range.from_ms, to_ms = range.to_ms },
		dashboard_uid = d.uid,
		datasources = if s.settings.status == "loading" then nil else s.settings.datasources,
	}, env)
	if #list == 0 then
		ps.extra, ps.extra_sig = nil, nil
		return
	end
	local sig = env.encode(list)
	if not force and sig == ps.extra_sig then
		return
	end
	ps.extra_sig = sig
	ps.req_gen += 1
	ps.req_tags = {}
	ps.extra = ps.extra or {}
	for i, r in list do
		ps.req_tags[i] = r.tag
		local route, request = requestRoute(s, r.signal, r.request)
		if route == nil then
			(ps.extra :: any)[r.tag] = { error = "cannot send a " .. tostring(r.signal) .. " request" }
			continue
		end
		table.insert(effects, http(tag("x", s.gen, ps.req_gen, i, inst.key), route :: Route, request))
	end
end

M.LIVE_MIN_MS = 250

-- Arms the shared live timer at the smallest period of the live panels
-- shown (the expanded or pinned panel alone when one is); a changed period
-- re-arms, an unchanged one keeps the pending tick.
local function armLive(s: State, env: Env, effects: { Effect })
	local keys: { string } = if (s.solo or s.expanded) and s.focus then { s.focus :: string } else s.order
	local period: number? = nil
	for _, key in keys do
		local ps = s.panels[key]
		local ms = if ps and ps.decision.mode == "native" then ps.live_ms else nil
		if ms then
			period = math.max(M.LIVE_MIN_MS, if period then math.min(period, ms) else ms)
		end
	end
	if period == s.live_ms then
		return
	end
	s.live_gen += 1
	s.live_ms = period
	if period then
		local p = period :: number
		-- On the period's boundary, so a seconds clock flips on the second.
		table.insert(effects, { kind = "timer", tag = tag("live", s.gen, s.live_gen), ms = p - env.now_ms % p })
	end
end

-- Recomputes the visible panels and issues the queries and renders they
-- need. `force` re-sends unchanged queries (refresh).
local function advancePanels(s: State, env: Env, force: boolean, effects: { Effect })
	local d = s.dashboard
	local route = s.route
	if
		d == nil
		or route == nil
		or s.settings.status == "loading"
		or s.user.status == "loading"
		or not Variables.settled(s.vars)
	then
		return
	end
	for _, uid in Model.libraryRefs(d) do
		if uid then
			-- Library panels still loading: wait for them.
			return
		end
	end
	s.sections = Repeat.expand(d, s.vars)
	local order: { string } = {}
	local visible: { Repeat.Instance } = {}
	for _, sec in s.sections do
		local collapsed = s.collapsed[sec.key]
		if collapsed == nil then
			collapsed = sec.row ~= nil and sec.row.collapsed
		end
		local items: { Layout.Item } = {}
		local byKey: { [string]: Repeat.Instance } = {}
		for _, inst in sec.panels do
			if s.solo then
				if inst.panel.id == s.solo and #visible == 0 then
					table.insert(visible, inst)
					table.insert(order, inst.key)
				end
			elseif not collapsed then
				table.insert(items, { key = inst.key, grid = inst.panel.grid })
				byKey[inst.key] = inst
			end
		end
		if not s.solo then
			for _, key in Layout.order(Layout.arrange(items)) do
				table.insert(order, key)
				table.insert(visible, byKey[key])
			end
		end
	end
	s.order = order
	if s.focus == nil or table.find(order, s.focus) == nil then
		s.focus = order[1]
		s.cursor = nil
	end
	for _, inst in visible do
		local ps = panelState(s, inst.key)
		local scope = M.panelScope(s, inst)
		ps.decision = Ladder.decide(inst.panel, M.ladderContext(s, scope), env)
		-- Every rung shows the time override info in its header.
		local pt = M.panelTime(s, inst, env)
		ps.time = pt
		if ps.decision.mode == "native" then
			ps.png = nil
			ps.live_ms = Registry.liveMs(inst.panel.json, env)
			advanceRequests(s, inst, ps, env, force, effects)
			local pq, err = nil, nil
			local qctx = queryContext(s, scope, env, pt.range)
			if Registry.queries(inst.panel.json, env) then
				pq, err = Queries.build(inst.panel.json, qctx, env)
			end
			if pq == nil then
				if err then
					ps.status, ps.error = "error", err
				elseif ps.status ~= "ready" or ps.data == nil or #(ps.data :: Queries.PanelData).frames > 0 then
					-- Nothing to query: keep one empty answer (the view memo
					-- keys on its identity).
					ps.status, ps.data, ps.error = "ready", { frames = {}, errors = {}, warnings = {} }, nil
				end
				continue
			end
			local signature = env.encode(pq.queries) .. "\31" .. pt.from .. "\31" .. pt.to
			if force or signature ~= ps.signature then
				ps.signature = signature
				ps.gen += 1
				ps.status = "loading"
				table.insert(
					effects,
					http(tag("q", s.gen, ps.gen, inst.key), route, Queries.request(route, pq, qctx, env))
				)
			end
		elseif ps.decision.mode == "png" then
			local spec = M.pngSpec(s, inst)
			if spec == nil then
				continue
			end
			local key = pngKey(s, spec)
			ps.png_want = key
			-- One render at a time: Grafana's renderer answers 429 to bursts,
			-- and each render takes seconds of its CPU.
			if s.pngs[key] == nil and s.png_errors[key] == nil and next(s.png_tags) == nil and not s.png_wait then
				s.png_gen += 1
				local t = tag("png", s.gen, s.png_gen)
				s.png_tags[t] = key
				table.insert(effects, http(t, route, RenderPng.request(spec)))
			end
			-- Keep showing the previous picture until the new one arrives.
			if s.pngs[key] or ps.png == nil or s.pngs[ps.png :: string] == nil then
				ps.png = key
			end
		end
	end
	armLive(s, env, effects)
end

local function advance(s: State, env: Env, force: boolean, effects: { Effect })
	if s.phase ~= "ready" then
		return
	end
	if s.user.status == "loading" then
		-- `${__user.login}` may appear in any query.
		return
	end
	advanceVariables(s, env, effects)
	advancePanels(s, env, force, effects)
end

-- Loading -----------------------------------------------------------------------------

local function armRefresh(s: State, effects: { Effect })
	s.timer_gen += 1
	local ms = s.refresh_ms
	if ms and s.auto then
		table.insert(effects, { kind = "timer", tag = tag("refresh", s.gen, s.timer_gen), ms = ms })
	end
end

local function startLoad(s: State, effects: { Effect })
	local route = s.route
	local uid = s.uid
	if route == nil or uid == nil then
		return
	end
	s.gen += 1
	s.phase = "loading"
	s.error = nil
	s.dashboard = nil
	s.vars = {}
	s.panels = {}
	s.memo = {}
	s.sections = {}
	s.order = {}
	s.png_tags = {}
	s.png_errors = {}
	s.png_wait = false
	s.live_gen += 1
	s.live_ms = nil
	table.insert(effects, http(tag("dash", s.gen), route, Model.request(uid)))
	if s.settings.status ~= "ready" then
		s.settings = { status = "loading", renderer = nil, datasources = {}, features = {} }
		table.insert(effects, http(tag("fs", s.gen), route, GrafanaSource.frontendSettingsRequest(route)))
	end
	if s.user.status ~= "ready" then
		s.user = { status = "loading" }
		table.insert(effects, http(tag("user", s.gen), route, GrafanaSource.userRequest(route)))
	end
end

local function startSearch(s: State, query: string, effects: { Effect })
	local route = s.route
	if route == nil then
		return
	end
	s.search.gen += 1
	s.search.status = "loading"
	table.insert(effects, http(tag("search", s.search.gen), route, Search.request(query)))
end

local function setError(s: State, message: string)
	s.phase = "error"
	s.error = message
end

local function onDashboard(s: State, response: any, env: Env, effects: { Effect })
	local d, err = Model.parseResponse(response, env)
	if d == nil then
		setError(s, err or "the dashboard could not be loaded")
		return
	end
	s.dashboard = d
	s.phase = "ready"
	if s.from == nil or s.to == nil then
		s.from, s.to = d.time.from, d.time.to
	end
	resolveRange(s, env)
	local vars, verr = Variables.fromModel(d.templating, env)
	s.vars = vars
	s.vars_error = verr
	Variables.applyUrl(s.vars, s.link_vars)
	s.refresh_ms = DashConfig.refreshMs(d.refresh, s.cfg)
	if s.link_panel and not s.solo then
		for _, sec in d.sections do
			for _, p in sec.panels do
				if p.id == s.link_panel then
					s.expanded = true
				end
			end
		end
	end
	local route = s.route :: Route
	for _, uid in Model.libraryRefs(d) do
		table.insert(effects, http(tag("lib", s.gen, uid), route, Model.libraryRequest(uid)))
	end
	s.updated_ms = env.now_ms
	armRefresh(s, effects)
	advance(s, env, false, effects)
	if s.link_panel then
		for _, key in s.order do
			local inst = Repeat.find(s.sections, key)
			if inst and inst.panel.id == s.link_panel then
				s.focus = key
				break
			end
		end
	end
end

local function onSettings(s: State, response: any, env: Env, effects: { Effect })
	local route = s.route :: Route
	local r = GrafanaSource.parseFrontendSettings(route, response, env)
	if r.ok then
		s.settings = {
			status = "ready",
			renderer = (r :: any).settings.renderer_available == true,
			datasources = Queries.frontendDatasources(response, env),
			features = Queries.frontendFeatures(response, env),
		}
	else
		s.settings = {
			status = "error",
			renderer = false,
			datasources = {},
			features = {},
			error = (r :: any).error.message,
		}
	end
	advance(s, env, false, effects)
end

local function onUser(s: State, response: any, env: Env, effects: { Effect })
	local r = GrafanaSource.parseUser(s.route :: Route, response, env)
	s.user = if r.ok then { status = "ready", login = (r :: any).user.login } else { status = "error" }
	advance(s, env, false, effects)
end

local function onLibrary(s: State, uid: string, response: any, env: Env, effects: { Effect })
	local d = s.dashboard
	if d == nil then
		return
	end
	local model = Model.parseLibrary(response, env)
	Model.applyLibrary(d, uid, model, env)
	advance(s, env, false, effects)
end

local function onVariable(s: State, name: string, response: any, env: Env, effects: { Effect })
	local v = Variables.find(s.vars, name)
	local route = s.route
	if v == nil or route == nil or v.status ~= "loading" then
		return
	end
	local scope = scopeOf(s)
	local fetch = Variables.fetchFor(v, scope, builtinScope(s))
	local uid = Variables.datasourceUid(v, scope) or defaultDsUid(s)
	if fetch == nil or uid == nil then
		Variables.setError(v, "variable query changed while loading")
	else
		local values, err = Variables.parseFetch(fetch, datasourceRoute(route, uid), response, env)
		if values == nil then
			Variables.setError(v, err or "no values")
		else
			local options, rerr = Variables.optionsFrom(v, values, scope)
			if rerr then
				Variables.setError(v, rerr)
			else
				Variables.setOptions(v, options)
			end
		end
	end
	advance(s, env, false, effects)
end

local function onQuery(s: State, key: string, response: any, env: Env)
	local ps = s.panels[key]
	if ps == nil then
		return
	end
	local inst = Repeat.find(s.sections, key)
	if inst == nil then
		return
	end
	local scope = M.panelScope(s, inst)
	local range = if ps.time then (ps.time :: PanelTime.Override).range else nil
	local pq = Queries.build(inst.panel.json, queryContext(s, scope, env, range), env)
	if pq == nil then
		return
	end
	local data, err = Queries.parse(response, pq, env)
	if data == nil then
		ps.status, ps.error = "error", err
		return
	end
	ps.data = data
	if key == s.focus then
		-- The selection indexes the old answer's exemplars.
		s.exemplar, s.ex_anchor = nil, nil
	end
	ps.error = nil
	ps.status = if #data.frames == 0 and #data.errors > 0 then "error" else "ready"
	if ps.status == "error" then
		ps.error = table.concat(data.errors, "; ")
	end
	s.updated_ms = env.now_ms
end

-- A module request's answer: tag x/<gen>/<req_gen>/<index>/<panel key>.
local function onExtra(s: State, parts: { string }, response: any, env: Env)
	local key = table.concat(parts, "/", 5)
	local ps = s.panels[key]
	local inst = Repeat.find(s.sections, key)
	if ps == nil or inst == nil or tonumber(parts[3] or "") ~= ps.req_gen then
		return
	end
	local name = ps.req_tags[tonumber(parts[4] or "") or 0]
	if name == nil then
		return
	end
	ps.extra = ps.extra or {}
	(ps.extra :: any)[name] = Registry.parse(inst.panel.json, name, response, env)
	ps.extra_gen += 1
	s.updated_ms = env.now_ms
end

M.PNG_BACKOFF_MS = 5000
M.PNG_BACKOFF_MAX_MS = 60000

local function onPng(s: State, t: string, response: any, env: Env, effects: { Effect })
	local key = s.png_tags[t]
	if key == nil then
		return
	end
	s.png_tags[t] = nil
	local status = response.status
	if status == 200 and response.failure == nil and string.sub(response.body or "", 2, 4) == "PNG" then
		rememberPng(s, key, response.body)
		s.png_backoff_ms = 0
	elseif status == 429 or status == 503 or response.timed_out then
		-- The renderer is busy: try again later, backing off.
		s.png_backoff_ms = math.min(M.PNG_BACKOFF_MAX_MS, math.max(M.PNG_BACKOFF_MS, s.png_backoff_ms * 2))
		s.png_wait = true
		table.insert(effects, { kind = "timer", tag = tag("pngretry", s.gen, s.png_gen), ms = s.png_backoff_ms })
	else
		local why = if response.failure then response.failure.message else "HTTP " .. tostring(status)
		s.png_errors[key] = "render failed (" .. why .. ")"
	end
	advance(s, env, false, effects)
end

-- Why the panel's wanted render failed, if it did.
function M.pngError(s: State, ps: PanelState): string?
	return if ps.png_want then s.png_errors[ps.png_want :: string] else nil
end

-- Links --------------------------------------------------------------------------------

-- The link this block shows now: canonical, secret-free, and what `save` keeps.
function M.link(s: State): Scheme.Link?
	if s.uid == nil then
		return nil
	end
	local params: { [string]: string } = { uid = s.uid :: string }
	if s.context then
		params.context = s.context :: string
	end
	if s.org then
		params.org = s.org :: string
	end
	if s.from and s.to then
		params.from, params.to = s.from :: string, s.to :: string
	end
	local vars = if s.dashboard then Variables.urlValues(s.vars) else s.link_vars
	if s.solo then
		params.panel = tostring(s.solo)
		return { action = "panel", params = params, vars = vars }
	end
	local inst = if s.expanded and s.focus then Repeat.find(s.sections, s.focus) else nil
	if inst then
		params.panel = tostring(inst.panel.id)
	end
	return { action = "dashboard", params = params, vars = vars }
end

local function validLink(l: Scheme.Link): string?
	local ok = Scheme.validate(l)
	return if ok then Scheme.encode(ok) else nil
end

-- Grafana's page for the dashboard (or the expanded panel) under the browser URL.
function M.grafanaUrl(s: State, env: Env): string?
	local base = M.browserBase(s)
	local l = M.link(s)
	if base == nil or l == nil then
		return nil
	end
	local page = Tbl.copy(l)
	page.action = "dashboard"
	return GrafanaUrl.build(page, base, env.encode)
end

local function browse(url: string): Effect
	return {
		kind = "open",
		target = Scheme.encode({ action = "browse", params = { url = url }, vars = {} }),
	}
end

-- The focused panel's solo page in the browser pane.
local function openPanelInBrowser(s: State, key: string?, effects: { Effect })
	local base = M.browserBase(s)
	local inst = if key then Repeat.find(s.sections, key) else nil
	if base == nil or inst == nil then
		return
	end
	local spec = M.pngSpec(s, inst)
	if spec == nil then
		return
	end
	spec.width, spec.height, spec.theme = nil, nil, nil
	table.insert(effects, browse(RenderPng.soloUrl(base, spec)))
end

export type PanelLink = { title: string, url: string }

-- The panel's links (panel.links) with variables, the time builtins and
-- `${__url_time_range}` interpolated; a path-only URL is on Grafana.
function M.panelLinks(s: State, inst: Repeat.Instance, env: Env): { PanelLink }
	local out: { PanelLink } = {}
	local links = Env.value(env, inst.panel.json.links)
	if type(links) ~= "table" then
		return out
	end
	local scope = Interpolate.merge(builtinScope(s), M.panelScope(s, inst))
	scope = Interpolate.merge(scope, {
		__url_time_range = Interpolate.value(
			"from=" .. Http.escape(s.from or "now-6h") .. "&to=" .. Http.escape(s.to or "now")
		),
	})
	local base = M.browserBase(s)
	for _, l in links do
		local url = if type(l) == "table" and type(l.url) == "string" then l.url else nil
		if url == nil or url == "" then
			continue
		end
		local u = Interpolate.replace(url :: string, scope, { format = Interpolate.text })
		if string.sub(u, 1, 1) == "/" and base then
			u = base .. u
		end
		local t = if type(l.title) == "string" and l.title ~= "" then l.title else u
		table.insert(out, { title = Interpolate.replace(t, scope, { format = Interpolate.text }), url = u })
	end
	return out
end

-- Opens panel link `<index>:<panel key>` in the browser pane.
local function openPanelLink(s: State, value: string, env: Env, effects: { Effect })
	local idx, key = string.match(value, "^(%d+):(.+)$")
	local inst = if key then Repeat.find(s.sections, key) else nil
	if inst == nil then
		return
	end
	local link = M.panelLinks(s, inst, env)[tonumber(idx) :: number]
	if link and string.match(link.url, "^https?://") then
		table.insert(effects, browse(link.url))
	end
end

-- Opens the focused panel as its own panel block.
local function pin(s: State, effects: { Effect })
	local inst = if s.focus then Repeat.find(s.sections, s.focus) else nil
	if inst == nil or s.uid == nil then
		return
	end
	local params: { [string]: string } = { uid = s.uid :: string, panel = tostring(inst.panel.id) }
	if s.context then
		params.context = s.context :: string
	end
	if s.org then
		params.org = s.org :: string
	end
	if s.from and s.to then
		params.from, params.to = s.from :: string, s.to :: string
	end
	local target = validLink({ action = "panel", params = params, vars = M.instanceVars(s, inst) })
	if target then
		table.insert(effects, { kind = "open", target = target })
	end
end

-- Init --------------------------------------------------------------------------------

local function applyLink(s: State, l: Scheme.Link)
	local p = l.params
	s.context = p.context
	s.uid = p.uid
	s.org = p.org
	s.from, s.to = p.from, p.to
	if s.from == nil or s.to == nil then
		s.from, s.to = nil, nil
	end
	s.link_vars = l.vars
	s.link_panel = tonumber(p.panel or "")
end

local function routeFor(s: State, env: Env): string?
	local cfg = env.config
	if cfg == nil then
		return "no valid config: open Grafana settings (tern-grafana://settings) or see docs/configuration.md"
	end
	local route, err = Route.route(cfg, s.context, "dashboards")
	if route == nil then
		return if err then err.message else "no Grafana endpoint"
	end
	s.route = route
	s.context = s.context or route.context
	return nil
end

-- `solo`: the panel block's panel id requirement (link action `panel`).
function M.initWith(args: { string }, saved: any, env: Env, solo: boolean): (State, { Effect })
	local s = newState(env)
	local effects: { Effect } = {}
	if type(saved) == "table" and saved.sync == true then
		s.sync.on = true
		-- The first poll adopts what the other blocks share.
		table.insert(effects, Shared.timer(s.sync))
	end
	local raw = if type(saved) == "table" and type(saved.link) == "string" then saved.link else args[1]
	if raw and raw ~= "" then
		local l, err = Scheme.decode(raw)
		if l == nil then
			setError(s, "invalid link: " .. (if err then err.message else "unknown error"))
			return s, effects
		end
		applyLink(s, l)
		if solo then
			s.solo = s.link_panel
		end
	end
	if solo and s.solo == nil then
		setError(s, "a panel block needs a tern-grafana://panel link with uid and panel")
		return s, effects
	end
	local routeErr = routeFor(s, env)
	if routeErr then
		setError(s, routeErr)
		return s, effects
	end
	if s.uid == nil then
		s.phase = "search"
		s.picker = { kind = "search", query = "" }
		startSearch(s, "", effects)
		return s, effects
	end
	startLoad(s, effects)
	return s, effects
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	return M.initWith(args, saved, env, false)
end

-- Refresh, range, variables -------------------------------------------------------------

local function refresh(s: State, env: Env, effects: { Effect })
	if s.phase ~= "ready" then
		return
	end
	s.refresh_gen += 1
	resolveRange(s, env)
	Variables.onTimeRange(s.vars)
	advance(s, env, true, effects)
end

-- Publishes the range and cursor when sync is on.
local function share(s: State, env: Env, effects: { Effect })
	local d = s.dashboard
	local from = s.from or (if d then d.time.from else nil)
	local to = s.to or (if d then d.time.to else nil)
	if from == nil or to == nil then
		return
	end
	local e = Shared.share(s.sync, { from = from :: string, to = to :: string }, s.cursor, env)
	if e then
		table.insert(effects, e)
	end
end

local function setRange(s: State, from: string, to: string, env: Env, effects: { Effect })
	s.from, s.to = from, to
	s.cursor = nil
	s.exemplar, s.ex_anchor = nil, nil
	refresh(s, env, effects)
	share(s, env, effects)
end

-- Applies a range and cursor another synced block shared: panels re-query
-- only when the range changed.
local function adoptShared(s: State, env: Env, r: Shared.Range, cursor: number?, effects: { Effect })
	if r.from ~= s.from or r.to ~= s.to then
		s.from, s.to = r.from, r.to
		s.exemplar, s.ex_anchor = nil, nil
		refresh(s, env, effects)
	end
	if cursor ~= s.cursor then
		s.cursor = cursor
		s.exemplar, s.ex_anchor = nil, nil
	end
end

local function toggleSync(s: State, env: Env, effects: { Effect })
	local t = Shared.toggle(s.sync)
	if t == nil then
		return
	end
	table.insert(effects, t)
	local d = s.dashboard
	local from = s.from or (if d then d.time.from else "now-6h")
	local to = s.to or (if d then d.time.to else "now")
	local r, cursor, e = Shared.join(s.sync, { from = from, to = to }, s.cursor, env)
	if r then
		adoptShared(s, env, r, cursor, effects)
	end
	if e then
		table.insert(effects, e)
	end
end

local function selectVariable(s: State, name: string, values: { string }, env: Env, effects: { Effect })
	local v = Variables.find(s.vars, name)
	if v == nil then
		return
	end
	Variables.select(v, values)
	Variables.invalidate(s.vars, Variables.dependents(s.vars, { name }))
	advance(s, env, false, effects)
end

-- Pickers ---------------------------------------------------------------------------------

export type PickerItem = { id: string, label: string, detail: string? }

local function matches(text: string, query: string): boolean
	return query == "" or string.find(string.lower(text), string.lower(query), 1, true) ~= nil
end

-- What the open picker lists, filtered by its query.
function M.pickerItems(s: State): { PickerItem }
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

local function openVarPicker(s: State, name: string)
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
	startLoad(s, effects)
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
local function pick(s: State, id: string, env: Env, effects: { Effect })
	local p = s.picker
	if p == nil then
		return
	end
	if p.kind == "search" then
		openDashboard(s, id, effects)
	elseif p.kind == "vars" then
		openVarPicker(s, id)
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
		selectVariable(s, v.name, { id }, env, effects)
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
		selectVariable(s, p.name or "", chosen, env, effects)
	end
end

local function moveSelection(s: State, delta: number)
	local p = s.picker
	if p == nil then
		return
	end
	local items = M.pickerItems(s)
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

local function pickerKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
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
		local items = M.pickerItems(s)
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
			pick(s, id, env, effects)
		end
		return true
	elseif name == "space" and p.kind == "var" and p.chosen then
		local id = p.selected or (M.pickerItems(s)[1] or {} :: any).id
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
		startSearch(s, p.query, effects)
	end
	return true
end

-- Keys ----------------------------------------------------------------------------------

local DIRS: { [string]: Layout.Direction } = {
	left = "left",
	right = "right",
	up = "up",
	down = "down",
}

local function items(s: State): { Layout.Item }
	local out: { Layout.Item } = {}
	for _, key in s.order do
		local inst = Repeat.find(s.sections, key)
		if inst then
			table.insert(out, { key = key, grid = inst.panel.grid })
		end
	end
	return out
end

-- Every sample time of the focused panel's frames, sorted.
local function sampleTimes(s: State): { number }
	local ps = if s.focus then s.panels[s.focus] else nil
	local out: { number } = {}
	if ps == nil or ps.data == nil then
		return out
	end
	local seen: { [number]: boolean } = {}
	for _, f in (ps.data :: Queries.PanelData).frames do
		for _, field in f.fields do
			if field.type == "time" then
				for _, t in field.values do
					if type(t) == "number" and not seen[t] then
						seen[t] = true
						table.insert(out, t)
					end
				end
			end
		end
	end
	table.sort(out)
	return out
end

local function moveCursor(s: State, dir: number, big: boolean): boolean
	local times = sampleTimes(s)
	if #times == 0 then
		return false
	end
	local idx = #times
	if s.cursor then
		for i, t in times do
			if t >= (s.cursor :: number) then
				idx = i
				break
			end
		end
		idx = math.clamp(idx + dir * (if big then 10 else 1), 1, #times)
	end
	s.cursor = times[idx]
	s.exemplar, s.ex_anchor = nil, nil
	return true
end

local function toggleRowOfFocus(s: State)
	local _, sec = Repeat.find(s.sections, s.focus or "")
	if sec and sec.row then
		s.collapsed[sec.key] = true
		s.focus = nil
	end
end

-- Flips label display of the focused logs panel, starting from the panel's
-- own `options.showLabels`.
local function toggleLabels(s: State): boolean
	local inst = if s.focus then Repeat.find(s.sections, s.focus :: string) else nil
	if inst == nil or inst.panel.type ~= "logs" then
		return false
	end
	local current = s.labels[inst.key]
	if current == nil then
		local options = inst.panel.json.options
		current = type(options) == "table" and options.showLabels == true
	end
	s.labels[inst.key] = not current
	return true
end

-- Starts an Investigate preview (G4) for the focused panel with its
-- interpolated queries and the values it shows; nothing is sent before the
-- user presses Send there.
local function investigate(s: State, env: Env, effects: { Effect }): boolean
	local d = s.dashboard
	local inst = if s.focus then Repeat.find(s.sections, s.focus :: string) else nil
	if d == nil or inst == nil then
		return false
	end
	local scope = M.panelScope(s, inst)
	local fps = s.panels[inst.key]
	local range = if fps and fps.time then (fps.time :: PanelTime.Override).range else nil
	local pq = Queries.build(inst.panel.json, queryContext(s, scope, env, range), env)
	local queries: { InvestigateSubject.Query } = {}
	if pq then
		for _, q in pq.queries do
			local text = if type(q.expr) == "string" then q.expr elseif type(q.query) == "string" then q.query else nil
			if text and text ~= "" then
				local ds = if type(q.datasource) == "table" then q.datasource.type else nil
				table.insert(queries, {
					ref = if type(q.refId) == "string" then q.refId else nil,
					expr = text,
					datasource = if type(ds) == "string" then ds else nil,
				})
			end
		end
	end
	local r = s.range or { from_ms = env.now_ms - 3600000, to_ms = env.now_ms }
	local ps = s.panels[inst.key]
	local subject = InvestigateSubject.fromPanel({
		context = s.context,
		dashboard = d.title,
		uid = s.uid,
		panel_id = inst.panel.id,
		title = Interpolate.replace(inst.panel.title, scope),
		type = inst.panel.type,
		queries = queries,
		range = { from = s.from or d.time.from, to = s.to or d.time.to, from_ms = r.from_ms, to_ms = r.to_ms },
		vars = M.instanceVars(s, inst),
		frames = if ps and ps.data then (ps.data :: Queries.PanelData).frames else nil,
	}, env.config, env.encode)
	for _, e in Handoff.start(subject, env) do
		table.insert(effects, e)
	end
	return true
end

-- The exemplars the focused time series panel draws (the same list and
-- order as its chart's layout.exemplars).
function M.focusedExemplars(s: State): { FrameProm.Exemplar }
	local inst = if s.focus then Repeat.find(s.sections, s.focus :: string) else nil
	local ps = if s.focus then s.panels[s.focus :: string] else nil
	local data = if ps then ps.data else nil
	local r = s.range
	if inst == nil or inst.panel.type ~= "timeseries" or data == nil or data.exemplars == nil or r == nil then
		return {}
	end
	return (SvgTimeseries.drawnExemplars(data.exemplars :: { FrameProm.Exemplar }, r.from_ms, r.to_ms))
end

function M.selectedExemplar(s: State): FrameProm.Exemplar?
	return if s.exemplar then M.focusedExemplars(s)[s.exemplar :: number] else nil
end

-- `x` in the single-panel view: the next exemplar nearest the cursor; the
-- cursor follows it.
local function cycleExemplar(s: State, env: Env, effects: { Effect }): boolean
	local list = M.focusedExemplars(s)
	local r = s.range
	if #list == 0 or r == nil then
		local text = if s.exemplars_on then "No exemplars in this panel" else "Exemplars are off (query.exemplars)"
		table.insert(effects, { kind = "toast", level = "info", text = text })
		return true
	end
	local layout: any = { exemplars = list }
	local anchor = if s.exemplar and s.ex_anchor then s.ex_anchor else (s.cursor or r.to_ms)
	local idx = Cursor.nextExemplar(layout, anchor, s.exemplar) :: number
	s.exemplar, s.ex_anchor = idx, anchor
	s.cursor = list[idx].time_ms
	share(s, env, effects)
	return true
end

local function openTrace(s: State, effects: { Effect })
	local e = M.selectedExemplar(s)
	if e == nil then
		return
	end
	local target, err = Jumps.traceLink(s.context, e, s.trace_label)
	if target then
		table.insert(effects, { kind = "open", target = target })
	else
		table.insert(effects, { kind = "toast", level = "info", text = err or "Cannot open the trace" })
	end
end

-- `L`: logs for the focused panel's series (the selected exemplar's series
-- when one is selected, else the labels all its series share) over the
-- dashboard's range.
local function openLogs(s: State, env: Env, effects: { Effect })
	local ps = if s.focus then s.panels[s.focus :: string] else nil
	local data = if ps then ps.data else nil
	if data == nil then
		table.insert(effects, { kind = "toast", level = "info", text = "Focus a panel with data: L opens its logs" })
		return
	end
	local labels: { [string]: string }
	local e = M.selectedExemplar(s)
	if e then
		labels = Tbl.copy(e.series)
		for k, v in e.labels do
			labels[k] = labels[k] or v
		end
	else
		labels = Jumps.commonLabels((data :: Queries.PanelData).frames)
	end
	local d = s.dashboard
	local from = s.from or (if d then d.time.from else "now-6h")
	local to = s.to or (if d then d.time.to else "now")
	local target, err = Jumps.logsLink(s.context, labels, Jumps.correlateLabels(env.config), from, to)
	if target then
		table.insert(effects, { kind = "open", target = target })
	else
		table.insert(effects, { kind = "toast", level = "info", text = err or "Cannot open logs" })
	end
end

local function commandKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local name = key.name
	local ch = key.text or ""
	local singleView = s.solo ~= nil or s.expanded
	if ch == "/" and not s.solo then
		s.picker = { kind = "search", query = "" }
		startSearch(s, "", effects)
		return true
	end
	if s.phase ~= "ready" then
		if ch == "r" and s.phase == "error" and s.uid then
			startLoad(s, effects)
			return true
		end
		return false
	end
	local dir: Layout.Direction? = DIRS[name]
	if dir then
		if singleView and (dir == "left" or dir == "right") then
			local moved = moveCursor(s, if dir == "left" then -1 else 1, key.shift)
			if moved then
				share(s, env, effects)
			end
			return moved
		end
		if singleView or s.focus == nil then
			return false
		end
		local next_ = Layout.neighbor(items(s), s.focus :: string, dir :: Layout.Direction)
		if next_ then
			s.focus = next_
			return true
		end
		return false
	end
	if name == "tab" then
		if singleView or #s.order == 0 then
			return false
		end
		local idx = table.find(s.order, s.focus or "") or 0
		idx = (idx - 1 + (if key.shift then -1 else 1)) % #s.order + 1
		s.focus = s.order[idx]
		return true
	elseif (name == "enter" or name == "return") and s.exemplar and singleView then
		openTrace(s, effects)
		return true
	elseif name == "enter" and not s.solo then
		if s.focus == nil then
			return false
		end
		s.expanded = not s.expanded
		s.cursor = nil
		s.exemplar, s.ex_anchor = nil, nil
		advance(s, env, false, effects)
		return true
	elseif name == "escape" then
		if s.exemplar then
			s.exemplar, s.ex_anchor = nil, nil
			return true
		elseif s.expanded then
			s.expanded = false
			s.cursor = nil
			advance(s, env, false, effects)
			return true
		elseif s.cursor then
			s.cursor = nil
			return true
		end
		return false
	end
	if key.ctrl or key.meta then
		return false
	end
	if ch == "v" then
		if #M.pickerItemsFor(s, "vars") == 0 then
			return false
		end
		s.picker = { kind = "vars", query = "" }
		return true
	elseif ch == "r" then
		refresh(s, env, effects)
		return true
	elseif ch == "a" then
		s.auto = not s.auto
		armRefresh(s, effects)
		return true
	elseif ch == "o" then
		openPanelInBrowser(s, s.focus, effects)
		return #effects > 0
	elseif ch == "O" then
		local url = M.grafanaUrl(s, env)
		if url then
			table.insert(effects, browse(url))
		end
		return url ~= nil
	elseif ch == "y" then
		local url = M.grafanaUrl(s, env)
		if url then
			table.insert(effects, { kind = "copy", text = url })
			table.insert(effects, { kind = "toast", level = "info", text = "Copied the Grafana URL" })
		end
		return url ~= nil
	elseif ch == "I" then
		return investigate(s, env, effects)
	elseif ch == "l" then
		return toggleLabels(s)
	elseif ch == "x" and singleView then
		return cycleExemplar(s, env, effects)
	elseif ch == "L" then
		openLogs(s, env, effects)
		return true
	elseif ch == "S" then
		toggleSync(s, env, effects)
		return true
	elseif ch == "p" and not s.solo then
		pin(s, effects)
		return #effects > 0
	elseif ch == "c" and not s.solo then
		toggleRowOfFocus(s)
		advance(s, env, false, effects)
		return true
	elseif ch == "C" and not s.solo then
		for _, sec in s.sections do
			if sec.row then
				s.collapsed[sec.key] = false
			end
		end
		advance(s, env, false, effects)
		return true
	elseif ch == "0" then
		local d = s.dashboard
		if d then
			setRange(s, d.time.from, d.time.to, env, effects)
			return true
		end
		return false
	end
	local from, to = TimeRange.forKey(ch, s.from or "now-6h", s.to or "now", env.now_ms)
	if from and to then
		setRange(s, from, to, env, effects)
		return true
	end
	return false
end

-- Picker items of a given kind regardless of what is open (used to know
-- whether `v` has anything to show).
function M.pickerItemsFor(s: State, kind: "vars"): { PickerItem }
	local saved = s.picker
	s.picker = { kind = kind, query = "" }
	local out = M.pickerItems(s)
	s.picker = saved
	return out
end

function M.key(s: State, key: Key, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	local before = s.focus
	local changed = if s.picker then pickerKey(s, key, env, effects) else commandKey(s, key, env, effects)
	-- Keyboard focus moved to a card that may be below the fold.
	local id = if s.focus ~= before
			and s.focus
			and not s.expanded
			and not s.solo
		then s.card_ids[s.focus :: string]
		else nil
	if id then
		table.insert(effects, { kind = "reveal", id = id, at = "start" })
	end
	return s, effects, changed or #effects > 0
end

-- Events --------------------------------------------------------------------------------

local function event(s: State, ev: UiEvent, env: Env, effects: { Effect })
	if ev.ev == "select" and type(ev.item) == "string" and s.picker then
		pick(s, ev.item, env, effects)
		return
	end
	if ev.ev ~= "action" then
		return
	end
	local act = ev.act
	local value = ev.value
	if type(act) ~= "string" or type(value) ~= "string" then
		return
	end
	if act == "focus" then
		if table.find(s.order, value) then
			s.focus = value
		end
	elseif act == "expand" then
		if table.find(s.order, value) then
			s.focus = value
			s.expanded = not s.expanded
			s.cursor = nil
			advance(s, env, false, effects)
		end
	elseif act == "row" then
		local sec: Repeat.SectionInstance? = nil
		for _, x in s.sections do
			if x.key == value then
				sec = x
			end
		end
		if sec and sec.row then
			local collapsed = s.collapsed[value]
			if collapsed == nil then
				collapsed = sec.row.collapsed
			end
			s.collapsed[value] = not collapsed
			advance(s, env, false, effects)
		end
	elseif act == "var" then
		openVarPicker(s, value)
	elseif act == "browser" then
		openPanelInBrowser(s, value, effects)
	elseif act == "plink" then
		openPanelLink(s, value, env, effects)
	elseif act == "dashboard" then
		local url = M.grafanaUrl(s, env)
		if url then
			table.insert(effects, browse(url))
		end
	elseif act == "retry" then
		if s.uid then
			startLoad(s, effects)
		end
	end
end

-- Update -----------------------------------------------------------------------------------

local function split(t: string): { string }
	local out: { string } = {}
	for part in string.gmatch(t, "[^/]+") do
		table.insert(out, part)
	end
	return out
end

function M.update(s: State, msg: Msg, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		local parts = split(msg.tag)
		local kind = parts[1]
		local gen = tonumber(parts[2] or "")
		if kind == "search" then
			if gen == s.search.gen then
				local hits, err = Search.parse(msg.response, env)
				s.search.status = if hits then "ready" else "error"
				s.search.hits = hits or {}
				s.search.error = err
			end
			return s, effects
		end
		if gen ~= s.gen then
			return s, effects
		end
		if kind == "dash" then
			onDashboard(s, msg.response, env, effects)
		elseif kind == "fs" then
			onSettings(s, msg.response, env, effects)
		elseif kind == "user" then
			onUser(s, msg.response, env, effects)
		elseif kind == "lib" then
			onLibrary(s, table.concat(parts, "/", 3), msg.response, env, effects)
		elseif kind == "var" then
			if tonumber(parts[3] or "") ~= nil then
				onVariable(s, table.concat(parts, "/", 4), msg.response, env, effects)
			end
		elseif kind == "q" then
			local key = table.concat(parts, "/", 4)
			local ps = s.panels[key]
			if ps and tonumber(parts[3] or "") == ps.gen then
				onQuery(s, key, msg.response, env)
			end
		elseif kind == "x" then
			onExtra(s, parts, msg.response, env)
		elseif kind == "png" then
			onPng(s, msg.tag, msg.response, env, effects)
		end
	elseif msg.kind == "tick" then
		if msg.tag == tag("pngretry", s.gen, s.png_gen) and s.png_wait then
			s.png_wait = false
			advance(s, env, false, effects)
			return s, effects
		end
		if Shared.isTick(s.sync, msg.tag) then
			local r, cursor = Shared.poll(s.sync, env)
			if r then
				adoptShared(s, env, r, cursor, effects)
			end
			table.insert(effects, Shared.timer(s.sync))
			return s, effects
		end
		if msg.tag == tag("live", s.gen, s.live_gen) and s.live_ms then
			-- Views redraw after every update; just keep ticking.
			s.live_tick += 1
			local p = s.live_ms :: number
			table.insert(effects, { kind = "timer", tag = msg.tag, ms = p - env.now_ms % p })
			return s, effects
		end
		if msg.tag == tag("refresh", s.gen, s.timer_gen) and s.auto then
			refresh(s, env, effects)
			armRefresh(s, effects)
		end
	elseif msg.kind == "event" then
		event(s, msg.ev, env, effects)
	elseif msg.kind == "key" then
		local _, keyEffects = M.key(s, msg.key, env)
		effects = keyEffects
	end
	return s, effects
end

-- Title and save ---------------------------------------------------------------------------

function M.title(s: State): string?
	local d = s.dashboard
	if s.solo and d then
		local p = Model.findPanel(d, s.solo :: number)
		if p and p.title ~= "" then
			return Interpolate.replace(p.title, scopeOf(s), { format = Interpolate.text })
		end
	end
	if d then
		return d.title
	end
	return if s.solo then "Grafana panel" else "Grafana dashboards"
end

function M.save(s: State): any
	local l = M.link(s)
	if l == nil then
		return nil
	end
	local encoded = validLink(l)
	if encoded == nil then
		return nil
	end
	return { link = encoded, sync = if s.sync.on then true else nil }
end

return M
