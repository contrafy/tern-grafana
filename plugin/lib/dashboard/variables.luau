--!strict
-- Dashboard template variables: the model, dependency order, option fetching
-- through the metrics source, regex filter, sort, include-all and multi-value
-- selection, URL overrides, and the interpolation scope they produce.
--
-- Semantics follow Grafana's variable system (public/app/features/variables
-- and the Prometheus and Loki datasources' metricFindQuery): option regexes use the
-- first capture group or named groups `text`/`value`; sort modes 1..8;
-- an include-all variable defaults to All; a multi-value variable keeps the
-- still-valid part of its selection after its options change; a variable
-- that references another one (`label_values(up{job=~"$job"}, instance)`,
-- datasource `${ds}`) is fetched after it and refetched when it changes.

local Adhoc = require("./adhoc")
local DsTypes = require("../datasources/types")
local Env = require("../env")
local Frame = require("../frame/types")
local Interpolate = require("./interpolate")
local Loki = require("../source/loki")
local Metrics = require("../source/metrics")
local Regex = require("../regex")
local Route = require("../config/route")
local Step = require("../time/step")
local TransportTypes = require("../transport/types")
local Tbl = require("../tbl")

type Env = Env.Env
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type Route = Route.Route

local M = {}

M.ALL = "$__all"

export type Option = { text: string, value: string }

export type Kind = "query" | "custom" | "constant" | "interval" | "datasource" | "textbox" | "adhoc" | "unsupported"

export type Status = "pending" | "loading" | "ready" | "error"

export type Variable = {
	name: string,
	kind: Kind,
	-- Grafana's own type name (shown when unsupported).
	type_name: string,
	label: string?,
	-- 0 shown, 1 label hidden, 2 variable hidden.
	hide: number,
	multi: boolean,
	include_all: boolean,
	all_value: string?,
	-- The query as a string (query variables: the classic function form).
	query: string,
	-- The saved query as written: a string, or the datasource's query object
	-- (Grafana Incident's {queryType}); datasource modules read it.
	query_model: any,
	datasource_uid: string?,
	datasource_type: string?,
	regex: string,
	sort: number,
	-- 0 never, 1 on dashboard load, 2 on time range change.
	refresh: number,
	auto: boolean,
	auto_count: number,
	auto_min: string,
	-- Without the All option.
	options: { Option },
	-- Selected values; { M.ALL } when All is selected.
	values: { string },
	texts: { string },
	-- The selection came from the link and may name values not in the options.
	from_url: boolean,
	status: Status,
	error: string?,
	-- Variables this one references (query, regex, datasource).
	deps: { string },
	-- Ad hoc filters (kind "adhoc"); `values` hold their URL forms.
	adhoc: Adhoc.Set?,
}

-- What a query variable asks its datasource for. Prometheus: `metrics` is
-- filtered by the server (`server`, Grafana 12.1+) or by the frontend's
-- unanchored regex test (before); `series` is the classic query, any other
-- expression. Loki: `hidden` are the label names its frontend leaves out.
export type Fetch =
	{ kind: "label_names", match: string? }
	| { kind: "label_values", label: string, match: string? }
	| { kind: "metrics", regex: string, server: boolean }
	| { kind: "query_result", expr: string }
	| { kind: "series", match: string }
	| { kind: "loki_label_names", hidden: { string } }
	| { kind: "loki_label_values", label: string, stream: string? }

-- The datasource instance a query variable reads (nil: not listed by
-- Grafana), its type (the reference's, else the instance's) and Grafana's
-- major version (nil: unknown, the newest behavior).
export type FetchContext = { ds: DsTypes.Datasource?, ds_type: string?, major: number? }

local KINDS: { [string]: Kind } = {
	query = "query",
	custom = "custom",
	constant = "constant",
	interval = "interval",
	datasource = "datasource",
	textbox = "textbox",
	adhoc = "adhoc",
}

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	if type(v) == "string" then
		return v
	elseif type(v) == "number" then
		return tostring(v)
	end
	return nil
end

local function strList(env: Env, v: any): { string }
	v = Env.value(env, v)
	if type(v) == "table" then
		local out: { string } = {}
		for _, x in v do
			local s = str(env, x)
			if s then
				table.insert(out, s)
			end
		end
		return out
	end
	local s = str(env, v)
	return if s then { s } else {}
end

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or s)
end

-- Grafana's custom variable query: comma-separated, `\,` escapes a comma,
-- `text : value` names a value.
function M.customOptions(query: string): { Option }
	local out: { Option } = {}
	local parts: { string } = {}
	local buf: { string } = {}
	local i = 1
	while i <= #query do
		local c = string.sub(query, i, i)
		if c == "\\" and string.sub(query, i + 1, i + 1) == "," then
			table.insert(buf, ",")
			i += 2
			continue
		end
		if c == "," then
			table.insert(parts, table.concat(buf))
			table.clear(buf)
		else
			table.insert(buf, c)
		end
		i += 1
	end
	table.insert(parts, table.concat(buf))
	for _, part in parts do
		local p = trim(part)
		if p == "" then
			continue
		end
		local text, value = string.match(p, "^(.-)%s+:%s+(.*)$")
		if text and value then
			table.insert(out, { text = trim(text), value = trim(value) })
		else
			table.insert(out, { text = p, value = p })
		end
	end
	return out
end

local function queryString(env: Env, raw: any): string
	local q = Env.value(env, raw.query)
	if type(q) == "table" then
		return str(env, q.query) or str(env, raw.definition) or ""
	end
	return str(env, q) or str(env, raw.definition) or ""
end

local function queryModel(env: Env, raw: any): any
	local q = Env.value(env, raw.query)
	return if type(q) == "table" then Tbl.copy(q) else q
end

-- Every string of a datasource's query object, keys sorted (scenes'
-- QueryVariable watches its whole `query` state for references).
local function modelTexts(model: any, out: { string }, depth: number)
	if type(model) == "string" then
		table.insert(out, model)
	elseif type(model) == "table" and depth < 8 then
		local keys: { any } = {}
		for k in model do
			table.insert(keys, k)
		end
		table.sort(keys, function(a: any, b: any): boolean
			return tostring(a) < tostring(b)
		end)
		for _, k in keys do
			modelTexts(model[k], out, depth + 1)
		end
	end
end

local function depsOf(v: Variable): { string }
	local texts = { v.query, v.regex, v.datasource_uid or "" }
	if type(v.query_model) == "table" then
		modelTexts(v.query_model, texts, 0)
	end
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, t in texts do
		for _, name in Interpolate.references(t) do
			if name ~= v.name and not seen[name] then
				seen[name] = true
				table.insert(out, name)
			end
		end
	end
	return out
end

local function intervalOptions(v: Variable): { Option }
	local out: { Option } = {}
	if v.auto then
		table.insert(out, { text = "auto", value = "$__auto_interval_" .. v.name })
	end
	for _, o in M.customOptions(v.query) do
		table.insert(out, o)
	end
	return out
end

local function variableOf(env: Env, raw: any): Variable?
	if type(raw) ~= "table" then
		return nil
	end
	local name = str(env, raw.name)
	if name == nil or name == "" then
		return nil
	end
	local typeName = str(env, raw.type) or "unknown"
	local kind: Kind = KINDS[typeName] or "unsupported"
	local ds = Env.value(env, raw.datasource)
	local dsUid, dsType = nil, nil
	if type(ds) == "table" then
		dsUid, dsType = str(env, ds.uid), str(env, ds.type)
	elseif type(ds) == "string" then
		dsUid = ds
	end
	local current = Env.value(env, raw.current)
	current = if type(current) == "table" then current else {}
	local refresh = Env.value(env, raw.refresh)
	local v: Variable = {
		name = name,
		kind = kind,
		type_name = typeName,
		label = str(env, raw.label),
		hide = (Env.value(env, raw.hide) :: number?) or 0,
		multi = Env.value(env, raw.multi) == true,
		include_all = Env.value(env, raw.includeAll) == true,
		all_value = str(env, raw.allValue),
		query = queryString(env, raw),
		query_model = queryModel(env, raw),
		datasource_uid = dsUid,
		datasource_type = dsType,
		regex = str(env, raw.regex) or "",
		sort = (Env.value(env, raw.sort) :: number?) or 0,
		refresh = if type(refresh) == "number" then refresh else 1,
		auto = Env.value(env, raw.auto) == true,
		auto_count = (Env.value(env, raw.auto_count) :: number?) or 30,
		auto_min = str(env, raw.auto_min) or "10s",
		options = {},
		values = strList(env, current.value),
		texts = strList(env, current.text),
		from_url = false,
		status = "ready",
		error = nil,
		deps = {},
		adhoc = if kind == "adhoc" then Adhoc.fromModel(raw, env) else nil,
	}
	if v.all_value == "" then
		v.all_value = nil
	end
	if kind == "datasource" and v.datasource_type == nil then
		-- The datasource variable's query is the plugin type it lists.
		v.datasource_type = v.query
	end
	if #v.texts ~= #v.values then
		v.texts = Tbl.copy(v.values)
	end
	v.deps = depsOf(v)
	return v
end

-- Applies the current selection against `options` the way Grafana validates
-- it after options change.
local function validate(v: Variable)
	local byValue: { [string]: Option } = {}
	for _, o in v.options do
		byValue[o.value] = o
	end
	if #v.values == 1 and v.values[1] == M.ALL and v.include_all then
		v.texts = { Interpolate.ALL_TEXT }
		return
	end
	local keep: { string } = {}
	local texts: { string } = {}
	for _, value in v.values do
		local o = byValue[value]
		if o then
			table.insert(keep, o.value)
			table.insert(texts, o.text)
		end
	end
	if #keep > 0 and (v.multi or #keep == 1) then
		v.values, v.texts = keep, texts
		return
	end
	if #keep > 0 then
		v.values, v.texts = { keep[1] }, { texts[1] }
		return
	end
	if v.from_url and #v.values > 0 then
		-- Grafana accepts values from the URL that the options do not list.
		v.texts = Tbl.copy(v.values)
		return
	end
	-- A single value no option holds keeps the option whose text it showed
	-- (scenes MultiValueVariable findOptionMatchingCurrent: value, then text).
	local savedText = v.texts[1]
	if not v.multi and savedText ~= nil then
		for _, o in v.options do
			if o.text == savedText then
				v.values, v.texts = { o.value }, { o.text }
				return
			end
		end
	end
	if v.include_all then
		v.values, v.texts = { M.ALL }, { Interpolate.ALL_TEXT }
	elseif v.options[1] then
		v.values, v.texts = { v.options[1].value }, { v.options[1].text }
	else
		v.values, v.texts = {}, {}
	end
end

-- An ad hoc variable's filters; its values are their URL forms.
function M.setFilters(v: Variable, filters: { Adhoc.Filter })
	local set = v.adhoc
	if set == nil then
		return
	end
	set.filters = filters
	local urls: { string } = table.create(#filters)
	local texts: { string } = table.create(#filters)
	for i, f in filters do
		urls[i] = Adhoc.toUrl(f)
		texts[i] = Adhoc.describe(f)
	end
	v.values, v.texts = urls, texts
end

local function initLocal(v: Variable)
	if v.kind == "custom" then
		v.options = M.customOptions(v.query)
		validate(v)
	elseif v.kind == "constant" then
		v.options = { { text = v.query, value = v.query } }
		v.values, v.texts = { v.query }, { v.query }
	elseif v.kind == "interval" then
		v.options = intervalOptions(v)
		validate(v)
	elseif v.kind == "textbox" then
		if #v.values == 0 then
			v.values, v.texts = { v.query }, { v.query }
		end
		v.options = { { text = v.values[1], value = v.values[1] } }
	elseif v.kind == "query" or v.kind == "datasource" then
		v.status = "pending"
	elseif v.kind == "adhoc" then
		M.setFilters(v, (v.adhoc :: Adhoc.Set).filters)
	end
end

-- Dependency order (a variable after everything it references), stable in
-- model order otherwise. A cycle is reported and its members kept in model order.
function M.order(vars: { Variable }): ({ Variable }, string?)
	local byName: { [string]: Variable } = {}
	for _, v in vars do
		byName[v.name] = v
	end
	local out: { Variable } = {}
	local state: { [string]: number } = {}
	local cycle: string? = nil
	local function visit(v: Variable)
		local s = state[v.name]
		if s == 2 then
			return
		elseif s == 1 then
			cycle = cycle or v.name
			return
		end
		state[v.name] = 1
		for _, d in v.deps do
			local dep = byName[d]
			if dep then
				visit(dep)
			end
		end
		state[v.name] = 2
		table.insert(out, v)
	end
	for _, v in vars do
		visit(v)
	end
	if cycle then
		return out, string.format("variable %q is part of a dependency cycle", cycle)
	end
	return out, nil
end

-- `templating.list` as variables in dependency order.
function M.fromModel(list: { any }, env: Env): ({ Variable }, string?)
	local vars: { Variable } = {}
	for _, raw in list do
		local v = variableOf(env, raw)
		if v then
			initLocal(v)
			table.insert(vars, v)
		end
	end
	return M.order(vars)
end

function M.find(vars: { Variable }, name: string): Variable?
	for _, v in vars do
		if v.name == name then
			return v
		end
	end
	return nil
end

local function isAllText(s: string): boolean
	return s == M.ALL or s == "All" or s == "$__all"
end

local function filtersFromUrl(values: { string }): { Adhoc.Filter }
	local out: { Adhoc.Filter } = {}
	for _, s in values do
		local f = Adhoc.fromUrl(s)
		if f then
			table.insert(out, f)
		end
	end
	return out
end

-- `var-<name>` values from a link override the dashboard's saved selection
-- (an ad hoc variable's `key|op|value` filters replace its own; an empty
-- `var-<name>=` clears them).
function M.applyUrl(vars: { Variable }, overrides: { [string]: { string } })
	for name, values in overrides do
		local v = M.find(vars, name)
		if v == nil or v.kind == "constant" or #values == 0 then
			continue
		end
		if v.kind == "adhoc" then
			M.setFilters(v, filtersFromUrl(values))
			continue
		end
		if v.include_all and #values == 1 and isAllText(values[1]) then
			v.values = { M.ALL }
		else
			v.values = Tbl.copy(values)
			if not v.multi then
				v.values = { values[1] }
			end
		end
		v.texts = Tbl.copy(v.values)
		v.from_url = true
		if v.kind ~= "query" and v.kind ~= "datasource" then
			if v.kind == "textbox" then
				v.options = { { text = v.values[1], value = v.values[1] } }
			end
			validate(v)
		end
	end
end

-- Values a selection expands to: every option value for All.
function M.expanded(v: Variable): { string }
	if #v.values == 1 and v.values[1] == M.ALL then
		local out: { string } = table.create(#v.options)
		for i, o in v.options do
			out[i] = o.value
		end
		return out
	end
	return v.values
end

-- Display texts of the expanded selection.
function M.expandedTexts(v: Variable): { string }
	if #v.values == 1 and v.values[1] == M.ALL then
		local out: { string } = table.create(#v.options)
		for i, o in v.options do
			out[i] = o.text
		end
		return out
	end
	return v.texts
end

export type ScopeContext = { from_ms: number, to_ms: number }

-- The resolved value of an interval variable (auto computed from the range).
local function intervalValue(v: Variable, ctx: ScopeContext?): string
	local value = v.values[1] or ""
	if string.sub(value, 1, 17) == "$__auto_interval_" then
		if ctx == nil then
			return "1m"
		end
		local minMs = Step.parseDuration(v.auto_min)
		return Step.interval(ctx.to_ms - ctx.from_ms, math.max(1, v.auto_count), minMs).interval_str
	end
	return value
end

-- Interpolation scope of every resolved variable. An ad hoc variable's
-- value is its filter expression (`key="value",...`), as scenes'
-- AdHocFiltersVariable.getValue gives it.
function M.scope(vars: { Variable }, ctx: ScopeContext?): Interpolate.Scope
	local scope: Interpolate.Scope = {}
	for _, v in vars do
		if v.kind == "unsupported" then
			continue
		end
		if v.kind == "interval" then
			local value = intervalValue(v, ctx)
			scope[v.name] = { values = { value }, texts = { value } }
			continue
		end
		local set = v.adhoc
		if set then
			local expr = Adhoc.expression(set.filters)
			scope[v.name] = { values = { expr }, texts = { expr }, name = v.name }
			continue
		end
		local isAll = #v.values == 1 and v.values[1] == M.ALL
		scope[v.name] = {
			values = M.expanded(v),
			texts = M.expandedTexts(v),
			multi = v.multi,
			include_all = v.include_all,
			is_all = isAll,
			all_value = if isAll then v.all_value else nil,
			name = v.name,
			query = v.query_model,
		}
	end
	return scope
end

-- `var-x` values for links and Grafana URLs (constants are not synced; an
-- ad hoc variable without filters is `var-x=`, as Grafana writes it).
function M.urlValues(vars: { Variable }): { [string]: { string } }
	local out: { [string]: { string } } = {}
	for _, v in vars do
		if v.kind == "adhoc" then
			out[v.name] = if #v.values > 0 then Tbl.copy(v.values) else { "" }
			continue
		end
		if v.kind == "constant" or v.kind == "unsupported" or #v.values == 0 then
			continue
		end
		if #v.values == 1 and v.values[1] == M.ALL then
			out[v.name] = { "$__all" }
		else
			out[v.name] = Tbl.copy(v.values)
		end
	end
	return out
end

-- A stable string of every selection: equal signatures interpolate equally.
function M.signature(vars: { Variable }, ctx: ScopeContext?): string
	local parts: { string } = {}
	for _, v in vars do
		local values = if v.kind == "interval" then { intervalValue(v, ctx) } else v.values
		table.insert(parts, v.name .. "=" .. table.concat(values, "\31"))
	end
	return table.concat(parts, "\30")
end

-- `inner` as JavaScript's `.+` matches it (no line breaks, not empty).
local function dotPlus(inner: string?): string?
	if inner == nil or inner == "" or string.find(inner, "[\r\n]") then
		return nil
	end
	return inner
end

-- `s` with the call `name(...)` and trailing white space, its argument text
-- as the regex `^name\((.+)\)\s*$` captures it.
local function call(s: string, name: string): string?
	local inner = string.match(s, "^" .. name .. "%((.*)%)%s*$")
	return dotPlus(inner)
end

-- Grafana's isFilterDefined: blank, or `{}` once spaces are removed, is no filter.
local function filterDefined(filter: string?): boolean
	return filter ~= nil and filter ~= "" and string.gsub(filter, " ", "") ~= "{}"
end

-- The Prometheus datasource's metricFindQuery (packages/grafana-prometheus
-- src/metric_find_query.ts, Grafana 11.6 to 13): label_names(), label
-- names of metrics matching `.*<m>.*`, label_values([selector,] label),
-- metrics(regex), query_result(expr), and any other expression as a series
-- query (the empty forms answer nothing). `major` picks how metrics()
-- filters (12.0 still filtered in the frontend; Tern takes 12 as 12.1+).
-- nil and no error: Grafana answers no options without asking.
function M.parseQuery(query: string, major: number?): (Fetch?, string?)
	if string.match(query, "^label_names%(%)%s*$") then
		return { kind = "label_names" }, nil
	end
	local inner = call(query, "label_names")
	if inner then
		return { kind = "label_names", match = '{__name__=~".*' .. inner .. '.*"}' }, nil
	end
	inner = call(query, "label_values")
	if inner then
		local filter, label = string.match(inner, "^(.+),%s*(.+)$")
		if label == nil then
			label = inner
		end
		return { kind = "label_values", label = label :: string, match = if filterDefined(filter) then filter else nil },
			nil
	end
	inner = call(query, "metrics")
	if inner then
		return { kind = "metrics", regex = inner, server = major == nil or major >= 12 }, nil
	end
	inner = call(query, "query_result")
	if inner then
		return { kind = "query_result", expr = inner }, nil
	end
	if query == "" or query == "label_values()" or query == "metrics()" or query == "query_result()" then
		return nil, nil
	end
	return { kind = "series", match = query }, nil
end

-- Loki's label names its frontend hides (LanguageProvider HIDDEN_LABELS;
-- Grafana 11 misspelled the first one).
local LOKI_HIDDEN_11 = { "__aggregrated_metric__", "__tenant_id__", "__stream_shard__" }
local LOKI_HIDDEN = { "__aggregated_metric__", "__tenant_id__", "__stream_shard__" }

local function lokiValues(label: string, stream: string?): Fetch?
	if label == "" then
		return nil
	end
	return { kind = "loki_label_values", label = label, stream = if stream == "" or stream == "{}" then nil else stream }
end

-- The Loki datasource's metricFindQuery (public/app/plugins/datasource/
-- loki/datasource.ts, Grafana 11.6 to 13): the editor's query object
-- ({type: 0 label names | 1 label values, label, stream}) with label and
-- stream interpolated, or a legacy string, interpolated, then parsed as
-- label_names() or label_values([stream,] label); anything else answers
-- nothing.
function M.lokiFetch(model: any, query: string, scope: Interpolate.Scope, major: number?): Fetch?
	local format = { format = Interpolate.loki }
	local names: Fetch =
		{ kind = "loki_label_names", hidden = if major and major < 12 then LOKI_HIDDEN_11 else LOKI_HIDDEN }
	if type(model) == "table" then
		if model.type == 0 then
			return names
		end
		local label = if type(model.label) == "string" then model.label else ""
		local stream = if type(model.stream) == "string" then model.stream else ""
		return lokiValues(Interpolate.replace(label, scope, format), Interpolate.replace(stream, scope, format))
	end
	local q = Interpolate.replace(query, scope, format)
	if string.match(q, "^label_names%(%)%s*$") then
		return names
	end
	local inner = string.match(q, "^label_values%((.*)%)%s*$")
	if inner == nil or string.find(inner, "[\r\n]") then
		return nil
	end
	local stream, label = string.match(inner, "^(.+),%s*([%a_%$][%w_]*)$")
	if label then
		return lokiValues(label, stream)
	end
	label = string.match(inner, "^([%a_%$][%w_]*)$")
	return if label then lokiValues(label, nil) else nil
end

-- The datasource uid a variable queries, after interpolation.
function M.datasourceUid(v: Variable, scope: Interpolate.Scope): string?
	local uid = v.datasource_uid
	if uid == nil or uid == "" then
		return nil
	end
	local resolved = Interpolate.replace(uid, scope)
	return if resolved == "" then nil else resolved
end

-- PrometheusVariableSupport's own `$__interval` and `$__interval_ms`: the
-- datasource's scrape interval (jsonData.timeInterval, else 15s).
local function promIntervals(ds: DsTypes.Datasource?): Interpolate.Scope
	local jd = if ds then ds.json_data else nil
	local interval = if jd
			and type(jd.timeInterval) == "string"
			and jd.timeInterval ~= ""
		then jd.timeInterval :: string
		else "15s"
	return {
		__interval = Interpolate.value(interval),
		__interval_ms = Interpolate.value(string.format("%d", Step.parseDuration(interval) or 15000)),
	}
end

-- The fetch for a query variable with its references interpolated as its
-- datasource interpolates them. nil and no error: no options, unasked.
function M.fetchFor(
	v: Variable,
	scope: Interpolate.Scope,
	builtins: Interpolate.Scope?,
	ctx: FetchContext?
): (Fetch?, string?)
	local c: FetchContext = ctx or {}
	local dsType = c.ds_type or v.datasource_type or "prometheus"
	local s = if builtins then Interpolate.merge(builtins, scope) else scope
	if dsType == "loki" then
		return M.lokiFetch(v.query_model, v.query, s, c.major), nil
	elseif dsType ~= "prometheus" then
		return nil, string.format("%s query variables are not supported (only prometheus and loki)", dsType)
	end
	local q =
		Interpolate.replace(v.query, Interpolate.merge(s, promIntervals(c.ds)), { format = Interpolate.prometheus })
	return M.parseQuery(q, c.major)
end

export type Range = { from_ms: number, to_ms: number }

function M.request(fetch: Fetch, route: Route, range: Range): Request
	local from_ms, to_ms = range.from_ms, range.to_ms
	if fetch.kind == "label_names" then
		local m = fetch.match
		return Metrics.labelsRequest(route, { match = if m then { m } else nil, from_ms = from_ms, to_ms = to_ms })
	elseif fetch.kind == "label_values" then
		local m = fetch.match
		return Metrics.labelValuesRequest(
			route,
			fetch.label,
			{ match = if m then { m } else nil, from_ms = from_ms, to_ms = to_ms }
		)
	elseif fetch.kind == "metrics" then
		local match = if fetch.server then { '{__name__=~"' .. fetch.regex .. '"}' } else nil
		return Metrics.labelValuesRequest(route, "__name__", { match = match, from_ms = from_ms, to_ms = to_ms })
	elseif fetch.kind == "series" then
		return Metrics.seriesRequest(route, { match = fetch.match, from_ms = from_ms, to_ms = to_ms })
	elseif fetch.kind == "loki_label_names" then
		return Loki.labelsRequest(route, { from_ms = from_ms, to_ms = to_ms })
	elseif fetch.kind == "loki_label_values" then
		return Loki.labelValuesRequest(route, fetch.label, { query = fetch.stream, from_ms = from_ms, to_ms = to_ms })
	end
	return Metrics.instantRequest(route, { expr = fetch.expr, time_ms = to_ms })
end

-- A series as the Prometheus datasource names it (getOriginalMetricName):
-- `name{a="1",b="2"}`, labels in the answer's (sorted) order, unescaped.
local function seriesText(labels: { [string]: string }): string
	local parts: { string } = {}
	for _, k in Frame.labelKeys(labels) do
		table.insert(parts, k .. '="' .. labels[k] .. '"')
	end
	return (labels.__name__ or "") .. "{" .. table.concat(parts, ",") .. "}"
end

-- A sample as Prometheus writes it (Go strconv.FormatFloat(v, 'f', -1, 64):
-- the shortest decimal that reads back as v, never an exponent), the text
-- Grafana copies into a query_result() row.
local function sampleText(v: any): string
	if type(v) ~= "number" then
		return tostring(v)
	elseif v ~= v then
		return "NaN"
	elseif v == math.huge then
		return "+Inf"
	elseif v == -math.huge then
		return "-Inf"
	elseif v == 0 then
		return "0"
	end
	local e = ""
	for p = 0, 16 do
		e = string.format("%." .. p .. "e", v)
		if tonumber(e) == v then
			break
		end
	end
	local sign, lead, frac, exp = string.match(e, "^(%-?)(%d)%.?(%d*)e([%+%-]%d+)$")
	if sign == nil or lead == nil or frac == nil or exp == nil then
		return e
	end
	local digits = string.gsub(lead .. frac, "0+$", "")
	local x = tonumber(exp) :: number
	local n = #digits
	local text: string
	if x >= n - 1 then
		text = digits .. string.rep("0", x - (n - 1))
	elseif x >= 0 then
		text = string.sub(digits, 1, x + 1) .. "." .. string.sub(digits, x + 2)
	else
		text = "0." .. string.rep("0", -x - 1) .. digits
	end
	return sign .. text
end

-- query_result() options as Grafana's Prometheus datasource writes them
-- (packages/grafana-prometheus/src/metric_find_query.ts queryResultQuery,
-- raw.githubusercontent.com/grafana/grafana/v12.4.0/...): a scalar or a
-- string result is its value alone; a vector row is `metric{a="1",b="2"}
-- value timestamp_ms` (labels sorted, no spaces); any other result type is
-- an error.
function M.queryResultValues(frames: { Frame.Frame }): ({ string }?, string?)
	local out: { string } = {}
	for _, frame in frames do
		local custom = if frame.meta then frame.meta.custom else nil
		local resultType = if custom then custom.resultType else nil
		local timeField = Frame.timeField(frame)
		if resultType == "scalar" or resultType == "string" then
			for _, field in frame.fields do
				if field ~= timeField then
					local value = field.values[#field.values]
					table.insert(out, if Frame.isNull(value) then "" else sampleText(value))
					break
				end
			end
			continue
		elseif resultType ~= nil and resultType ~= "vector" then
			return nil, string.format("Unknown/Unhandled result type: [%s]", tostring(resultType))
		end
		for _, field in Frame.numberFields(frame) do
			local n = #field.values
			local value = field.values[n]
			local ts = if timeField then timeField.values[n] else nil
			local text = seriesText(field.labels or {})
			text ..= " " .. sampleText(if Frame.isNull(value) then 0 / 0 else value)
			if type(ts) == "number" then
				text ..= " " .. string.format("%d", ts)
			end
			table.insert(out, text)
		end
	end
	return out, nil
end

-- The raw values a fetch answered, before regex and sort.
function M.parseFetch(fetch: Fetch, route: Route, response: Response, env: Env): ({ string }?, string?)
	if fetch.kind == "query_result" then
		local r = Metrics.parse(route, response, env, "instant")
		if not r.ok then
			return nil, (r :: any).error.message
		end
		return M.queryResultValues((r :: any).frames)
	elseif fetch.kind == "series" then
		local r = Metrics.parseSeries(route, response, env)
		if not r.ok then
			return nil, (r :: any).error.message
		end
		local out: { string } = {}
		for _, labels in (r :: any).series :: { { [string]: string } } do
			table.insert(out, seriesText(labels))
		end
		return out, nil
	end
	local r = if fetch.kind == "loki_label_names" or fetch.kind == "loki_label_values"
		then Loki.parseList(route, response, env)
		else Metrics.parseList(route, response, env)
	if not r.ok then
		return nil, (r :: any).error.message
	end
	local values: { string } = (r :: any).values
	if fetch.kind == "loki_label_names" or (fetch.kind == "label_names" and fetch.match) then
		local hidden: { string } = if fetch.kind == "loki_label_names" then fetch.hidden else { "__name__" }
		local out: { string } = {}
		for _, name in values do
			if not table.find(hidden, name) then
				table.insert(out, name)
			end
		end
		return out, nil
	end
	if fetch.kind == "metrics" and not fetch.server and fetch.regex ~= "" then
		local re, err = Regex.compile(fetch.regex)
		if re == nil then
			return nil, "metrics(): " .. tostring(err)
		end
		local out: { string } = {}
		for _, name in values do
			if Regex.test(re, name) then
				table.insert(out, name)
			end
		end
		values = out
	end
	return values, nil
end

-- Numeric sort key: Grafana's /.*?(\d+).*/ first number, else -1.
local function numericKey(text: string): number
	local digits = string.match(text, "%d+")
	return if digits then tonumber(digits) :: number else -1
end

-- Natural order: digit runs compare as numbers.
local function naturalLess(a: string, b: string): boolean
	local i, j = 1, 1
	local la, lb = string.lower(a), string.lower(b)
	while i <= #la and j <= #lb do
		local da = string.match(la, "^%d+", i)
		local db = string.match(lb, "^%d+", j)
		if da and db then
			local na, nb = tonumber(da) :: number, tonumber(db) :: number
			if na ~= nb then
				return na < nb
			end
			i += #da
			j += #db
		else
			local ca, cb = string.sub(la, i, i), string.sub(lb, j, j)
			if ca ~= cb then
				return ca < cb
			end
			i += 1
			j += 1
		end
	end
	return #la - i < #lb - j
end

-- Grafana's sortVariableValues: 1/2 alphabetical, 3/4 numerical, 5/6
-- case-insensitive, 7/8 natural; even modes descending. Stable.
function M.sortOptions(options: { Option }, mode: number): { Option }
	if mode <= 0 then
		return options
	end
	local kind = math.ceil(mode / 2)
	local indexed: { { o: Option, i: number } } = table.create(#options)
	for i, o in options do
		indexed[i] = { o = o, i = i }
	end
	local less: (a: Option, b: Option) -> boolean
	if kind == 1 then
		less = function(a, b)
			return a.text < b.text
		end
	elseif kind == 2 then
		less = function(a, b)
			return numericKey(a.text) < numericKey(b.text)
		end
	elseif kind == 3 then
		less = function(a, b)
			return string.lower(a.text) < string.lower(b.text)
		end
	else
		less = function(a, b)
			return naturalLess(a.text, b.text)
		end
	end
	table.sort(indexed, function(x, y)
		if less(x.o, y.o) then
			return true
		elseif less(y.o, x.o) then
			return false
		end
		return x.i < y.i
	end)
	local out: { Option } = table.create(#indexed)
	for i, e in indexed do
		out[i] = e.o
	end
	if mode % 2 == 0 then
		local n = #out
		for i = 1, n // 2 do
			out[i], out[n - i + 1] = out[n - i + 1], out[i]
		end
	end
	return out
end

-- Raw values -> options: the variable's regex (Grafana's
-- metricNamesToVariableValues, applied to the value), duplicates dropped by
-- value, then sorted. `texts[i]`: the display text of `values[i]` when the
-- datasource names one (a datasource module's options); the regex's groups
-- replace it as they replace the value.
function M.optionsFrom(
	v: Variable,
	values: { string },
	scope: Interpolate.Scope,
	texts: { string }?
): ({ Option }, string?)
	local re: Regex.Regex? = nil
	if v.regex ~= "" then
		local source = Interpolate.replace(v.regex, scope, { format = Interpolate.named("regex") })
		local compiled, err = Regex.parseJs(source)
		if compiled == nil then
			return {}, "regex: " .. tostring(err)
		end
		re = compiled
	end
	local out: { Option } = {}
	local seen: { [string]: boolean } = {}
	local function add(text: string, value: string)
		if not seen[value] then
			seen[value] = true
			table.insert(out, { text = text, value = value })
		end
	end
	for i, value in values do
		local text = if texts then texts[i] or value else value
		if re == nil then
			add(text, value)
			continue
		end
		local matches: { Regex.Match } = {}
		local init = 1
		while true do
			local m = Regex.exec(re, value, init)
			if m == nil then
				break
			end
			table.insert(matches, m)
			if not re.global then
				break
			end
			init = if m.finish >= m.start then m.finish + 1 else m.start + 1
			if init > #value + 1 then
				break
			end
		end
		if #matches == 0 then
			continue
		end
		local valueGroup, textGroup, firstGroup = nil, nil, nil
		for _, m in matches do
			valueGroup = valueGroup or m.named.value
			textGroup = textGroup or m.named.text
			if firstGroup == nil and m.groups[1] ~= nil then
				firstGroup = m.groups[1]
			end
		end
		if valueGroup or textGroup then
			add(textGroup or valueGroup :: string, valueGroup or textGroup :: string)
		elseif #matches > 1 and firstGroup then
			for _, m in matches do
				local g = m.groups[1]
				if g then
					add(g, g)
				end
			end
		elseif firstGroup then
			add(firstGroup, firstGroup)
		else
			add(text, value)
		end
	end
	return M.sortOptions(out, v.sort), nil
end

-- New options for a fetched variable; the selection is validated against them.
function M.setOptions(v: Variable, options: { Option })
	v.options = options
	v.status = "ready"
	v.error = nil
	validate(v)
	v.from_url = false
end

function M.setError(v: Variable, message: string)
	v.status = "error"
	v.error = message
	v.from_url = false
end

-- A datasource module's answer to a query variable (lib/datasources): its
-- options through the variable's regex and sort, or its error.
function M.applyOutcome(v: Variable, outcome: DsTypes.Outcome, scope: Interpolate.Scope)
	local opts = outcome.options
	if opts == nil then
		M.setError(v, outcome.error or "no values")
		return
	end
	local values: { string } = table.create(#opts)
	local texts: { string } = table.create(#opts)
	for i, o in opts do
		values[i], texts[i] = o.value, o.text
	end
	local options, err = M.optionsFrom(v, values, scope, texts)
	if err then
		M.setError(v, err)
	else
		M.setOptions(v, options)
	end
end

-- Options of a datasource variable from Grafana's datasource list.
function M.datasourceOptions(
	v: Variable,
	datasources: { DsTypes.Datasource },
	scope: Interpolate.Scope
): ({ Option }, string?)
	local re: Regex.Regex? = nil
	if v.regex ~= "" then
		local compiled, err =
			Regex.parseJs(Interpolate.replace(v.regex, scope, { format = Interpolate.named("regex") }))
		if compiled == nil then
			return {}, "regex: " .. tostring(err)
		end
		re = compiled
	end
	local out: { Option } = {}
	for _, ds in datasources do
		if ds.type ~= v.datasource_type then
			continue
		end
		if re and not Regex.test(re, ds.name) then
			continue
		end
		table.insert(out, { text = ds.name, value = ds.uid })
	end
	table.sort(out, function(a, b)
		return a.text < b.text
	end)
	return out, nil
end

-- A datasource variable may hold a name instead of a uid (older dashboards).
function M.normalizeDatasource(v: Variable)
	for i, value in v.values do
		for _, o in v.options do
			if o.text == value and o.value ~= value then
				v.values[i] = o.value
				v.texts[i] = o.text
			end
		end
	end
	validate(v)
end

-- The ad hoc variables queries read (Queries.Context.adhoc): each one's
-- datasource, interpolated, and its filters.
function M.adhocVars(
	vars: { Variable },
	scope: Interpolate.Scope
): { { datasource: string?, filters: { Adhoc.Filter } } }
	local out: { { datasource: string?, filters: { Adhoc.Filter } } } = {}
	for _, v in vars do
		local set = v.adhoc
		if set then
			table.insert(out, { datasource = M.datasourceUid(v, scope), filters = set.filters })
		end
	end
	return out
end

-- The user picked values. `values` = { M.ALL } selects All; an ad hoc
-- variable takes its filters' URL forms.
function M.select(v: Variable, values: { string })
	if v.kind == "adhoc" then
		M.setFilters(v, filtersFromUrl(values))
		return
	end
	if not v.multi and #values > 1 then
		values = { values[1] }
	end
	v.values = Tbl.copy(values)
	v.from_url = false
	if v.kind == "textbox" then
		v.texts = Tbl.copy(values)
		v.options = { { text = values[1] or "", value = values[1] or "" } }
		return
	end
	if #values == 0 then
		v.texts = {}
		validate(v)
		return
	end
	validate(v)
end

-- Every variable that (transitively) references one of `names`.
function M.dependents(vars: { Variable }, names: { string }): { string }
	local hit: { [string]: boolean } = {}
	for _, n in names do
		hit[n] = true
	end
	local out: { string } = {}
	-- vars are in dependency order, so one pass reaches every level.
	for _, v in vars do
		if hit[v.name] then
			continue
		end
		for _, d in v.deps do
			if hit[d] then
				hit[v.name] = true
				table.insert(out, v.name)
				break
			end
		end
	end
	return out
end

local function fetched(v: Variable): boolean
	return v.kind == "query" or v.kind == "datasource"
end

-- Marks fetched variables named (and everything depending on them) for a refetch.
function M.invalidate(vars: { Variable }, names: { string })
	local all = Tbl.copy(names)
	for _, d in M.dependents(vars, names) do
		table.insert(all, d)
	end
	local set: { [string]: boolean } = {}
	for _, n in all do
		set[n] = true
	end
	for _, v in vars do
		if set[v.name] and fetched(v) then
			v.status = "pending"
		end
	end
end

-- The variables refreshed when the time range changes (refresh = 2).
function M.onTimeRange(vars: { Variable }): { string }
	local names: { string } = {}
	for _, v in vars do
		if fetched(v) and v.refresh == 2 then
			table.insert(names, v.name)
		end
	end
	M.invalidate(vars, names)
	return names
end

-- Pending variables whose references are all settled: fetch these now.
function M.ready(vars: { Variable }): { Variable }
	local byName: { [string]: Variable } = {}
	for _, v in vars do
		byName[v.name] = v
	end
	local out: { Variable } = {}
	for _, v in vars do
		if v.status ~= "pending" then
			continue
		end
		local ok = true
		for _, d in v.deps do
			local dep = byName[d]
			if dep and (dep.status == "pending" or dep.status == "loading") then
				ok = false
				break
			end
		end
		if ok then
			table.insert(out, v)
		end
	end
	return out
end

-- True when no variable is waiting for options.
function M.settled(vars: { Variable }): boolean
	for _, v in vars do
		if v.status == "pending" or v.status == "loading" then
			return false
		end
	end
	return true
end

-- The variable's selection as shown on its chip.
function M.display(v: Variable): string
	if v.kind == "adhoc" then
		return if #v.texts == 0 then "+ Add filter" else table.concat(v.texts, ", ")
	end
	if v.kind == "interval" and #v.values == 1 and string.sub(v.values[1], 1, 17) == "$__auto_interval_" then
		return "auto"
	end
	if #v.values == 1 and v.values[1] == M.ALL then
		return Interpolate.ALL_TEXT
	end
	if #v.texts == 0 then
		return "(none)"
	end
	return table.concat(v.texts, " + ")
end

return M
