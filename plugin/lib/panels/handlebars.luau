--!strict
-- The Handlebars 4 language as marcusolsson-dynamictext-panel 6.3.1 runs it
-- (handlebars.compile(content)(data), src/utils/html.ts), without partials
-- or decorators:
-- - `{{path}}` HTML-escaped, `{{{path}}}` / `{{&path}}` raw, `{{! }}` and
--   `{{!-- --}}` comments, `\{{` literal, `~` whitespace control and
--   standalone block lines removed as Handlebars does;
-- - paths `a.b`, `a/b`, `[any name]`, `this`, `.`, `../` (one level per
--   context-changing block), `@index`, `@key`, `@first`, `@last`, `@root`;
-- - literals (strings, numbers, true/false/null/undefined), subexpressions
--   `(helper a b)` and `key=value` hash arguments;
-- - blocks `#if` (`includeZero`), `#unless`, `#each` (arrays and objects,
--   `{{else}}` when empty), `#with`, `{{else if ...}}` chains, `{{^x}}`
--   inverse sections, and blockHelperMissing sections `{{#field}}`;
-- - helpers lookup and log, plus the plugin's registerHelpers
--   (src/utils/handlebars.ts) with JavaScript semantics: and, contains,
--   startsWith, endsWith, match, eq, json, gt, gte, join, lt, lte, not, or,
--   split, toFixed, unlessEq. Callers add date, variable, variableValue and
--   fieldStatusColor (they need the dashboard).
--
-- Values are Luau values: nil is `undefined`/`null`, arrays are sequences,
-- objects are tables (M.object keeps their key order for `#each` and json).
-- A template error raises a message like Handlebars' own.

local Shared = require("./transforms/shared")

export type Options = {
	fn: (context: any, data: Data?) -> string,
	inverse: (context: any, data: Data?) -> string,
	hash: { [string]: any },
	data: Data,
	block: boolean,
}

export type Helper = (args: { any }, options: Options) -> any

export type Data = {
	root: any,
	index: number?,
	key: any?,
	first: boolean?,
	last: boolean?,
}

type Path = { k: "path", data: boolean, depth: number, parts: { string }, original: string, simple: boolean }
type Lit = { k: "lit", v: any }
type Sub = { k: "sub", call: Call }
type Expr = Path | Lit | Sub
type Call = { head: Expr, params: { Expr }, hash: { [string]: Expr } }

type Text = { k: "text", s: string }
type Mustache = { k: "mustache", call: Call, raw: boolean }
type Block = { k: "block", call: Call, program: { Node }, inverse: { Node }?, invert: boolean }
type Node = Text | Mustache | Block

export type Template = { nodes: { Node } }

local M = {}

-- Key order of objects built by M.object (weak keys).
local ORDER: { [any]: { string } } = setmetatable({}, { __mode = "k" }) :: any

-- `values` as an object whose keys iterate in `keys` order.
function M.object(values: { [string]: any }, keys: { string }): { [string]: any }
	ORDER[values] = keys
	return values
end

local function isArray(v: any): boolean
	return type(v) == "table" and ORDER[v] == nil and (v[1] ~= nil or next(v) == nil)
end

local function keysOf(v: { [any]: any }): { string }
	local keys = ORDER[v]
	if keys then
		return keys
	end
	local out: { string } = {}
	for k in v do
		if type(k) == "string" then
			table.insert(out, k)
		end
	end
	table.sort(out)
	return out
end

-- Tokens ---------------------------------------------------------------------

type Tok = {
	kind: string, -- text, open, close, inverse, else, mustache, raw, comment
	s: string,
	strip_l: boolean,
	strip_r: boolean,
}

local function tokenize(src: string): { Tok }
	local toks: { Tok } = {}
	local i, n = 1, #src
	local buf: { string } = {}
	local function flush()
		if #buf > 0 then
			table.insert(toks, { kind = "text", s = table.concat(buf), strip_l = false, strip_r = false })
			table.clear(buf)
		end
	end
	while i <= n do
		local at = string.find(src, "{{", i, true)
		if at == nil then
			table.insert(buf, string.sub(src, i))
			break
		end
		if at > i and string.sub(src, at - 1, at - 1) == "\\" and string.sub(src, at - 2, at - 2) ~= "\\" then
			-- `\{{x}}`: literal up to the next mustache.
			table.insert(buf, string.sub(src, i, at - 2))
			local nxt = string.find(src, "{{", at + 2, true) or n + 1
			table.insert(buf, string.sub(src, at, nxt - 1))
			i = nxt
			continue
		end
		if at > i and string.sub(src, at - 2, at - 1) == "\\\\" then
			table.insert(buf, string.sub(src, i, at - 2))
		else
			table.insert(buf, string.sub(src, i, at - 1))
		end
		flush()
		local j = at + 2
		local stripL = string.sub(src, j, j) == "~"
		if stripL then
			j += 1
		end
		local kind, body, stop
		if string.sub(src, j, j + 2) == "!--" then
			local e = string.find(src, "--}}", j + 3, true)
			local et = string.find(src, "--~}}", j + 3, true)
			if et and (e == nil or et < e) then
				e = et + 1
			end
			if e == nil then
				error("Parse error: unclosed comment", 0)
			end
			kind, body, stop = "comment", "", e + 4
		elseif string.sub(src, j, j) == "{" then
			local e = string.find(src, "}}}", j + 1, true)
			if e == nil then
				error("Parse error: expecting '}}}'", 0)
			end
			kind, body, stop = "raw", string.sub(src, j + 1, e - 1), e + 3
		else
			local e = string.find(src, "}}", j, true)
			if e == nil then
				error("Parse error: expecting '}}'", 0)
			end
			body, stop = string.sub(src, j, e - 1), e + 2
			local c = string.sub(body, 1, 1)
			if c == "!" then
				kind = "comment"
			elseif c == "#" then
				kind, body = "open", string.sub(body, 2)
				local d = string.sub(body, 1, 1)
				if d == ">" or d == "*" then
					error("Parse error: partial blocks and decorators are not supported", 0)
				end
			elseif c == "/" then
				kind, body = "close", string.sub(body, 2)
			elseif c == "^" then
				local rest = string.match(string.sub(body, 2), "^%s*(.-)%s*~?$") or ""
				if rest == "" then
					kind, body = "else", ""
				else
					kind, body = "inverse", string.sub(body, 2)
				end
			elseif c == ">" then
				error("The partial " .. (string.match(body, "^>%s*([^%s~]+)") or "") .. " could not be found", 0)
			elseif c == "&" then
				kind, body = "raw", string.sub(body, 2)
			elseif string.match(body, "^%s*else%s*~?$") or string.match(body, "^%s*else%s") then
				kind, body = "else", (string.gsub(body, "^%s*else", "", 1))
			else
				kind = "mustache"
			end
		end
		local stripR = false
		if kind ~= "comment" then
			body = string.match(body, "^%s*(.-)%s*$") :: string
			if string.sub(body, -1) == "~" then
				stripR = true
				body = string.match(string.sub(body, 1, -2), "^(.-)%s*$") :: string
			end
		else
			stripR = string.sub(src, stop - 3, stop - 3) == "~"
		end
		if kind == "raw" and string.sub(src, stop - 4, stop - 4) == "~" then
			stripR = true
		end
		table.insert(toks, { kind = kind, s = body, strip_l = stripL, strip_r = stripR })
		i = stop
	end
	flush()
	return toks
end

local STANDALONE = { open = true, close = true, inverse = true, ["else"] = true, comment = true }

-- `~` strips the whitespace on its side; a block tag or comment alone on its
-- line takes that line's indentation and newline with it.
local function whitespace(toks: { Tok })
	for idx, t in toks do
		if t.kind == "text" then
			continue
		end
		local prev, nxt = toks[idx - 1], toks[idx + 1]
		local prevText = prev and prev.kind == "text"
		local nextText = nxt and nxt.kind == "text"
		if t.strip_l and prevText then
			prev.s = string.match(prev.s, "^(.-)%s*$") :: string
		end
		if t.strip_r and nextText then
			nxt.s = string.match(nxt.s, "^%s*(.*)$") :: string
		end
		if STANDALONE[t.kind] then
			local before = if prevText then prev.s elseif prev == nil then "" else nil
			local after = if nextText then nxt.s elseif nxt == nil then "" else nil
			if before == nil or after == nil then
				continue
			end
			local okBefore = string.match(before, "\n[ \t]*$") ~= nil or (idx <= 2 and string.match(before, "^[ \t]*$"))
			local okAfter = string.match(after, "^[ \t]*\r?\n") ~= nil
				or (idx >= #toks - 1 and string.match(after, "^[ \t]*$"))
			if okBefore and okAfter then
				if prevText then
					prev.s = string.gsub(prev.s, "[ \t]*$", "", 1)
				end
				if nextText then
					nxt.s = string.gsub(nxt.s, "^[ \t]*\r?\n?", "", 1)
				end
			end
		end
	end
end

-- Expressions ------------------------------------------------------------------

local function parsePath(s: string): Path
	local data = string.sub(s, 1, 1) == "@"
	local rest = if data then string.sub(s, 2) else s
	local depth = 0
	while string.sub(rest, 1, 3) == "../" do
		depth += 1
		rest = string.sub(rest, 4)
	end
	local parts: { string } = {}
	local i = 1
	while i <= #rest do
		local c = string.sub(rest, i, i)
		if c == "[" then
			local e = string.find(rest, "]", i + 1, true) or #rest + 1
			table.insert(parts, string.sub(rest, i + 1, e - 1))
			i = e + 1
		elseif c == "." or c == "/" then
			i += 1
		else
			local seg = string.match(rest, "^[^%./%[]+", i) :: string
			table.insert(parts, seg)
			i += #seg
		end
	end
	local scoped = false
	if not data and (parts[1] == "this" or (#parts == 0 and (rest == "." or rest == ""))) then
		if parts[1] == "this" then
			table.remove(parts, 1)
		end
		scoped = true
	end
	if depth > 0 and string.match(rest, "^%.?$") then
		scoped = true
	end
	return {
		k = "path",
		data = data,
		depth = depth,
		parts = parts,
		original = s,
		simple = not data and not scoped and depth == 0 and #parts == 1 and not string.find(s, "[%./%[]"),
	}
end

-- Splits an expression body into words, strings, parens and `=`.
local function words(s: string): { string }
	local out: { string } = {}
	local i, n = 1, #s
	while i <= n do
		local c = string.sub(s, i, i)
		if string.match(c, "%s") then
			i += 1
		elseif c == "(" or c == ")" or c == "=" then
			table.insert(out, c)
			i += 1
		elseif c == '"' or c == "'" then
			local j = i + 1
			local parts: { string } = {}
			while j <= n do
				local d = string.sub(s, j, j)
				if d == "\\" and string.sub(s, j + 1, j + 1) == c then
					table.insert(parts, c)
					j += 2
				elseif d == c then
					break
				else
					table.insert(parts, d)
					j += 1
				end
			end
			if j > n then
				error("Parse error: unterminated string in " .. s, 0)
			end
			table.insert(out, "\0" .. table.concat(parts))
			i = j + 1
		else
			local j = i
			while j <= n do
				local d = string.sub(s, j, j)
				if d == "[" then
					j = (string.find(s, "]", j + 1, true) or n) + 1
				elseif string.match(d, "[%s()=]") then
					break
				else
					j += 1
				end
			end
			table.insert(out, string.sub(s, i, j - 1))
			i = j
		end
	end
	return out
end

local parseCall: (ws: { string }, i: number, stop: string?) -> (Call, number)

local function parseExpr(ws: { string }, i: number): (Expr, number)
	local w = ws[i]
	if w == nil then
		error("Parse error: expected an expression", 0)
	elseif w == "(" then
		local call, j = parseCall(ws, i + 1, ")")
		return { k = "sub", call = call }, j + 1
	elseif string.sub(w, 1, 1) == "\0" then
		return { k = "lit", v = string.sub(w, 2) }, i + 1
	elseif w == "true" or w == "false" then
		return { k = "lit", v = w == "true" }, i + 1
	elseif w == "null" or w == "undefined" then
		return { k = "lit", v = nil }, i + 1
	elseif string.match(w, "^%-?%d+%.?%d*$") or string.match(w, "^%-?%.%d+$") then
		return { k = "lit", v = tonumber(w) }, i + 1
	end
	return parsePath(w), i + 1
end

parseCall = function(ws: { string }, i: number, stop: string?): (Call, number)
	local head, j = parseExpr(ws, i)
	local params: { Expr } = {}
	local hash: { [string]: Expr } = {}
	while ws[j] ~= nil and ws[j] ~= stop do
		if ws[j + 1] == "=" then
			local key = ws[j]
			local v
			v, j = parseExpr(ws, j + 2)
			hash[key] = v
		else
			local e
			e, j = parseExpr(ws, j)
			table.insert(params, e)
		end
	end
	if stop and ws[j] ~= stop then
		error("Parse error: expected '" .. stop .. "'", 0)
	end
	return { head = head, params = params, hash = hash }, j
end

local function parseBody(s: string): Call
	local ws = words(s)
	if #ws == 0 then
		error("Parse error: empty expression", 0)
	end
	local call, j = parseCall(ws, 1, nil)
	if ws[j] ~= nil then
		error("Parse error: unexpected '" .. ws[j] .. "'", 0)
	end
	return call
end

-- Program --------------------------------------------------------------------------

local function headName(call: Call): string
	local h = call.head
	return if h.k == "path" then h.original else ""
end

local parseNodes: (toks: { Tok }, i: number) -> ({ Node }, number)

-- The block opened at toks[i - 1] by `call`, through its close tag; a
-- chained `else if` block shares its parent's close tag.
local function parseBlock(toks: { Tok }, i: number, call: Call, invert: boolean, chained: boolean): (Block, number)
	local program, j = parseNodes(toks, i)
	local inverse: { Node }? = nil
	local stop = toks[j]
	if stop and stop.kind == "else" then
		if stop.s ~= "" and not string.match(stop.s, "^%s*$") then
			local nested
			nested, j = parseBlock(toks, j + 1, parseBody(stop.s), false, true)
			inverse = { nested }
			stop = toks[j]
		else
			inverse, j = parseNodes(toks, j + 1)
			stop = toks[j]
		end
	end
	if stop == nil or stop.kind ~= "close" then
		error(headName(call) .. " doesn't match (missing {{/" .. headName(call) .. "}})", 0)
	end
	if not chained and stop.s ~= headName(call) then
		error(headName(call) .. " doesn't match " .. stop.s, 0)
	end
	local block: Block = {
		k = "block",
		call = call,
		program = if invert then inverse or {} else program,
		inverse = if invert then program else inverse,
		invert = invert,
	}
	-- A chained block leaves the close tag to its parent.
	return block, if chained then j else j + 1
end

parseNodes = function(toks: { Tok }, i: number): ({ Node }, number)
	local nodes: { Node } = {}
	while i <= #toks do
		local t = toks[i]
		if t.kind == "text" then
			if t.s ~= "" then
				table.insert(nodes, { k = "text", s = t.s })
			end
			i += 1
		elseif t.kind == "comment" then
			i += 1
		elseif t.kind == "mustache" or t.kind == "raw" then
			table.insert(nodes, { k = "mustache", call = parseBody(t.s), raw = t.kind == "raw" })
			i += 1
		elseif t.kind == "open" or t.kind == "inverse" then
			local block
			block, i = parseBlock(toks, i + 1, parseBody(t.s), t.kind == "inverse", false)
			table.insert(nodes, block)
		else
			return nodes, i
		end
	end
	return nodes, i
end

function M.compile(src: string): Template
	local toks = tokenize(src)
	whitespace(toks)
	local nodes, i = parseNodes(toks, 1)
	local t = toks[i]
	if t then
		if t.kind == "else" then
			error("Parse error: {{else}} outside a block", 0)
		end
		error(t.s .. " doesn't match (no open block)", 0)
	end
	return { nodes = nodes }
end

-- Values ---------------------------------------------------------------------------

local ESCAPES: { [string]: string } = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	['"'] = "&quot;",
	["'"] = "&#x27;",
	["`"] = "&#x60;",
	["="] = "&#x3D;",
}

-- Handlebars.escapeExpression.
function M.escape(s: string): string
	return (string.gsub(s, "[&<>\"'`=]", ESCAPES))
end

-- What `{{v}}` writes before escaping.
function M.toString(v: any): string
	if v == nil then
		return ""
	elseif type(v) == "table" and ORDER[v] then
		return "[object Object]"
	end
	return Shared.jsString(v)
end

-- Handlebars Utils.isEmpty (the `#if` test, with includeZero).
local function isEmpty(v: any, includeZero: boolean): boolean
	if v == nil or v == false or v == "" then
		return true
	elseif v == 0 then
		return not includeZero
	elseif type(v) == "number" and v ~= v then
		return true
	elseif isArray(v) and #v == 0 then
		return true
	end
	return false
end

local function jsonValue(v: any, indent: string, out: { string })
	if v == nil then
		table.insert(out, "null")
	elseif type(v) == "table" then
		local inner = indent .. "  "
		if isArray(v) then
			if #v == 0 then
				table.insert(out, "[]")
				return
			end
			table.insert(out, "[")
			for i, x in v do
				table.insert(out, (if i > 1 then ",\n" else "\n") .. inner)
				jsonValue(x, inner, out)
			end
			table.insert(out, "\n" .. indent .. "]")
		else
			local keys = keysOf(v)
			local first = true
			table.insert(out, "{")
			for _, k in keys do
				local x = v[k]
				if x == nil then
					continue
				end
				table.insert(out, (if first then "\n" else ",\n") .. inner)
				table.insert(out, Shared.jsonStringify(k, { null = false } :: any) :: string .. ": ")
				jsonValue(x, inner, out)
				first = false
			end
			table.insert(out, if first then "}" else "\n" .. indent .. "}")
		end
	elseif type(v) == "number" then
		table.insert(out, if v ~= v or v == math.huge or v == -math.huge then "null" else Shared.jsString(v))
	elseif type(v) == "boolean" then
		table.insert(out, if v then "true" else "false")
	else
		table.insert(out, Shared.jsonStringify(tostring(v), { null = false } :: any) :: string)
	end
end

-- JSON.stringify(v, null, 2).
function M.json(v: any): string
	local out: { string } = {}
	jsonValue(v, "", out)
	return table.concat(out)
end

-- JavaScript regex source as Luau patterns (alternatives), for `match`.
-- Raises on constructs Luau patterns cannot express.
function M.regexPatterns(src: string): { string }
	local alts: { string } = {}
	local cur: { string } = {}
	local i, n = 1, #src
	local function unsupported()
		error("the regular expression " .. src .. " is not supported natively", 0)
	end
	local function escapeClass(c: string): string
		return if c == "d"
			then "%d"
			elseif c == "D" then "%D"
			elseif c == "w" then "[%w_]"
			elseif c == "W" then "[^%w_]"
			elseif c == "s" then "%s"
			elseif c == "S" then "%S"
			elseif c == "t" then "\t"
			elseif c == "n" then "\n"
			elseif string.match(c, "%p") then "%" .. c
			else c
	end
	while i <= n do
		local c = string.sub(src, i, i)
		local atom: string
		if c == "|" then
			table.insert(alts, table.concat(cur))
			table.clear(cur)
			i += 1
			continue
		elseif c == "^" then
			if #cur > 0 then
				unsupported()
			end
			table.insert(cur, "^")
			i += 1
			continue
		elseif c == "$" then
			table.insert(cur, "$")
			i += 1
			continue
		elseif c == "(" or c == ")" or string.match(c, "[%*%+%?{]") then
			unsupported()
			atom = ""
		elseif c == "\\" then
			atom = escapeClass(string.sub(src, i + 1, i + 1))
			i += 2
		elseif c == "[" then
			local e = i + 1
			if string.sub(src, e, e) == "^" then
				e += 1
			end
			if string.sub(src, e, e) == "]" then
				e += 1
			end
			local close = string.find(src, "]", e, true)
			if close == nil then
				unsupported()
			end
			local body = string.sub(src, i + 1, (close :: number) - 1)
			local neg = string.sub(body, 1, 1) == "^"
			if neg then
				body = string.sub(body, 2)
			end
			local parts: { string } = {}
			local k = 1
			while k <= #body do
				local d = string.sub(body, k, k)
				if d == "\\" then
					local e2 = escapeClass(string.sub(body, k + 1, k + 1))
					table.insert(parts, if string.sub(e2, 1, 1) == "[" then string.sub(e2, 2, -2) else e2)
					k += 2
				elseif d == "%" or d == "]" or d == "[" then
					table.insert(parts, "%" .. d)
					k += 1
				else
					table.insert(parts, d)
					k += 1
				end
			end
			atom = "[" .. (if neg then "^" else "") .. table.concat(parts) .. "]"
			i = (close :: number) + 1
		elseif c == "." then
			atom = "."
			i += 1
		else
			atom = if string.match(c, "%p") then "%" .. c else c
			i += 1
		end
		local q = string.sub(src, i, i)
		if q == "*" or q == "+" or q == "?" then
			local lazy = string.sub(src, i + 1, i + 1) == "?"
			if lazy and q ~= "*" then
				unsupported()
			end
			table.insert(cur, atom .. (if lazy then "-" else q))
			i += if lazy then 2 else 1
		elseif q == "{" then
			local a, b, close = string.match(src, "^{(%d+)(,?%d*)}()", i)
			if a == nil then
				unsupported()
			end
			local lo = tonumber(a) :: number
			local hi = if b == "" then lo elseif b == "," then nil else tonumber(string.sub(b :: string, 2))
			table.insert(cur, string.rep(atom, lo))
			if hi == nil then
				table.insert(cur, atom .. "*")
			else
				for _ = lo + 1, hi do
					table.insert(cur, atom .. "?")
				end
			end
			i = close :: number
		else
			table.insert(cur, atom)
		end
	end
	table.insert(alts, table.concat(cur))
	return alts
end

local function needString(v: any, what: string): string
	if type(v) ~= "string" then
		error(what .. " is not a function", 0)
	end
	return v
end

-- JavaScript relational comparison (a < b), false when either is NaN.
local function less(a: any, b: any): boolean
	if type(a) == "string" and type(b) == "string" then
		return a < b
	end
	local x, y = Shared.jsNumber(a), Shared.jsNumber(b)
	return x < y
end

-- registerHelpers in src/utils/handlebars.ts plus Handlebars' lookup/log.
M.HELPERS = {
	["and"] = function(a: { any }): any
		return if Shared.truthy(a[1]) then a[2] else a[1]
	end,
	["or"] = function(a: { any }): any
		return if Shared.truthy(a[1]) then a[1] else a[2]
	end,
	["not"] = function(a: { any }): any
		return not Shared.truthy(a[1])
	end,
	contains = function(a: { any }): any
		local arr, v = a[1], a[2]
		if type(arr) == "string" then
			return string.find(arr, M.toString(v), 1, true) ~= nil
		elseif type(arr) ~= "table" then
			error("arr.indexOf is not a function", 0)
		end
		for _, x in arr do
			if x == v then
				return true
			end
		end
		return false
	end,
	startsWith = function(a: { any }): any
		local s, p = needString(a[1], "left.startsWith"), M.toString(a[2])
		return string.sub(s, 1, #p) == p
	end,
	endsWith = function(a: { any }): any
		local s, p = needString(a[1], "left.endsWith"), M.toString(a[2])
		return p == "" or string.sub(s, -#p) == p
	end,
	match = function(a: { any }): any
		local s = needString(a[1], "left.match")
		for _, pat in M.regexPatterns(M.toString(a[2])) do
			if string.find(s, pat) then
				return true
			end
		end
		return false
	end,
	eq = function(a: { any }): any
		return a[1] == a[2]
	end,
	unlessEq = function(a: { any }): any
		return a[1] ~= a[2]
	end,
	json = function(a: { any }): any
		return M.json(a[1])
	end,
	gt = function(a: { any }): any
		return less(a[2], a[1])
	end,
	gte = function(a: { any }): any
		return less(a[2], a[1])
			or (not less(a[1], a[2]) and Shared.jsNumber(a[1]) == Shared.jsNumber(a[2]))
			or (type(a[1]) == "string" and a[1] == a[2])
	end,
	lt = function(a: { any }): any
		return less(a[1], a[2])
	end,
	lte = function(a: { any }): any
		return less(a[1], a[2])
			or (not less(a[2], a[1]) and Shared.jsNumber(a[1]) == Shared.jsNumber(a[2]))
			or (type(a[1]) == "string" and a[1] == a[2])
	end,
	join = function(a: { any }): any
		local arr = a[1]
		if type(arr) ~= "table" then
			error("arr.join is not a function", 0)
		end
		local sep = if a[2] == nil then "," else M.toString(a[2])
		local parts: { string } = {}
		for i = 1, #arr do
			table.insert(parts, M.toString(arr[i]))
		end
		return table.concat(parts, sep)
	end,
	split = function(a: { any }): any
		local s = needString(a[1], "str.split")
		local sep = a[2]
		if sep == nil then
			return { s }
		end
		sep = M.toString(sep)
		local out: { string } = {}
		if sep == "" then
			for _, cp in utf8.codes(s) do
				table.insert(out, utf8.char(cp))
			end
			return out
		end
		local i = 1
		while true do
			local at = string.find(s, sep, i, true)
			if at == nil then
				table.insert(out, string.sub(s, i))
				return out
			end
			table.insert(out, string.sub(s, i, at - 1))
			i = at + #sep
		end
	end,
	toFixed = function(a: { any }): any
		local num, digits = a[1], a[2]
		if type(num) ~= "number" or type(digits) ~= "number" then
			return 0
		end
		if num ~= num then
			return "NaN"
		end
		return string.format("%." .. math.clamp(math.floor(digits), 0, 100) .. "f", num)
	end,
	lookup = function(a: { any }): any
		local obj, key = a[1], a[2]
		if type(obj) ~= "table" then
			return nil
		end
		if isArray(obj) and type(key) == "number" then
			return obj[key + 1]
		end
		return obj[key]
	end,
	log = function(_: { any }): any
		return nil
	end,
} :: { [string]: Helper }

-- Evaluation --------------------------------------------------------------------

type Frame = { contexts: { any }, data: Data, helpers: { [string]: Helper } }

local function child(v: any, part: string): any
	if type(v) == "table" then
		if isArray(v) then
			if part == "length" then
				return #v
			end
			local n = tonumber(part)
			return if n then v[n + 1] else nil
		end
		return v[part]
	elseif type(v) == "string" and part == "length" then
		return utf8.len(v) or #v
	end
	return nil
end

local function lookup(p: Path, f: Frame): any
	local v: any
	if p.data then
		local d: any = f.data
		local first = p.parts[1]
		v = if first == "root" then d.root else d[first]
		for k = 2, #p.parts do
			v = child(v, p.parts[k])
		end
		return v
	end
	local idx = math.max(1, #f.contexts - p.depth)
	v = f.contexts[idx]
	for _, part in p.parts do
		v = child(v, part)
	end
	return v
end

local render: (nodes: { Node }, f: Frame, out: { string }) -> ()
local eval: (e: Expr, f: Frame) -> any

local function helperOf(call: Call, f: Frame): (Helper?, string)
	local h = call.head
	if h.k == "path" and h.simple then
		return f.helpers[h.parts[1]], h.parts[1]
	end
	return nil, if h.k == "path" then h.original else ""
end

local function hashOf(call: Call, f: Frame): { [string]: any }
	local out: { [string]: any } = {}
	for k, e in call.hash do
		out[k] = eval(e, f)
	end
	return out
end

local function argsOf(call: Call, f: Frame): { any }
	local args: { any } = table.create(#call.params)
	for i, e in call.params do
		args[i] = eval(e, f)
	end
	return args
end

local function invoke(call: Call, f: Frame, block: Block?): any
	local helper, name = helperOf(call, f)
	local function runner(nodes: { Node }?): (any, Data?) -> string
		return function(ctx: any, data: Data?): string
			if nodes == nil then
				return ""
			end
			-- nil keeps `this`; a new context adds one `../` level (Handlebars
			-- pushes a depth only when the context changes).
			local contexts = f.contexts
			if ctx ~= nil and ctx ~= contexts[#contexts] then
				contexts = table.clone(contexts)
				table.insert(contexts, ctx)
			end
			local out: { string } = {}
			render(nodes, { contexts = contexts, data = data or f.data, helpers = f.helpers }, out)
			return table.concat(out)
		end
	end
	local function options(): Options
		return {
			fn = runner(if block then block.program else nil),
			inverse = runner(if block then block.inverse else nil),
			hash = hashOf(call, f),
			data = f.data,
			block = block ~= nil,
		}
	end
	if helper then
		return helper(argsOf(call, f), options())
	end
	if #call.params > 0 or next(call.hash) ~= nil then
		error('Missing helper: "' .. name .. '"', 0)
	end
	local value = eval(call.head, f)
	if block == nil then
		return value
	end
	-- blockHelperMissing.
	local o = options()
	local this = f.contexts[#f.contexts]
	if value == true then
		return o.fn(this)
	elseif value == false or value == nil then
		return o.inverse(this)
	elseif isArray(value) then
		if #value == 0 then
			return o.inverse(this)
		end
		return (f.helpers.each :: Helper)({ value }, o)
	end
	return o.fn(value)
end

eval = function(e: Expr, f: Frame): any
	if e.k == "lit" then
		return e.v
	elseif e.k == "sub" then
		return invoke(e.call, f, nil)
	end
	local p = e :: Path
	if p.simple and f.helpers[p.parts[1]] then
		return (f.helpers[p.parts[1]] :: Helper)({}, {
			fn = function(): string
				return ""
			end,
			inverse = function(): string
				return ""
			end,
			hash = {},
			data = f.data,
			block = false,
		})
	end
	return lookup(p, f)
end

render = function(nodes: { Node }, f: Frame, out: { string })
	for _, node in nodes do
		if node.k == "text" then
			table.insert(out, node.s)
		elseif node.k == "mustache" then
			local v = invoke(node.call, f, nil)
			local s = M.toString(v)
			table.insert(out, if node.raw then s else M.escape(s))
		else
			local v = invoke(node.call, f, node)
			if v ~= nil then
				table.insert(out, M.toString(v))
			end
		end
	end
end

local BLOCKS: { [string]: Helper } = {
	["if"] = function(a: { any }, o: Options): any
		if isEmpty(a[1], o.hash.includeZero == true) then
			return o.inverse(nil)
		end
		return o.fn(nil)
	end,
	unless = function(a: { any }, o: Options): any
		if isEmpty(a[1], o.hash.includeZero == true) then
			return o.fn(nil)
		end
		return o.inverse(nil)
	end,
	with = function(a: { any }, o: Options): any
		if isEmpty(a[1], false) then
			return o.inverse(nil)
		end
		return o.fn(a[1])
	end,
	each = function(a: { any }, o: Options): any
		local v = a[1]
		local out: { string } = {}
		local base = o.data
		if type(v) == "table" then
			if isArray(v) then
				for i = 1, #v do
					table.insert(
						out,
						o.fn(v[i], { root = base.root, index = i - 1, key = i - 1, first = i == 1, last = i == #v })
					)
				end
			else
				local keys = keysOf(v)
				local live: { string } = {}
				for _, k in keys do
					if v[k] ~= nil then
						table.insert(live, k)
					end
				end
				for i, k in live do
					table.insert(
						out,
						o.fn(v[k], { root = base.root, index = i - 1, key = k, first = i == 1, last = i == #live })
					)
				end
			end
		end
		if #out == 0 then
			return o.inverse(nil)
		end
		return table.concat(out)
	end,
}

-- The template applied to `context`; `extra` adds or replaces helpers.
function M.render(t: Template, context: any, extra: { [string]: Helper }?): string
	local helpers: { [string]: Helper } = table.clone(M.HELPERS)
	for k, h in BLOCKS do
		helpers[k] = h
	end
	if extra then
		for k, h in extra do
			helpers[k] = h
		end
	end
	local f: Frame = { contexts = { context }, data = { root = context }, helpers = helpers }
	local out: { string } = {}
	render(t.nodes, f, out)
	return table.concat(out)
end

return M
