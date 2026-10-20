--!strict
-- Per-panel data: every target of a panel in one `/api/ds/query` body, the
-- way Grafana's frontend sends a panel's queries (mixed datasources
-- included), and the answer back as frames per panel.
--
-- Datasources: a target's own datasource wins over the panel's; `-- Mixed --`
-- means "per target"; `${ds}` resolves through the variables; a missing
-- reference is the instance default; a bare string is a legacy name or uid.
--
-- Which datasources run natively (`resolve`): Prometheus, Loki and TestData
-- as before; Tempo for the panels that draw its frames; and every other
-- backend datasource plugin (frontend settings `meta.backend`, else a known
-- list) through the generic path below. Frontend-only plugins, and backend
-- ones whose frontends query or post-process in the browser (CLIENT_SIDE,
-- and the per-target rules of targetBlocker), keep a precise reason.
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
-- (Tern blocks have no pane width to derive it from); the interval is
-- Grafana's calculateInterval with the target's or panel's min interval, and
-- becomes `$__interval`/`$__interval_ms`. `$__rate_interval` is left to
-- Grafana's backend, which knows the datasource's scrape interval.
--
-- Exemplars: time series panels ask Prometheus range targets for exemplars
-- when config `query.exemplars` is on (and never when it is off, whatever the
-- target says); the exemplar frames come back apart from the series frames.

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
	["grafana-incident-datasource"] = true,
})

-- Backend plugins whose frontends query or post-process in the browser in
-- ways /api/ds/query cannot reproduce.
M.CLIENT_SIDE = table.freeze({
	-- alexanderzobnin-zabbix-app datasource module: only metric targets go to
	-- the backend, then Alias functions run in the browser; problems, text,
	-- IT service and direct DB queries run in the browser.
	["alexanderzobnin-zabbix-datasource"] = "Zabbix queries are post-processed in the browser",
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

-- manage_alerts: the data source manages alert rules (Grafana's
-- isDataSourceManagingAlerts: jsonData.manageAlerts, else the
-- defaultDatasourceManageAlertsUiToggle of Grafana 12, else true).
-- backend: the plugin has a backend (frontend settings meta.backend).
export type Datasource = {
	uid: string,
	type: string,
	name: string,
	is_default: boolean,
	manage_alerts: boolean?,
	backend: boolean?,
}

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
}

export type PanelQuery = {
	queries: { { [string]: any } },
	-- The refIds whose results the panel shows (hidden ones are not).
	ref_ids: { string },
	interval_ms: number,
	max_points: number,
}

export type PanelData = {
	frames: { Frame },
	-- "A: parse error ..." per failed target.
	errors: { string },
	warnings: { string },
	-- Exemplars of time series targets, sorted by time.
	exemplars: { FrameProm.Exemplar }?,
}

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

-- Variables of `scope` that `text` references.
local function referencesScope(text: string, scope: Scope): boolean
	for _, name in Interpolate.references(text) do
		if scope[name] then
			return true
		end
	end
	return false
end

-- Rules for one target of a supported datasource.
local function targetBlocker(ref: DsRef, t: { [string]: any }, scope: Scope, env: Env): string?
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
	elseif kind == "grafana-incident-datasource" then
		-- Its interpolateVariable writes `label:'..'`/`severity:'..'` filters
		-- by variable query type and drops "All" in the browser.
		local q = str(env, t.queryString)
		if q and referencesScope(q, scope) then
			return "Grafana Incident formats query variables in the browser"
		end
	end
	return nil
end

-- The datasource of each target Grafana sends, or why the panel cannot be
-- queried natively. Panels without targets (text) need no query. A
-- `-- Dashboard --` panel resolves to that one reference.
function M.resolve(panel: { [string]: any }, scope: Scope, list: { Datasource }, env: Env): ({ DsRef }?, string?)
	local ts = targets(panel, env)
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
		local blocker = typeBlocker(ref, list, panelType) or targetBlocker(ref, t, scope, env)
		if blocker then
			return nil, blocker
		end
		table.insert(out, ref)
	end
	return out, nil
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
local function shape(ref: DsRef, t: { [string]: any }, scope: Scope, expr: boolean, env: Env): { [string]: any }
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
		q.expr = Interpolate.replace(promExpr, scope, fmt)
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

-- The /api/ds/query objects for a panel; nil when it has nothing to query
-- (a `-- Dashboard --` panel gets its frames from the source panel).
function M.build(panel: { [string]: any }, ctx: Context, env: Env): (PanelQuery?, string?)
	local refs, err = M.resolve(panel, ctx.scope, ctx.datasources, env)
	if refs == nil then
		return nil, err
	end
	local ts, expr = targets(panel, env)
	if #ts == 0 or (refs[1] and refs[1].uid == M.DASHBOARD) then
		return nil, nil
	end
	local mdp = Env.value(env, panel.maxDataPoints)
	local maxPoints = if type(mdp) == "number" and mdp > 0 then mdp else ctx.max_points
	local panelMin = minInterval(str(env, panel.interval), ctx.scope)
	local range_ms = math.max(1, ctx.to_ms - ctx.from_ms)
	local timeseries = str(env, panel.type) == "timeseries"
	local queries: { { [string]: any } } = {}
	local refIds: { string } = {}
	local smallest: number? = nil
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
		local q = shape(ref, t, scope, expr, env)
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
	end
	if #queries == 0 then
		return nil, nil
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
	if data.exemplars then
		FrameProm.sortExemplars(data.exemplars :: { FrameProm.Exemplar })
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
			table.insert(out, {
				uid = uid,
				type = typ,
				name = str(env, ds.name) or name,
				is_default = Env.value(env, ds.isDefault) == true or name == defaultName,
				manage_alerts = manage,
				backend = if type(backend) == "boolean" then backend else nil,
			})
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

-- Grafana's frontend feature toggles (`featureToggles`), the ones on.
function M.frontendFeatures(response: TransportTypes.Response, env: Env): { [string]: boolean }
	local doc = Response.json(response, env, "frontend settings")
	local out: { [string]: boolean } = {}
	local map = if type(doc) == "table" then Env.value(env, doc.featureToggles) else nil
	if type(map) == "table" then
		for name, on in map do
			if type(name) == "string" and Env.value(env, on) == true then
				out[name] = true
			end
		end
	end
	return out
end

return M
