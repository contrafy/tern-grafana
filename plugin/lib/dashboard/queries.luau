--!strict
-- Per-panel data: every target of a panel in one `/api/ds/query` body, the
-- way Grafana's frontend sends a panel's queries (mixed datasources
-- included), and the answer back as frames per panel.
--
-- Datasources: a target's own datasource wins over the panel's; `-- Mixed --`
-- means "per target"; `${ds}` resolves through the variables; a missing
-- reference is the instance default; a bare string is a legacy name or uid.
--
-- Which datasources run natively (`resolve`): a type with a datasource
-- module (lib/datasources/registry.luau) is decided by its module alone;
-- otherwise Prometheus, Loki and TestData as before; Tempo for the panels
-- that draw its frames; and every other backend datasource plugin (frontend
-- settings `meta.backend`, else a known list) through the generic path
-- below. Frontend-only plugins, and backend ones whose frontends query or
-- post-process in the browser (CLIENT_SIDE, and the per-target rules of
-- targetBlocker), keep a precise reason.
--
-- Datasource modules: backend ones shape their targets (`shape`, else the
-- generic shaping with their `format`) and post-process their frames
-- (`postprocess`); frontend ones run jobs (`start`/`step`), one per
-- datasource instance, whose requests the Dashboard block sends and whose
-- results join the /api/ds/query ones in target order (`combine`).
--
-- Each target is shaped as its datasource's frontend shapes it before
-- DataSourceWithBackend.query (packages/grafana-runtime/src/utils/
-- DataSourceWithBackend.ts) adds datasource, intervalMs and maxDataPoints:
-- - Prometheus, Loki, TestData, Tempo: expr/query/legendFormat/interval
--   interpolated with the datasource's variable formatting;
-- - SQL (packages/grafana-sql/src/datasource/SqlDatasource.ts
--   applyTemplateVariables): only refId, datasource, rawSql and format,
--   rawSql with the SQL quoting (Interpolate.sql / Interpolate.postgres);
--   `$__timeFilter(...)` and the other SQL macros are the backend's;
-- - Elasticsearch (elasticsearch/datasource.ts applyTemplateVariables): the
--   Lucene query (and `filters` bucket queries) with the lucene format,
--   then every string with the default one;
-- - any other plugin: every string field of the target with Grafana's
--   default (glob) format, as plugins' templateSrv.replace calls do.
--
-- Server-side expressions (`__expr__` targets): Grafana's runRequest hands
-- the whole request to the expression datasource, which sends every target
-- (hidden ones included: expressions read them by refId; no filterQuery)
-- and drops the hidden refIds from the answer. Expression targets go as
-- written, with Grafana's expression datasource reference.
--
-- `-- Dashboard --` (public/app/plugins/datasource/dashboard/datasource.ts)
-- reuses another panel's results: `dashboardQuery` reads its first target;
-- the Dashboard block feeds the source panel's frames (lib/dashboard/state).
--
-- Interval: maxDataPoints is the panel's, else config `dashboard.max_points`
-- (Tern gives a block its pane width in cells, not px); the interval is
-- Grafana's calculateInterval with the target's or panel's min interval, and
-- becomes `$__interval`/`$__interval_ms`. `$__rate_interval` is left to
-- Grafana's backend, which knows the datasource's scrape interval.
--
-- Exemplars: time series panels ask Prometheus range targets for exemplars
-- when config `query.exemplars` is on (and never when it is off, whatever the
-- target says); the exemplar frames come back apart from the series frames.
--
-- Ad hoc filters (lib/dashboard/adhoc.luau): a panel whose datasource (its
-- own, else its first target's; never `-- Mixed --`) is an ad hoc
-- variable's gets that variable's filters, as scenes' SceneQueryRunner hands
-- them to the datasource: Prometheus adds them to every selector of `expr`
-- (then interpolates the expression again, as applyTemplateVariables does,
-- with or without filters), Loki to its stream selectors or after its
-- parsers.

local Adhoc = require("./adhoc")
local DsRegistry = require("../datasources/registry")
local DsTypes = require("../datasources/types")
local Env = require("../env")
local Frame = require("../frame/types")
local FrameGrafana = require("../frame/grafana")
local FrameProm = require("../frame/prom")
local GrafanaSource = require("../source/grafana")
local Interpolate = require("./interpolate")
local Response = require("../source/response")
local Route = require("../config/route")
local Step = require("../time/step")
local Tbl = require("../tbl")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Frame = Frame.Frame
type Request = TransportTypes.Request
type Scope = Interpolate.Scope

local M = {}

-- Datasources with their own target shaping here. TestData runs on
-- Grafana's backend except the scenarios its frontend fakes.
M.NATIVE_TYPES =
	table.freeze({ prometheus = true, loki = true, ["grafana-testdata-datasource"] = true, testdata = true })
M.BROWSER_ONLY_SCENARIOS = table.freeze({ node_graph = true, trace = true, flame_graph = true, raw_frame = true })
-- Datasources only some panel types can draw: Tempo trace frames by the
-- traces panel (lib/panels/traces), Tempo search results as a table.
M.PANEL_DATASOURCES = table.freeze({ tempo = table.freeze({ traces = true, table = true }) })

-- The SQL datasources (SqlDatasource subclasses). Postgres quotes a single
-- value of a multi-value variable differently (its own interpolateVariable).
M.SQL_TYPES = table.freeze({
	["grafana-postgresql-datasource"] = "postgres",
	postgres = "postgres",
	mysql = "sql",
	mssql = "sql",
})

-- Backend plugins when the frontend settings list the datasource without
-- `meta.backend`.
M.KNOWN_BACKEND = table.freeze({
	["grafana-postgresql-datasource"] = true,
	postgres = true,
	mysql = true,
	mssql = true,
	elasticsearch = true,
	["yesoreyeram-infinity-datasource"] = true,
})

-- Backend plugins whose frontends query or post-process in the browser in
-- ways /api/ds/query cannot reproduce.
M.CLIENT_SIDE = table.freeze({
	-- graphite/datasource.ts query: the /render API through the datasource proxy.
	graphite = "Graphite queries are sent by the browser through the datasource proxy",
	-- influxdb/datasource.ts: InfluxQL runs classicQuery in the browser unless
	-- the backend migration toggle is on.
	influxdb = "InfluxDB queries are built in the browser",
})

-- Infinity (yesoreyeram-infinity-datasource module isBackendQuery): what its
-- backend parses; anything else is parsed in the browser.
local INFINITY_BACKEND_TYPES =
	table.freeze({ json = true, csv = true, tsv = true, graphql = true, xml = true, html = true })
local INFINITY_BACKEND_PARSERS = table.freeze({ backend = true, ["jq-backend"] = true })
local INFINITY_PASSTHROUGH = table.freeze({ transformations = true, ["google-sheets"] = true })

M.MIXED = "-- Mixed --"
M.DASHBOARD = "-- Dashboard --"
M.GRAFANA = "-- Grafana --"
M.EXPRESSION = "__expr__"

-- Default `maxLines` for Loki log queries (Grafana's datasource default).
M.LOKI_MAX_LINES = 1000

export type Datasource = DsTypes.Datasource

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
	-- Config query.exemplars.
	exemplars: boolean?,
	-- Queries.resolve answers already computed for this scope (see Resolved).
	resolved: Resolved?,
	-- Grafana's major version (frontend settings buildInfo); nil: unknown.
	grafana_major: number?,
	-- Ad hoc filter variables, in dashboard order.
	adhoc: { AdhocVar }?,
	-- Grafana's frontend feature toggles that are on.
	features: { [string]: boolean }?,
}

-- An ad hoc filter variable: its datasource (uid or name, interpolated) and
-- its filters.
export type AdhocVar = { datasource: string?, filters: { Adhoc.Filter } }

-- Queries.resolve answers by panel JSON table, all for one scope and
-- datasource list (one panel instance): the ladder and the query build of
-- one advance resolve each panel once.
export type Resolved = { [any]: { refs: { DsRef }?, err: string? } }

-- A frontend datasource job of a panel: the visible refIds it answers, its
-- run, and the requests of its first step (part of the query's identity).
export type PanelJob = { ref_ids: { string }, run: DsRegistry.Run, first: { DsTypes.DsRequest } }

-- Frames of a backend datasource module's targets, post-processed together
-- (one group per datasource instance, as Grafana calls the plugin's query).
export type PostGroup = {
	module: DsTypes.DsModule,
	ref_ids: { string },
	targets: { { [string]: any } },
	ctx: DsTypes.DsContext,
}

export type PanelQuery = {
	-- The /api/ds/query objects (none when every target runs as a job).
	queries: { { [string]: any } },
	-- The refIds whose results the panel shows (hidden ones are not).
	ref_ids: { string },
	interval_ms: number,
	max_points: number,
	jobs: { PanelJob }?,
	-- With jobs: the order results combine in (0: the /api/ds/query
	-- answer, i: jobs[i]), by each part's first target, and the parsed
	-- /api/ds/query answer once it arrived.
	parts: { number }?,
	dsq: PanelData?,
	post: { PostGroup }?,
}

export type PanelData = DsTypes.PanelData

-- A `-- Dashboard --` query: the source panel and whether its
-- transformations apply.
export type DashboardQuery = { panel_id: number, with_transforms: boolean }

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

-- A datasource of `list` by uid, else by name.
M.findDatasource = findDs

local function defaultDs(list: { Datasource }): Datasource?
	for _, ds in list do
		if ds.is_default then
			return ds
		end
	end
	return nil
end

-- Grafana's isExpressionReference (a reference's type, or a bare string).
local function isExpression(raw: any, env: Env): boolean
	raw = Env.value(env, raw)
	if type(raw) == "string" then
		return raw == M.EXPRESSION or raw == "Expression"
	elseif type(raw) == "table" then
		local t, u = str(env, raw.type), str(env, raw.uid)
		return t == M.EXPRESSION or t == "Expression" or u == M.EXPRESSION
	end
	return false
end

-- Resolves a datasource reference (table, string or nil) to {uid, type}.
local function resolveRef(raw: any, scope: Scope, list: { Datasource }, env: Env): (DsRef?, string?)
	raw = Env.value(env, raw)
	if isExpression(raw, env) then
		return { uid = M.EXPRESSION, type = M.EXPRESSION }, nil
	end
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

-- The targets Grafana sends and whether the panel has server-side
-- expressions (then hidden targets are sent too).
local function targets(panel: { [string]: any }, env: Env): ({ { [string]: any } }, boolean)
	local list = Env.value(env, panel.targets)
	local all: { { [string]: any } } = {}
	local expr = false
	if type(list) ~= "table" then
		return all, false
	end
	for _, t in list do
		if type(t) == "table" then
			table.insert(all, t)
			expr = expr or isExpression(t.datasource, env)
		end
	end
	if expr then
		return all, true
	end
	local out: { { [string]: any } } = {}
	for _, t in all do
		if Env.value(env, t.hide) ~= true then
			table.insert(out, t)
		end
	end
	return out, false
end

-- Whether `ds` has a backend Tern can send its targets to.
local function typeBlocker(ref: DsRef, list: { Datasource }, panelType: string): string?
	local kind = ref.type
	if M.NATIVE_TYPES[kind] or kind == M.EXPRESSION then
		return nil
	end
	local byPanel = M.PANEL_DATASOURCES[kind]
	if byPanel then
		return if byPanel[panelType] then nil else string.format("%s queries are not run natively", kind)
	end
	if kind == "datasource" then
		-- `-- Grafana --` (search, live, annotations: run in the browser).
		return string.format("%s queries are not run natively", kind)
	end
	local client = M.CLIENT_SIDE[kind]
	if client then
		return client
	end
	-- A datasource Grafana's settings do not list is not one Grafana can run.
	local ds = findDs(list, ref.uid)
	if ds == nil then
		return string.format("%s queries are not run natively", kind)
	end
	local backend = ds.backend
	if backend == nil then
		backend = M.KNOWN_BACKEND[kind]
	end
	if backend == true then
		return nil
	elseif backend == false then
		return string.format("%s queries run in the browser (a frontend datasource plugin)", kind)
	end
	return string.format("%s queries are not run natively", kind)
end

-- Rules for one target of a supported datasource.
local function targetBlocker(ref: DsRef, t: { [string]: any }, env: Env): string?
	local kind = ref.type
	if kind == "grafana-testdata-datasource" or kind == "testdata" then
		local scenario = str(env, t.scenarioId) or "random_walk"
		if M.BROWSER_ONLY_SCENARIOS[scenario] then
			return string.format("the TestData scenario %s runs in the browser only", scenario)
		end
	elseif kind == "yesoreyeram-infinity-datasource" then
		local qt = str(env, t.type) or "json"
		if qt == "global" then
			return "Infinity global queries are not run natively"
		end
		local parser = str(env, t.parser)
		if
			not INFINITY_PASSTHROUGH[qt]
			and not (INFINITY_BACKEND_TYPES[qt] and parser and INFINITY_BACKEND_PARSERS[parser])
		then
			return string.format("Infinity %s queries with the %s parser run in the browser", qt, parser or "default")
		end
	end
	return nil
end

-- A target of a datasource module's type: the instance must be one
-- Grafana lists (its url and settings come from there); then the module's
-- blocker decides. Server-side expressions cannot read a job's results.
local function moduleBlocker(
	mod: DsTypes.DsModule,
	ref: DsRef,
	t: { [string]: any },
	scope: Scope,
	list: { Datasource },
	expr: boolean,
	major: number?,
	env: Env
): string?
	local ds = findDs(list, ref.uid)
	if ds == nil then
		return string.format("%s queries are not run natively", ref.type)
	end
	if expr and mod.start then
		return string.format("server-side expressions cannot read %s queries (run in the browser)", ref.type)
	end
	local blocker = mod.blocker
	if blocker == nil then
		return nil
	end
	return blocker(t, { scope = scope, datasources = list, ds = ds :: Datasource, grafana_major = major }, env)
end

-- The datasource of each target Grafana sends, or why the panel cannot be
-- queried natively. Panels without targets (text) need no query. A
-- `-- Dashboard --` panel resolves to that one reference. `major`: Grafana's
-- major version, for datasource modules whose rules depend on it.
function M.resolve(
	panel: { [string]: any },
	scope: Scope,
	list: { Datasource },
	env: Env,
	major: number?
): ({ DsRef }?, string?)
	local ts, expr = targets(panel, env)
	local panelRef, panelErr = resolveRef(panel.datasource, scope, list, env)
	if panelRef and panelRef.uid == M.DASHBOARD then
		return { panelRef }, nil
	end
	local panelType = str(env, panel.type) or ""
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
			return nil, "a -- Dashboard -- query among other queries is not run natively"
		end
		if ref.uid == M.MIXED then
			return nil, "a target has no datasource of its own in a mixed panel"
		end
		local mod = DsRegistry.module(ref.type)
		local blocker = if mod
			then moduleBlocker(mod, ref, t, scope, list, expr, major, env)
			else typeBlocker(ref, list, panelType) or targetBlocker(ref, t, env)
		if blocker then
			return nil, blocker
		end
		table.insert(out, ref)
	end
	return out, nil
end

-- M.resolve through `resolved` (nil: no memo).
function M.resolveIn(
	resolved: Resolved?,
	panel: { [string]: any },
	scope: Scope,
	list: { Datasource },
	env: Env,
	major: number?
): ({ DsRef }?, string?)
	if resolved == nil then
		return M.resolve(panel, scope, list, env, major)
	end
	local hit = resolved[panel]
	if hit == nil then
		local refs, err = M.resolve(panel, scope, list, env, major)
		hit = { refs = refs, err = err }
		resolved[panel] = hit
	end
	return hit.refs, hit.err
end

-- The `-- Dashboard --` query of a panel whose datasource is
-- `-- Dashboard --` (its first target, as DashboardDatasource.query reads
-- it), nil for other panels and for one with no source panel id; or why it
-- cannot be reproduced.
function M.dashboardQuery(panel: { [string]: any }, env: Env): (DashboardQuery?, string?)
	local raw = Env.value(env, panel.datasource)
	local uid = if type(raw) == "table" then str(env, raw.uid) elseif type(raw) == "string" then raw else nil
	if uid ~= M.DASHBOARD then
		return nil, nil
	end
	local list = Env.value(env, panel.targets)
	local t = if type(list) == "table" then Env.value(env, list[1]) else nil
	if type(t) ~= "table" then
		return nil, nil
	end
	local id = Env.value(env, t.panelId)
	if type(id) ~= "number" or id == 0 then
		return nil, nil
	end
	if str(env, t.topic) == "annotations" then
		return nil, "reuses another panel's annotations (-- Dashboard --)"
	end
	if Env.value(env, t.adHocFiltersEnabled) == true then
		return nil, "ad hoc filters on a -- Dashboard -- query are not supported"
	end
	return { panel_id = id, with_transforms = Env.value(env, t.withTransforms) == true }, nil
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

-- A copy of decoded JSON `v` with every string interpolated (decoded arrays
-- stay arrays, so an empty one still encodes as `[]`).
local function interpolateAll(v: any, scope: Scope, opts: Interpolate.Options?, env: Env): any
	if type(v) == "string" then
		return Interpolate.replace(v, scope, opts)
	elseif type(v) ~= "table" or v == env.null then
		return v
	end
	local out: { [any]: any } = {}
	for k, x in v do
		out[k] = interpolateAll(x, scope, opts, env)
	end
	if getmetatable(v :: any) ~= nil and env.array then
		return env.array(out)
	end
	return out
end

-- Elasticsearch's interpolateLuceneQuery for the query and `filters`
-- bucket aggregations, before the default pass over every string.
local function elasticsearchTarget(t: { [string]: any }, scope: Scope, env: Env): { [string]: any }
	local lucene = { format = Interpolate.named("lucene") }
	local q: { [string]: any } = Tbl.copy(t)
	q.query = Interpolate.replace(str(env, t.query) or "", scope, lucene)
	local aggs = Env.value(env, t.bucketAggs)
	if type(aggs) == "table" then
		local list: { any } = {}
		for i, agg in aggs do
			local raw = if type(agg) == "table" and str(env, agg.type) == "filters"
				then Env.value(env, agg.settings)
				else nil
			local filters = if type(raw) == "table" then Env.value(env, raw.filters) else nil
			if type(filters) == "table" then
				local copy: { [string]: any } = Tbl.copy(agg)
				local settings: { [string]: any } = Tbl.copy(raw)
				local fs: { any } = {}
				for j, f in filters do
					local nf: { [string]: any } = if type(f) == "table" then Tbl.copy(f) else {}
					local fq = Interpolate.replace(str(env, nf.query) or "", scope, lucene)
					nf.query = if fq == "" then "*" else fq
					fs[j] = nf
				end
				settings.filters = if env.array then env.array(fs) else fs
				copy.settings = settings
				list[i] = copy
			else
				list[i] = agg
			end
		end
		q.bucketAggs = if env.array then env.array(list) else list
	end
	return interpolateAll(q, scope, nil, env)
end

-- The target as its datasource's frontend hands it to
-- DataSourceWithBackend.query (before datasource/interval fields). With
-- expressions (`expr`) the expression datasource uses each datasource's
-- interpolateVariablesInQueries instead of applyTemplateVariables: SQL
-- targets then go whole, with rawSql interpolated and rawQuery set.
-- `filters`: the panel's ad hoc filters (Prometheus and Loki apply them).
local function shape(
	ref: DsRef,
	t: { [string]: any },
	scope: Scope,
	expr: boolean,
	env: Env,
	filters: { Adhoc.Filter }?,
	promOpts: Adhoc.PromOptions?
): { [string]: any }
	local kind = ref.type
	local sql = M.SQL_TYPES[kind]
	if sql then
		local fmt = { format = if sql == "postgres" then Interpolate.postgres else Interpolate.sql }
		local rawSql = Interpolate.replace(str(env, t.rawSql) or "", scope, fmt)
		if not expr then
			return { rawSql = rawSql, format = Env.value(env, t.format) }
		end
		local q: { [string]: any } = {}
		for k, v in t do
			if v ~= env.null then
				q[k] = v
			end
		end
		q.rawSql, q.rawQuery = rawSql, true
		return q
	elseif kind == "elasticsearch" then
		return elasticsearchTarget(t, scope, env)
	elseif not M.NATIVE_TYPES[kind] and not M.PANEL_DATASOURCES[kind] then
		return interpolateAll(t, scope, nil, env)
	end
	local q: { [string]: any } = {}
	for k, v in t do
		if v ~= env.null then
			q[k] = v
		end
	end
	local fmt = { format = formatterFor(kind) }
	local promExpr = str(env, t.expr)
	if promExpr then
		local e = Interpolate.replace(promExpr, scope, fmt)
		if kind == "prometheus" then
			-- applyTemplateVariables interpolates again after adding the
			-- filters (whose values may hold variables).
			e = Interpolate.replace(Adhoc.promApply(e, filters or {}, promOpts), scope, fmt)
		elseif kind == "loki" and filters then
			e = Adhoc.lokiApply(e, filters)
			-- Grafana 12.1+ with lokiQuerySplitting applies the filters in
			-- runSplitQuery and again in DataSourceWithBackend.query for the
			-- queries it splits (not instant, no `$__range`): a filter added
			-- after a parser shows twice, as in Grafana's request.
			local o: Adhoc.PromOptions = promOpts or {}
			local queryType = Env.value(env, t.queryType)
			if
				(o.major or 0) >= 12
				and o.loki_split
				and queryType ~= "instant"
				and not string.find(promExpr, "$__range", 1, true)
			then
				e = Adhoc.lokiApply(e, filters)
			end
		end
		q.expr = e
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
	return q
end

-- What a datasource module sees for targets of instance `ds`.
local function dsContext(
	ctx: Context,
	ds: Datasource,
	scope: Scope,
	interval_ms: number,
	maxPoints: number,
	env: Env
): DsTypes.DsContext
	return {
		scope = scope,
		from_ms = ctx.from_ms,
		to_ms = ctx.to_ms,
		interval_ms = interval_ms,
		max_points = maxPoints,
		now_ms = env.now_ms,
		datasources = ctx.datasources,
		ds = ds,
		grafana_major = ctx.grafana_major,
		dashboard_uid = ctx.dashboard_uid,
	}
end

-- Targets of one frontend datasource instance, in target order.
type JobGroup = {
	module: DsTypes.DsModule,
	ctx: DsTypes.DsContext,
	targets: { DsTypes.Target },
	ref_ids: { string },
}

-- The ad hoc filters a panel's queries get and the datasource uid they are
-- for: the filters of every variable whose datasource is the panel's
-- (SceneQueryRunner.findAndSubscribeToDrilldowns on the panel datasource,
-- else the first query's; a `-- Mixed --` panel gets none), merged in
-- order without repeats (DrilldownDependenciesManager.getFilters). A
-- variable without a datasource is on the default one (Grafana's schema
-- migration gives it that reference).
local function panelFilters(
	panel: { [string]: any },
	refs: { DsRef },
	ctx: Context,
	env: Env
): ({ Adhoc.Filter }?, string?)
	local vars = ctx.adhoc
	if vars == nil or #vars == 0 then
		return nil, nil
	end
	local raw = Env.value(env, panel.datasource)
	local ref: DsRef? = refs[1]
	if raw ~= nil then
		ref = resolveRef(raw, ctx.scope, ctx.datasources, env)
	end
	if ref == nil or ref.uid == M.MIXED then
		return nil, nil
	end
	local out: { Adhoc.Filter } = {}
	local seen: { [string]: boolean } = {}
	for _, v in vars do
		local ds = if v.datasource and v.datasource ~= ""
			then findDs(ctx.datasources, v.datasource :: string)
			else defaultDs(ctx.datasources)
		local uid = if ds then ds.uid else v.datasource
		if uid ~= ref.uid then
			continue
		end
		for _, f in Adhoc.applied(v.filters) do
			local id = f.key
				.. "\0"
				.. f.operator
				.. "\0"
				.. (if f.values then table.concat(f.values, "\1") else f.value)
			if not seen[id] then
				seen[id] = true
				table.insert(out, f)
			end
		end
	end
	if #out == 0 then
		return nil, nil
	end
	return out, ref.uid
end

-- The /api/ds/query objects for a panel, and the jobs of its frontend
-- datasources; nil when it has nothing to query (a `-- Dashboard --` panel
-- gets its frames from the source panel).
function M.build(panel: { [string]: any }, ctx: Context, env: Env): (PanelQuery?, string?)
	local refs, err = M.resolveIn(ctx.resolved, panel, ctx.scope, ctx.datasources, env, ctx.grafana_major)
	if refs == nil then
		return nil, err
	end
	local ts, expr = targets(panel, env)
	if #ts == 0 or (refs[1] and refs[1].uid == M.DASHBOARD) then
		return nil, nil
	end
	local filters, filtersUid = panelFilters(panel, refs, ctx, env)
	local features: { [string]: boolean } = ctx.features or {}
	local promOpts: Adhoc.PromOptions = {
		major = ctx.grafana_major,
		special = features.prometheusSpecialCharsInLabelValues == true,
		loki_split = features.lokiQuerySplitting == true,
	}
	local mdp = Env.value(env, panel.maxDataPoints)
	local maxPoints = if type(mdp) == "number" and mdp > 0 then mdp else ctx.max_points
	local panelMin = minInterval(str(env, panel.interval), ctx.scope)
	local range_ms = math.max(1, ctx.to_ms - ctx.from_ms)
	local timeseries = str(env, panel.type) == "timeseries"
	local queries: { { [string]: any } } = {}
	local refIds: { string } = {}
	local smallest: number? = nil
	local parts: { number } = {}
	local groups: { JobGroup } = {}
	local groupOf: { [string]: number } = {}
	local post: { PostGroup } = {}
	local postOf: { [string]: PostGroup } = {}
	for i, t in ts do
		local ref = refs[i]
		local refId = str(env, t.refId) or string.char(64 + math.min(i, 26))
		local hidden = Env.value(env, t.hide) == true
		if ref.type == M.EXPRESSION then
			-- Sent as written: the expression datasource applies no variables.
			local q: { [string]: any } = {}
			for k, v in t do
				if v ~= env.null then
					q[k] = v
				end
			end
			q.refId = refId
			q.datasource = { type = M.EXPRESSION, uid = M.EXPRESSION, name = "Expression" }
			table.insert(queries, q)
			if not hidden then
				table.insert(refIds, refId)
			end
			if table.find(parts, 0) == nil then
				table.insert(parts, 0)
			end
			continue
		end
		-- The datasources' filterQuery (not applied with expressions): Grafana
		-- never sends a Prometheus target without an expression, or a Loki one
		-- with an empty one.
		local rawExpr = str(env, t.expr)
		if
			not expr
			and (
				(ref.type == "prometheus" and (rawExpr == nil or rawExpr == ""))
				or (ref.type == "loki" and rawExpr == "")
			)
		then
			continue
		end
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
		local mod = DsRegistry.module(ref.type)
		local ds = if mod then findDs(ctx.datasources, ref.uid) else nil
		if mod and ds and mod.start then
			-- Hidden targets never reach start(): nothing reads them without
			-- expressions, which a job's targets cannot feed.
			if hidden then
				continue
			end
			local gi = groupOf[ref.uid]
			if gi == nil then
				table.insert(groups, {
					module = mod,
					ctx = dsContext(ctx, ds, scope, interval.interval_ms, maxPoints, env),
					targets = {},
					ref_ids = {},
				})
				gi = #groups
				groupOf[ref.uid] = gi
				table.insert(parts, gi)
			end
			local g = groups[gi :: number]
			table.insert(g.targets, t)
			table.insert(g.ref_ids, refId)
			continue
		end
		local q: { [string]: any }
		if mod and ds then
			local dctx = dsContext(ctx, ds, scope, interval.interval_ms, maxPoints, env)
			local shapeFn = mod.shape
			q = if shapeFn
				then shapeFn(t, dctx, env)
				else interpolateAll(t, scope, { format = DsRegistry.formatter(mod, dctx) }, env)
			if mod.postprocess then
				local pg = postOf[ref.uid]
				if pg == nil then
					pg = { module = mod, ref_ids = {}, targets = {}, ctx = dctx }
					postOf[ref.uid] = pg
					table.insert(post, pg :: PostGroup)
				end
				table.insert((pg :: PostGroup).ref_ids, refId)
				table.insert((pg :: PostGroup).targets, q)
			end
		else
			q = shape(ref, t, scope, expr, env, if ref.uid == filtersUid then filters else nil, promOpts)
		end
		q.refId = refId
		q.datasource = { uid = ref.uid, type = ref.type }
		q.intervalMs = interval.interval_ms
		q.maxDataPoints = maxPoints
		if ref.type == "prometheus" and q.range == nil and q.instant == nil then
			q.range = true
		elseif ref.type == "loki" and q.maxLines == nil then
			q.maxLines = M.LOKI_MAX_LINES
		end
		if ref.type == "prometheus" and ctx.exemplars ~= nil then
			q.exemplar = ctx.exemplars == true and timeseries and q.range == true and q.instant ~= true
		end
		table.insert(queries, q)
		if not hidden then
			table.insert(refIds, refId)
		end
		if table.find(parts, 0) == nil then
			table.insert(parts, 0)
		end
	end
	if #queries == 0 and #groups == 0 then
		return nil, nil
	end
	local pq: PanelQuery = { queries = queries, ref_ids = refIds, interval_ms = smallest or 0, max_points = maxPoints }
	if #post > 0 then
		pq.post = post
	end
	if #groups > 0 then
		local jobs: { PanelJob } = {}
		for gi, g in groups do
			local start = g.module.start :: ({ DsTypes.Target }, DsTypes.DsContext, Env) -> DsTypes.Job
			local run, first = DsRegistry.begin(g.module, start(g.targets, g.ctx, env), g.ref_ids, env)
			jobs[gi] = { ref_ids = g.ref_ids, run = run, first = first }
		end
		pq.jobs = jobs
		pq.parts = parts
	end
	return pq, nil
end

-- What identifies a panel query: its /api/ds/query objects and its jobs'
-- first requests.
function M.identity(pq: PanelQuery, env: Env): string
	local jobs = pq.jobs
	if jobs == nil then
		return env.encode(pq.queries)
	end
	local first: { any } = {}
	for i, j in jobs do
		first[i] = j.first
	end
	return env.encode(pq.queries) .. "\31" .. env.encode(first)
end

function M.request(route: Route.Route, pq: PanelQuery, ctx: Context, env: Env): Request
	return GrafanaSource.dsQueryRequest(route, pq.queries, { from_ms = ctx.from_ms, to_ms = ctx.to_ms }, env)
end

-- Each post-processing group's frames replaced by its module's output, at
-- the place of the group's first frame.
local function postprocess(frames: { Frame }, groups: { PostGroup }, env: Env): { Frame }
	for _, g in groups do
		local mine: { [string]: boolean } = {}
		for _, refId in g.ref_ids do
			mine[refId] = true
		end
		local own: { Frame } = {}
		local at: number? = nil
		local rest: { Frame } = {}
		for _, f in frames do
			if f.refId and mine[f.refId :: string] then
				table.insert(own, f)
				at = at or #rest + 1
			else
				table.insert(rest, f)
			end
		end
		local out = (g.module.postprocess :: any)(own, g.targets, g.ctx, env) :: { Frame }
		local pos = at or #rest + 1
		for k, f in out do
			table.insert(rest, pos + k - 1, f)
		end
		frames = rest
	end
	return frames
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
			local frames, exemplars = FrameGrafana.splitExemplars(ok.frames)
			for _, f in frames do
				f.refId = f.refId or refId
				table.insert(data.frames, f)
			end
			if #exemplars > 0 then
				local list = data.exemplars or {}
				table.move(exemplars, 1, #exemplars, #list + 1, list)
				data.exemplars = list
			end
			for _, w in ok.warnings do
				table.insert(data.warnings, w)
			end
		else
			table.insert(data.errors, refId .. ": " .. (res :: any).error.message)
		end
	end
	if pq.post then
		data.frames = postprocess(data.frames, pq.post :: { PostGroup }, env)
	end
	if data.exemplars then
		FrameProm.sortExemplars(data.exemplars :: { FrameProm.Exemplar })
	end
	return data, nil
end

-- The /api/ds/query part of a query with jobs, from its answer: a failed
-- request is an error line per target, so the jobs' results still show.
function M.setAnswer(pq: PanelQuery, response: TransportTypes.Response, env: Env)
	local data, err = M.parse(response, pq, env)
	if data == nil then
		local errors: { string } = {}
		for _, refId in pq.ref_ids do
			table.insert(errors, refId .. ": " .. (err or "the query failed"))
		end
		data = { frames = {}, errors = errors, warnings = {} }
	end
	pq.dsq = data
end

-- A query with jobs, once every part answered: the parts' results in
-- target order (frames, error lines, warnings, exemplars); nil while one is
-- pending.
function M.combine(pq: PanelQuery): PanelData?
	local jobs: { PanelJob } = pq.jobs or {}
	if #pq.queries > 0 and pq.dsq == nil then
		return nil
	end
	for _, j in jobs do
		if j.run.outcome == nil then
			return nil
		end
	end
	local out: PanelData = { frames = {}, errors = {}, warnings = {} }
	local parts: { number } = pq.parts or { 0 }
	for _, part in parts do
		local d = if part == 0 then pq.dsq else DsRegistry.panelData(jobs[part].run)
		if d == nil then
			continue
		end
		local src = d :: PanelData
		table.move(src.frames, 1, #src.frames, #out.frames + 1, out.frames)
		table.move(src.errors, 1, #src.errors, #out.errors + 1, out.errors)
		table.move(src.warnings, 1, #src.warnings, #out.warnings + 1, out.warnings)
		if src.exemplars then
			local list = out.exemplars or {}
			table.move(src.exemplars :: { FrameProm.Exemplar }, 1, #(src.exemplars :: any), #list + 1, list)
			out.exemplars = list
		end
	end
	if out.exemplars then
		FrameProm.sortExemplars(out.exemplars :: { FrameProm.Exemplar })
	end
	return out
end

-- Grafana's datasource catalog for the signed-in user, from the frontend
-- settings body (`datasources` by name, `defaultDatasource` by name). Unlike
-- /api/datasources it needs no admin rights. Each keeps its `url` and a copy
-- of its `jsonData` for datasource modules: they may hold credentials
-- (lib/datasources/types.luau), so they never leave memory.
function M.frontendDatasources(response: TransportTypes.Response, env: Env): { Datasource }
	local doc = Response.json(response, env, "frontend settings")
	local out: { Datasource } = {}
	if type(doc) ~= "table" then
		return out
	end
	local map = Env.value(env, doc.datasources)
	local defaultName = str(env, doc.defaultDatasource)
	local manageDefault = Env.value(env, doc.defaultDatasourceManageAlertsUiToggle)
	if type(map) ~= "table" then
		return out
	end
	for name, ds in map do
		if type(name) ~= "string" or type(ds) ~= "table" then
			continue
		end
		local uid, typ = str(env, ds.uid), str(env, ds.type)
		if uid and typ then
			local jsonData = Env.value(env, ds.jsonData)
			local manage = if type(jsonData) == "table" then Env.value(env, jsonData.manageAlerts) else nil
			if type(manage) ~= "boolean" then
				manage = if type(manageDefault) == "boolean" then manageDefault else true
			end
			local meta = Env.value(env, ds.meta)
			local backend = if type(meta) == "table" then Env.value(env, meta.backend) else nil
			local multi = if type(meta) == "table" then Env.value(env, meta.multiValueFilterOperators) else nil
			table.insert(out, {
				uid = uid,
				type = typ,
				name = str(env, ds.name) or name,
				is_default = Env.value(env, ds.isDefault) == true or name == defaultName,
				manage_alerts = manage,
				backend = if type(backend) == "boolean" then backend else nil,
				url = str(env, ds.url),
				json_data = if type(jsonData) == "table" then Tbl.copy(jsonData) else nil,
				multi_value_filters = if multi == true then true else nil,
			})
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

-- Toggles Grafana made default and dropped from `featureToggles`, by the
-- major version that did: 13's gauge panel always draws gauge/v2, and its
-- panels always have the new header padding.
local GA_FEATURES: { [string]: number } = { newGauge = 13, newPanelPadding = 13 }

-- Grafana's frontend feature toggles (`featureToggles`), the ones on, plus
-- the GA ones for the server's version (`buildInfo.version`).
function M.frontendFeatures(response: TransportTypes.Response, env: Env): { [string]: boolean }
	local doc = Response.json(response, env, "frontend settings")
	local out: { [string]: boolean } = {}
	if type(doc) ~= "table" then
		return out
	end
	local map = Env.value(env, doc.featureToggles)
	if type(map) == "table" then
		for name, on in map do
			if type(name) == "string" and Env.value(env, on) == true then
				out[name] = true
			end
		end
	end
	local build = Env.value(env, doc.buildInfo)
	local version = if type(build) == "table" then Env.value(env, build.version) else nil
	local major = M.major(if type(version) == "string" then version else nil)
	if major then
		for name, since in GA_FEATURES do
			if major >= since then
				out[name] = true
			end
		end
	end
	return out
end

-- Grafana's frontend reads its OpenFeature flags from the server's OFREP
-- endpoint (@grafana/runtime initOpenFeature: OFREPWebProvider at the app
-- root, context `targetingKey` = the namespace plus `openFeatureContext`).
-- The flags the native panels follow; Grafana 12 and older have none of
-- them (12 answers the endpoint with its index page).
M.OPEN_FEATURE_FLAGS = { "table.autoColumnWidths" }
M.OPEN_FEATURE_SINCE = 13

-- The OFREP evaluation of `flag` as the frontend asks for it, or nil when
-- the server predates the flags or names no OpenFeature context.
function M.flagRequest(response: TransportTypes.Response, flag: string, env: Env): Request?
	local doc = Response.json(response, env, "frontend settings")
	if type(doc) ~= "table" then
		return nil
	end
	local build = Env.value(env, doc.buildInfo)
	local version = if type(build) == "table" then Env.value(env, build.version) else nil
	local major = M.major(if type(version) == "string" then version else nil)
	local ctx = Env.value(env, doc.openFeatureContext)
	if major == nil or major < M.OPEN_FEATURE_SINCE or type(ctx) ~= "table" then
		return nil
	end
	local context = Tbl.copy(ctx)
	local namespace = Env.value(env, doc.namespace)
	context.targetingKey = if type(namespace) == "string" then namespace else context.namespace
	return {
		method = "POST",
		path = "/ofrep/v1/evaluate/flags/" .. flag,
		headers = { ["Content-Type"] = "application/json" },
		body = env.encode({ context = context }),
	}
end

-- Whether an OFREP evaluation answered true; anything else (an error, a
-- page that is not JSON, a disabled flag) leaves the flag off, as the
-- frontend's default value does.
function M.flagOn(response: TransportTypes.Response, env: Env): boolean
	local doc = Response.json(response, env, "feature flag")
	return type(doc) == "table" and Env.value(env, doc.value) == true
end

-- The major version of a Grafana version string ("12.4.0" -> 12).
function M.major(version: string?): number?
	return tonumber(if version then string.match(version, "^(%d+)%.") else nil)
end

return M
