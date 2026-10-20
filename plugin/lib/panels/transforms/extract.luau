--!strict
-- extractFields: public/app/features/transformers/extractFields/
-- extractFields.ts and fieldExtractors.ts. A string (or object) field is
-- parsed per row as JSON (optionally picking `jsonPaths`), key=value pairs,
-- delimited values, a regular expression with named groups, or "auto" (the
-- first of those that parses); every key becomes a field, added after the
-- frame's fields or replacing them (`replace`), with `keepTime` keeping the
-- time field. Object keys keep their JSON order (JavaScript's: array-index
-- keys first); a decoded object without one is visited in sorted key order,
-- the order Grafana's backend serializes labels in.

local Json = require("../json")
local Frame = require("../../frame/types")
local Regex = require("../../regex")
local Shared = require("./shared")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

-- An object with its keys in order.
type Obj = { keys: { string }, values: { [string]: any } }

-- JSON -----------------------------------------------------------------------------

local function skipWs(s: string, i: number): number
	local _, e = string.find(s, "^[ \t\r\n]*", i)
	return (e :: number) + 1
end

local parseValue: (string, number, any) -> (any, number)

local function parseString(s: string, i: number): (string, number)
	local out: { string } = {}
	i += 1
	while true do
		local c = string.sub(s, i, i)
		if c == "" then
			error("unterminated string")
		elseif c == '"' then
			return table.concat(out), i + 1
		elseif c == "\\" then
			local e = string.sub(s, i + 1, i + 1)
			local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
			if e == "u" then
				local hex = string.sub(s, i + 2, i + 5)
				local code = tonumber(hex, 16)
				if code == nil then
					error("bad escape")
				end
				local cp = code :: number
				i += 6
				if cp >= 0xD800 and cp <= 0xDBFF and string.sub(s, i, i + 1) == "\\u" then
					local low = tonumber(string.sub(s, i + 2, i + 5), 16)
					if low and low >= 0xDC00 and low <= 0xDFFF then
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
						i += 6
					end
				end
				table.insert(out, utf8.char(cp))
			elseif map[e] then
				table.insert(out, map[e])
				i += 2
			else
				error("bad escape")
			end
		else
			local j = string.find(s, '["\\]', i) or (#s + 1)
			table.insert(out, string.sub(s, i, j - 1))
			i = j
		end
	end
end

local function arrayIndex(k: string): number?
	if k == "0" or string.match(k, "^[1-9]%d*$") then
		local n = tonumber(k) :: number
		if n < 4294967295 then
			return n
		end
	end
	return nil
end

-- JavaScript's own-key order: array indexes ascending, then insertion order.
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
	for _, k in rest do
		table.insert(idx, k)
	end
	return idx
end

local function parseObject(s: string, i: number, env: any): (Obj, number)
	local obj: Obj = { keys = {}, values = {} }
	i = skipWs(s, i + 1)
	if string.sub(s, i, i) == "}" then
		return obj, i + 1
	end
	while true do
		if string.sub(s, i, i) ~= '"' then
			error("expected key")
		end
		local key
		key, i = parseString(s, i)
		i = skipWs(s, i)
		if string.sub(s, i, i) ~= ":" then
			error("expected colon")
		end
		local v
		v, i = parseValue(s, skipWs(s, i + 1), env)
		if obj.values[key] == nil then
			table.insert(obj.keys, key)
		end
		obj.values[key] = v
		i = skipWs(s, i)
		local c = string.sub(s, i, i)
		if c == "," then
			i = skipWs(s, i + 1)
		elseif c == "}" then
			obj.keys = jsKeyOrder(obj.keys)
			return obj, i + 1
		else
			error("expected , or }")
		end
	end
end

-- Nested objects become plain tables; only the top level keeps an order.
local function plain(v: any): any
	if type(v) == "table" and v.keys and v.values and getmetatable(v) == nil and v.__obj then
		local out: { [string]: any } = {}
		for _, k in v.keys do
			out[k] = plain(v.values[k])
		end
		return out
	end
	return v
end

parseValue = function(s: string, i: number, env: any): (any, number)
	local c = string.sub(s, i, i)
	if c == "{" then
		local obj, j = parseObject(s, i, env)
		local t = obj :: any
		t.__obj = true
		return t, j
	elseif c == "[" then
		local out: { any } = {}
		i = skipWs(s, i + 1)
		if string.sub(s, i, i) == "]" then
			return out, i + 1
		end
		while true do
			local v
			v, i = parseValue(s, i, env)
			table.insert(out, plain(v))
			i = skipWs(s, i)
			local d = string.sub(s, i, i)
			if d == "," then
				i = skipWs(s, i + 1)
			elseif d == "]" then
				return out, i + 1
			else
				error("expected , or ]")
			end
		end
	elseif c == '"' then
		return parseString(s, i)
	elseif string.sub(s, i, i + 3) == "true" then
		return true, i + 4
	elseif string.sub(s, i, i + 4) == "false" then
		return false, i + 5
	elseif string.sub(s, i, i + 3) == "null" then
		return Frame.NULL, i + 4
	end
	local num = string.match(s, "^-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
	if num and num ~= "" and num ~= "-" then
		local n = tonumber(num)
		if n then
			return n, i + #num
		end
	end
	error("unexpected token")
end

-- JSON.parse; an object result keeps its key order.
local function parseJson(text: string, env: any): any
	local i = skipWs(text, 1)
	local v, j = parseValue(text, i, env)
	if skipWs(text, j) <= #text then
		error("trailing characters")
	end
	if type(v) == "table" and (v :: any).__obj then
		local obj = v :: any
		local o: Obj = { keys = obj.keys, values = {} }
		for _, k in obj.keys do
			o.values[k] = plain(obj.values[k])
		end
		return o
	end
	return v
end

-- Key/value pairs (parseKeyValuePairs) -------------------------------------------------

local function parseKeyValuePairs(raw: string): Obj
	local buff: { string } = {}
	local esc = ""
	local key = ""
	local obj: Obj = { keys = {}, values = {} }
	local function set(k: string, v: string)
		if obj.values[k] == nil then
			table.insert(obj.keys, k)
		end
		obj.values[k] = v
	end
	local n = #raw
	local i = 1
	while i <= n do
		local c = string.sub(raw, i, i)
		if c == esc then
			esc = ""
			i += 1
			c = string.sub(raw, i, i)
		end
		local escaped = c == "\\"
		if escaped then
			i += 1
			c = string.sub(raw, i, i)
		end
		if escaped or #esc > 0 then
			table.insert(buff, c)
			i += 1
			continue
		end
		if c == '"' or c == "'" then
			esc = c
		end
		if c == ":" or c == "=" then
			if #buff > 0 then
				if key ~= "" then
					set(key, "")
				end
				key = table.concat(buff)
				table.clear(buff)
			end
		elseif
			c == '"'
			or c == "'"
			or c == " "
			or c == "\t"
			or c == "\r"
			or c == "\n"
			or c == ","
			or c == ";"
			or c == "&"
			or c == "{"
			or c == "}"
		then
			local whitespaceOrQuote = c == '"' or c == "'" or c == " " or c == "\t" or c == "\r" or c == "\n"
			if whitespaceOrQuote and #buff > 0 and key == "" then
				set(table.concat(buff), "")
				table.clear(buff)
			end
			if #buff > 0 then
				local val = table.concat(buff)
				if #key > 0 then
					set(key, val)
					key = ""
				else
					key = val
				end
				table.clear(buff)
			end
		else
			table.insert(buff, c)
			if i == n and key == "" and #buff > 0 then
				set(table.concat(buff), "")
				table.clear(buff)
			end
		end
		i += 1
	end
	if #key > 0 then
		set(key, table.concat(buff))
	end
	obj.keys = jsKeyOrder(obj.keys)
	return obj
end

local function parseDelimited(raw: string, delimiter: string): Obj
	local obj: Obj = { keys = {}, values = {} }
	local s = string.match(raw, "^%s*(.-)%s*$") :: string
	local re = Regex.compile("\\s*" .. Regex.escape(delimiter) .. "\\s*", "g")
	local parts: { string } = {}
	local start = 1
	if re then
		while start <= #s + 1 do
			local a, b = Regex.find(re, s, start)
			if a == nil or (b :: number) < (a :: number) then
				break
			end
			table.insert(parts, string.sub(s, start, (a :: number) - 1))
			start = (b :: number) + 1
		end
	end
	table.insert(parts, string.sub(s, start))
	for _, p in parts do
		if obj.values[p] == nil then
			table.insert(obj.keys, p)
		end
		obj.values[p] = 1
	end
	obj.keys = jsKeyOrder(obj.keys)
	return obj
end

local function regexParser(source: string?): (string) -> Obj?
	local re: Regex.Regex? = nil
	if source and string.match(source, "^/.*/%a*$") then
		re = (Regex.parseJs(source))
	end
	if re == nil then
		re = (Regex.compile("(?<NewField>.*)"))
	end
	return function(v: string): Obj?
		local m = if re then (Regex.exec(re, v)) else nil
		if m == nil or next(m.named) == nil then
			return nil
		end
		local names: { string } = {}
		for k in m.named do
			table.insert(names, k)
		end
		-- Group order: by position of the group in the source.
		local src = (re :: Regex.Regex).source
		table.sort(names, function(a, b): boolean
			return (string.find(src, "(?<" .. a .. ">", 1, true) or 0)
				< (string.find(src, "(?<" .. b .. ">", 1, true) or 0)
		end)
		return { keys = names, values = m.named }
	end
end

type Parser = (string) -> any

local function parserFor(format: string, options: any, env: any): Parser?
	local delimiter = Json.str(env, Json.path(env, options, "delimiter")) or ","
	local json: Parser = function(v: string): any
		return parseJson(v, env)
	end
	local kvp: Parser = parseKeyValuePairs
	local delim: Parser = function(v: string): any
		return parseDelimited(v, delimiter)
	end
	local regexp: Parser = regexParser(Json.str(env, Json.path(env, options, "regExp")))
	if format == "json" then
		return json
	elseif format == "kvp" then
		return kvp
	elseif format == "delimiter" then
		return delim
	elseif format == "regexp" then
		return regexp
	elseif format == "auto" then
		local list = { json, kvp, delim, regexp }
		return function(v: string): any
			for _, p in list do
				local ok, r = pcall(p, v)
				if ok and r ~= nil and r ~= Frame.NULL then
					return r
				end
			end
			return nil
		end
	end
	return nil
end

-- lodash get(obj, path) for "a.b[0].c".
local function getPath(v: any, path: string): any
	local cur = v
	for part in string.gmatch(path, "[^%.%[%]]+") do
		if type(cur) ~= "table" then
			return nil
		end
		local obj = cur :: any
		if obj.keys and obj.values and type(obj.values) == "table" then
			cur = obj.values[part]
		else
			local n = tonumber(part)
			local item = if n and #obj > 0 then obj[n + 1] else obj[part]
			cur = item
		end
	end
	return cur
end

-- getFieldTypeFromValue.
local function typeOf(v: any): Frame.FieldType
	local t = type(v)
	if t == "number" then
		return "number"
	elseif t == "string" then
		return "string"
	elseif t == "boolean" then
		return "boolean"
	end
	return "other"
end

-- An object value's entries in order.
local function entries(v: any, env: any): ({ string }?, { [string]: any }?)
	if type(v) ~= "table" or v == env.null then
		return nil, nil
	end
	local obj = v :: any
	if obj.keys and obj.values and type(obj.keys) == "table" and type(obj.values) == "table" then
		return obj.keys, obj.values
	end
	local keys: { string } = {}
	local values: { [string]: any } = {}
	if #obj > 0 then
		for i, x in obj do
			local k = tostring(i - 1)
			table.insert(keys, k)
			values[k] = x
		end
		return keys, values
	end
	for k, x in obj do
		local key = tostring(k)
		table.insert(keys, key)
		values[key] = if x == env.null then Frame.NULL else x
	end
	table.sort(keys)
	return jsKeyOrder(keys), values
end

-- findField: by name, then display name.
local function findField(frame: Frame, name: string?): Field?
	if name == nil or name == "" then
		return nil
	end
	for _, f in frame.fields do
		if f.name == name or Shared.displayName(f, frame) == name then
			return f
		end
	end
	return nil
end

local FORMATS: { [string]: boolean } = { json = true, kvp = true, auto = true, delimiter = true, regexp = true }

function M.unsupported(options: any, ctx: Ctx): string?
	local env = ctx.env
	local format = Json.str(env, Json.path(env, options, "format")) or "auto"
	if not FORMATS[format] then
		return "format " .. format
	end
	return nil
end

local function extract(frame: Frame, options: any, env: any): Frame
	local sourceName = Json.str(env, Json.path(env, options, "source"))
	local source = findField(frame, sourceName)
	if source == nil then
		return frame
	end
	local format = Json.str(env, Json.path(env, options, "format")) or "auto"
	local parse = parserFor(format, options, env)
	if parse == nil then
		return frame
	end
	local paths: { { path: string, alias: string? } } = {}
	if format == "json" then
		for _, p in Json.list(env, Json.path(env, options, "jsonPaths")) do
			local path = Json.str(env, Json.path(env, p, "path"))
			if path and path ~= "" then
				table.insert(paths, { path = path, alias = Json.str(env, Json.path(env, p, "alias")) })
			end
		end
	end
	local count = Shared.length(frame)
	local names: { string } = {}
	local columns: { [string]: { any } } = {}
	for i = 1, count do
		local obj: any = source.values[i]
		if type(obj) == "string" then
			local ok, r = pcall(parse, obj)
			obj = if ok then r else { keys = {}, values = {} }
		end
		if Shared.nullish(obj) then
			continue
		end
		if #paths > 0 then
			local picked: Obj = { keys = {}, values = {} }
			for _, p in paths do
				local key = if p.alias and p.alias ~= "" then p.alias else p.path
				local v = getPath(obj, p.path)
				if picked.values[key] == nil then
					table.insert(picked.keys, key)
				end
				picked.values[key] = if Shared.nullish(v) then "Not Found" else v
			end
			picked.keys = jsKeyOrder(picked.keys)
			obj = picked
		end
		local keys, values = entries(obj, env)
		if keys == nil then
			continue
		end
		for _, key in keys do
			local col = columns[key]
			if col == nil then
				col = table.create(count, Shared.GAP)
				columns[key] = col
				table.insert(names, key)
			end
			local v = (values :: any)[key]
			col[i] = if v == nil then Shared.GAP else v
		end
	end
	local replace = Json.bool(env, Json.path(env, options, "replace")) == true
	local sourceTime: Field? = nil
	if Json.bool(env, Json.path(env, options, "keepTime")) == true then
		sourceTime = findField(frame, "Time") or findField(frame, "time")
	end
	local taken: { [string]: boolean } = {}
	if not replace then
		for _, f in frame.fields do
			taken[f.name] = true
		end
	end
	if sourceTime then
		taken[sourceTime.name] = true
	end
	local fields: { Field } = {}
	if not replace then
		for _, f in frame.fields do
			table.insert(fields, f)
		end
	end
	if sourceTime then
		table.insert(fields, sourceTime)
	end
	for _, name in names do
		local unique = name
		local dupe = 1
		while taken[unique] do
			unique = name .. " " .. dupe
			dupe += 1
		end
		taken[unique] = true
		local col = columns[name]
		local first: any = nil
		for _, v in col do
			if not Shared.nullish(v) then
				first = v
				break
			end
		end
		table.insert(fields, Frame.field(unique, if first == nil then "other" else typeOf(first), col, nil, {}))
	end
	return Shared.withFields(frame, fields)
end

function M.apply(frames: { Frame }, options: any, ctx: Ctx): { Frame }
	local out: { Frame } = {}
	for _, frame in frames do
		table.insert(out, extract(frame, options, ctx.env))
	end
	return out
end

return M
