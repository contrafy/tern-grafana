--!strict
-- Dashboard template variables: the model, dependency order, option fetching
-- through the metrics source, regex filter, sort, include-all and multi-value
-- selection, URL overrides, and the interpolation scope they produce.
--
-- Semantics follow Grafana's variable system (public/app/features/variables
-- and the Prometheus datasource's metricFindQuery): option regexes use the
-- first capture group or named groups `text`/`value`; sort modes 1..8;
-- an include-all variable defaults to All; a multi-value variable keeps the
-- still-valid part of its selection after its options change; a variable
-- that references another one (`label_values(up{job=~"$job"}, instance)`,
-- datasource `${ds}`) is fetched after it and refetched when it changes.

local Env = require("../env")
local Frame = require("../frame/types")
local Interpolate = require("./interpolate")
local Metrics = require("../source/metrics")
local Regex = require("../regex")
local Route = require("../config/route")
local Step = require("../time/step")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type Route = Route.Route

local M = {}

M.ALL = "$__all"

export type Option = { text: string, value: string }

export type Kind = "query" | "custom" | "constant" | "interval" | "datasource" | "textbox" | "unsupported"

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
}

-- What a query variable asks the metrics source for.
export type Fetch =
	{ kind: "label_names", match: string? }
	| { kind: "label_values", label: string, match: string? }
	| { kind: "metrics", regex: string }
	| { kind: "query_result", expr: string }

local KINDS: { [string]: Kind } = {
	query = "query",
	custom = "custom",
	constant = "constant",
	interval = "interval",
	datasource = "datasource",
	textbox = "textbox",
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

local function depsOf(v: Variable): { string }
	local texts = { v.query, v.regex, v.datasource_uid or "" }
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
	}
	if v.all_value == "" then
		v.all_value = nil
	end
	if kind == "datasource" and v.datasource_type == nil then
		-- The datasource variable's query is the plugin type it lists.
		v.datasource_type = v.query
	end
	if #v.texts ~= #v.values then
		v.texts = table.clone(v.values)
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
		v.texts = table.clone(v.values)
		return
	end
	if v.include_all then
		v.values, v.texts = { M.ALL }, { Interpolate.ALL_TEXT }
	elseif v.options[1] then
		v.values, v.texts = { v.options[1].value }, { v.options[1].text }
	else
		v.values, v.texts = {}, {}
	end
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

-- `var-<name>` values from a link override the dashboard's saved selection.
function M.applyUrl(vars: { Variable }, overrides: { [string]: { string } })
	for name, values in overrides do
		local v = M.find(vars, name)
		if v == nil or v.kind == "constant" or #values == 0 then
			continue
		end
		if v.include_all and #values == 1 and isAllText(values[1]) then
			v.values = { M.ALL }
		else
			v.values = table.clone(values)
			if not v.multi then
				v.values = { values[1] }
			end
		end
		v.texts = table.clone(v.values)
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

-- Interpolation scope of every resolved variable.
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
		local isAll = #v.values == 1 and v.values[1] == M.ALL
		scope[v.name] = {
			values = M.expanded(v),
			texts = M.expandedTexts(v),
			multi = v.multi,
			include_all = v.include_all,
			is_all = isAll,
			all_value = if isAll then v.all_value else nil,
		}
	end
	return scope
end

-- `var-x` values for links and Grafana URLs (constants are not synced).
function M.urlValues(vars: { Variable }): { [string]: { string } }
	local out: { [string]: { string } } = {}
	for _, v in vars do
		if v.kind == "constant" or v.kind == "unsupported" or #v.values == 0 then
			continue
		end
		if #v.values == 1 and v.values[1] == M.ALL then
			out[v.name] = { "$__all" }
		else
			out[v.name] = table.clone(v.values)
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

-- Parses the classic Prometheus variable query functions.
function M.parseQuery(query: string): (Fetch?, string?)
	local q = trim(query)
	local inner = string.match(q, "^label_names%((.*)%)$")
	if inner then
		inner = trim(inner)
		return { kind = "label_names", match = if inner == "" then nil else inner }, nil
	end
	inner = string.match(q, "^label_values%((.*)%)$")
	if inner then
		local selector, label = string.match(inner, "^(.*),%s*([%w_]+)%s*$")
		if selector and label then
			return { kind = "label_values", label = label, match = trim(selector) }, nil
		end
		local only = string.match(inner, "^%s*([%w_]+)%s*$")
		if only then
			return { kind = "label_values", label = only }, nil
		end
		return nil, "label_values needs a label name"
	end
	inner = string.match(q, "^metrics%((.*)%)$")
	if inner then
		return { kind = "metrics", regex = trim(inner) }, nil
	end
	inner = string.match(q, "^query_result%((.*)%)$")
	if inner then
		return { kind = "query_result", expr = trim(inner) }, nil
	end
	if q == "" then
		return nil, "the variable has no query"
	end
	return nil, "unsupported variable query (supported: label_names, label_values, metrics, query_result)"
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

-- The fetch for a query variable with its references interpolated.
function M.fetchFor(v: Variable, scope: Interpolate.Scope, builtins: Interpolate.Scope?): (Fetch?, string?)
	if v.datasource_type and v.datasource_type ~= "prometheus" then
		return nil, string.format("%s query variables are not supported (only prometheus)", v.datasource_type)
	end
	local s = if builtins then Interpolate.merge(builtins, scope) else scope
	local q = Interpolate.replace(v.query, s, { format = Interpolate.prometheus })
	return M.parseQuery(q)
end

export type Range = { from_ms: number, to_ms: number }

function M.request(fetch: Fetch, route: Route, range: Range): Request
	if fetch.kind == "label_names" then
		local m = fetch.match
		return Metrics.labelsRequest(
			route,
			{ match = if m then { m } else nil, from_ms = range.from_ms, to_ms = range.to_ms }
		)
	elseif fetch.kind == "label_values" then
		local m = fetch.match
		return Metrics.labelValuesRequest(
			route,
			fetch.label,
			{ match = if m then { m } else nil, from_ms = range.from_ms, to_ms = range.to_ms }
		)
	elseif fetch.kind == "metrics" then
		return Metrics.labelValuesRequest(route, "__name__", { from_ms = range.from_ms, to_ms = range.to_ms })
	end
	return Metrics.instantRequest(route, { expr = fetch.expr, time_ms = range.to_ms })
end

local function number(v: any): string
	if type(v) ~= "number" then
		return tostring(v)
	elseif v ~= v then
		return "NaN"
	elseif v == math.huge then
		return "+Inf"
	elseif v == -math.huge then
		return "-Inf"
	elseif v == math.floor(v) and math.abs(v) < 1e15 then
		return string.format("%d", v)
	end
	return string.format("%.17g", v)
end

-- query_result rows as Grafana's Prometheus datasource writes them:
-- `metric{a="1",b="2"} value timestamp_ms` (labels sorted, no spaces).
function M.queryResultValues(frames: { Frame.Frame }): { string }
	local out: { string } = {}
	for _, frame in frames do
		local timeField = Frame.timeField(frame)
		for _, field in Frame.numberFields(frame) do
			local n = #field.values
			local value = field.values[n]
			local ts = if timeField then timeField.values[n] else nil
			local labels: { [string]: string } = field.labels or {}
			local parts: { string } = {}
			for _, k in Frame.labelKeys(labels) do
				table.insert(parts, k .. '="' .. labels[k] .. '"')
			end
			local text = (labels.__name__ or "") .. "{" .. table.concat(parts, ",") .. "}"
			text ..= " " .. number(if Frame.isNull(value) then 0 / 0 else value)
			if type(ts) == "number" then
				text ..= " " .. string.format("%d", ts)
			end
			table.insert(out, text)
		end
	end
	return out
end

-- The raw values a fetch answered, before regex and sort.
function M.parseFetch(fetch: Fetch, route: Route, response: Response, env: Env): ({ string }?, string?)
	if fetch.kind == "query_result" then
		local r = Metrics.parse(route, response, env, "instant")
		if not r.ok then
			return nil, (r :: any).error.message
		end
		return M.queryResultValues((r :: any).frames), nil
	end
	local r = Metrics.parseList(route, response, env)
	if not r.ok then
		return nil, (r :: any).error.message
	end
	local values: { string } = (r :: any).values
	if fetch.kind == "metrics" and fetch.regex ~= "" then
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
-- metricNamesToVariableValues), duplicates dropped by value, then sorted.
function M.optionsFrom(v: Variable, values: { string }, scope: Interpolate.Scope): ({ Option }, string?)
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
	for _, value in values do
		if re == nil then
			add(value, value)
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
			add(value, value)
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

-- Options of a datasource variable from Grafana's datasource list.
function M.datasourceOptions(
	v: Variable,
	datasources: { { uid: string, type: string, name: string, is_default: boolean } },
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

-- The user picked values. `values` = { M.ALL } selects All.
function M.select(v: Variable, values: { string })
	if not v.multi and #values > 1 then
		values = { values[1] }
	end
	v.values = table.clone(values)
	v.from_url = false
	if v.kind == "textbox" then
		v.texts = table.clone(values)
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
	local all = table.clone(names)
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
