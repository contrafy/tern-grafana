--!strict
-- Dashboard variable interpolation, ported from Grafana's TemplateSrv.replace
-- (public/app/features/templating/template_srv.ts) and its format registry
-- (formatRegistry.ts). Syntaxes: `$name`, `${name}`, `${name:format}`,
-- `[[name]]`, `[[name:format]]`. A name the scope does not know stays as
-- written, so `$__rate_interval` survives for Grafana's backend when the
-- caller does not provide it.
--
-- A variable's value is a list when it is multi-value or "All" is selected
-- (Grafana passes an array then, even with one element); otherwise a single
-- string. The default format is the caller's (the Prometheus and Loki
-- datasources format multi-value variables as escaped regex alternations),
-- else Grafana's `glob`.

local M = {}

export type Var = {
	values: { string },
	-- Display texts per value (the `text` format); defaults to the values.
	texts: { string }?,
	-- Multi-value variable: its value is a list.
	multi: boolean?,
	include_all: boolean?,
	-- "All" is selected: `values` hold every option value.
	is_all: boolean?,
	-- Custom all value (`allValue`), used raw instead of the option list.
	all_value: string?,
	-- One value of a repeated panel or row: a plain string even when the
	-- variable is multi-value (Grafana's scopedVars).
	single: boolean?,
}

export type Scope = { [string]: Var }

-- Formats a value list (`list` = Grafana would see an array) for a variable.
export type Formatter = (values: { string }, var: Var, list: boolean) -> string

export type Options = {
	-- Used when the reference names no format.
	format: Formatter?,
}

M.ALL_TEXT = "All"

-- Characters Grafana's kbn.regexEscape escapes.
local function regexEscape(s: string): string
	return (string.gsub(s, "[\\%^%$%*%+%?%.%(%)|%[%]{}/]", "\\%0"))
end

local function luceneEscape(s: string): string
	return (string.gsub(s, '[!%*%+%-=<>%s&|%(%)%[%]{}%^~%?:\\/"]', "\\%0"))
end

-- encodeURIComponent plus !'()* (Grafana's encodeURIComponentStrict).
local function percentEncode(s: string): string
	return (
		string.gsub(s, "[^%w%-%._~]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

local function jsonString(s: string): string
	local escaped = string.gsub(s, '[%c"\\]', function(c: string): string
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\t" then
			return "\\t"
		elseif c == "\r" then
			return "\\r"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. escaped .. '"'
end

local function mapJoin(values: { string }, fn: (string) -> string, sep: string): string
	local out = table.create(#values)
	for i, v in values do
		out[i] = fn(v)
	end
	return table.concat(out, sep)
end

local function single(values: { string }): string
	return values[1] or ""
end

-- Grafana's formats by id; `list` says whether the value is an array.
local FORMATS: { [string]: (values: { string }, list: boolean) -> string } = {
	regex = function(values, list)
		if not list then
			return regexEscape(single(values))
		end
		if #values == 1 then
			return regexEscape(values[1])
		end
		return "(" .. mapJoin(values, regexEscape, "|") .. ")"
	end,
	pipe = function(values, _list)
		return table.concat(values, "|")
	end,
	csv = function(values, _list)
		return table.concat(values, ",")
	end,
	raw = function(values, _list)
		return table.concat(values, ",")
	end,
	json = function(values, list)
		if not list then
			return jsonString(single(values))
		end
		return "[" .. mapJoin(values, jsonString, ",") .. "]"
	end,
	glob = function(values, list)
		if list and #values > 1 then
			return "{" .. table.concat(values, ",") .. "}"
		end
		return table.concat(values, ",")
	end,
	singlequote = function(values, _list)
		return mapJoin(values, function(v: string): string
			return "'" .. string.gsub(v, "'", "\\'") .. "'"
		end, ",")
	end,
	doublequote = function(values, _list)
		return mapJoin(values, function(v: string): string
			return '"' .. string.gsub(v, '"', '\\"') .. '"'
		end, ",")
	end,
	sqlstring = function(values, _list)
		return mapJoin(values, function(v: string): string
			return "'" .. string.gsub(v, "'", "''") .. "'"
		end, ",")
	end,
	lucene = function(values, list)
		if not list then
			return luceneEscape(single(values))
		end
		if #values == 0 then
			return "__empty__"
		end
		return "("
			.. mapJoin(values, function(v: string): string
				return '"' .. luceneEscape(v) .. '"'
			end, " OR ")
			.. ")"
	end,
	percentencode = function(values, _list)
		return percentEncode(table.concat(values, ","))
	end,
}

M.FORMATS = table.freeze((function()
	local names = {}
	for name in FORMATS do
		table.insert(names, name)
	end
	table.insert(names, "text")
	table.insert(names, "queryparam")
	table.sort(names)
	return names
end)())

-- A default formatter from one of Grafana's named formats (`regex` for
-- variable regexes, as Grafana interpolates them).
function M.named(name: string): Formatter
	local f = FORMATS[name] or FORMATS.glob
	return function(values: { string }, _var: Var, list: boolean): string
		return f(values, list)
	end
end

-- Display texts (`${x:text}`) as the default: panel and row titles.
function M.text(values: { string }, var: Var, _list: boolean): string
	if var.is_all and not var.single then
		return M.ALL_TEXT
	end
	return table.concat(var.texts or values, " + ")
end

-- Prometheus datasource escaping (prometheusRegularEscape and
-- prometheusSpecialRegexEscape in public/app/plugins/datasource/prometheus).
local function promRegular(s: string): string
	return (string.gsub(s, "'", "\\\\'"))
end

local function promSpecial(s: string): string
	local out = string.gsub(s, "\\", "\\\\\\\\")
	out = string.gsub(out, "[%$%^%*{}%[%]'%+%?%.%(%)|]", "\\\\%0")
	return out
end

-- The Prometheus datasource's interpolateQueryExpr: plain values are quoted
-- for a string literal; multi-value and include-all variables become a regex
-- alternation (they are meant for `=~`).
function M.prometheus(values: { string }, var: Var, list: boolean): string
	if not var.multi and not var.include_all then
		return promRegular(table.concat(values, ","))
	end
	if not list then
		return promSpecial(single(values))
	end
	if #values == 1 then
		return promSpecial(values[1])
	end
	return "(" .. mapJoin(values, promSpecial, "|") .. ")"
end

-- The Loki datasource: the same regex escaping, alternatives without parentheses.
function M.loki(values: { string }, var: Var, list: boolean): string
	if not var.multi and not var.include_all then
		return (string.gsub(table.concat(values, ","), "\\", "\\\\"))
	end
	if not list then
		return promSpecial(single(values))
	end
	return mapJoin(values, promSpecial, "|")
end

local function isoDate(ms: number): string
	local s = math.floor(ms / 1000)
	local frac = math.floor(ms - s * 1000)
	return os.date("!%Y-%m-%dT%H:%M:%S", s) .. string.format(".%03dZ", frac)
end

-- `${__from:date:...}` and friends: the variable's value is epoch ms.
local function dateFormat(var: Var, arg: string?): string
	local ms = tonumber(single(var.values))
	if ms == nil then
		return single(var.values)
	end
	if arg == "seconds" then
		return string.format("%d", ms // 1000)
	end
	-- "iso", no argument, or a moment pattern (not supported: ISO instead).
	return isoDate(ms)
end

local function formatVar(name: string, var: Var, fmt: string?, opts: Options?): string
	local list = not var.single and (var.multi == true or var.is_all == true)
	local values = var.values
	local fmtName: string?, fmtArg: string? = fmt, nil
	if fmt then
		local head, rest = string.match(fmt, "^([^:]*):(.*)$")
		if head and rest then
			fmtName, fmtArg = head, rest
		end
	end
	if fmtName == "date" then
		return dateFormat(var, fmtArg)
	end
	if fmtName == "text" then
		if var.is_all then
			return M.ALL_TEXT
		end
		return table.concat(var.texts or values, " + ")
	end
	local queryParam = fmtName == "queryparam"
	if var.is_all and var.all_value and fmtName ~= "percentencode" then
		if queryParam then
			return "var-" .. name .. "=$__all"
		end
		return var.all_value
	end
	if queryParam then
		return mapJoin(values, function(v: string): string
			return "var-" .. percentEncode(name) .. "=" .. percentEncode(v)
		end, "&")
	end
	local formatter = if fmtName then FORMATS[fmtName] else nil
	if formatter then
		return formatter(values, list)
	end
	if fmtName == nil and opts and opts.format then
		return opts.format(values, var, list)
	end
	return FORMATS.glob(values, list)
end

-- One reference found in a text. `field` is the `${name.field}` path.
type Ref = { start: number, finish: number, name: string, field: string?, fmt: string? }

-- `${...}` at `s`: name, then an optional `.field`, then an optional `:format`.
local function bracedRef(text: string, s: number): Ref?
	local name, e = string.match(text, "^%${([%w_]+)()", s)
	if name == nil or e == nil then
		return nil
	end
	local field: string?, fmt: string? = nil, nil
	local f, fe = string.match(text, "^%.([^:}]+)()", e)
	if f and fe then
		field, e = f, fe
	end
	local m, me = string.match(text, "^:([^}]+)()", e)
	if m and me then
		fmt, e = m, me
	end
	if string.sub(text, e, e) ~= "}" then
		return nil
	end
	return { start = s, finish = e, name = name, field = field, fmt = fmt }
end

-- The next reference at or after `pos`, Grafana's variableRegex:
-- \$(\w+)|\[\[(\w+?)(?::(\w+))?\]\]|\${(\w+)(?:\.([^:^\}]+))?(?::([^\}]+))?}
local function nextRef(text: string, pos: number): Ref?
	while true do
		local s = string.find(text, "[%$%[]", pos)
		if s == nil then
			return nil
		end
		if string.sub(text, s, s) == "$" then
			local braced = bracedRef(text, s)
			if braced then
				return braced
			end
			local plain, pe = string.match(text, "^%$([%w_]+)()", s)
			if plain and pe then
				return { start = s, finish = pe - 1, name = plain }
			end
		else
			local name, fmt, e = string.match(text, "^%[%[([%w_]+):?([%w_]*)%]%]()", s)
			if name and e then
				return { start = s, finish = e - 1, name = name, fmt = if fmt == "" then nil else fmt }
			end
		end
		pos = s + 1
	end
end

-- The scope entry a reference names: `${x.field}` looks up "x.field" first
-- (built-ins such as `${__user.login}`); `.text` and `.value` of a plain
-- variable select its display text or value.
local function lookup(ref: Ref, scope: Scope): (string?, Var?, string?)
	if ref.field == nil then
		return ref.name, scope[ref.name], ref.fmt
	end
	local dotted = ref.name .. "." .. ref.field
	if scope[dotted] then
		return dotted, scope[dotted], ref.fmt
	end
	local base = scope[ref.name]
	if base and ref.field == "text" then
		return ref.name, base, "text"
	elseif base and ref.field == "value" then
		return ref.name, base, ref.fmt
	end
	return nil, nil, nil
end

function M.replace(text: string, scope: Scope, opts: Options?): string
	if not string.find(text, "[%$%[]") then
		return text
	end
	local out: { string } = {}
	local pos = 1
	while true do
		local ref = nextRef(text, pos)
		if ref == nil then
			break
		end
		local name, var, fmt = lookup(ref, scope)
		if name and var then
			table.insert(out, string.sub(text, pos, ref.start - 1))
			table.insert(out, formatVar(name, var, fmt, opts))
		else
			table.insert(out, string.sub(text, pos, ref.finish))
		end
		pos = ref.finish + 1
	end
	table.insert(out, string.sub(text, pos))
	return table.concat(out)
end

-- Variable names referenced in `text`, in order of first use, no duplicates.
function M.references(text: string): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local pos = 1
	while true do
		local ref = nextRef(text, pos)
		if ref == nil then
			return out
		end
		if not seen[ref.name] then
			seen[ref.name] = true
			table.insert(out, ref.name)
		end
		pos = ref.finish + 1
	end
end

-- A single-valued scope entry (built-ins, constants).
function M.value(v: string): Var
	return { values = { v } }
end

-- Grafana's built-in variables for a time range and panel interval.
export type Builtins = {
	from_ms: number,
	to_ms: number,
	interval_ms: number?,
	interval: string?,
	rate_interval: string?,
	dashboard_title: string?,
	dashboard_uid: string?,
	org_id: number?,
	org_name: string?,
	user_login: string?,
}

local function int(n: number): string
	return string.format("%d", math.floor(n))
end

function M.builtins(b: Builtins): Scope
	local range_ms = b.to_ms - b.from_ms
	local range_s = int(math.floor(range_ms / 1000 + 0.5))
	local scope: Scope = {
		__from = M.value(int(b.from_ms)),
		__to = M.value(int(b.to_ms)),
		__range_ms = M.value(int(range_ms)),
		__range_s = M.value(range_s),
		__range = M.value(range_s .. "s"),
	}
	local function put(name: string, v: string?)
		if v then
			scope[name] = M.value(v)
		end
	end
	put("__interval_ms", if b.interval_ms then int(b.interval_ms) else nil)
	put("__interval", b.interval)
	put("__rate_interval", b.rate_interval)
	put("__dashboard", b.dashboard_title)
	put("__dashboard.uid", b.dashboard_uid)
	put("__org", if b.org_id then int(b.org_id) else nil)
	put("__org.id", if b.org_id then int(b.org_id) else nil)
	put("__org.name", b.org_name)
	put("__user.login", b.user_login)
	return scope
end

-- `a` overlaid with `b` (b wins).
function M.merge(a: Scope, b: Scope): Scope
	local out: Scope = table.clone(a)
	for k, v in b do
		out[k] = v
	end
	return out
end

return M
