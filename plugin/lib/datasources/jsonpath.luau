--!strict
-- JSONPath as the JSON API datasource evaluates it: jsonpath-plus 10.3.0
-- (src/jsonpath.js) with `eval: false` and the default `wrap: true`, ported
-- step by step so a path selects what it selects in Grafana, quirks
-- included: the path is split by toPathArray's regex rewrites (so
-- `$['a','b']` names the keys `a'` and `'b`, and `[-1]` selects nothing;
-- `[-1:]` is the last item), `length` is an own property of arrays and
-- strings, slices treat an end of 0 as "to the end", and filter or script
-- expressions (`[?(...)]`, `[(...)]`) fail with the library's "Eval ...
-- prevented" error once the walk reaches them. `^` (parent), `~` (property
-- name), `@type()` selectors and backtick-escaped names work as there.
--
-- Documents are decoded here (M.decode) rather than with the host codec:
-- object keys keep JavaScript's order (array-index keys ascending, then
-- insertion order), which `*`, `..` and JSON.stringify depend on, and empty
-- arrays stay distinct from empty objects.

local Frame = require("../frame/types")

local M = {}

-- JSON null in decoded documents (and in frame values).
M.NULL = Frame.NULL

local ARRAY = table.freeze({ __type = "json-array" })
local OBJECT = table.freeze({ __type = "json-object" })

-- A decoded object: keys in JavaScript's own-key order.
export type Object = { keys: { string }, values: { [string]: any } }

function M.isArray(v: any): boolean
	return type(v) == "table" and getmetatable(v) == ARRAY
end

function M.isObject(v: any): boolean
	return type(v) == "table" and getmetatable(v) == OBJECT
end

function M.array(items: { any }): { any }
	return setmetatable(items, ARRAY) :: any
end

-- An object from keys and values (keys put in JavaScript's order).
function M.object(keys: { string }, values: { [string]: any }): Object
	return setmetatable({ keys = keys, values = values }, OBJECT) :: any
end

-- JavaScript ---------------------------------------------------------------------

-- A canonical array index ("0", "17"; not "01" or "-1"), as a number.
local function arrayIndex(k: string): number?
	if k == "0" or string.match(k, "^[1-9]%d*$") then
		local n = tonumber(k) :: number
		if n < 4294967295 then
			return n
		end
	end
	return nil
end

M.arrayIndex = arrayIndex

-- JavaScript's own-key order: array indexes ascending, then the rest in
-- insertion order.
local function jsKeyOrder(keys: { string }): { string }
	local idx: { string } = {}
	local rest: { string } = {}
	for _, k in keys do
		table.insert(if arrayIndex(k) then idx else rest, k)
	end
	if #idx == 0 then
		return keys
	end
	table.sort(idx, function(a, b): boolean
		return (arrayIndex(a) :: number) < (arrayIndex(b) :: number)
	end)
	table.move(rest, 1, #rest, #idx + 1, idx)
	return idx
end

M.jsKeyOrder = jsKeyOrder

-- JavaScript truthiness of a decoded value.
local function truthy(v: any): boolean
	if v == nil or v == M.NULL or v == false or v == "" then
		return false
	end
	return not (type(v) == "number" and (v == 0 or v ~= v))
end

M.truthy = truthy

-- `typeof v === "object"` (null included).
local function isObjectType(v: any): boolean
	return v == M.NULL or M.isArray(v) or M.isObject(v)
end

-- UTF-16 code units of a string, each as the text it stands for (a
-- character outside the BMP is one entry per unit: the character, then "").
local function utf16Units(s: string): { string }
	local out: { string } = {}
	local ok = pcall(function()
		for _, cp in utf8.codes(s) do
			table.insert(out, utf8.char(cp))
			if cp >= 0x10000 then
				table.insert(out, "")
			end
		end
	end)
	if not ok then
		out = {}
		for i = 1, #s do
			out[i] = string.sub(s, i, i)
		end
	end
	return out
end

local function jsNumberKey(n: number): string
	if n == math.floor(n) and math.abs(n) < 1e21 then
		return string.format("%d", n)
	end
	return tostring(n)
end

-- Object.hasOwn(val, key) and val[key], for `val &&` values.
local function own(val: any, key: any): (boolean, any)
	if not truthy(val) then
		return false, nil
	end
	if M.isArray(val) then
		local n = #val
		local i: number? = nil
		if type(key) == "number" then
			i = if key == math.floor(key) and key >= 0 then key else nil
		elseif type(key) == "string" then
			if key == "length" then
				return true, n
			end
			i = arrayIndex(key)
		end
		if i and i < n then
			return true, val[(i :: number) + 1]
		end
		return false, nil
	elseif M.isObject(val) then
		local k = if type(key) == "number" then jsNumberKey(key) else tostring(key)
		local v = (val :: Object).values[k]
		if v == nil then
			return false, nil
		end
		return true, v
	elseif type(val) == "string" then
		local k = if type(key) == "number" then jsNumberKey(key) else tostring(key)
		local units = utf16Units(val)
		if k == "length" then
			return true, #units
		end
		local i = arrayIndex(k)
		if i and i < #units then
			return true, units[i + 1]
		end
	end
	return false, nil
end

-- Object.keys / array indexes, as jsonpath-plus's _walk visits them.
local function walk(val: any, f: (any) -> ())
	if M.isArray(val) then
		for i = 0, #val - 1 do
			f(i)
		end
	elseif M.isObject(val) then
		for _, k in (val :: Object).keys do
			f(k)
		end
	end
end

local function child(val: any, m: any): any
	if M.isArray(val) then
		return val[m + 1]
	end
	return (val :: Object).values[m]
end

-- JSON.parse -------------------------------------------------------------------------

local ESCAPES: { [string]: string } =
	{ b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function fail(what: string, pos: number): never
	error({ json_error = string.format("%s in JSON at position %d", what, pos - 1) }, 0)
end

local function skipWs(s: string, i: number): number
	local _, e = string.find(s, "^[ \t\r\n]*", i)
	return (e :: number) + 1
end

local parseValue: (string, number) -> (any, number)

local function parseString(s: string, i: number): (string, number)
	local out: { string } = {}
	i += 1
	while true do
		local j = string.find(s, '[\1-\31"\\]', i)
		if j == nil then
			fail("Unterminated string", #s + 1)
		end
		local at = j :: number
		if at > i then
			table.insert(out, string.sub(s, i, at - 1))
		end
		local c = string.sub(s, at, at)
		if c == '"' then
			return table.concat(out), at + 1
		elseif c == "\\" then
			local e = string.sub(s, at + 1, at + 1)
			if e == "u" then
				local hex = string.sub(s, at + 2, at + 5)
				if not string.match(hex, "^%x%x%x%x$") then
					fail("Bad Unicode escape", at)
				end
				local cp = tonumber(hex, 16) :: number
				i = at + 6
				if cp >= 0xD800 and cp <= 0xDBFF and string.sub(s, i, i + 1) == "\\u" then
					local low = tonumber(string.sub(s, i + 2, i + 5), 16)
					if low and low >= 0xDC00 and low <= 0xDFFF then
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
						i += 6
					end
				end
				table.insert(out, if cp >= 0xD800 and cp <= 0xDFFF then utf8.char(0xFFFD) else utf8.char(cp))
			elseif ESCAPES[e] then
				table.insert(out, ESCAPES[e])
				i = at + 2
			else
				fail("Bad escaped character", at + 1)
			end
		else
			fail("Bad control character in string literal", at)
		end
	end
end

parseValue = function(s: string, i: number): (any, number)
	i = skipWs(s, i)
	local c = string.sub(s, i, i)
	if c == "{" then
		local keys: { string } = {}
		local values: { [string]: any } = {}
		i = skipWs(s, i + 1)
		if string.sub(s, i, i) == "}" then
			return M.object(keys, values), i + 1
		end
		while true do
			if string.sub(s, i, i) ~= '"' then
				fail("Expected property name", i)
			end
			local key
			key, i = parseString(s, i)
			i = skipWs(s, i)
			if string.sub(s, i, i) ~= ":" then
				fail("Expected ':' after property name", i)
			end
			local v
			v, i = parseValue(s, i + 1)
			if values[key] == nil then
				table.insert(keys, key)
			end
			values[key] = v
			i = skipWs(s, i)
			local d = string.sub(s, i, i)
			if d == "," then
				i = skipWs(s, i + 1)
			elseif d == "}" then
				return M.object(jsKeyOrder(keys), values), i + 1
			else
				fail("Expected ',' or '}' after property value", i)
			end
		end
	elseif c == "[" then
		local items: { any } = {}
		i = skipWs(s, i + 1)
		if string.sub(s, i, i) == "]" then
			return M.array(items), i + 1
		end
		while true do
			local v
			v, i = parseValue(s, i)
			table.insert(items, v)
			i = skipWs(s, i)
			local d = string.sub(s, i, i)
			if d == "," then
				i += 1
			elseif d == "]" then
				return M.array(items), i + 1
			else
				fail("Expected ',' or ']' after array element", i)
			end
		end
	elseif c == '"' then
		return parseString(s, i)
	elseif string.sub(s, i, i + 3) == "true" then
		return true, i + 4
	elseif string.sub(s, i, i + 4) == "false" then
		return false, i + 5
	elseif string.sub(s, i, i + 3) == "null" then
		return M.NULL, i + 4
	end
	local num = string.match(s, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
	if
		num
		and (
			string.match(num, "^%-?0$")
			or string.match(num, "^%-?[1-9]%d*$")
			or string.match(num, "^%-?0%.%d+$")
			or string.match(num, "^%-?[1-9]%d*%.%d+$")
			or string.match(num, "^%-?0[eE][%+%-]?%d+$")
			or string.match(num, "^%-?[1-9]%d*[eE][%+%-]?%d+$")
			or string.match(num, "^%-?0%.%d+[eE][%+%-]?%d+$")
			or string.match(num, "^%-?[1-9]%d*%.%d+[eE][%+%-]?%d+$")
		)
	then
		return tonumber(num) :: number, i + #num
	end
	if c == "" then
		fail("Unexpected end of JSON input", i)
	end
	fail("Unexpected token", i)
	return nil, i
end

-- JSON.parse(text) in the document model (objects keep their key order);
-- nil and the error when the text is not JSON.
function M.decode(text: string): (any, string?)
	local ok, v = pcall(function()
		local value, pos = parseValue(text, 1)
		pos = skipWs(text, pos)
		if pos <= #text then
			fail("Unexpected non-whitespace character after JSON", pos)
		end
		return value
	end)
	if not ok then
		local e = v :: any
		return nil, if type(e) == "table" and e.json_error then e.json_error else tostring(e)
	end
	return v, nil
end

-- JSON.stringify ---------------------------------------------------------------------

local function jsonString(s: string): string
	local out = string.gsub(s, '[%c"\\]', function(c: string): string
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		elseif c == "\b" then
			return "\\b"
		elseif c == "\f" then
			return "\\f"
		elseif c == "\127" then
			return c
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. out .. '"'
end

-- Number.prototype.toString: the shortest round-trip digits (Luau's
-- tostring) laid out by JavaScript's rules (plain notation from 1e-6 up to
-- 1e21, exponent notation outside).
function M.numberString(v: number): string
	if v ~= v then
		return "NaN"
	elseif v == math.huge then
		return "Infinity"
	elseif v == -math.huge then
		return "-Infinity"
	elseif v == 0 then
		return "0"
	end
	local sign = if v < 0 then "-" else ""
	local s = tostring(math.abs(v))
	local mant, ex = string.match(s, "^([%d%.]+)[eE]([%+%-]?%d+)$")
	local m = (mant or s) :: string
	local e = if ex then tonumber(ex) :: number else 0
	local int, frac = string.match(m, "^(%d*)%.?(%d*)$")
	local digits = (int :: string) .. (frac :: string)
	-- n: where the decimal point sits after the first digit of `digits`.
	local n = #(int :: string) + e
	local lead = string.match(digits, "^0*") :: string
	digits = string.sub(digits, #lead + 1)
	n -= #lead
	digits = string.gsub(digits, "0+$", "") :: string
	local k = #digits
	if k <= n and n <= 21 then
		return sign .. digits .. string.rep("0", n - k)
	elseif 0 < n and n <= 21 then
		return sign .. string.sub(digits, 1, n) .. "." .. string.sub(digits, n + 1)
	elseif -6 < n and n <= 0 then
		return sign .. "0." .. string.rep("0", -n) .. digits
	end
	local exp = n - 1
	local expText = (if exp >= 0 then "+" else "-") .. tostring(math.abs(exp))
	if k == 1 then
		return sign .. digits .. "e" .. expText
	end
	return sign .. string.sub(digits, 1, 1) .. "." .. string.sub(digits, 2) .. "e" .. expText
end

function M.stringify(v: any): string
	if v == M.NULL or v == nil then
		return "null"
	elseif type(v) == "string" then
		return jsonString(v)
	elseif type(v) == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "null"
		end
		return M.numberString(v)
	elseif type(v) == "boolean" then
		return if v then "true" else "false"
	elseif M.isArray(v) then
		local parts = table.create(#v)
		for i, x in v do
			parts[i] = M.stringify(x)
		end
		return "[" .. table.concat(parts, ",") .. "]"
	elseif M.isObject(v) then
		local o = v :: Object
		local parts = table.create(#o.keys)
		for i, k in o.keys do
			parts[i] = jsonString(k) .. ":" .. M.stringify(o.values[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

-- String(v).
function M.toString(v: any): string
	if v == M.NULL then
		return "null"
	elseif type(v) == "string" then
		return v
	elseif type(v) == "number" then
		return M.numberString(v)
	elseif type(v) == "boolean" then
		return if v then "true" else "false"
	elseif M.isArray(v) then
		local parts = table.create(#v)
		for i, x in v do
			parts[i] = if x == M.NULL then "" else M.toString(x)
		end
		return table.concat(parts, ",")
	elseif M.isObject(v) then
		return "[object Object]"
	end
	return tostring(v)
end

-- toPathArray ------------------------------------------------------------------------
-- JSONPath.toPathArray's chain of regex replacements, each written as the
-- scan the regex performs.

local VALUE_TYPES = table.freeze({
	null = true,
	boolean = true,
	number = true,
	string = true,
	integer = true,
	undefined = true,
	nonFinite = true,
	scalar = true,
	array = true,
	object = true,
	["function"] = true,
	other = true,
})

local function isLineTerminator(c: string): boolean
	return c == "\n" or c == "\r"
end

local function at(s: string, i: number): string
	return string.sub(s, i, i)
end

-- .replaceAll(/[['](\??\(.*?\))[\]'](?!.\])/gu, '[#n]'), collecting the groups.
local function extractScripts(s: string, subx: { string }): string
	local out: { string } = {}
	local i = 1
	local n = #s
	while i <= n do
		local c = at(s, i)
		local matched = false
		if c == "[" or c == "'" then
			local p: number? = nil
			if at(s, i + 1) == "?" and at(s, i + 2) == "(" then
				p = i + 2
			elseif at(s, i + 1) == "(" then
				p = i + 1
			end
			if p then
				local j = (p :: number) + 1
				while j <= n do
					local cj = at(s, j)
					if
						cj == ")"
						and (at(s, j + 1) == "]" or at(s, j + 1) == "'")
						and not (j + 2 <= n and not isLineTerminator(at(s, j + 2)) and at(s, j + 3) == "]")
					then
						break
					end
					if isLineTerminator(cj) then
						j = n + 1
						break
					end
					j += 1
				end
				if j <= n then
					table.insert(subx, string.sub(s, i + 1, j))
					table.insert(out, "[#" .. (#subx - 1) .. "]")
					i = j + 2
					matched = true
				end
			end
		end
		if not matched then
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

-- .replaceAll(/\[['"]([^'\]]*)['"]\]/gu, ...): bracketed names keep their
-- periods and tildes (escaped until the split).
local function protectBracketNames(s: string): string
	local out: { string } = {}
	local i = 1
	local n = #s
	while i <= n do
		local c = at(s, i)
		local q = at(s, i + 1)
		local done = false
		if c == "[" and (q == "'" or q == '"') then
			local k = i + 2
			while k <= n and at(s, k) ~= "'" and at(s, k) ~= "]" do
				k += 1
			end
			local prop: string? = nil
			local stop = 0
			if k <= n and at(s, k) == "'" and at(s, k + 1) == "]" then
				prop, stop = string.sub(s, i + 2, k - 1), k + 1
			elseif k <= n and at(s, k) == "]" and k - 1 >= i + 2 and at(s, k - 1) == '"' then
				prop, stop = string.sub(s, i + 2, k - 2), k
			end
			if prop then
				local escaped = string.gsub(string.gsub(prop, "%.", "%%@%%"), "~", "%%%%@@%%%%")
				table.insert(out, "['" .. escaped .. "']")
				i = stop + 1
				done = true
			end
		end
		if not done then
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

-- .replaceAll(/['"]?\.['"]?(?![^[]*\])|\[['"]?/gu, ';')
local function splitBoundaries(s: string): string
	local out: { string } = {}
	local i = 1
	local n = #s
	local function quote(c: string): boolean
		return c == "'" or c == '"'
	end
	while i <= n do
		local c = at(s, i)
		local dot: number? = nil
		if c == "." then
			dot = i
		elseif quote(c) and at(s, i + 1) == "." then
			dot = i + 1
		end
		local matched = false
		if dot then
			local stop = dot :: number
			if quote(at(s, stop + 1)) then
				stop += 1
			end
			-- (?![^[]*\]): no "]" before the next "[".
			local k = stop + 1
			local inside = false
			while k <= n do
				local ck = at(s, k)
				if ck == "[" then
					break
				elseif ck == "]" then
					inside = true
					break
				end
				k += 1
			end
			if not inside then
				table.insert(out, ";")
				i = stop + 1
				matched = true
			end
		end
		if not matched and c == "[" then
			table.insert(out, ";")
			i += if quote(at(s, i + 1)) then 2 else 1
			matched = true
		end
		if not matched then
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

-- .replaceAll(/(?:;)?(\^+)(?:;)?/gu, ';^;^;')
local function splitParents(s: string): string
	if not string.find(s, "^", 1, true) then
		return s
	end
	local out: { string } = {}
	local i = 1
	local n = #s
	while i <= n do
		local c = at(s, i)
		local start: number? = nil
		if c == ";" and at(s, i + 1) == "^" then
			start = i + 1
		elseif c == "^" then
			start = i
		end
		if start then
			local j = start :: number
			local ups: { string } = {}
			while at(s, j) == "^" do
				table.insert(ups, "^")
				j += 1
			end
			if at(s, j) == ";" then
				j += 1
			end
			table.insert(out, ";" .. table.concat(ups, ";") .. ";")
			i = j
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

-- .replaceAll(/;;;|;;/gu, ';..;')
local function descendants(s: string): string
	local out: { string } = {}
	local i = 1
	local n = #s
	while i <= n do
		if string.sub(s, i, i + 2) == ";;;" then
			table.insert(out, ";..;")
			i += 3
		elseif string.sub(s, i, i + 1) == ";;" then
			table.insert(out, ";..;")
			i += 2
		else
			table.insert(out, at(s, i))
			i += 1
		end
	end
	return table.concat(out)
end

-- .replaceAll(/;$|'?\]|'$/gu, '')
local function trimClosers(s: string): string
	local out: { string } = {}
	local i = 1
	local n = #s
	while i <= n do
		local c = at(s, i)
		if (c == ";" and i == n) or c == "]" or (c == "'" and i == n) then
			i += 1
		elseif c == "'" and at(s, i + 1) == "]" then
			i += 2
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

local function split(s: string, sep: string): { string }
	local out: { string } = {}
	local start = 1
	while true do
		local i = string.find(s, sep, start, true)
		if i == nil then
			table.insert(out, string.sub(s, start))
			return out
		end
		table.insert(out, string.sub(s, start, i - 1))
		start = i + #sep
	end
end

-- JSONPath.toPathArray: the path's parts (a part naming a script group is
-- that group's text; one naming no group is nil, as in the library).
function M.toPathArray(expr: string): { string? }
	local subx: { string } = {}
	local s = string.gsub(expr, "@(%a+)%(%)", function(name: string): string
		return if VALUE_TYPES[name] then ";@" .. name .. "();" else "@" .. name .. "()"
	end)
	s = extractScripts(s, subx)
	s = protectBracketNames(s)
	s = string.gsub(s, "~", ";~;")
	s = splitBoundaries(s)
	s = string.gsub(s, "%%@%%", ".")
	s = string.gsub(s, "%%%%@@%%%%", "~")
	s = splitParents(s)
	s = descendants(s)
	s = trimClosers(s)
	local parts = split(s, ";")
	local out: { string? } = table.create(#parts)
	for i, p in parts do
		local idx = string.match(p, "#(%d+)")
		if idx then
			out[i] = subx[(tonumber(idx) :: number) + 1]
		else
			out[i] = p
		end
	end
	return out
end

-- Evaluation ----------------------------------------------------------------------

type Ret = { value: any, parent_sel: boolean?, expr: { any }?, path: number? }

type State = { has_parent: boolean, n: number }

-- A thrown JavaScript error of the library (the message Grafana shows).
local function throw(message: string): never
	error({ jsonpath_error = message }, 0)
end

local function slice(list: { any }, from: number): { any }
	return table.move(list, from, #list, 1, {})
end

local function unshift(first: any, rest: { any }): { any }
	local out = { first }
	table.move(rest, 1, #rest, 2, out)
	return out
end

local function isSliceLoc(loc: string): boolean
	local a, b, c = string.match(loc, "^(%-?%d*):(%-?%d*):?(%d*)$")
	return a ~= nil and b ~= nil and c ~= nil
end

-- Number.parseInt(part) || dflt
local function parseIntOr(part: string?, dflt: number): number
	if part == nil or part == "" then
		return dflt
	end
	local n = tonumber(string.match(part :: string, "^%-?%d+"))
	if n == nil or n == 0 then
		return dflt
	end
	return n :: number
end

local trace: (State, { any }, any, any, any, boolean?) -> any

local function addRet(ret: { any }, elems: any)
	if type(elems) == "table" and elems.__list then
		for _, e in elems.items do
			table.insert(ret, e)
		end
	else
		table.insert(ret, elems)
	end
end

local function list(items: { any }): any
	return { __list = true, items = items }
end

local function sliceTrace(st: State, loc: string, expr: { any }, val: any, parent: any, prop: any): any
	if not M.isArray(val) then
		return nil
	end
	local len = #val
	local parts = split(loc, ":")
	local step = parseIntOr(parts[3], 1)
	local start = parseIntOr(parts[1], 0)
	local stop = parseIntOr(parts[2], len)
	start = if start < 0 then math.max(0, start + len) else math.min(len, start)
	stop = if stop < 0 then math.max(0, stop + len) else math.min(len, stop)
	local ret: { any } = {}
	local i = start
	while i < stop do
		local tmp = trace(st, unshift(i, expr), val, parent, prop, nil)
		addRet(ret, tmp)
		i += step
	end
	return list(ret)
end

local function valueType(loc: string, val: any): boolean
	local kind = string.sub(loc, 2, -3)
	if kind == "scalar" then
		return not truthy(val) or not (M.isArray(val) or M.isObject(val))
	elseif kind == "boolean" then
		return type(val) == "boolean"
	elseif kind == "string" then
		return type(val) == "string"
	elseif kind == "undefined" or kind == "function" then
		return false
	elseif kind == "integer" then
		return type(val) == "number" and val == val and math.abs(val) ~= math.huge and val % 1 == 0
	elseif kind == "number" then
		return type(val) == "number" and val == val and math.abs(val) ~= math.huge
	elseif kind == "nonFinite" then
		return type(val) == "number" and (val ~= val or math.abs(val) == math.huge)
	elseif kind == "object" then
		return M.isArray(val) or M.isObject(val)
	elseif kind == "array" then
		return M.isArray(val)
	elseif kind == "other" then
		throw("You must supply an otherTypeCallback callback option with the @other() operator.")
	elseif kind == "null" then
		return val == M.NULL
	end
	throw("Unknown value type " .. kind)
	return false
end

-- JSONPath.prototype._trace: a list (see `list`) or a single result.
trace = function(st: State, expr: { any }, val: any, parent: any, prop: any, literalPriority: boolean?): any
	st.n += 1
	if st.n > 1000000 then
		throw("the JSONPath walk visited more than 1000000 nodes")
	end
	if #expr == 0 then
		return { value = val } :: Ret
	end
	local loc = expr[1]
	local x = slice(expr, 2)
	local ret: { any } = {}
	local isString = type(loc) == "string"
	local hit, v = false, nil
	if not isString or literalPriority then
		hit, v = own(val, loc)
	end
	if hit then
		addRet(ret, trace(st, x, v, val, loc, nil))
	elseif loc == "*" then
		walk(val, function(m: any)
			addRet(ret, trace(st, x, child(val, m), val, m, true))
		end)
	elseif loc == ".." then
		addRet(ret, trace(st, x, val, parent, prop, nil))
		walk(val, function(m: any)
			local c = child(val, m)
			if isObjectType(c) then
				addRet(ret, trace(st, slice(expr, 1), c, val, m, nil))
			end
		end)
	elseif loc == "^" then
		st.has_parent = true
		return { parent_sel = true, expr = x } :: Ret
	elseif loc == "~" then
		return { value = if prop == nil then M.NULL else prop } :: Ret
	elseif loc == "$" then
		addRet(ret, trace(st, x, val, nil, nil, nil))
	elseif not isString then
		-- A missing script group (a "#n" part naming none): JavaScript fails
		-- reading the part's string methods.
		throw("Cannot read properties of undefined (reading 'indexOf')")
	elseif isSliceLoc(loc) then
		addRet(ret, sliceTrace(st, loc, x, val, parent, prop))
	elseif string.sub(loc, 1, 2) == "?(" then
		throw("Eval [?(expr)] prevented in JSONPath expression.")
	elseif string.sub(loc, 1, 1) == "(" then
		throw("Eval [(expr)] prevented in JSONPath expression.")
	elseif string.sub(loc, 1, 1) == "@" then
		if valueType(loc, val) then
			return { value = val } :: Ret
		end
	elseif string.sub(loc, 1, 1) == "`" and (own(val, string.sub(loc, 2))) then
		local name = string.sub(loc, 2)
		local _, w = own(val, name)
		addRet(ret, trace(st, x, w, val, name, true))
	elseif string.find(loc, ",", 1, true) then
		for _, part in split(loc, ",") do
			addRet(ret, trace(st, unshift(part, x), val, parent, prop, nil))
		end
	elseif not literalPriority then
		local ok, w = own(val, loc)
		if ok then
			addRet(ret, trace(st, x, w, val, loc, true))
		end
	end
	if st.has_parent then
		local t = 1
		while t <= #ret do
			local r = ret[t]
			if type(r) == "table" and r.parent_sel then
				local tmp = trace(st, r.expr :: { any }, val, parent, prop, nil)
				if type(tmp) == "table" and tmp.__list then
					local items = tmp.items
					ret[t] = if items[1] == nil then false else items[1]
					for tt = 2, #items do
						t += 1
						table.insert(ret, t, items[tt])
					end
				else
					ret[t] = if tmp == nil then false else tmp
				end
			end
			t += 1
		end
	end
	return list(ret)
end

-- JSONPath({path, json, eval: false}) with the default wrap: the values the
-- path selects, or the error the library throws.
function M.query(path: string, json: any): ({ any }?, string?)
	if not truthy(json) then
		return nil, nil
	end
	local parts = M.toPathArray(path)
	if parts[1] == "$" and #parts > 1 then
		table.remove(parts, 1)
	end
	local st: State = { has_parent = false, n = 0 }
	local ok, res = pcall(trace, st, parts :: { any }, json, nil, nil, nil)
	if not ok then
		local e = res :: any
		if type(e) == "table" and e.jsonpath_error then
			return nil, e.jsonpath_error
		end
		error(e, 0)
	end
	if type(res) ~= "table" or not res.__list then
		return nil, "this._trace(...).filter is not a function"
	end
	local out: { any } = {}
	for _, r in res.items do
		if type(r) == "table" and not r.parent_sel then
			table.insert(out, r.value)
		end
	end
	return out, nil
end

return M
