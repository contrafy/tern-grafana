--!strict
-- The dashboard machine's data layers (Grafana's dashboard scene runs them
-- next to the panel queries): the annotation layers (lib/dashboard/
-- annotations.luau) and the alert states of linked panels (lib/dashboard/
-- alert_states.luau). Every advance builds the batch of layer requests for
-- the dashboard's range and sends it when it changed (or on refresh); an
-- answer that repeats what is shown changes nothing, so panels keep their
-- drawn charts. Tags: layer/<gen>/<layers gen>/<layer index | "alerts">.

local AlertStates = require("./alert_states")
local Annotations = require("./annotations")
local Core = require("./core")
local Effect = require("../effect")
local Env = require("../env")
local Interpolate = require("./interpolate")
local Json = require("../panels/json")
local Model = require("./model")
local Queries = require("./queries")
local Range = require("../time/range")
local Route = require("../config/route")
local SvgAnnotations = require("../render/svg_annotations")
local TransportTypes = require("../transport/types")
local Types = require("./types")

type Env = Env.Env
type Effect = Effect.Effect
type Route = Route.Route
type State = Types.State
type Mark = SvgAnnotations.Mark

local M = {}

local function sameEvents(a: { Annotations.Event }?, b: { Annotations.Event }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	if #a ~= #b then
		return false
	end
	for i, e in a do
		local f = b[i]
		if e.time_ms ~= f.time_ms or e.end_ms ~= f.end_ms or e.color ~= f.color or e.panel_id ~= f.panel_id then
			return false
		end
	end
	return true
end

local function sameMarks(a: { Mark }, b: { Mark }): boolean
	if #a ~= #b then
		return false
	end
	for i, m in a do
		local n = b[i]
		if m.time_ms ~= n.time_ms or m.end_ms ~= n.end_ms or m.color ~= n.color or m.lane ~= n.lane then
			return false
		end
	end
	return true
end

local function sameStates(a: { [number]: AlertStates.State }?, b: { [number]: AlertStates.State }?): boolean
	if a == nil or b == nil then
		return a == b
	end
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- The datasource type of an annotation layer's reference under `qctx`
-- (DashboardMigrator migrateDatasourceNameToRef, then the datasource
-- service's lookup by uid or name with variables interpolated).
local function typeOf(qctx: Queries.Context, env: Env): Annotations.TypeOf
	return function(raw: any): string?
		raw = Env.value(env, raw)
		local uid: string? = nil
		if type(raw) == "table" then
			local typ = Json.str(env, raw.type)
			if typ then
				return typ
			end
			uid = Json.str(env, raw.uid)
		elseif type(raw) == "string" then
			uid = raw
		end
		if uid == nil or uid == "" or uid == "default" then
			for _, ds in qctx.datasources do
				if ds.is_default then
					return ds.type
				end
			end
			return nil
		end
		local ds = Queries.findDatasource(qctx.datasources, Interpolate.replace(uid :: string, qctx.scope))
		return if ds then ds.type else nil
	end
end

-- The layer requests for a dashboard `width` px wide.
local function batch(
	s: State,
	env: Env,
	width: number
): ({ Types.AnnotationLayer }, { TransportTypes.Request }, boolean)
	local d, route, r = s.dashboard :: Model.Dashboard, s.route :: Route, s.range :: Range.Range
	local ls = s.layers
	local qctx = Core.queryContext(s, Core.scopeOf(s), env, r, nil, width)
	local layers: { Types.AnnotationLayer } = {}
	local requests: { TransportTypes.Request } = {}
	ls.toggles = Annotations.toggles(d.annotations, env, s.layer_on)
	for _, def in Annotations.defs(d.annotations, env, s.layer_on, typeOf(qctx, env)) do
		local request: TransportTypes.Request
		local pq: Queries.PanelQuery? = nil
		if def.kind == "prometheus" then
			local p = Queries.build(def.panel :: { [string]: any }, qctx, env)
			-- Not run: no expression, a datasource that is not Prometheus,
			-- or one answered by a frontend module.
			if p == nil or #p.queries ~= 1 or p.jobs or p.queries[1].datasource.type ~= "prometheus" then
				continue
			end
			pq = p
			request = Queries.request(route, p, qctx, env)
		else
			request = Annotations.request(def, d.uid, r.from_ms, r.to_ms)
		end
		table.insert(layers, { def = def, pq = pq })
		table.insert(requests, request)
	end
	local alerts = AlertStates.applies(s.to or d.time.to) and not ls.no_rules
	if alerts then
		table.insert(requests, AlertStates.request(d.uid))
	end
	return layers, requests, alerts
end

-- Sends the layer requests when they changed (or `force`, a refresh).
-- Runs once the variables have settled (a Prometheus layer's expression
-- and datasource may use them).
function M.advance(s: State, env: Env, force: boolean, effects: { Effect })
	local d, route, r = s.dashboard, s.route, s.range
	if d == nil or route == nil or r == nil then
		return
	end
	local ls = s.layers
	local width = Core.designWidth(env)
	local layers, requests, alerts = batch(s, env, ls.width_px or width)
	local sig = env.encode(requests)
	if not force and sig == ls.sig then
		return
	end
	-- A batch sent anyway takes the dashboard's width now.
	if ls.width_px ~= nil and ls.width_px ~= width then
		layers, requests, alerts = batch(s, env, width)
		sig = env.encode(requests)
	end
	ls.width_px = width
	ls.sig = sig
	ls.gen += 1
	-- What is shown stays until the new answers replace it.
	for i, l in layers do
		local old = ls.annotations[i]
		if old and old.def.kind == l.def.kind and old.def.name == l.def.name then
			l.events, l.error = old.events, old.error
		end
	end
	ls.stamp += 1
	ls.annotations = layers
	if not alerts then
		ls.alert_states = nil
	end
	for i in layers do
		table.insert(effects, Core.http(Core.tag("layer", s.gen, ls.gen, i), route, requests[i]))
	end
	if alerts then
		table.insert(effects, Core.http(Core.tag("layer", s.gen, ls.gen, "alerts"), route, requests[#requests]))
	end
end

-- An answer (parts of its tag); false when stale or nothing changed.
function M.answer(s: State, parts: { string }, response: TransportTypes.Response, env: Env): boolean
	local ls = s.layers
	if tonumber(parts[3] or "") ~= ls.gen then
		return false
	end
	local which = parts[4]
	if which == "alerts" then
		local states = AlertStates.parse(response, env)
		-- A failed request keeps the states shown (VizPanel keeps its alertState).
		if states == nil then
			return false
		end
		if next(states) == nil then
			ls.no_rules = true
		end
		if sameStates(states, ls.alert_states) then
			return false
		end
		ls.alert_states = states
		return true
	end
	local l = ls.annotations[tonumber(which or "") or 0]
	if l == nil then
		return false
	end
	local events: { Annotations.Event }?, err: string? = nil, nil
	if l.pq then
		local data, perr = Queries.parse(response, l.pq :: Queries.PanelQuery, env)
		if data then
			events = Annotations.promEvents(l.def, data.frames)
		end
		err = perr
	else
		events, err = Annotations.parse(l.def, response, env)
	end
	-- A failed layer shows no annotations (its data layer publishes none).
	events = events or {}
	l.error = err
	if sameEvents(events, l.events) then
		return false
	end
	l.events = events
	ls.stamp += 1
	return true
end

-- The annotation marks panel `id` draws. A list equal to the previous one
-- is the same table, so the view memo still holds.
function M.marks(s: State, id: number): { Mark }
	local ls = s.layers
	local hit = ls.marks[id]
	if hit and hit.stamp == ls.stamp then
		return hit.list
	end
	local list = Annotations.marks(ls.annotations :: any, id)
	if hit and sameMarks(hit.list, list) then
		list = hit.list
	end
	ls.marks[id] = { stamp = ls.stamp, list = list }
	return list
end

-- The alert state of panel `id` for its header; nil without one.
function M.alertState(s: State, id: number): AlertStates.State?
	local states = s.layers.alert_states
	return if states then states[id] else nil
end

return M
