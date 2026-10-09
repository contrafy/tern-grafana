--!strict
-- Per-panel data: every visible target of a panel in one `/api/ds/query`
-- body, the way Grafana's frontend sends a panel's queries (mixed
-- datasources included), and the answer back as frames per panel.
--
-- Datasources: a target's own datasource wins over the panel's; `-- Mixed --`
-- means "per target"; `${ds}` resolves through the variables; a missing
-- reference is the instance default; a bare string is a legacy name or uid.
-- Only Prometheus and Loki targets are queried natively: anything else (and
-- `-- Dashboard --`, which reuses another panel's results) is a ladder reason.
--
-- Interval: maxDataPoints is the panel's, else config `dashboard.max_points`
-- (Tern blocks have no pane width to derive it from); the interval is
-- Grafana's calculateInterval with the target's or panel's min interval, and
-- becomes `$__interval`/`$__interval_ms`. `$__rate_interval` is left to
-- Grafana's backend, which knows the datasource's scrape interval.

local Env = require("../env")
local Frame = require("../frame/types")
local GrafanaSource = require("../source/grafana")
local Interpolate = require("./interpolate")
local Response = require("../source/response")
local Route = require("../config/route")
local Step = require("../time/step")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Frame = Frame.Frame
type Request = TransportTypes.Request
type Scope = Interpolate.Scope

local M = {}

M.NATIVE_TYPES = table.freeze({ prometheus = true, loki = true })

M.MIXED = "-- Mixed --"
M.DASHBOARD = "-- Dashboard --"
M.GRAFANA = "-- Grafana --"

-- Default `maxLines` for Loki log queries (Grafana's datasource default).
M.LOKI_MAX_LINES = 1000

export type Datasource = { uid: string, type: string, name: string, is_default: boolean }

export type DsRef = { uid: string, type: string }

export type Context = {
	scope: Scope,
	from_ms: number,
	to_ms: number,
	max_points: number,
	datasources: { Datasource },
	dashboard_uid: string?,
	dashboard_title: string?,
	org_id: number?,
	user_login: string?,
}

export type PanelQuery = {
	queries: { { [string]: any } },
	ref_ids: { string },
	interval_ms: number,
	max_points: number,
}

export type PanelData = {
	frames: { Frame },
	-- "A: parse error ..." per failed target.
	errors: { string },
	warnings: { string },
}

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

local function findDs(list: { Datasource }, key: string): Datasource?
	for _, ds in list do
		if ds.uid == key then
			return ds
		end
	end
	for _, ds in list do
		if ds.name == key then
			return ds
		end
	end
	return nil
end

local function defaultDs(list: { Datasource }): Datasource?
	for _, ds in list do
		if ds.is_default then
			return ds
		end
	end
	return nil
end

-- Resolves a datasource reference (table, string or nil) to {uid, type}.
local function resolveRef(raw: any, scope: Scope, list: { Datasource }, env: Env): (DsRef?, string?)
	raw = Env.value(env, raw)
	local uid: string?, typ: string? = nil, nil
	if type(raw) == "table" then
		uid, typ = str(env, raw.uid), str(env, raw.type)
	elseif type(raw) == "string" then
		uid = raw
	end
	if uid then
		uid = Interpolate.replace(uid, scope)
	end
	if uid == nil or uid == "" or uid == "default" then
		local d = defaultDs(list)
		if d == nil then
			return nil, "no default datasource"
		end
		return { uid = d.uid, type = d.type }, nil
	end
	local u = uid :: string
	if u == M.MIXED or u == M.DASHBOARD or u == M.GRAFANA then
		return { uid = u, type = typ or "datasource" }, nil
	end
	if string.find(u, "$", 1, true) then
		return nil, string.format("datasource %s is not resolved", u)
	end
	local known = findDs(list, u)
	if known then
		return { uid = known.uid, type = typ or known.type }, nil
	end
	if typ then
		return { uid = u, type = typ }, nil
	end
	return nil, string.format("unknown datasource %q", u)
end

local function targets(panel: { [string]: any }, env: Env): { { [string]: any } }
	local out: { { [string]: any } } = {}
	local list = Env.value(env, panel.targets)
	if type(list) ~= "table" then
		return out
	end
	for _, t in list do
		if type(t) == "table" and Env.value(env, t.hide) ~= true then
			table.insert(out, t)
		end
	end
	return out
end

-- The datasource of each visible target, or why the panel cannot be queried
-- natively. Panels without targets (text) need no query.
function M.resolve(panel: { [string]: any }, scope: Scope, list: { Datasource }, env: Env): ({ DsRef }?, string?)
	local ts = targets(panel, env)
	local panelRef, panelErr = resolveRef(panel.datasource, scope, list, env)
	local out: { DsRef } = {}
	for _, t in ts do
		local ref: DsRef?, err: string? = nil, nil
		if Env.value(env, t.datasource) ~= nil then
			ref, err = resolveRef(t.datasource, scope, list, env)
		else
			ref, err = panelRef, panelErr
		end
		if ref == nil then
			return nil, err
		end
		if ref.uid == M.DASHBOARD then
			return nil, "reuses another panel's query (-- Dashboard --)"
		end
		if ref.uid == M.MIXED then
			return nil, "a target has no datasource of its own in a mixed panel"
		end
		if not M.NATIVE_TYPES[ref.type] then
			return nil, string.format("%s queries are not run natively", ref.type)
		end
		table.insert(out, ref)
	end
	return out, nil
end

local function minInterval(raw: string?, scope: Scope): number?
	if raw == nil or raw == "" then
		return nil
	end
	local s = Interpolate.replace(raw, scope)
	s = string.gsub(s, "^>", "")
	return Step.parseDuration(s)
end

local function formatterFor(dsType: string): Interpolate.Formatter
	return if dsType == "loki" then Interpolate.loki else Interpolate.prometheus
end

-- The /api/ds/query objects for a panel; nil when it has nothing to query.
function M.build(panel: { [string]: any }, ctx: Context, env: Env): (PanelQuery?, string?)
	local refs, err = M.resolve(panel, ctx.scope, ctx.datasources, env)
	if refs == nil then
		return nil, err
	end
	local ts = targets(panel, env)
	if #ts == 0 then
		return nil, nil
	end
	local mdp = Env.value(env, panel.maxDataPoints)
	local maxPoints = if type(mdp) == "number" and mdp > 0 then mdp else ctx.max_points
	local panelMin = minInterval(str(env, panel.interval), ctx.scope)
	local range_ms = math.max(1, ctx.to_ms - ctx.from_ms)
	local queries: { { [string]: any } } = {}
	local refIds: { string } = {}
	local smallest: number? = nil
	for i, t in ts do
		local ref = refs[i]
		local q: { [string]: any } = {}
		for k, v in t do
			if v ~= env.null then
				q[k] = v
			end
		end
		local refId = str(env, t.refId) or string.char(64 + math.min(i, 26))
		local interval = Step.interval(range_ms, maxPoints, minInterval(str(env, t.interval), ctx.scope) or panelMin)
		smallest = if smallest then math.min(smallest, interval.interval_ms) else interval.interval_ms
		local scope = Interpolate.merge(
			Interpolate.builtins({
				from_ms = ctx.from_ms,
				to_ms = ctx.to_ms,
				interval_ms = interval.interval_ms,
				interval = interval.interval_str,
				dashboard_title = ctx.dashboard_title,
				dashboard_uid = ctx.dashboard_uid,
				org_id = ctx.org_id,
				user_login = ctx.user_login,
			}),
			ctx.scope
		)
		local fmt = { format = formatterFor(ref.type) }
		q.refId = refId
		q.datasource = { uid = ref.uid, type = ref.type }
		q.intervalMs = interval.interval_ms
		q.maxDataPoints = maxPoints
		local expr = str(env, t.expr)
		if expr then
			q.expr = Interpolate.replace(expr, scope, fmt)
		end
		local query = str(env, t.query)
		if query then
			q.query = Interpolate.replace(query, scope, fmt)
		end
		local legend = str(env, t.legendFormat)
		if legend then
			q.legendFormat = Interpolate.replace(legend, scope)
		end
		local iv = str(env, t.interval)
		if iv then
			q.interval = Interpolate.replace(iv, scope)
		end
		if ref.type == "prometheus" and q.range == nil and q.instant == nil then
			q.range = true
		elseif ref.type == "loki" and q.maxLines == nil then
			q.maxLines = M.LOKI_MAX_LINES
		end
		table.insert(queries, q)
		table.insert(refIds, refId)
	end
	return { queries = queries, ref_ids = refIds, interval_ms = smallest or 0, max_points = maxPoints }, nil
end

function M.request(route: Route.Route, pq: PanelQuery, ctx: Context, env: Env): Request
	return GrafanaSource.dsQueryRequest(route, pq.queries, { from_ms = ctx.from_ms, to_ms = ctx.to_ms }, env)
end

-- Frames of every target in target order; a failed target is an error line
-- and the others still show.
function M.parse(response: TransportTypes.Response, pq: PanelQuery, env: Env): (PanelData?, string?)
	local r = GrafanaSource.parseDsQuery(response, env)
	if not r.ok then
		return nil, (r :: any).error.message
	end
	local results: { [string]: Frame.QueryResult } = (r :: any).results
	local data: PanelData = { frames = {}, errors = {}, warnings = {} }
	for _, refId in pq.ref_ids do
		local res = results[refId]
		if res == nil then
			continue
		end
		if res.ok then
			local ok = res :: any
			for _, f in ok.frames do
				f.refId = f.refId or refId
				table.insert(data.frames, f)
			end
			for _, w in ok.warnings do
				table.insert(data.warnings, w)
			end
		else
			table.insert(data.errors, refId .. ": " .. (res :: any).error.message)
		end
	end
	return data, nil
end

-- Grafana's datasource catalog for the signed-in user, from the frontend
-- settings body (`datasources` by name, `defaultDatasource` by name). Unlike
-- /api/datasources it needs no admin rights.
function M.frontendDatasources(response: TransportTypes.Response, env: Env): { Datasource }
	local doc = Response.json(response, env, "frontend settings")
	local out: { Datasource } = {}
	if type(doc) ~= "table" then
		return out
	end
	local map = Env.value(env, doc.datasources)
	local defaultName = str(env, doc.defaultDatasource)
	if type(map) ~= "table" then
		return out
	end
	for name, ds in map do
		if type(name) ~= "string" or type(ds) ~= "table" then
			continue
		end
		local uid, typ = str(env, ds.uid), str(env, ds.type)
		if uid and typ then
			table.insert(out, {
				uid = uid,
				type = typ,
				name = str(env, ds.name) or name,
				is_default = Env.value(env, ds.isDefault) == true or name == defaultName,
			})
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

return M
