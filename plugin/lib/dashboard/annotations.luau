--!strict
-- A dashboard's annotation layers (`annotations.list`), as Grafana 13's
-- dashboard scene runs them for its panels (@grafana/scenes 9
-- AnnotationsDataLayer, standardAnnotationQuery executeAnnotationQuery,
-- layers/annotations/utils.ts postProcessQueryResult, filterAnnotations.ts;
-- the datasources' annotation support):
--
-- - enabled layers only, over the dashboard's range;
-- - Grafana's built-in "Annotations & Alerts" and other `-- Grafana --`
--   layers of type dashboard (public/app/plugins/datasource/grafana/
--   datasource.ts getAnnotations): `GET /api/annotations` with from, to,
--   limit (default 100), matchAny and the dashboard uid. Its answer holds
--   the dashboard's annotations and the alert state history Grafana writes
--   for rules linked to its panels (`__dashboardUid__`/`__panelId__`);
-- - Prometheus layers (@grafana/prometheus annotations.ts): the layer's
--   expression as one /api/ds/query target "Anno" with the layer's step as
--   its interval; every series' samples above 0 become events, merged into
--   one region while they are at most the query step apart (the step read
--   from the answer's executedQueryString, default 60s);
-- - colors: the layer's iconColor, except alert state changes by their new
--   state: pending yellow, alerting red, ok/normal green, no_data/nodata
--   gray (other states, "Normal (NoData)" or "Recovering", keep iconColor);
--   an event is a region when it ends at another time than it starts;
-- - per panel: an annotation of a dashboard-type layer shows on its own
--   panel or, with panel id 0, on every panel (one without a panel id: see
--   M.shows); a layer's filter shows it only on (or, exclude, everywhere
--   but) the listed panel ids.
--
-- Other layer types (tags, time regions, other datasources) are not run.

local Env = require("../env")
local Frame = require("../frame/types")
local Json = require("../panels/json")
local Response = require("../source/response")
local SvgAnnotations = require("../render/svg_annotations")
local Tbl = require("../tbl")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Mark = SvgAnnotations.Mark

local M = {}

export type Filter = { exclude: boolean, ids: { number } }

export type Def = {
	name: string,
	kind: "dashboard" | "prometheus",
	icon_color: string,
	filter: Filter?,
	-- dashboard: GET /api/annotations parameters.
	limit: number,
	match_any: boolean,
	-- prometheus: a panel with the layer's one target, for the dashboard's
	-- query builder (lib/dashboard/queries), and useValueForTime.
	panel: { [string]: any }?,
	use_value_for_time: boolean,
}

export type Event = {
	time_ms: number,
	end_ms: number?,
	color: string,
	-- dashboard layers: the panel the annotation belongs to (0: all).
	panel_id: number?,
}

M.PATH = "/api/annotations"
M.DEFAULT_LIMIT = 100
M.DEFAULT_STEP_MS = 60000
M.GRAFANA_UID = "-- Grafana --"

local STATE_COLORS: { [string]: string } = {
	pending = "yellow",
	alerting = "red",
	ok = "green",
	normal = "green",
	no_data = "gray",
	nodata = "gray",
}

local function grafanaDatasource(env: Env, a: { [any]: any }): boolean
	local ds = Env.value(env, a.datasource)
	if ds == nil then
		return Json.num(env, a.builtIn) == 1
	elseif type(ds) == "string" then
		return ds == M.GRAFANA_UID or ds == "grafana"
	elseif type(ds) == "table" then
		return Json.str(env, ds.uid) == M.GRAFANA_UID or Json.str(env, ds.type) == "grafana"
	end
	return false
end

local function prometheusDatasource(env: Env, a: { [any]: any }): boolean
	local ds = Env.value(env, a.datasource)
	return type(ds) == "table" and Json.str(env, ds.type) == "prometheus"
end

local function filterOf(env: Env, a: { [any]: any }): Filter?
	local f = Json.tbl(env, a.filter)
	if f == nil then
		return nil
	end
	local ids: { number } = {}
	for _, id in Json.list(env, f.ids) do
		local n = Json.num(env, id)
		if n then
			table.insert(ids, n)
		end
	end
	return { exclude = Json.bool(env, f.exclude) == true, ids = ids }
end

-- DashboardModel.addBuiltInAnnotationQuery: the built-in layer a dashboard
-- without one gets.
M.BUILT_IN = table.freeze({
	datasource = table.freeze({ uid = M.GRAFANA_UID, type = "grafana" }),
	name = "Annotations & Alerts",
	type = "dashboard",
	iconColor = SvgAnnotations.DEFAULT_COLOR,
	enable = true,
	hide = true,
	builtIn = 1,
})

-- The enabled layers this module runs, in dashboard order (a layer is on
-- only with `enable` true: transformSaveModelToScene isEnabled).
function M.defs(list: { any }, env: Env): { Def }
	local all: { any } = {}
	for _, raw in list do
		local a = Json.tbl(env, raw)
		if a and Json.num(env, a.builtIn) == 1 then
			all = list
			break
		end
	end
	if all ~= list then
		table.insert(all, M.BUILT_IN)
		table.move(list, 1, #list, 2, all)
	end
	local out: { Def } = {}
	for _, raw in all do
		local a = Json.tbl(env, raw)
		if a == nil or Json.bool(env, a.enable) ~= true then
			continue
		end
		local target = Json.obj(env, a.target)
		local def: Def = {
			name = Json.str(env, a.name) or "",
			kind = "dashboard",
			icon_color = Json.str(env, a.iconColor) or SvgAnnotations.DEFAULT_COLOR,
			filter = filterOf(env, a),
			limit = Json.num(env, target.limit) or Json.num(env, a.limit) or M.DEFAULT_LIMIT,
			match_any = (Json.bool(env, target.matchAny) or Json.bool(env, a.matchAny)) == true,
			panel = nil,
			use_value_for_time = Json.bool(env, a.useValueForTime) == true,
		}
		if grafanaDatasource(env, a) then
			-- GrafanaDatasource prepareAnnotation: a layer without a target
			-- gets one of its own type (default dashboard); a target without
			-- a type asks for tags.
			local kind = if Json.tbl(env, a.target)
				then Json.str(env, target.type)
				else (Json.str(env, a.type) or "dashboard")
			if kind ~= "dashboard" then
				continue
			end
		elseif prometheusDatasource(env, a) then
			-- PrometheusAnnotationSupport prepareAnnotation; the query runs as
			-- refId "Anno" (executeAnnotationQuery).
			local t = Tbl.copy(target)
			t.refId = "Anno"
			t.expr = Json.str(env, target.expr) or Json.str(env, a.expr) or ""
			t.interval = Json.str(env, target.interval) or Json.str(env, a.step) or ""
			t.datasource = a.datasource
			def.kind = "prometheus"
			def.panel = { type = "annotations", datasource = a.datasource, targets = { t } }
		else
			continue
		end
		table.insert(out, def)
	end
	return out
end

-- GrafanaDatasource.getAnnotations for a dashboard-type layer.
function M.request(def: Def, dashboardUid: string, from_ms: number, to_ms: number): TransportTypes.Request
	return {
		method = "GET",
		path = M.PATH,
		query = {
			{ "from", string.format("%d", from_ms) },
			{ "to", string.format("%d", to_ms) },
			{ "limit", string.format("%d", def.limit) },
			{ "matchAny", if def.match_any then "true" else "false" },
			{ "dashboardUID", dashboardUid },
		},
	}
end

-- postProcessQueryResult's color.
function M.color(def: Def, newState: string?): string
	return (if newState then STATE_COLORS[string.lower(newState)] else nil) or def.icon_color
end

-- A dashboard-type layer's `/api/annotations` answer as events; nil and the
-- error message when the request failed.
function M.parse(def: Def, response: TransportTypes.Response, env: Env): ({ Event }?, string?)
	local doc, err = Response.json(response, env, "annotations")
	if err or doc == nil then
		return nil, if err then err.message else "annotations: no response"
	end
	local out: { Event } = {}
	for _, raw in Json.list(env, doc) do
		local a = Json.tbl(env, raw)
		local t = if a then Json.num(env, a.time) else nil
		if a == nil or t == nil then
			continue
		end
		local stop = Json.num(env, a.timeEnd)
		table.insert(out, {
			time_ms = t,
			end_ms = if stop and stop ~= 0 and stop ~= t then stop else nil,
			color = M.color(def, Json.str(env, a.newState)),
			panel_id = Json.num(env, a.panelId),
		})
	end
	return out, nil
end

-- rangeUtil.intervalToSeconds of the first `<count><unit>` in `text` (the
-- regex is unanchored, so "1m0s" reads 1m), in ms.
local UNIT_MS: { [string]: number } =
	{ y = 31536000000, M = 2592000000, w = 604800000, d = 86400000, h = 3600000, m = 60000, s = 1000, ms = 1 }

function M.stepMs(executed: string?): number
	local step = if executed then string.match(executed, "Step:%s*([%w]+)") else nil
	if step == nil then
		return M.DEFAULT_STEP_MS
	end
	if tonumber(step) then
		return math.floor(tonumber(step) :: number) * 1000
	end
	for i = 1, #step do
		local count = string.match(step, "^%-?%d+", i)
		if count then
			local rest = string.sub(step, i + #count)
			local unit = if string.sub(rest, 1, 2) == "ms" then "ms" else string.sub(rest, 1, 1)
			if UNIT_MS[unit] then
				return (tonumber(count) :: number) * UNIT_MS[unit]
			end
		end
	end
	return M.DEFAULT_STEP_MS
end

local function sampleNumber(v: any): number?
	if type(v) == "number" then
		return if v == v then v else nil
	elseif type(v) == "string" then
		local n = tonumber(v)
		return if n and n == n then n else nil
	end
	return nil
end

-- PrometheusAnnotationSupport.processEvents over the layer's frames.
function M.promEvents(def: Def, frames: { Frame.Frame }): { Event }
	local out: { Event } = {}
	if #frames == 0 then
		return out
	end
	local meta = frames[1].meta
	local step = M.stepMs(if meta then meta.executedQueryString else nil)
	for _, f in frames do
		local tf, vf = f.fields[1], f.fields[2]
		if tf == nil or vf == nil then
			continue
		end
		local active: { number } = {}
		for i, raw in vf.values do
			local t: number?, v: number?
			if def.use_value_for_time then
				local n = sampleNumber(raw)
				t, v = if n then math.floor(n) else nil, 1
			else
				local n = sampleNumber(tf.values[i])
				t, v = if n then math.floor(n) else nil, sampleNumber(raw)
			end
			if t and v and v > 0 then
				table.insert(active, t)
			end
		end
		local open: Event? = nil
		local function close()
			local e = open :: Event
			local stop = e.end_ms :: number
			e.end_ms = if stop ~= e.time_ms then stop else nil
			table.insert(out, e)
		end
		for _, t in active do
			if open and (open.end_ms :: number) + step >= t then
				open.end_ms = t
				continue
			end
			if open then
				close()
			end
			open = { time_ms = t, end_ms = t, color = def.icon_color }
		end
		if open then
			close()
		end
	end
	return out
end

-- filterAnnotations for one panel: is the event of layer `def` shown on it?
-- `panelField`: the layer's frame has a panelId field, i.e. one of its
-- events has a panel id (getAnnotationsFromData drops null values, so on
-- Grafana 12 and 13, which answer null for a dashboard-wide annotation,
-- such an annotation shows on no panel once another one has a panel id;
-- Grafana 11 answers 0, shown on every panel).
function M.shows(def: Def, e: Event, panelId: number, panelField: boolean): boolean
	if def.kind == "dashboard" and panelField and e.panel_id ~= panelId and e.panel_id ~= 0 then
		return false
	end
	local f = def.filter
	if f then
		local listed = table.find(f.ids, panelId) ~= nil
		if f.exclude == listed then
			return false
		end
	end
	return true
end

-- The marks a panel draws from the answered layers (in layer order; nil
-- events: not answered). Lanes count the layers with an event shown here.
function M.marks(layers: { { def: Def, events: { Event }? } }, panelId: number): { Mark }
	local out: { Mark } = {}
	local lane = 0
	for _, l in layers do
		local events: { Event } = l.events or {}
		local panelField = false
		for _, e in events do
			if e.panel_id ~= nil then
				panelField = true
				break
			end
		end
		local any = false
		for _, e in events do
			if M.shows(l.def, e, panelId, panelField) then
				table.insert(out, { time_ms = e.time_ms, end_ms = e.end_ms, color = e.color, lane = lane })
				any = true
			end
		end
		if any then
			lane += 1
		end
	end
	return out
end

return M
