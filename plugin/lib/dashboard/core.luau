--!strict
-- Helpers every part of the dashboard machine (lib/dashboard/state.luau)
-- shares: request tags, routes, the variable scopes (built once per `rev`
-- and range, see Types.ScopeMemo), the panel instance index, panel states,
-- the panel's range and query context.

local DsTypes = require("../datasources/types")
local Effect = require("../effect")
local Env = require("../env")
local Interpolate = require("./interpolate")
local Ladder = require("./ladder")
local Model = require("./model")
local PanelTime = require("./panel_time")
local Queries = require("./queries")
local Range = require("../time/range")
local Redraw = require("../render/redraw")
local Registry = require("../panels/registry")
local RenderPng = require("./render_png")
local Repeat = require("./repeat")
local Route = require("../config/route")
local Tbl = require("../tbl")
local Types = require("./types")
local Variables = require("./variables")

type Env = Env.Env
type Effect = Effect.Effect
type Route = Route.Route
type State = Types.State
type PanelState = Types.PanelState
type ScopeMemo = Types.ScopeMemo

local M = {}

-- Tags --------------------------------------------------------------------------

function M.tag(...: any): string
	local parts = { ... }
	for i, p in parts do
		parts[i] = tostring(p)
	end
	return table.concat(parts, "/")
end

function M.http(t: string, route: Route, request: any): Effect
	return { kind = "http", tag = t, route = route, request = request }
end

-- Effects for a panel's datasource job requests (lib/datasources): tag
-- ds/<gen>/<panel gen>/<job index>/<request tag>/<panel state key>, sent to
-- the dashboard's Grafana.
function M.jobRequests(
	s: State,
	ps: PanelState,
	key: string,
	index: number,
	requests: { DsTypes.DsRequest },
	effects: { Effect }
)
	local route = s.route
	if route == nil then
		return
	end
	for _, r in requests do
		table.insert(effects, M.http(M.tag("ds", s.gen, ps.gen, index, r.tag, key), route, r.request))
	end
end

-- Effects for a query variable's datasource job requests: tag
-- dsv/<gen>/<var gen>/<request tag>/<variable name>.
function M.variableRequests(s: State, gen: number, name: string, requests: { DsTypes.DsRequest }, effects: { Effect })
	local route = s.route
	if route == nil then
		return
	end
	for _, r in requests do
		table.insert(effects, M.http(M.tag("dsv", s.gen, gen, r.tag, name), route, r.request))
	end
end

-- Shows `data` as the answer to the panel's query in flight.
function M.showData(s: State, key: string, ps: PanelState, data: Queries.PanelData, env: Env)
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
	ps.drawn = ps.asked
	s.updated_ms = env.now_ms
end

function M.setError(s: State, message: string)
	s.phase = "error"
	s.error = message
end

-- Range ----------------------------------------------------------------------------

function M.resolveRange(s: State, env: Env)
	local r = Range.resolve(s.from or "now-6h", s.to or "now", { now_ms = env.now_ms })
	if r then
		s.range = r
	end
end

-- Routes -------------------------------------------------------------------------

-- Grafana's datasource proxy for one datasource uid (variable queries).
function M.datasourceRoute(base: Route, uid: string): Route
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

function M.orgId(s: State): number?
	local o = tonumber(s.org or "")
	if o then
		return o
	end
	return if s.route then s.route.endpoint.org_id else nil
end

-- Variables ------------------------------------------------------------------------

-- Every change to the variables (selection, options, status) or to the
-- dashboard model goes through here: it drops the scope memo and makes the
-- next advance expand repeats again.
function M.changed(s: State)
	s.rev += 1
	s.scope_memo = nil
end

local WEAK_KEYS = { __mode = "k" }

local function memo(s: State): ScopeMemo
	local m = s.scope_memo
	local r = s.range
	local from_ms = if r then r.from_ms else nil
	local to_ms = if r then r.to_ms else nil
	if m and m.rev == s.rev and m.vars == s.vars and m.from_ms == from_ms and m.to_ms == to_ms then
		return m
	end
	local fresh: ScopeMemo = {
		rev = s.rev,
		vars = s.vars,
		from_ms = from_ms,
		to_ms = to_ms,
		scope = Variables.scope(s.vars, if r then { from_ms = r.from_ms, to_ms = r.to_ms } else nil),
		insts = setmetatable({}, WEAK_KEYS) :: any,
		titles = setmetatable({}, WEAK_KEYS) :: any,
		descriptions = setmetatable({}, WEAK_KEYS) :: any,
	}
	s.scope_memo = fresh
	return fresh
end

-- The memo of the current variables and range (titles and descriptions of
-- the view live there too). Callers never modify the scopes it holds.
M.memo = memo

-- Interpolation scope of every resolved variable over the dashboard range.
function M.scopeOf(s: State): Interpolate.Scope
	return memo(s).scope
end

-- Variables.signature over the dashboard range.
function M.signature(s: State): string
	local m = memo(s)
	local sig = m.signature
	if sig == nil then
		sig = Variables.signature(s.vars, s.range)
		m.signature = sig
	end
	return sig :: string
end

-- Variables.scope without a range (`$__auto_interval` reads 1m), as row
-- titles interpolate.
function M.plainScope(s: State): Interpolate.Scope
	local m = memo(s)
	local p = m.plain
	if p == nil then
		p = Variables.scope(s.vars)
		m.plain = p
	end
	return p :: Interpolate.Scope
end

function M.defaultDsUid(s: State): string?
	for _, ds in s.settings.datasources do
		if ds.is_default then
			return ds.uid
		end
	end
	return nil
end

function M.builtinScope(s: State): Interpolate.Scope
	local r = s.range or { from_ms = 0, to_ms = 0 }
	local d = s.dashboard
	return Interpolate.builtins({
		from_ms = r.from_ms,
		to_ms = r.to_ms,
		dashboard_title = if d then d.title else nil,
		dashboard_uid = if d then d.uid else nil,
		org_id = M.orgId(s),
		user_login = s.user.login,
	})
end

-- Panels -----------------------------------------------------------------------------

-- Replaces the expanded sections and rebuilds the instance index.
function M.setSections(s: State, sections: { Repeat.SectionInstance })
	s.sections = sections
	local index: { [string]: Repeat.Instance } = {}
	local index_sec: { [string]: Repeat.SectionInstance } = {}
	local sources: { [number]: Repeat.Instance } = {}
	for _, sec in sections do
		-- A `-- Dashboard --` query reads the panel with that id itself
		-- (Grafana's `panel-<id>` key), never a repeat copy.
		local copy = string.find(sec.key, ".", 1, true) ~= nil
		for _, inst in sec.panels do
			if index[inst.key] == nil then
				index[inst.key] = inst
				index_sec[inst.key] = sec
			end
			if not copy and inst.clone == 0 and sources[inst.panel.id] == nil then
				sources[inst.panel.id] = inst
			end
		end
	end
	s.index, s.index_sec, s.sources = index, index_sec, sources
end

-- Finds an instance (and its section) by key, as Repeat.find does.
function M.find(s: State, key: string): (Repeat.Instance?, Repeat.SectionInstance?)
	return s.index[key], s.index_sec[key]
end

-- The panel instance a `-- Dashboard --` query of panel `id` reads.
function M.sourceInstance(s: State, id: number): Repeat.Instance?
	return s.sources[id]
end

-- The panel instance key of a panel state key.
function M.instanceKey(key: string): string
	return if string.sub(key, 1, 1) == "=" then string.sub(key, 2) else key
end

function M.panelState(s: State, key: string): PanelState
	local ps = s.panels[key]
	if ps == nil then
		ps = {
			status = "idle",
			decision = { mode = "native" },
			gen = s.gen_floor,
			req_gen = s.gen_floor,
			req_tags = {},
			extra_gen = 0,
		}
		s.panels[key] = ps
	end
	return ps :: PanelState
end

function M.panelScope(s: State, inst: Repeat.Instance): Interpolate.Scope
	local m = memo(s)
	if next(inst.scoped) == nil then
		return m.scope
	end
	local scope = m.insts[inst]
	if scope == nil then
		scope = Interpolate.merge(m.scope, inst.scoped)
		m.insts[inst] = scope
	end
	return scope :: Interpolate.Scope
end

function M.ladderContext(s: State, scope: Interpolate.Scope): Ladder.Context
	return {
		supports = Registry.supports,
		renderer_available = if s.settings.status == "loading" then nil else s.settings.renderer == true,
		scope = scope,
		datasources = s.settings.datasources,
		grafana_major = s.settings.major,
		source = function(id: number): Model.Panel?
			local inst = M.sourceInstance(s, id)
			return if inst then inst.panel else nil
		end,
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
		org_id = M.orgId(s),
		from = s.from or d.time.from,
		to = s.to or d.time.to,
		width = w,
		height = h,
		tz = RenderPng.tz(d.timezone),
		theme = s.cfg.render_theme,
		vars = M.instanceVars(s, inst),
	}
end

-- `range`: the panel's own range (panel_time), else the dashboard's.
-- `resolved`: Queries.resolve answers of this panel instance (see
-- Queries.Context).
function M.queryContext(
	s: State,
	scope: Interpolate.Scope,
	env: Env,
	range: Range.Range?,
	resolved: Queries.Resolved?
): Queries.Context
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
		org_id = M.orgId(s),
		user_login = s.user.login,
		exemplars = s.exemplars_on,
		resolved = resolved,
		grafana_major = s.settings.major,
		adhoc = Variables.adhocVars(s.vars, scope),
		features = s.settings.features,
	}
end

-- The range a native panel draws: its own (time override) or the
-- dashboard's, with an end relative to now snapped down to the panel's query
-- interval (lib/render/redraw.luau), so a refresh that brought the same
-- answer draws the same bytes.
function M.drawRange(s: State, ps: PanelState?): Range.Range?
	local t = if ps then ps.time else nil
	-- Data is drawn over the range it was asked for (until a refreshed answer
	-- arrives the old one stays on its own axis: no extra redraw meanwhile).
	local d = if ps then ps.drawn else nil
	local r = if d then d.range elseif t then t.range else s.range
	if r == nil then
		return nil
	end
	local to = if t then t.to else s.to
	if d == nil or not Redraw.relative(to) then
		return r
	end
	local from_ms, to_ms = Redraw.snapRange(r.from_ms, r.to_ms, (d :: Types.Drawn).interval_ms)
	return { from_ms = from_ms, to_ms = to_ms }
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

return M
