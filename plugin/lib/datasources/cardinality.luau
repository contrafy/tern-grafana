--!strict
-- Grafana Cloud cardinality management (grafanacloud-cardinality-datasource,
-- ported from its 2.6.1 frontend bundle; a frontend-only plugin). Every
-- target asks the TARGET Prometheus datasource's proxy for Mimir's
-- cardinality API, plus the plugin's own proxy (`/unused`,
-- `/usages/<metric>`) and Grafana's API for usage titles, then builds the
-- frames in the browser. Tern makes the same requests and the same frames.
--
-- A target: cardinalityType (metrics, labels, pairs, series; default
-- metrics), resultType (top, total, subtotal, details, list, usage; default
-- top), targetDatasource (interpolated, a Prometheus datasource by uid or
-- name), parameterList (each interpolated, empty ones dropped), selector,
-- limit, exampleCount. Hidden targets are not queried (filterQuery).
--
-- Selector items (selectorItems): the `${filter}` ad hoc variable's value
-- split at "," with `\\` escapes undone (nothing when it does not
-- interpolate), then the target's selector with one pair of braces and the
-- surrounding blanks stripped (a selector that is only braces stays as is),
-- interpolated; empty items dropped. Requests carry `{<items joined by ,>}`;
-- details and the series subtotal put `__name__='<metric>'` first.
--
-- Requests (`Le`): query parameters sorted by key, arrays as `name[]`,
-- absent values omitted, under the target's proxy path:
-- - label_values {count_method: active, label_names[], limit, selector},
--   label_names {count_method: active, limit, selector} (a 404 means the
--   target is no Mimir: "does not support Cardinality management");
-- - lists: api/v1/label/__name__/values and api/v1/labels with limit 200 and
--   start/end = now-2h..now, each rounded up to 900 s.
-- What runs is the bundle's control flow (getTargetDataFrame), including its
-- fall-throughs: list falls into details for pairs and series, and every
-- combination nothing claims (top/total and the rest) ends in the bottom
-- switch, which queries by cardinality type and builds totals or top
-- tables, else an empty "unsupported" frame.
--
-- The plugin's own proxy serves usage data when its jsonData.unusedMetrics
-- has proxyType "insights" and the target's uid is metricsDataSourceUid:
-- metrics top adds a "Used" column from `/unused` (no column when that fails
-- or holds no map; a 204 adds it empty with "pending"); usage reads
-- `/usages/<metric>` (404: "No data found for stack"; other failures: no
-- frame; unconfigured: "Usage data only available ..."), then each
-- dashboard's title (`/api/dashboards/uid/<uid>`) and each Grafana rule's
-- "<group> / <title>" (`/api/v1/provisioning/alert-rules/<uid>`), "" for a
-- 404 and empty for other failures.
--
-- query() awaits the targets in order, so the panel fails with the first
-- failing target's error. Query variables (metricFindQuery) run the same
-- query and list the first string field's values (else the first field's).
--
-- Not ported: the bundle's per-datasource request queue and 15 minute
-- response cache (Tern asks each step's distinct requests at once), and the
-- OpenFeature flag datasources.cardinalityApiServerProxy (default off) that
-- moves both proxies under /apis/...: Tern uses the classic proxy paths.

local Env = require("../env")
local Frame = require("../frame/types")
local Interpolate = require("../dashboard/interpolate")
local Response = require("../source/response")
local TransportTypes = require("../transport/types")
local Types = require("./types")
local Url = require("../url")

type Env = Env.Env
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type Scope = Interpolate.Scope

local M = {}

M.TYPE = "grafanacloud-cardinality-datasource"

M.NO_TARGET = "No target data source has been selected."
M.USAGE_UNAVAILABLE = "Usage data only available for the metric instance of this stack"
M.NO_USAGE = "No data found for stack"

local COUNT_METHOD = "active"
local LIST_LIMIT = "200"
local LIST_WINDOW_S = 7200
local LIST_ROUND_S = 900
local PROXY = "/api/datasources/proxy/uid/"

-- The percentage column of the top tables (Vt): a gradient gauge cell.
local function percentageField(displayName: string, values: { any }): Frame.Field
	return Frame.field("percentage", "number", values, nil, {
		custom = { displayMode = "gradient-gauge" },
		displayName = displayName,
		max = 100,
		min = 0,
		thresholds = {
			mode = "percentage",
			steps = { { color = "blue", value = 0 }, { color = "yellow", value = 30 } },
		},
		unit = "percent",
	})
end

-- Helpers -------------------------------------------------------------------

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

-- JavaScript truthiness of a decoded JSON value.
local function truthy(env: Env, v: any): boolean
	v = Env.value(env, v)
	return v ~= nil and v ~= false and v ~= 0 and v ~= "" and v == v
end

-- JavaScript's String(v) for a query parameter value.
local function jsString(v: any): string
	if type(v) == "number" then
		return if v == math.floor(v) and math.abs(v) < 2 ^ 53 then string.format("%d", v) else tostring(v)
	end
	return tostring(v)
end

local function num(env: Env, v: any): any
	v = Env.value(env, v)
	return if type(v) == "number" then v else Frame.NULL
end

local function list(env: Env, v: any): { any }
	v = Env.value(env, v)
	return if type(v) == "table" then v else {}
end

local function findDs(datasources: { Types.Datasource }, key: string): Types.Datasource?
	for _, ds in datasources do
		if ds.uid == key then
			return ds
		end
	end
	for _, ds in datasources do
		if ds.name == key then
			return ds
		end
	end
	return nil
end

local function defaultDs(datasources: { Types.Datasource }): Types.Datasource?
	for _, ds in datasources do
		if ds.is_default then
			return ds
		end
	end
	return nil
end

-- Le: sorted parameters (a stable sort by key), arrays as `name[]`.
local function params(entries: { { any } }, env: Env): { { string } }
	local out: { { string } } = {}
	for _, e in entries do
		local k, v = e[1] :: string, Env.value(env, e[2])
		if v == nil then
			continue
		elseif type(v) == "table" then
			for _, item in v :: { any } do
				table.insert(out, { k .. "[]", jsString(item) })
			end
		else
			table.insert(out, { k, jsString(v) })
		end
	end
	local order: { [{ string }]: number } = {}
	for i, p in out do
		order[p] = i
	end
	table.sort(out, function(a, b)
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		return order[a] < order[b]
	end)
	return out
end

local function get(path: string, query: { { string } }?): Request
	return { method = "GET", path = path, query = query }
end

-- The answer's JSON document, or the error Grafana's backendSrv reports.
local function decoded(response: Response?, env: Env, what: string): (any, string?)
	if response == nil then
		return nil, "the datasource did not answer"
	end
	local doc, err = Response.json(response, env, what)
	if err then
		return nil, err.message
	end
	return doc, nil
end

local function ok(response: Response?): boolean
	return response ~= nil and response.failure == nil and response.status >= 200 and response.status < 300
end

-- Selectors -------------------------------------------------------------------

-- selectorItems: the ad hoc filters, then the target's selector.
local function selectorItems(selector: string, scope: Scope): { string }
	local items: { string } = {}
	local filter = Interpolate.replace("${filter}", scope)
	if filter ~= "${filter}" then
		for _, part in string.split(filter, ",") do
			table.insert(items, (string.gsub(part, "\\\\([%.%*%+%?%^%${}%(%)|%[%]\\])", "%1")))
		end
	end
	local inner = string.match(selector, "^%s*{?%s*(.-)%s*}?%s*$")
	table.insert(items, Interpolate.replace(if inner and inner ~= "" then inner else selector, scope))
	local out: { string } = {}
	for _, item in items do
		if item ~= "" then
			table.insert(out, item)
		end
	end
	return out
end

local function braces(items: { string }): string
	return "{" .. table.concat(items, ",") .. "}"
end

-- Frames ----------------------------------------------------------------------

-- Yt: one field, one row.
local function total(name: string, value: any, refId: string): Frame.Frame
	return { refId = refId, fields = { Frame.field(name, "number", { value }) } }
end

local function labelEntry(env: Env, doc: any, name: string): any
	for _, l in list(env, doc.labels) do
		if type(l) == "table" and l.label_name == name then
			return l
		end
	end
	return nil
end

-- Kt: metrics by series count, with a Used column when `unused` is a set.
local function metricsTop(env: Env, doc: any, unused: { [string]: boolean }?, refId: string): Frame.Frame
	local names, counts, pcts, used = {}, {}, {}, {}
	local entry = labelEntry(env, doc, "__name__")
	local totalSeries = Env.value(env, doc.series_count_total)
	if entry then
		for _, c in list(env, entry.cardinality) do
			local name = str(env, c.label_value)
			local count = num(env, c.series_count)
			table.insert(names, if name then name else Frame.NULL)
			table.insert(counts, count)
			table.insert(
				pcts,
				if type(count) == "number" and type(totalSeries) == "number"
					then count / totalSeries * 100
					else Frame.NULL
			)
			table.insert(used, not (unused ~= nil and name ~= nil and unused[name] == true))
		end
	end
	local fields = {
		Frame.field("value", "string", names, nil, { displayName = "Metric" }),
		Frame.field("count", "number", counts, nil, { displayName = "Number of series" }),
		percentageField("Percentage of total series", pcts),
	}
	if unused then
		table.insert(fields, Frame.field("used", "boolean", used, nil, { displayName = "Used" }))
	end
	return { refId = refId, fields = fields }
end

-- Labels top: label names by their number of values.
local function labelsTop(env: Env, doc: any, refId: string): Frame.Frame
	local labels, counts, pcts = {}, {}, {}
	local totalValues = Env.value(env, doc.label_values_count_total)
	for _, c in list(env, doc.cardinality) do
		local count = num(env, c.label_values_count)
		table.insert(labels, str(env, c.label_name) or Frame.NULL)
		table.insert(counts, count)
		table.insert(
			pcts,
			if type(count) == "number" and type(totalValues) == "number" then count / totalValues * 100 else Frame.NULL
		)
	end
	return {
		refId = refId,
		fields = {
			Frame.field("label", "string", labels, nil, { displayName = "Label" }),
			Frame.field("count", "number", counts, nil, { displayName = "Number of unique values" }),
			percentageField("Percentage of total unique values", pcts),
		},
	}
end

-- Mt: a metric's labels by number of values, with example values.
local function metricDetails(env: Env, names: any, examples: any?, refId: string): Frame.Frame
	local byLabel: { [string]: { string } } = {}
	local hasExamples = false
	if examples then
		for _, l in list(env, examples.labels) do
			local values: { string } = {}
			for _, c in list(env, l.cardinality) do
				table.insert(values, str(env, c.label_value) or "")
			end
			local name = str(env, l.label_name)
			if name then
				byLabel[name] = values
				hasExamples = true
			end
		end
	end
	local labels, counts, ex = {}, {}, {}
	for _, c in list(env, names.cardinality) do
		local name = str(env, c.label_name)
		table.insert(labels, name or Frame.NULL)
		table.insert(counts, num(env, c.label_values_count))
		table.insert(ex, if name and byLabel[name] then byLabel[name] else Frame.NULL)
	end
	local fields = {
		Frame.field("label", "string", labels, nil, { displayName = "Label" }),
		Frame.field("count", "number", counts, nil, { displayName = "Number of values" }),
	}
	if hasExamples then
		table.insert(fields, Frame.field("examples", "other", ex, nil, { displayName = "Example label values" }))
	end
	return { refId = refId, fields = fields }
end

-- Ht: label values by series count (metric names are prefixed with
-- "__name__: " only among other labels).
local function valueCounts(env: Env, doc: any, labelNames: { string }, refId: string): Frame.Frame
	local labels = list(env, doc.labels)
	local values, counts = {}, {}
	for _, l in labels do
		local prefix = if l.label_name ~= "__name__" or #labels == 1 then "" else "__name__: "
		for _, c in list(env, l.cardinality) do
			local v = Env.value(env, c.label_value)
			table.insert(values, prefix .. (if v == nil then "undefined" else tostring(v)))
			table.insert(counts, num(env, c.series_count))
		end
	end
	local first = labelNames[1]
	return {
		refId = refId,
		fields = {
			Frame.field("value", "string", values, nil, {
				displayName = if first == "__name__" then "Metric" else first or "undefined",
			}),
			Frame.field("count", "number", counts, nil, { displayName = "Count of series" }),
		},
	}
end

-- Labels subtotal: each label's number of values and share of series.
local function labelSubtotal(env: Env, doc: any, refId: string): Frame.Frame
	local labels, subtotals, pcts = {}, {}, {}
	local totalSeries = Env.value(env, doc.series_count_total)
	for _, l in list(env, doc.labels) do
		local series = Env.value(env, l.series_count)
		table.insert(labels, str(env, l.label_name) or Frame.NULL)
		table.insert(
			pcts,
			if type(series) == "number" and type(totalSeries) == "number"
				then series / totalSeries * 100
				else Frame.NULL
		)
		table.insert(subtotals, num(env, l.label_values_count))
	end
	return {
		refId = refId,
		fields = {
			Frame.field("label", "string", labels, nil, { displayName = "Label" }),
			Frame.field("subtotal", "number", subtotals, nil, { displayName = "Subtotal" }),
			Frame.field(
				"percent",
				"number",
				pcts,
				nil,
				{ decimals = 1, displayName = "Percent of series", unit = "%" }
			),
		},
	}
end

-- Ut: a list variable's values.
local function values(env: Env, doc: any, refId: string): Frame.Frame
	local out = {}
	for _, v in list(env, doc.data) do
		table.insert(out, if type(v) == "string" then v else Frame.NULL)
	end
	return { refId = refId, fields = { Frame.field("value", "string", out) } }
end

local USAGE_FIELDS: { { string } } = {
	{ "dashboardUid", "Dashboard UID", "string" },
	{ "dashboardTitle", "Dashboard", "string" },
	{ "grafanaruleUid", "Grafana rule UID", "string" },
	{ "grafanaruleTitle", "Grafana rule", "string" },
	{ "rule", "Mimir Rule count", "number" },
	{ "time", "Time", "time" },
	{ "querycount", "Query count", "number" },
}

-- The usage table: dashboard rows, Grafana rule rows, one row per query log
-- interval (time = the interval's end), then the Mimir rule count.
local function usageFrame(
	env: Env,
	usage: any,
	titles: { [string]: any },
	rules: { [string]: any },
	refId: string
): Frame.Frame
	local rows: { { [string]: any } } = {}
	for _, uid in list(env, usage.dashboards) do
		table.insert(rows, { dashboardUid = uid, dashboardTitle = titles[uid] })
	end
	for _, uid in list(env, usage.grafana_rules) do
		table.insert(rows, { grafanaruleUid = uid, grafanaruleTitle = rules[uid] })
	end
	local logs = Env.value(env, usage.query_logs)
	if type(logs) == "table" then
		for _, i in list(env, logs.intervals) do
			local interval = str(env, i.interval) or ""
			local finish = tonumber(string.split(interval, "-")[2] or "")
			table.insert(rows, { querycount = num(env, i.count), time = if finish then finish * 1000 else nil })
		end
	end
	local mimir = Env.value(env, usage.mimir_rules)
	if mimir ~= nil then
		table.insert(rows, { rule = mimir })
	end
	local fields: { Frame.Field } = {}
	for _, spec in USAGE_FIELDS do
		local name = spec[1]
		local column = table.create(#rows)
		for r, row in rows do
			local v = row[name]
			column[r] = if v == nil then Frame.NULL else v
		end
		table.insert(fields, Frame.field(name, spec[3] :: any, column, nil, { displayName = spec[2] }))
	end
	return { refId = refId, fields = fields }
end

local function emptyFrame(refId: string?): Frame.Frame
	return { refId = refId, fields = {} }
end

-- Tasks -------------------------------------------------------------------------
-- One target's progress: the requests it waits for (by name), then the
-- next phase or its result.

type Task = {
	ref_id: string,
	phase: string,
	wait: { [string]: Request },
	-- The tag each waited-for request was asked under.
	tags: { [string]: string },
	frame: Frame.Frame?,
	error: string?,
	-- false: the target ended without a frame (a failed usage lookup).
	has_frame: boolean,
	done: boolean,
	-- Phase data.
	cardinality_type: string,
	result_type: string,
	target_name: string,
	base: string,
	names: { string },
	names_doc: any,
	usage: any,
	unused: boolean,
}

type Setup = {
	ds: Types.Datasource,
	now_ms: number,
}

local function finish(task: Task, frame: Frame.Frame?)
	task.done = true
	task.frame = frame
	task.has_frame = frame ~= nil
	task.wait = {}
end

local function fail(task: Task, message: string)
	task.done = true
	task.error = message
	task.wait = {}
end

-- Ve: the target Prometheus datasource, or why it cannot be queried.
local function target(name: string?, datasources: { Types.Datasource }): (Types.Datasource?, string?)
	if name == nil or name == "" then
		return nil, M.NO_TARGET
	end
	local ds = if name == "default" then defaultDs(datasources) else findDs(datasources, name)
	if ds == nil then
		return nil, string.format('The target data source "%s" could not be found.', name)
	end
	if ds.type ~= "prometheus" then
		return nil, string.format('The target data source "%s" is not compatible.', ds.type)
	end
	if ds.url == nil or ds.url == "" then
		return nil, string.format('The target data source "%s" does not have a URL.', ds.name)
	end
	return ds, nil
end

-- Browser (direct) access: the browser fetches the server itself.
local function direct(ds: Types.Datasource): boolean
	return string.sub(ds.url or "", 1, 1) ~= "/"
end

local function directReason(ds: Types.Datasource): string
	return string.format(
		'the cardinality target data source "%s" uses browser (direct) access, which only the browser can reach',
		ds.name
	)
end

local function labelValues(task: Task, env: Env, names: { string }, selector: string, limit: any): Request
	return get(
		task.base .. "/api/v1/cardinality/label_values",
		params({
			{ "count_method", COUNT_METHOD },
			{ "label_names", names },
			{ "limit", limit },
			{ "selector", selector },
		}, env)
	)
end

local function labelNames(task: Task, env: Env, selector: string, limit: any): Request
	return get(
		task.base .. "/api/v1/cardinality/label_names",
		params({ { "count_method", COUNT_METHOD }, { "limit", limit }, { "selector", selector } }, env)
	)
end

-- Ye: now-2h..now in seconds, each rounded up to 900 s.
local function listRange(now_ms: number): (number, number)
	local now = math.floor(now_ms / 1000)
	local from = math.floor((now_ms - LIST_WINDOW_S * 1000) / 1000)
	return LIST_ROUND_S * math.ceil(from / LIST_ROUND_S), LIST_ROUND_S * math.ceil(now / LIST_ROUND_S)
end

-- The plugin's own proxy, when it serves usage data for this target.
local function usageBase(setup: Setup, targetDs: Types.Datasource, env: Env): string?
	local jsonData = setup.ds.json_data
	local cfg = if jsonData then Env.value(env, jsonData.unusedMetrics) else nil
	if type(cfg) ~= "table" or str(env, cfg.proxyType) ~= "insights" then
		return nil
	end
	local uid = str(env, cfg.metricsDataSourceUid)
	if uid == nil or uid ~= targetDs.uid then
		return nil
	end
	return PROXY .. Url.percentEncode(setup.ds.uid)
end

local function interpolateList(env: Env, raw: any, scope: Scope): { string }
	local out: { string } = {}
	for _, v in list(env, raw) do
		if type(v) == "string" then
			local s = Interpolate.replace(v, scope)
			if s ~= "" then
				table.insert(out, s)
			end
		end
	end
	return out
end

local function newTask(refId: string): Task
	return {
		ref_id = refId,
		phase = "",
		wait = {},
		tags = {},
		has_frame = false,
		done = false,
		cardinality_type = "",
		result_type = "",
		target_name = "",
		base = "",
		names = {},
		unused = false,
	}
end

-- The bottom switch of getTargetDataFrame: totals, tops, else unsupported.
local function bottom(task: Task, env: Env, items: { string }, limit: any)
	local ct = task.cardinality_type
	if ct == "metrics" or ct == "series" then
		task.phase = "series_bottom"
		task.wait = { values = labelValues(task, env, { "__name__" }, braces(items), limit) }
	elseif ct == "labels" or ct == "pairs" then
		task.phase = "names_bottom"
		task.wait = { names = labelNames(task, env, braces(items), limit) }
	else
		finish(task, emptyFrame(nil))
	end
end

-- getTargetDataFrame up to its first requests.
local function plan(t: Types.Target, refId: string, scope: Scope, ctx: Types.DsContext, env: Env): Task
	local task = newTask(refId)
	local raw = str(env, t.targetDatasource)
	local name = if raw then Interpolate.replace(raw, scope) else nil
	local ds, err = target(name, ctx.datasources)
	if ds == nil then
		fail(task, err or M.NO_TARGET)
		return task
	end
	local tds = ds :: Types.Datasource
	if direct(tds) then
		fail(task, directReason(tds))
		return task
	end
	task.target_name = tds.name
	task.base = PROXY .. Url.percentEncode(tds.uid)
	local ct = str(env, t.cardinalityType) or "metrics"
	local rt = str(env, t.resultType) or "top"
	task.cardinality_type, task.result_type = ct, rt
	local limit = Env.value(env, t.limit)
	local items = selectorItems(str(env, t.selector) or "", scope)
	local setup: Setup = { ds = ctx.ds, now_ms = ctx.now_ms }

	local fallthrough = false
	if rt == "list" then
		if ct == "metrics" or ct == "labels" then
			local start, finishS = listRange(setup.now_ms)
			task.phase = "list"
			task.wait = {
				list = get(
					task.base .. (if ct == "metrics" then "/api/v1/label/__name__/values" else "/api/v1/labels"),
					params({ { "end", finishS }, { "limit", LIST_LIMIT }, { "start", start } }, env)
				),
			}
			return task
		end
		fallthrough = true
	end
	if rt == "details" or fallthrough then
		local ps = interpolateList(env, t.parameterList, scope)
		if ct == "metrics" then
			if #ps == 0 then
				finish(task, emptyFrame(nil))
				return task
			end
			local sel = table.create(#ps + #items)
			for _, p in ps do
				table.insert(sel, "__name__='" .. p .. "'")
			end
			for _, item in items do
				table.insert(sel, item)
			end
			task.phase = "metric_details"
			task.names = { braces(sel) }
			task.wait = { names = labelNames(task, env, braces(sel), limit) }
			task.usage = Env.value(env, t.exampleCount)
			return task
		elseif ct == "labels" then
			task.phase = "value_counts"
			task.names = ps
			task.wait = { values = labelValues(task, env, ps, braces(items), limit) }
			return task
		elseif ct == "pairs" then
			task.phase = "value_counts"
			task.names = { "__name__" }
			task.wait = { values = labelValues(task, env, { "__name__" }, braces(items), nil) }
			return task
		end
	elseif rt == "usage" then
		if truthy(env, t.parameterList) then
			local metric = interpolateList(env, t.parameterList, scope)[1]
			local base = usageBase(setup, tds, env)
			if base == nil then
				fail(task, M.USAGE_UNAVAILABLE)
				return task
			end
			task.phase = "usage"
			task.wait = { usage = get((base :: string) .. "/usages/" .. Url.percentEncode(metric or "undefined")) }
			return task
		end
	elseif rt == "subtotal" then
		if ct == "series" then
			local sel: { string } = {}
			for _, p in interpolateList(env, t.parameterList, scope) do
				table.insert(sel, "__name__='" .. p .. "'")
			end
			for _, item in items do
				table.insert(sel, item)
			end
			task.phase = "series_subtotal"
			task.wait = { values = labelValues(task, env, { "__name__" }, braces(sel), limit) }
			return task
		elseif ct == "labels" then
			task.phase = "label_subtotal"
			task.wait = {
				values = labelValues(task, env, interpolateList(env, t.parameterList, scope), braces(items), 0),
			}
			return task
		end
	end
	bottom(task, env, items, limit)
	if task.phase == "series_bottom" and ct == "metrics" and rt == "top" then
		local base = usageBase(setup, tds, env)
		if base then
			task.unused = true
			task.wait.unused = get((base :: string) .. "/unused")
		end
	end
	return task
end

-- A cardinality API answer (Nt): a 404 means the target is no Mimir.
local function cardinalityDoc(task: Task, response: Response?, env: Env): (any, string?)
	if response and response.failure == nil and response.status == 404 then
		return nil,
			string.format('The target data source "%s" does not support Cardinality management.', task.target_name)
	end
	return decoded(response, env, "cardinality")
end

-- rt: the unused metrics as a set; nil when the request failed or holds no
-- map (the bundle then drops the column), false for a 204 (column pending).
local function unusedSet(response: Response?, env: Env): ({ [string]: boolean }?, boolean)
	if response == nil or not ok(response) then
		return nil, false
	end
	if (response :: Response).status ~= 200 then
		return nil, true
	end
	local okDecode, doc = pcall(env.decode, (response :: Response).body)
	if not okDecode or type(doc) ~= "table" or type(doc.unused) ~= "table" then
		return nil, false
	end
	local set: { [string]: boolean } = {}
	for k in doc.unused do
		if type(k) == "string" then
			set[k] = true
		end
	end
	return set, false
end

local function advanceTask(task: Task, got: { [string]: Response }, env: Env)
	local phase = task.phase
	if phase == "list" then
		local doc, err = decoded(got.list, env, "list")
		if err then
			return fail(task, err)
		end
		return finish(task, values(env, doc, task.ref_id))
	elseif phase == "metric_details" then
		local doc, err = cardinalityDoc(task, got.names, env)
		if err then
			return fail(task, err)
		end
		local count = Env.value(env, doc.label_names_count)
		if truthy(env, task.usage) and type(count) == "number" and count > 0 then
			local names: { string } = {}
			for _, c in list(env, doc.cardinality) do
				table.insert(names, str(env, c.label_name) or "undefined")
			end
			task.names_doc = doc
			task.phase = "metric_examples"
			task.wait = { examples = labelValues(task, env, names, task.names[1], task.usage) }
			return
		end
		return finish(task, metricDetails(env, doc, nil, task.ref_id))
	elseif phase == "metric_examples" then
		local doc, err = cardinalityDoc(task, got.examples, env)
		if err then
			return fail(task, err)
		end
		return finish(task, metricDetails(env, task.names_doc, doc, task.ref_id))
	elseif phase == "value_counts" then
		local doc, err = cardinalityDoc(task, got.values, env)
		if err then
			return fail(task, err)
		end
		return finish(task, valueCounts(env, doc, task.names, task.ref_id))
	elseif phase == "series_subtotal" then
		local doc, err = cardinalityDoc(task, got.values, env)
		if err then
			return fail(task, err)
		end
		return finish(task, metricsTop(env, doc, nil, task.ref_id))
	elseif phase == "label_subtotal" then
		local doc, err = cardinalityDoc(task, got.values, env)
		if err then
			return fail(task, err)
		end
		return finish(task, labelSubtotal(env, doc, task.ref_id))
	elseif phase == "series_bottom" then
		local doc, err = cardinalityDoc(task, got.values, env)
		if err then
			return fail(task, err)
		end
		local ct, rt = task.cardinality_type, task.result_type
		if ct == "series" then
			local entry = labelEntry(env, doc, "__name__")
			local n = if entry then Env.value(env, entry.series_count) else nil
			return finish(task, total("series", if truthy(env, n) then n else 0, task.ref_id))
		elseif rt == "top" then
			local set, pending = nil, false
			if task.unused then
				set, pending = unusedSet(got.unused, env)
			end
			local frame = metricsTop(env, doc, set, task.ref_id)
			if pending then
				local column = table.create(#frame.fields[1].values, Frame.NULL)
				table.insert(
					frame.fields,
					Frame.field("used", "string", column, nil, { displayName = "Used", noValue = "pending" })
				)
			end
			return finish(task, frame)
		elseif rt == "total" then
			local entry = labelEntry(env, doc, "__name__")
			local n = if entry then Env.value(env, entry.label_values_count) else nil
			return finish(task, total("values", if truthy(env, n) then n else 0, task.ref_id))
		end
		return finish(task, emptyFrame(nil))
	elseif phase == "names_bottom" then
		local doc, err = cardinalityDoc(task, got.names, env)
		if err then
			return fail(task, err)
		end
		local ct, rt = task.cardinality_type, task.result_type
		if ct == "pairs" then
			return finish(task, total("pairs", num(env, doc.label_values_count_total), task.ref_id))
		elseif rt == "top" then
			return finish(task, labelsTop(env, doc, task.ref_id))
		elseif rt == "total" then
			return finish(task, total("labels", num(env, doc.label_names_count), task.ref_id))
		end
		return finish(task, emptyFrame(nil))
	elseif phase == "usage" then
		local response = got.usage
		if response and response.failure == nil and response.status == 404 then
			return fail(task, M.NO_USAGE)
		end
		if response == nil or not ok(response) or response.status ~= 200 then
			return finish(task, nil)
		end
		local okDecode, doc = pcall(env.decode, response.body)
		if not okDecode or doc == nil or doc == env.null then
			return fail(task, M.USAGE_UNAVAILABLE)
		end
		task.usage = doc
		local wait: { [string]: Request } = {}
		if type(doc) == "table" then
			for i, uid in list(env, doc.dashboards) do
				wait["d" .. i] = get("/api/dashboards/uid/" .. Url.percentEncode(jsString(uid)))
			end
			for i, uid in list(env, doc.grafana_rules) do
				wait["r" .. i] = get("/api/v1/provisioning/alert-rules/" .. Url.percentEncode(jsString(uid)))
			end
		end
		if next(wait) == nil then
			return finish(task, usageFrame(env, doc, {}, {}, task.ref_id))
		end
		task.phase = "usage_titles"
		task.wait = wait
		return
	elseif phase == "usage_titles" then
		local doc = task.usage
		local function title(response: Response?, of: (any) -> string?): any
			if response and response.failure == nil and response.status == 404 then
				return ""
			end
			if response == nil or not ok(response) then
				return nil
			end
			local okDecode, body = pcall(env.decode, response.body)
			if not okDecode or type(body) ~= "table" then
				return nil
			end
			return of(body)
		end
		local titles: { [string]: any } = {}
		for i, uid in list(env, doc.dashboards) do
			titles[uid] = title(got["d" .. i], function(body: any): string?
				local dash = Env.value(env, body.dashboard)
				return if type(dash) == "table" then str(env, dash.title) else nil
			end)
		end
		local rules: { [string]: any } = {}
		for i, uid in list(env, doc.grafana_rules) do
			rules[uid] = title(got["r" .. i], function(body: any): string?
				local group, ruleTitle = Env.value(env, body.ruleGroup), Env.value(env, body.title)
				return string.format(
					"%s / %s",
					if group == nil then "undefined" else tostring(group),
					if ruleTitle == nil then "undefined" else tostring(ruleTitle)
				)
			end)
		end
		return finish(task, usageFrame(env, doc, titles, rules, task.ref_id))
	end
	return fail(task, "unknown cardinality query phase " .. phase)
end

-- Jobs ----------------------------------------------------------------------------

type CardJob = {
	tasks: { Task },
	-- A variable job (metricFindQuery) rather than a panel's.
	variable: boolean,
}

local function requestKey(r: Request): string
	local parts = { r.method, r.path }
	for _, p in r.query or {} :: { { string } } do
		table.insert(parts, p[1] .. "=" .. p[2])
	end
	return table.concat(parts, "\0")
end

-- Asks each distinct waited-for request once.
local function ask(tasks: { Task }): { Types.DsRequest }
	local out: { Types.DsRequest } = {}
	local tagOf: { [string]: string } = {}
	for _, task in tasks do
		task.tags = {}
		local waitNames: { string } = {}
		for name in task.wait do
			table.insert(waitNames, name)
		end
		table.sort(waitNames)
		for _, name in waitNames do
			local r = task.wait[name]
			local key = requestKey(r)
			local tag = tagOf[key]
			if tag == nil then
				tag = "r" .. (#out + 1)
				tagOf[key] = tag
				table.insert(out, { tag = tag, request = r })
			end
			task.tags[name] = tag :: string
		end
	end
	return out
end

-- metricFindQuery: the first string field's values (else the first
-- field's), as both text and value.
local function options(frame: Frame.Frame?): { Types.Option }
	local out: { Types.Option } = {}
	if frame == nil then
		return out
	end
	local field: Frame.Field? = nil
	for _, f in frame.fields do
		if f.type == "string" then
			field = f
			break
		end
	end
	field = field or frame.fields[1]
	if field == nil then
		return out
	end
	for _, v in (field :: Frame.Field).values do
		if not Frame.isNull(v) then
			local text = jsString(v)
			table.insert(out, { text = text, value = text })
		end
	end
	return out
end

local function outcome(job: CardJob): Types.Outcome
	for _, task in job.tasks do
		if task.error then
			return { error = task.error }
		end
	end
	if job.variable then
		return { options = options(job.tasks[1] and job.tasks[1].frame) }
	end
	local frames: { Frame.Frame } = {}
	for _, task in job.tasks do
		if task.frame then
			table.insert(frames, task.frame :: Frame.Frame)
		end
	end
	return { data = { frames = frames, errors = {}, warnings = {} } }
end

local function step(job: Types.Job, answers: Types.Answers, env: Env): (Types.Job, { Types.DsRequest }, Types.Outcome?)
	local j = job :: CardJob
	for _, task in j.tasks do
		if task.done or next(task.tags) == nil then
			continue
		end
		local got: { [string]: Response } = {}
		for name, tag in task.tags do
			got[name] = answers[tag]
		end
		advanceTask(task, got, env)
	end
	local pending: { Task } = {}
	for _, task in j.tasks do
		if not task.done then
			table.insert(pending, task)
		end
	end
	if #pending == 0 then
		return job, {}, outcome(j)
	end
	return job, ask(pending), nil
end

M.step = step

function M.start(targets: { Types.Target }, ctx: Types.DsContext, env: Env): Types.Job
	local tasks: { Task } = {}
	for i, t in targets do
		if Env.value(env, t.hide) == true then
			continue
		end
		local refId = str(env, t.refId) or string.char(64 + math.min(i, 26))
		table.insert(tasks, plan(t, refId, ctx.scope, ctx, env))
	end
	local job: CardJob = { tasks = tasks, variable = false }
	return job :: any
end

function M.variable(query: any, ctx: Types.DsContext, env: Env): Types.Job
	local q = if type(query) == "table" then query else {}
	local job: CardJob = { tasks = { plan(q, "variable", ctx.scope, ctx, env) }, variable = true }
	return job :: any
end

-- Direct (browser) access to the target is the one thing Tern cannot
-- reproduce; every other failure is the error Grafana shows too.
function M.blocker(t: Types.Target, ctx: Types.BlockerContext, env: Env): string?
	local raw = str(env, t.targetDatasource)
	if raw == nil then
		return nil
	end
	local ds = target(Interpolate.replace(raw, ctx.scope), ctx.datasources)
	if ds and direct(ds) then
		return directReason(ds)
	end
	return nil
end

local module: Types.DsModule = {
	types = { M.TYPE },
	blocker = M.blocker,
	start = M.start,
	step = step,
	variable = M.variable,
}

return module
