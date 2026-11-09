--!strict
-- The dashboard machine's query orchestration: variables in dependency
-- order, then every visible panel down its ladder rung (queries, module
-- requests, renders, `-- Dashboard --` sources, the live timer), and the
-- refresh, range, shared-range and variable changes that start it.

local Core = require("./core")
local Effect = require("../effect")
local Env = require("../env")
local Interpolate = require("./interpolate")
local Ladder = require("./ladder")
local Layout = require("./layout")
local Model = require("./model")
local PanelTime = require("./panel_time")
local Png = require("./png")
local Queries = require("./queries")
local Registry = require("../panels/registry")
local RenderPng = require("./render_png")
local Repeat = require("./repeat")
local Route = require("../config/route")
local Shared = require("../time/shared")
local Tbl = require("../tbl")
local Transform = require("../panels/transform")
local Types = require("./types")
local Variables = require("./variables")

type Env = Env.Env
type Effect = Effect.Effect
type Route = Route.Route
type State = Types.State
type PanelState = Types.PanelState

local tag, http = Core.tag, Core.http

local M = {}

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
		local scope = Core.scopeOf(s)
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
				Core.changed(s)
				progressed = true
				break
			end
			local fetch, err = Variables.fetchFor(v, scope, Core.builtinScope(s))
			local uid = Variables.datasourceUid(v, scope) or Core.defaultDsUid(s)
			if fetch == nil then
				Variables.setError(v, err or "unsupported variable query")
				Core.changed(s)
				progressed = true
				break
			end
			if uid == nil then
				if s.settings.status == "loading" then
					continue
				end
				Variables.setError(v, "no datasource for this variable")
				Core.changed(s)
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
					Variables.request(fetch, Core.datasourceRoute(route, uid), r)
				)
			)
		end
	end
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

-- Sends a panel's query when it changed (or `again`); `key` names the panel
-- state in the answer's tag. `resolved`: the instance's Queries.resolve memo.
local function queryPanel(
	s: State,
	inst: Repeat.Instance,
	key: string,
	ps: PanelState,
	scope: Interpolate.Scope,
	pt: PanelTime.Override,
	env: Env,
	again: boolean,
	effects: { Effect },
	resolved: Queries.Resolved?
)
	local route = s.route :: Route
	local pq, err = nil, nil
	local qctx = Core.queryContext(s, scope, env, pt.range, resolved)
	if Registry.queries(inst.panel.json, env) then
		pq, err = Queries.build(inst.panel.json, qctx, env)
	end
	if pq == nil then
		-- An answer still in flight finds no query to parse it with.
		ps.pq = nil
		if err then
			ps.status, ps.error = "error", err
		elseif ps.status ~= "ready" or ps.data == nil or #(ps.data :: Queries.PanelData).frames > 0 then
			-- Nothing to query: keep one empty answer (the view memo
			-- keys on its identity).
			ps.status, ps.data, ps.error = "ready", { frames = {}, errors = {}, warnings = {} }, nil
		end
		return
	end
	local p = pq :: Queries.PanelQuery
	local signature = env.encode(p.queries) .. "\31" .. pt.from .. "\31" .. pt.to
	-- The answer of the query in flight is parsed against the query that
	-- has this signature (the same queries and refIds).
	ps.pq = p
	if again or signature ~= ps.signature then
		ps.signature = signature
		ps.gen += 1
		ps.status = "loading"
		ps.asked = { range = pt.range, interval_ms = p.interval_ms }
		table.insert(effects, http(tag("q", s.gen, ps.gen, key), route, Queries.request(route, p, qctx, env)))
	end
end

-- Chained `-- Dashboard --` queries followed at most this deep.
local MAX_SHARED_CHAIN = 8

-- The panel state key of the source panel `id` of a `-- Dashboard --`
-- query: its own when it holds its data this round, else "=<key>", queried
-- for its consumers only (Grafana runs a source's queries even when the
-- source is off screen or not drawn natively); nil without such a panel.
local function provide(
	s: State,
	id: number,
	env: Env,
	force: boolean,
	effects: { Effect },
	held: { [string]: boolean },
	depth: number
): string?
	local inst = Core.sourceInstance(s, id)
	if inst == nil then
		return nil
	end
	if held[inst.key] then
		return inst.key
	end
	local key = "=" .. inst.key
	if held[key] then
		return key
	end
	held[key] = true
	local ps = Core.panelState(s, key)
	local dq = if Registry.queries(inst.panel.json, env) then Queries.dashboardQuery(inst.panel.json, env) else nil
	ps.source_query = dq
	if dq then
		ps.source = if depth < MAX_SHARED_CHAIN
			then provide(s, dq.panel_id, env, force, effects, held, depth + 1)
			else nil
		return key
	end
	ps.source, ps.source_data = nil, nil
	local pt = Core.panelTime(s, inst, env)
	ps.time = pt
	local again = force or ps.stale == true
	ps.stale = nil
	queryPanel(s, inst, key, ps, Core.panelScope(s, inst), pt, env, again, effects, nil)
	return key
end

-- DashboardDatasource.query: the source's series (after its datasource's
-- own processing), with its transformations when `withTransforms`.
local function sharedData(source: any, data: Queries.PanelData, withTransforms: boolean, env: Env): Queries.PanelData
	local p = source
	if not withTransforms then
		p = Tbl.copy(source)
		p.transformations = nil
	end
	return { frames = Transform.prepare(p, data.frames, env), errors = data.errors, warnings = data.warnings }
end

-- Grafana's error when the source panel is gone.
M.NO_SOURCE_PANEL = "Could not find source panel"

-- A `-- Dashboard --` panel state from its source's (sources first). The
-- frames are derived once per source answer, so the view memo holds.
local function syncSource(s: State, ps: PanelState, env: Env, depth: number)
	local dq = ps.source_query
	if dq == nil then
		return
	end
	local key = ps.source
	if key == nil then
		ps.status, ps.error, ps.source_data = "error", M.NO_SOURCE_PANEL, nil
		return
	end
	local src = s.panels[key]
	local inst = Core.find(s, Core.instanceKey(key))
	if src == nil or inst == nil then
		return
	end
	if src.source_query and depth < MAX_SHARED_CHAIN then
		syncSource(s, src, env, depth + 1)
	end
	local data = src.data
	if data ~= ps.source_data then
		ps.source_data = data
		ps.data = if data then sharedData(inst.panel.json, data, dq.with_transforms, env) else nil
	end
	ps.status, ps.error, ps.drawn = src.status, src.error, src.drawn
end

function M.syncShared(s: State, env: Env)
	for _, ps in s.panels do
		syncSource(s, ps, env, 0)
	end
end

-- After the repeats expanded anew: drops the panel states and view memos of
-- instances that no longer exist (a repeat value deselected), with the
-- data, answers and drawn nodes they hold. Collapsed rows keep theirs.
local function prune(s: State)
	for key, ps in s.panels do
		if s.index[Core.instanceKey(key)] == nil then
			-- Instance keys are positional (p3.2): a later instance under the
			-- same key starts above these gens, so their late answers stay stale.
			s.gen_floor = math.max(s.gen_floor, ps.gen, ps.req_gen)
			s.panels[key] = nil
		end
	end
	for key in s.memo do
		if s.index[key] == nil then
			s.memo[key] = nil
		end
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
	-- Repeats depend on the variables and the model only (both bump `rev`).
	if s.sections_rev ~= s.rev then
		Core.setSections(s, Repeat.expand(d, s.vars))
		s.sections_rev = s.rev
		prune(s)
	end
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
	-- The expanded view shows the focused panel alone: the others are not
	-- refreshed (no queries, renders or blobs) until they are shown again.
	local behind = s.expanded and not s.solo and s.focus ~= nil
	-- Panel states that hold their panel's data this round, and the
	-- `-- Dashboard --` panels among them.
	local held: { [string]: boolean } = {}
	local consumers: { PanelState } = {}
	local ladder = Core.ladderContext(s, Core.scopeOf(s))
	for _, inst in visible do
		local ps = Core.panelState(s, inst.key)
		if behind and inst.key ~= s.focus then
			if force then
				ps.stale = true
			end
			continue
		end
		local scope = Core.panelScope(s, inst)
		-- The ladder and the query build resolve this instance's panels once.
		local resolved: Queries.Resolved = {}
		ladder.scope, ladder.resolved = scope, resolved
		ps.decision = Ladder.decide(inst.panel, ladder, env)
		-- Every rung shows the time override info in its header.
		local pt = Core.panelTime(s, inst, env)
		ps.time = pt
		ps.source_query = nil
		if ps.decision.mode == "native" then
			ps.png = nil
			ps.live_ms = Registry.liveMs(inst.panel.json, env)
			local again = force or ps.stale == true
			ps.stale = nil
			advanceRequests(s, inst, ps, env, again, effects)
			local dq = if Registry.queries(inst.panel.json, env)
				then Queries.dashboardQuery(inst.panel.json, env)
				else nil
			ps.source_query = dq
			if dq then
				table.insert(consumers, ps)
			else
				ps.source, ps.source_data = nil, nil
				queryPanel(s, inst, inst.key, ps, scope, pt, env, again, effects, resolved)
			end
			held[inst.key] = true
		elseif ps.decision.mode == "png" then
			local spec = Core.pngSpec(s, inst)
			if spec == nil then
				continue
			end
			local key = Png.key(s, spec)
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
	for _, ps in consumers do
		local dq = ps.source_query :: Queries.DashboardQuery
		ps.source = provide(s, dq.panel_id, env, force, effects, held, 0)
	end
	M.syncShared(s, env)
	armLive(s, env, effects)
end

function M.advance(s: State, env: Env, force: boolean, effects: { Effect })
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

-- Refresh, range, variables -------------------------------------------------------------

function M.armRefresh(s: State, effects: { Effect })
	s.timer_gen += 1
	local ms = s.refresh_ms
	if ms and s.auto then
		table.insert(effects, { kind = "timer", tag = tag("refresh", s.gen, s.timer_gen), ms = ms })
	end
end

function M.refresh(s: State, env: Env, effects: { Effect })
	if s.phase ~= "ready" then
		return
	end
	s.refresh_gen += 1
	Png.forgetErrors(s)
	Core.resolveRange(s, env)
	-- Only marks variables for a refetch: their answers change the scope.
	Variables.onTimeRange(s.vars)
	M.advance(s, env, true, effects)
end

-- Publishes the range and cursor when sync is on.
function M.share(s: State, env: Env, effects: { Effect })
	local d = s.dashboard
	local from = s.from or (if d then d.time.from else nil)
	local to = s.to or (if d then d.time.to else nil)
	if from == nil or to == nil then
		return
	end
	Shared.shareInto(effects, s.sync, { from = from :: string, to = to :: string }, s.cursor, env)
end

function M.setRange(s: State, from: string, to: string, env: Env, effects: { Effect })
	s.from, s.to = from, to
	s.cursor = nil
	s.exemplar, s.ex_anchor = nil, nil
	M.refresh(s, env, effects)
	M.share(s, env, effects)
end

-- Applies a range and cursor another synced block shared: panels re-query
-- only when the range changed. False when both were this block's already.
function M.adoptShared(s: State, env: Env, r: Shared.Range, cursor: number?, effects: { Effect }): boolean
	local changed = false
	if r.from ~= s.from or r.to ~= s.to then
		s.from, s.to = r.from, r.to
		s.exemplar, s.ex_anchor = nil, nil
		M.refresh(s, env, effects)
		changed = true
	end
	if cursor ~= s.cursor then
		s.cursor = cursor
		s.exemplar, s.ex_anchor = nil, nil
		changed = true
	end
	return changed
end

function M.toggleSync(s: State, env: Env, effects: { Effect })
	local d = s.dashboard
	local from = s.from or (if d then d.time.from else "now-6h")
	local to = s.to or (if d then d.time.to else "now")
	local r, cursor = Shared.toggleInto(effects, s.sync, { from = from, to = to }, s.cursor, env)
	if r then
		M.adoptShared(s, env, r, cursor, effects)
	end
end

function M.selectVariable(s: State, name: string, values: { string }, env: Env, effects: { Effect })
	local v = Variables.find(s.vars, name)
	if v == nil then
		return
	end
	Variables.select(v, values)
	Variables.invalidate(s.vars, Variables.dependents(s.vars, { name }))
	Core.changed(s)
	M.advance(s, env, false, effects)
end

return M
