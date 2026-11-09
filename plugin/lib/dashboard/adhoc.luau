--!strict
-- Grafana's ad hoc filter variables: the model (scenes' AdHocFiltersVariable
-- as Grafana's dashboard-scene builds it from the saved `templating.list`
-- entry), its value (`filterExpression`), its URL form, the label selectors
-- its key and value lists are fetched with, and how the Prometheus and Loki
-- datasources add the filters to their queries.
--
-- Sources (grafana/scenes main, grafana/grafana v11.6..v13.0):
-- - packages/scenes/src/variables/adhoc/AdHocFiltersVariable.tsx (OPERATORS,
--   isFilterComplete, isMatchAllFilter, _getKeys/_getValuesFor) and
--   AdHocFiltersVariableUrlSyncHandler.ts (toArray, toFilter), utils.ts
--   (renderPrometheusLabelFilters, the URL delimiter escapes);
-- - packages/grafana-prometheus/src/add_label_to_query.ts (addLabelToQuery:
--   every vector selector, as lezer-promql finds them, re-rendered with the
--   filter by the query builder's renderQuery), datasource.ts
--   (enhanceExprWithAdHocFilters, remapOneOf from Grafana 13,
--   extractResourceMatcher), escaping.ts (prometheusRegularEscape);
-- - public/app/plugins/datasource/loki/modifyQuery.ts (addLabelToQuery: into
--   the stream selectors, or after the last parser, label filter or
--   label_format of each expression) and datasource.ts (addAdHocFilters,
--   getTagKeys/getTagValues).

local Env = require("../env")

type Env = Env.Env

local M = {}

export type Filter = {
	key: string,
	operator: string,
	value: string,
	-- The values of a multi-value operator (`=|`, `!=|`).
	values: { string }?,
	key_label: string?,
	value_labels: { string }?,
}

export type Key = { text: string, value: string }

export type Set = {
	filters: { Filter },
	-- Applied when listing keys only (scenes' baseFilters).
	base_filters: { Filter },
	-- Static keys that replace the datasource's key list.
	default_keys: { Key }?,
	-- Typed keys and values; without it the regex operators are not offered.
	allow_custom_value: boolean,
}

export type Operator = { value: string, description: string, multi: boolean?, regex: boolean? }

M.OPERATORS = table.freeze({
	{ value = "=", description = "Equals" },
	{ value = "!=", description = "Not equal" },
	{ value = "=|", description = "One of. Use to filter on multiple values.", multi = true },
	{ value = "!=|", description = "Not one of. Use to exclude multiple values.", multi = true },
	{ value = "=~", description = "Matches regex", regex = true },
	{ value = "!~", description = "Does not match regex", regex = true },
} :: { Operator })

M.ALL = "$__all"

function M.isMulti(op: string): boolean
	return op == "=|" or op == "!=|"
end

-- scenes' _getOperators: multi-value operators only where the datasource
-- plugin declares them (meta.multiValueFilterOperators), regex ones only
-- with custom values.
function M.operators(set: Set, multi: boolean): { Operator }
	local out: { Operator } = {}
	for _, o in M.OPERATORS do
		if (o.multi and not multi) or (o.regex and not set.allow_custom_value) then
			continue
		end
		table.insert(out, o)
	end
	return out
end

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	if type(v) == "string" then
		return v
	elseif type(v) == "number" then
		return tostring(v)
	end
	return nil
end

local function strList(env: Env, v: any): { string }?
	v = Env.value(env, v)
	if type(v) ~= "table" then
		return nil
	end
	local out: { string } = {}
	for _, x in v do
		local s = str(env, x)
		if s then
			table.insert(out, s)
		end
	end
	return out
end

local function filterOf(env: Env, raw: any): Filter?
	raw = Env.value(env, raw)
	if type(raw) ~= "table" then
		return nil
	end
	local key = str(env, raw.key)
	if key == nil or key == "" then
		return nil
	end
	local op = str(env, raw.operator) or "="
	local values = strList(env, raw.values)
	return {
		key = key,
		operator = op,
		value = str(env, raw.value) or (if values and values[1] then values[1] else ""),
		values = if M.isMulti(op) then values or {} else nil,
		key_label = str(env, raw.keyLabel),
		value_labels = strList(env, raw.valueLabels),
	}
end

local function filterList(env: Env, raw: any): { Filter }
	raw = Env.value(env, raw)
	local out: { Filter } = {}
	if type(raw) ~= "table" then
		return out
	end
	for _, r in raw do
		local f = filterOf(env, r)
		if f then
			table.insert(out, f)
		end
	end
	return out
end

-- The saved variable (dashboard-scene's createSceneVariableFromVariableModel:
-- origin filters first, then the user's).
function M.fromModel(raw: any, env: Env): Set
	local origin: { Filter } = {}
	local own: { Filter } = {}
	local list = Env.value(env, raw.filters)
	if type(list) == "table" then
		for _, r in list do
			local f = filterOf(env, r)
			if f then
				local o = Env.value(env, (Env.value(env, r) :: any).origin)
				table.insert(if type(o) == "string" and o ~= "" then origin else own, f)
			end
		end
	end
	for _, f in own do
		table.insert(origin, f)
	end
	local keys: { Key }? = nil
	local dk = Env.value(env, raw.defaultKeys)
	if type(dk) == "table" then
		local out: { Key } = {}
		for _, k in dk do
			k = Env.value(env, k)
			if type(k) == "table" then
				local text = str(env, k.text)
				local value = str(env, k.value) or text
				if value then
					table.insert(out, { text = text or value, value = value })
				end
			end
		end
		keys = out
	end
	return {
		filters = origin,
		base_filters = filterList(env, raw.baseFilters),
		default_keys = keys,
		allow_custom_value = Env.value(env, raw.allowCustomValue) ~= false,
	}
end

function M.isComplete(f: Filter): boolean
	return f.key ~= "" and f.operator ~= "" and f.value ~= ""
end

function M.isGroupBy(f: Filter): boolean
	return f.operator == "groupBy"
end

-- Matches everything (`=|` with All, or `=~ .*`): never sent to a datasource.
function M.isMatchAll(f: Filter): boolean
	if f.operator == "=|" then
		local values = f.values or (if f.value ~= "" then { f.value } else {})
		return table.find(values, M.ALL) ~= nil
	end
	return f.operator == "=~" and f.value == ".*"
end

-- The filters queries get (DrilldownDependenciesManager.getFilters).
function M.applied(filters: { Filter }): { Filter }
	local out: { Filter } = {}
	for _, f in filters do
		if M.isComplete(f) and not M.isGroupBy(f) and not M.isMatchAll(f) then
			table.insert(out, f)
		end
	end
	return out
end

-- Escapes ------------------------------------------------------------------------------

-- RE2 metacharacters (scenes' escapeLokiRegexp).
local function escapeRegex(s: string): string
	return (string.gsub(s, "[%*%+%?%(%)|\\%.%[%]{}%^%$]", "\\%0"))
end

-- Backslash, newline and double quote (escapeLabelValueInExactSelector).
local function escapeExact(s: string): string
	local out = string.gsub(s, "\\", "\\\\")
	out = string.gsub(out, "\n", "\\n")
	out = string.gsub(out, '"', '\\"')
	return out
end

local function unescapeLabelValue(s: string): string
	local out = string.gsub(s, "\\n", "\n")
	out = string.gsub(out, '\\"', '"')
	out = string.gsub(out, "\\\\", "\\")
	return out
end

-- The Prometheus datasource's prometheusRegularEscape; `special`: the
-- prometheusSpecialCharsInLabelValues feature toggle.
function M.promEscape(s: string, special: boolean?): string
	if special then
		-- A whole matcher (`job="grafana"`) keeps its quotes.
		local name = string.match(s, "^[%w_]+")
		if name then
			local rest = string.sub(s, #name + 1)
			local op = string.match(rest, "^[=!]~") or string.match(rest, "^!=") or string.match(rest, "^=")
			local quoted = if op then string.sub(rest, #op + 1) else ""
			if op and #quoted >= 2 and string.match(quoted, '^".*"$') then
				return s
			end
		end
		local out = string.gsub(s, "\\", "\\\\")
		out = string.gsub(out, '"', '\\"')
		return out
	end
	local out = string.gsub(s, "\\", "\\\\")
	out = string.gsub(out, "'", "\\\\'")
	return out
end

-- The variable's value (renderPrometheusLabelFilters over the applicable
-- filters): `key="value"` joined by commas; regex and one-of values are
-- regex-escaped.
function M.expression(filters: { Filter }): string
	local parts: { string } = {}
	for _, f in filters do
		if M.isGroupBy(f) or M.isMatchAll(f) then
			continue
		end
		local op, value = f.operator, ""
		if op == "=|" or op == "!=|" then
			op = if op == "=|" then "=~" else "!~"
			local vs: { string } = {}
			for i, v in f.values or {} :: { string } do
				vs[i] = escapeExact(escapeRegex(v))
			end
			value = table.concat(vs, "|")
		elseif op == "=~" or op == "!~" then
			value = escapeExact(escapeRegex(f.value))
		else
			value = escapeExact(f.value)
		end
		table.insert(parts, f.key .. op .. '"' .. value .. '"')
	end
	return table.concat(parts, ",")
end

-- How a filter shows in the variable bar.
function M.describe(f: Filter): string
	local value = if f.values and M.isMulti(f.operator)
		then table.concat(f.value_labels or f.values, ", ")
		else (if f.value_labels and f.value_labels[1] then f.value_labels[1] else f.value)
	return (f.key_label or f.key) .. " " .. f.operator .. " " .. value
end

-- URL form (`var-<name>=key|op|value`) ------------------------------------------------

local function escapeComma(s: string): string
	return (string.gsub(s, ",", "__gfc__"))
end

local function escapePipeHash(s: string): string
	return (string.gsub(string.gsub(s, "|", "__gfp__"), "#", "__gfh__"))
end

local function unescapeDelimiters(s: string): string
	local out = string.gsub(s, "__gfp__", "|")
	out = string.gsub(out, "__gfc__", ",")
	out = string.gsub(out, "__gfh__", "#")
	return out
end

local function commaDelimited(value: string, label: string?): string
	if label == nil or label == "" or label == value then
		return escapeComma(value)
	end
	return escapeComma(value) .. "," .. escapeComma(label)
end

function M.toUrl(f: Filter): string
	local parts = { commaDelimited(f.key, f.key_label), f.operator }
	if M.isMulti(f.operator) then
		for i, v in f.values or {} :: { string } do
			table.insert(parts, commaDelimited(v, if f.value_labels then f.value_labels[i] else nil))
		end
	else
		table.insert(parts, commaDelimited(f.value, if f.value_labels then f.value_labels[1] else nil))
	end
	for i, p in parts do
		parts[i] = escapePipeHash(p)
	end
	return table.concat(parts, "|")
end

-- One `var-<name>` value; nil for an empty or malformed one.
function M.fromUrl(s: string): Filter?
	if s == "" then
		return nil
	end
	local body = string.match(s, "^([^#]*)") or s
	local flat: { string } = {}
	for _, part in string.split(body, "|") do
		local comma = string.find(part, ",", 1, true)
		local key = if comma then string.sub(part, 1, comma - 1) else part
		local rest = if comma then string.sub(part, comma + 1) else nil
		local label = if rest then (string.match(rest, "^([^,]*)") or rest) else key
		table.insert(flat, unescapeDelimiters(key))
		table.insert(flat, unescapeDelimiters(label))
	end
	local key, keyLabel, op = flat[1] or "", flat[2], flat[3] or ""
	if key == "" then
		return nil
	end
	local values: { string } = {}
	local labels: { string } = {}
	for i = 5, #flat do
		table.insert(if (i - 5) % 2 == 0 then values else labels, flat[i])
	end
	return {
		key = key,
		operator = op,
		value = values[1] or "",
		values = if M.isMulti(op) then values else nil,
		key_label = if keyLabel ~= key then keyLabel else nil,
		value_labels = if table.concat(labels, "\0") ~= table.concat(values, "\0") then labels else nil,
	}
end

-- PromQL ----------------------------------------------------------------------------------

local SPECIAL: { [string]: boolean } = {
	inf = true,
	nan = true,
	bool = true,
	ignoring = true,
	on = true,
	group_left = true,
	group_right = true,
	offset = true,
}

local GROUPING: { [string]: boolean } = {
	by = true,
	without = true,
	on = true,
	ignoring = true,
	group_left = true,
	group_right = true,
}

local BINARY_WORDS: { [string]: boolean } = { ["and"] = true, ["or"] = true, unless = true, atan2 = true }

-- Aggregations may put their `by`/`without` before the body.
local AGGREGATIONS: { [string]: boolean } = {
	avg = true,
	bottomk = true,
	count = true,
	count_values = true,
	group = true,
	limitk = true,
	limit_ratio = true,
	max = true,
	min = true,
	quantile = true,
	stddev = true,
	stdvar = true,
	sum = true,
	topk = true,
}

local function isNameStart(c: string): boolean
	return string.match(c, "^[%a_:]$") ~= nil
end

local function isNameChar(c: string): boolean
	return string.match(c, "^[%w_:%.]$") ~= nil
end

local function skipSpace(q: string, i: number): number
	local n = #q
	while i <= n do
		local c = string.sub(q, i, i)
		if c == "#" then
			local nl = string.find(q, "\n", i, true)
			i = if nl then nl + 1 else n + 1
		elseif string.match(c, "^%s$") then
			i += 1
		else
			break
		end
	end
	return i
end

-- The end of the string literal opening at `i`: lezer's StringLiteral (an
-- unterminated one runs to the line or text end).
local function stringEnd(q: string, i: number): number
	local quote = string.sub(q, i, i)
	local n = #q
	local j = i + 1
	if quote == "`" then
		-- An unterminated raw string is no string.
		local e = string.find(q, "`", j, true)
		return e or i
	end
	while j <= n do
		local c = string.sub(q, j, j)
		if c == "\\" then
			j += 2
		elseif c == quote then
			return j
		elseif c == "\n" then
			return j - 1
		else
			j += 1
		end
	end
	return n
end

-- The `}` closing the matchers block opening at `i` (strings skipped).
local function braceEnd(q: string, i: number): number
	local n = #q
	local j = i + 1
	while j <= n do
		local c = string.sub(q, j, j)
		if c == '"' or c == "'" or c == "`" then
			j = stringEnd(q, j) + 1
		elseif c == "}" then
			return j
		else
			j += 1
		end
	end
	return n
end

local function closeEnd(q: string, i: number, open: string, close: string): number
	local n = #q
	local depth = 0
	local j = i
	while j <= n do
		local c = string.sub(q, j, j)
		if c == '"' or c == "'" or c == "`" then
			j = stringEnd(q, j)
		elseif c == open then
			depth += 1
		elseif c == close then
			depth -= 1
			if depth == 0 then
				return j
			end
		end
		j += 1
	end
	return n
end

export type Span = { from: number, to: number }

-- The vector selectors of a PromQL expression (byte spans, inclusive), as
-- lezer-promql's VectorSelector nodes: a metric name with its optional
-- `{...}` matchers, or a bare `{...}`. Function and aggregation names (a
-- name before `(`), keywords, grouping label lists, strings, comments and
-- `[...]` ranges are not selectors; `and`/`or`/`unless`/`atan2` are
-- operators after an operand and metric names elsewhere, as the grammar's
-- contextual keywords are.
function M.promSelectors(q: string): { Span }
	local out: { Span } = {}
	local n = #q
	local i = 1
	local operand = false
	-- After `offset` or `@` a leftover `$var`/`${...}` is the modifier's
	-- (lezer recovers without a selector there).
	local modifier = false
	while i <= n do
		local c = string.sub(q, i, i)
		if string.match(c, "^%s$") or c == "#" then
			i = skipSpace(q, i)
			continue
		elseif c == "$" and modifier then
			local k = i + 1
			if string.sub(q, k, k) == "{" then
				k = braceEnd(q, k) + 1
			else
				while k <= n and isNameChar(string.sub(q, k, k)) do
					k += 1
				end
			end
			i = k
			operand = true
		elseif c == '"' or c == "'" or c == "`" then
			i = stringEnd(q, i) + 1
			operand = true
		elseif c == "[" then
			i = closeEnd(q, i, "[", "]") + 1
			operand = true
		elseif c == "{" then
			local e = braceEnd(q, i)
			table.insert(out, { from = i, to = e })
			i = e + 1
			operand = true
		elseif isNameStart(c) then
			local j = i
			while j + 1 <= n and isNameChar(string.sub(q, j + 1, j + 1)) do
				j += 1
			end
			local word = string.lower(string.sub(q, i, j))
			local k = skipSpace(q, j + 1)
			local nextc = string.sub(q, k, k)
			if GROUPING[word] and nextc == "(" then
				i = closeEnd(q, k, "(", ")") + 1
				operand = word == "by" or word == "without"
			elseif SPECIAL[word] then
				i = j + 1
				operand = word == "inf" or word == "nan"
				modifier = word == "offset"
				continue
			elseif
				nextc == "("
				or (AGGREGATIONS[word] and string.match(string.lower(q), "^by[^%w_:]", k) ~= nil)
				or (AGGREGATIONS[word] and string.match(string.lower(q), "^without[^%w_:]", k) ~= nil)
				or (BINARY_WORDS[word] and operand)
			then
				-- A function or aggregation name, or a binary operator word.
				i = j + 1
				operand = false
			else
				local e = j
				if nextc == "{" then
					e = braceEnd(q, k)
				end
				table.insert(out, { from = i, to = e })
				i = e + 1
				operand = true
			end
		elseif string.match(c, "^%d$") or (c == "." and string.match(string.sub(q, i + 1, i + 1), "^%d$")) then
			local j = i
			while j + 1 <= n do
				local d = string.sub(q, j + 1, j + 1)
				local exponent = (d == "+" or d == "-")
					and string.match(string.sub(q, j, j), "^[eE]$") ~= nil
					and string.match(string.sub(q, j + 2, j + 2), "^%d$") ~= nil
				if string.match(d, "^[%w_%.]$") or exponent then
					j += 1
				else
					break
				end
			end
			i = j + 1
			operand = true
		elseif c == ")" then
			i += 1
			operand = true
		else
			i += 1
			operand = false
			modifier = c == "@"
			continue
		end
		modifier = false
	end
	return out
end

type Label = { label: string, op: string, value: string }
type Selector = { metric: string, labels: { Label } }

local MATCH_OPS = { "=~", "!~", "!=", "=" }

local function matchOpAt(s: string, i: number): string?
	for _, op in MATCH_OPS do
		if string.sub(s, i, i + #op - 1) == op then
			return op
		end
	end
	return nil
end

-- One `{`, `"`, `'` or backtick stripped from each end (the query builder's
-- /^["'`]|["'`]$/g).
local function unquote(s: string): string
	if string.match(s, "^[\"'`]") then
		s = string.sub(s, 2)
	end
	if string.match(s, "[\"'`]$") then
		s = string.sub(s, 1, -2)
	end
	return s
end

-- A selector as the Prometheus query builder parses it
-- (buildVisualQueryFromString on the selector text): the metric (a name,
-- or a quoted name alone in the braces) and the matchers with their values
-- as written between the quotes.
local function parseSelector(s: string): Selector
	local sel: Selector = { metric = "", labels = {} }
	local n = #s
	local i = skipSpace(s, 1)
	if isNameStart(string.sub(s, i, i)) then
		local j = i
		while j + 1 <= n and isNameChar(string.sub(s, j + 1, j + 1)) do
			j += 1
		end
		sel.metric = string.sub(s, i, j)
		i = skipSpace(s, j + 1)
	end
	if string.sub(s, i, i) ~= "{" then
		return sel
	end
	i += 1
	while i <= n do
		i = skipSpace(s, i)
		local c = string.sub(s, i, i)
		if c == "}" or i > n then
			break
		elseif c == "," then
			i += 1
			continue
		end
		local name: string? = nil
		local quoted = false
		if c == '"' or c == "'" or c == "`" then
			local e = stringEnd(s, i)
			name = string.sub(s, i, e)
			quoted = true
			i = e + 1
		elseif string.match(c, "^[%a_]$") then
			local j = i
			while j + 1 <= n and string.match(string.sub(s, j + 1, j + 1), "^[%w_%.]$") do
				j += 1
			end
			name = string.sub(s, i, j)
			i = j + 1
		else
			i += 1
			continue
		end
		local k = skipSpace(s, i)
		local op = matchOpAt(s, k)
		if op == nil then
			if quoted and sel.metric == "" then
				sel.metric = string.sub(name :: string, 2, -2)
			end
			continue
		end
		k = skipSpace(s, k + #op)
		local v = ""
		local vc = string.sub(s, k, k)
		if vc == '"' or vc == "'" or vc == "`" then
			local e = stringEnd(s, k)
			v = string.sub(s, k, e)
			k = e + 1
		end
		local label = if quoted then string.sub(name :: string, 2, -2) else name :: string
		table.insert(sel.labels, { label = label, op = op, value = unquote(v) })
		i = k
	end
	return sel
end

local function isLegacyName(s: string): boolean
	return string.match(s, "^[%a_:][%w_:]*$") ~= nil
end

local function utf8Name(s: string): string
	return if s == "" or isLegacyName(s) then s else '"' .. s .. '"'
end

local function renderSelector(sel: Selector, special: boolean?): string
	if sel.metric == "" and #sel.labels == 0 then
		return ""
	end
	local parts: { string } = {}
	for i, l in sel.labels do
		local v = l.value
		if special and l.op ~= "=~" and l.op ~= "!~" then
			v = M.promEscape(v, true)
		end
		parts[i] = utf8Name(l.label) .. l.op .. '"' .. v .. '"'
	end
	local labels = if #parts > 0 then "{" .. table.concat(parts, ", ") .. "}" else ""
	if sel.metric ~= "" then
		if isLegacyName(sel.metric) then
			return sel.metric .. labels
		end
		return '{"' .. sel.metric .. '"' .. (if #parts > 0 then ", " .. string.sub(labels, 2) else "}")
	end
	return labels
end

-- The Prometheus datasource's addLabelToQuery: the filter joins every
-- vector selector, unless the selector already has that label with that
-- value (then only a different operator is replaced).
function M.promAddLabel(q: string, key: string, value: string, op: string?, special: boolean?): string
	local operator = op or "="
	local spans = M.promSelectors(q)
	if #spans == 0 then
		return q
	end
	local out: { string } = {}
	local prev = 1
	for _, span in spans do
		local sel = parseSelector(string.sub(q, span.from, span.to))
		local hit = false
		for i, l in sel.labels do
			if l.label == key and l.value == value then
				hit = true
				if l.op ~= operator then
					sel.labels[i] = { label = key, op = operator, value = value }
				end
			end
		end
		if not hit then
			table.insert(sel.labels, { label = key, op = operator, value = value })
		end
		table.insert(out, string.sub(q, prev, span.from - 1))
		table.insert(out, renderSelector(sel, special))
		prev = span.to + 1
	end
	table.insert(out, string.sub(q, prev))
	return table.concat(out)
end

export type PromOptions = {
	-- Grafana's major version: 13 maps the one-of operators to regexes.
	major: number?,
	-- The prometheusSpecialCharsInLabelValues feature toggle.
	special: boolean?,
	-- Loki's lokiQuerySplitting feature toggle.
	loki_split: boolean?,
}

-- enhanceExprWithAdHocFilters: each filter added in turn, regex values
-- escaped as the datasource escapes them.
function M.promApply(expr: string, filters: { Filter }, opts: PromOptions?): string
	local o: PromOptions = opts or {}
	for _, f in filters do
		local op, value = f.operator, f.value
		if (o.major or 0) >= 13 and M.isMulti(op) then
			op = if op == "=|" then "=~" else "!~"
			local vs: { string } = {}
			for i, v in f.values or {} :: { string } do
				vs[i] = M.promEscape(v, o.special)
			end
			value = table.concat(vs, "|")
		end
		if op == "=~" or op == "!~" then
			value = M.promEscape(value, o.special)
		end
		expr = M.promAddLabel(expr, f.key, value, op, o.special)
	end
	return expr
end

-- The metric names the Prometheus queries select (populateMatchParamsFromQueries).
function M.promMetrics(exprs: { string }): { string }
	local out: { string } = {}
	for _, e in exprs do
		for _, span in M.promSelectors(e) do
			local m = parseSelector(string.sub(e, span.from, span.to)).metric
			if m ~= "" then
				table.insert(out, m)
			end
		end
	end
	return out
end

-- The `match[]` selector of a Prometheus key or value list
-- (extractResourceMatcher): the queries' metrics and the other filters.
function M.promMatch(metrics: { string }, filters: { Filter }, special: boolean?): string?
	local parts: { string } = {}
	if #metrics > 0 then
		table.insert(parts, '__name__=~"' .. table.concat(metrics, "|") .. '"')
	end
	for _, f in filters do
		local v = f.value
		if special and f.operator ~= "=~" and f.operator ~= "!~" then
			v = M.promEscape(v, true)
		end
		table.insert(parts, utf8Name(f.key) .. f.operator .. '"' .. v .. '"')
	end
	if #parts == 0 then
		return nil
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- LogQL -----------------------------------------------------------------------------------

-- JavaScript's String.prototype.substring over 0-based offsets (swapped when
-- start > end), which Grafana's splices rely on.
local function jsSub(s: string, a: number, b: number?): string
	local e = if b == nil then #s else math.clamp(b, 0, #s)
	local st = math.clamp(a, 0, #s)
	if st > e then
		st, e = e, st
	end
	return string.sub(s, st + 1, e)
end

-- 0-based [from, to) positions, as lezer's.
type Pos = { from: number, to: number }

type Pipeline = {
	selector: Pos,
	has_matcher: boolean,
	-- Parser, label filter and label_format stages.
	marks: { Pos },
	parser: boolean,
	-- Label names in the selector.
	names: { string },
}

local LOKI_PARSERS: { [string]: boolean } = { json = true, logfmt = true, regexp = true, pattern = true, unpack = true }

local LOKI_STAGE_END: { [string]: boolean } = { ["|"] = true, ["["] = true, [")"] = true }

-- The end (exclusive, 0-based) of the pipeline stage starting at 1-based
-- `i`: its last token before the next `|`, line filter, `[` or unmatched `)`.
local function lokiStageEnd(q: string, i: number): (number, number)
	local n = #q
	local depth = 0
	local last = i - 1
	local j = i
	while j <= n do
		local c = string.sub(q, j, j)
		if string.match(c, "^%s$") or c == "#" then
			j = skipSpace(q, j)
			continue
		end
		if depth == 0 then
			if LOKI_STAGE_END[c] then
				break
			end
		end
		if c == '"' or c == "`" or c == "'" then
			local e = stringEnd(q, j)
			last = e
			j = e + 1
			continue
		end
		if c == "(" then
			depth += 1
		elseif c == ")" then
			depth -= 1
		end
		last = j
		j += 1
	end
	return last, j
end

-- A stream selector as the Loki query builder parses it: values are the
-- text between the quotes.
local function lokiParseSelector(s: string): { Label }
	local out: { Label } = {}
	local n = #s
	local i = 1
	while i <= n do
		local a, b, name = string.find(s, "([%a_][%w_]*)", i)
		if a == nil then
			break
		end
		local k = skipSpace(s, (b :: number) + 1)
		local op = matchOpAt(s, k)
		if op == nil then
			i = (b :: number) + 1
			continue
		end
		k = skipSpace(s, k + #op)
		local vc = string.sub(s, k, k)
		local v = ""
		if vc == '"' or vc == "`" then
			local e = stringEnd(s, k)
			v = string.sub(s, k + 1, e - 1)
			k = e + 1
		end
		table.insert(out, { label = name :: string, op = op, value = v })
		i = k
	end
	return out
end

-- Every stream selector with its pipeline, and the expression leaves (the
-- operands of LogQL binary operators) in text order; a leaf without a
-- pipeline (a number, `vector(1)`) holds none.
local function lokiScan(q: string): ({ Pipeline }, { { Pipeline? } })
	local pipelines: { Pipeline } = {}
	local leaves: { { Pipeline? } } = {}
	local n = #q
	local i = 1
	local operand = false
	-- The duration after `offset` is no operand.
	local afterOffset = false
	local leaf: { Pipeline? }? = nil
	local function ensureLeaf()
		if leaf == nil then
			leaf = {}
			table.insert(leaves, leaf :: { Pipeline? })
		end
	end
	while i <= n do
		local c = string.sub(q, i, i)
		if string.match(c, "^%s$") or c == "#" then
			i = skipSpace(q, i)
			continue
		elseif c == '"' or c == "`" or c == "'" then
			i = stringEnd(q, i) + 1
			operand = true
		elseif c == "[" then
			i = closeEnd(q, i, "[", "]") + 1
			operand = true
		elseif c == "{" then
			local e = braceEnd(q, i)
			local names: { string } = {}
			for _, l in lokiParseSelector(string.sub(q, i, e)) do
				table.insert(names, l.label)
			end
			local hasMatcher = #names > 0
			local to = e
			if not hasMatcher then
				-- An empty selector takes the blanks after it (lezer's error recovery).
				local k = e + 1
				while k <= n and string.match(string.sub(q, k, k), "^%s$") do
					k += 1
				end
				to = k - 1
			end
			local p: Pipeline = {
				selector = { from = i - 1, to = to },
				has_matcher = hasMatcher,
				marks = {},
				parser = false,
				names = names,
			}
			table.insert(pipelines, p)
			ensureLeaf()
			table.insert(leaf :: { Pipeline? }, p)
			i = e + 1
			-- The pipeline stages.
			while true do
				local k = skipSpace(q, i)
				local two = string.sub(q, k, k + 1)
				if two == "|=" or two == "|~" or two == "|>" or two == "!=" or two == "!~" or two == "!>" then
					local _, nxt = lokiStageEnd(q, k + 2)
					i = nxt
				elseif string.sub(q, k, k) == "|" then
					local s = skipSpace(q, k + 1)
					local word = string.match(q, "^[%a_][%w_]*", s) or ""
					local last, nxt = lokiStageEnd(q, s)
					local after = skipSpace(q, s + #word)
					local nextc = string.sub(q, after, after)
					local filter = word ~= "" and (nextc == "=" or nextc == "!" or nextc == ">" or nextc == "<")
					if LOKI_PARSERS[word] or word == "label_format" or filter then
						table.insert(p.marks, { from = s - 1, to = last })
						p.parser = p.parser or LOKI_PARSERS[word] == true
					end
					i = nxt
				else
					i = k
					break
				end
			end
			operand = true
		elseif string.match(c, "^[%a_]$") then
			local j = i
			while j + 1 <= n and string.match(string.sub(q, j + 1, j + 1), "^[%w_]$") do
				j += 1
			end
			local word = string.lower(string.sub(q, i, j))
			local k = skipSpace(q, j + 1)
			if
				(
					word == "by"
					or word == "without"
					or word == "on"
					or word == "ignoring"
					or word == "group_left"
					or word == "group_right"
				) and string.sub(q, k, k) == "("
			then
				i = closeEnd(q, k, "(", ")") + 1
				operand = word == "by" or word == "without"
			elseif (word == "and" or word == "or" or word == "unless") and operand then
				leaf = nil
				operand = false
				i = j + 1
			elseif word == "vector" and string.sub(q, k, k) == "(" then
				ensureLeaf()
				i = closeEnd(q, k, "(", ")") + 1
				operand = true
			else
				i = j + 1
				operand = word ~= "bool"
				afterOffset = word == "offset"
				continue
			end
		elseif string.match(c, "^%d$") or (c == "$" and string.match(q, "^[%w_{]", i + 1)) then
			-- A number (or a variable standing for one) operand of a binary
			-- operator is a leaf of its own.
			local j = i
			if string.sub(q, i + 1, i + 1) == "{" then
				j = braceEnd(q, i + 1)
			end
			while j + 1 <= n and string.match(string.sub(q, j + 1, j + 1), "^[%w_%.]$") do
				j += 1
			end
			-- An argument (`topk(5, ...)`) and an offset are none.
			local k = skipSpace(q, j + 1)
			local nextc = string.sub(q, k, k)
			if nextc ~= "," and not afterOffset then
				ensureLeaf()
			end
			i = j + 1
			operand = true
		elseif c == ")" then
			i += 1
			operand = true
		elseif c == "(" or c == "," then
			i += 1
			operand = false
		else
			-- An operator: a binary one ends the operand's leaf.
			local two = string.sub(q, i, i + 1)
			local width = if two == "==" or two == "!=" or two == ">=" or two == "<=" then 2 else 1
			if operand and string.match(c, "^[%+%-%*/%%%^=!<>]$") then
				leaf = nil
			end
			i += width
			operand = false
		end
		afterOffset = false
	end
	return pipelines, leaves
end

local function lokiRender(labels: { Label }): string
	if #labels == 0 then
		return "{}"
	end
	local parts: { string } = {}
	for i, l in labels do
		parts[i] = l.label .. l.op .. '"' .. l.value .. '"'
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- Loki's addLabelToQuery (no label type: ad hoc filters carry none).
function M.lokiAddLabel(q: string, key: string, op: string, value: string): string
	local pipelines, leaves = lokiScan(q)
	if #pipelines == 0 then
		return q
	end
	local indexed, parsers, every = false, false, true
	for _, p in pipelines do
		if table.find(p.names, key) then
			indexed = true
		end
		parsers = parsers or p.parser
		every = every and p.has_matcher
	end
	if indexed or not parsers or not every then
		local out: { string } = {}
		local prev = 0
		for idx, p in pipelines do
			local labels = lokiParseSelector(jsSub(q, p.selector.from, p.selector.to))
			local hit = false
			for _, l in labels do
				if l.label == key and l.value == value then
					hit = true
				end
			end
			if not hit then
				table.insert(labels, { label = key, op = op, value = value })
			end
			table.insert(out, jsSub(q, prev, p.selector.from))
			table.insert(out, lokiRender(labels))
			if idx == #pipelines then
				table.insert(out, jsSub(q, p.selector.to))
			end
			prev = p.selector.to
		end
		return table.concat(out)
	end
	-- After the last parser, label filter or label_format of each leaf
	-- (a leaf with none splices at offset 0, as Grafana's findLastPosition does).
	local positions: { Pos } = {}
	for _, l in leaves do
		local last: Pos = { from = 0, to = 0 }
		for _, p in l do
			for _, m in (p :: Pipeline).marks do
				if m.to > last.to then
					last = m
				end
			end
		end
		table.insert(positions, last)
	end
	local num = tonumber(value)
	local filter = if num and (op == "<" or op == ">")
		then " | " .. key .. op .. tostring(num)
		else " | " .. key .. op .. "`" .. unescapeLabelValue(value) .. "`"
	local out: { string } = {}
	local prev = 0
	for idx, m in positions do
		table.insert(out, jsSub(q, prev, m.to))
		table.insert(out, filter)
		if idx == #positions then
			table.insert(out, jsSub(q, m.to))
		end
		prev = m.to
	end
	return table.concat(out)
end

-- The Loki datasource's addAdHocFilters: exact values escaped for the
-- selector, regex values as typed.
function M.lokiApply(expr: string, filters: { Filter }): string
	for _, f in filters do
		local value = f.value
		if not (string.find(f.operator, "=~", 1, true) or string.find(f.operator, "!~", 1, true)) then
			value = escapeExact(value)
		end
		expr = M.lokiAddLabel(expr, f.key, f.operator, value)
	end
	return expr
end

-- The stream selector a Loki key or value list is narrowed with (getTagKeys,
-- getTagValues); nil when it is `{}`.
function M.lokiMatch(filters: { Filter }): string?
	local s = "{}"
	for _, f in filters do
		s = M.lokiAddLabel(s, f.key, f.operator, f.value)
	end
	return if s == "{}" then nil else s
end

return M
