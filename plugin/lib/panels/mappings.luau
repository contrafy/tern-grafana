--!strict
-- Grafana value mappings (packages/grafana-data/src/utils/valueMappings.ts
-- getValueMappingResult, types/valueMapping.ts): value -> text/color by
-- exact value, numeric range, regex or special value (null, NaN, true,
-- false, empty). The first mapping that matches wins, in dashboard order.

local Env = require("../env")
local Frame = require("../frame/types")
local Regex = require("../regex")

type Env = Env.Env

export type Result = { text: string?, color: string?, icon: string?, index: number? }

export type Mapping =
	{ kind: "value", options: { [string]: Result } }
	| { kind: "range", from: number?, to: number?, result: Result }
	| { kind: "regex", regex: Regex.Regex?, result: Result }
	| { kind: "special", match: string, result: Result }

local M = {}

local function result(raw: any, env: Env): Result?
	if type(raw) ~= "table" or raw == env.null then
		return nil
	end
	local text = Env.value(env, raw.text)
	local color = Env.value(env, raw.color)
	local icon = Env.value(env, raw.icon)
	local index = Env.value(env, raw.index)
	return {
		text = if type(text) == "string" then text elseif type(text) == "number" then tostring(text) else nil,
		color = if type(color) == "string" and color ~= "" then color else nil,
		icon = if type(icon) == "string" then icon else nil,
		index = if type(index) == "number" then index else nil,
	}
end

-- The dashboard JSON `mappings` list; entries of unknown type are dropped.
function M.parse(raw: any, env: Env): { Mapping }
	local out: { Mapping } = {}
	if type(raw) ~= "table" or raw == env.null then
		return out
	end
	for _, m in raw do
		if type(m) ~= "table" or m == env.null then
			continue
		end
		local options = Env.value(env, m.options)
		if type(options) ~= "table" then
			continue
		end
		local kind = m.type
		if kind == "value" then
			local map: { [string]: Result } = {}
			for k, v in options do
				local r = result(v, env)
				if type(k) == "string" and r then
					map[k] = r
				end
			end
			table.insert(out, { kind = "value", options = map })
		elseif kind == "range" then
			local r = result(Env.value(env, options.result), env)
			local from = Env.value(env, options.from)
			local to = Env.value(env, options.to)
			if r then
				table.insert(out, {
					kind = "range",
					from = if type(from) == "number" then from else tonumber(from),
					to = if type(to) == "number" then to else tonumber(to),
					result = r,
				})
			end
		elseif kind == "regex" then
			local r = result(Env.value(env, options.result), env)
			local pattern = Env.value(env, options.pattern)
			if r and type(pattern) == "string" and pattern ~= "" then
				-- Grafana throws on an invalid pattern; a mapping that can
				-- never match is the closest non-failing equivalent.
				table.insert(out, { kind = "regex", regex = (Regex.parseJs(pattern)), result = r })
			end
		elseif kind == "special" then
			local r = result(Env.value(env, options.result), env)
			local match = Env.value(env, options.match)
			if r and type(match) == "string" then
				table.insert(out, { kind = "special", match = match, result = r })
			end
		end
	end
	return out
end

-- JavaScript String(v), the key a value-to-text mapping is looked up by.
function M.key(v: any): string?
	if type(v) == "number" then
		if v ~= v then
			return "NaN"
		elseif v == math.huge then
			return "Infinity"
		elseif v == -math.huge then
			return "-Infinity"
		elseif v % 1 == 0 and math.abs(v) < 1e21 then
			return string.format("%d", v)
		end
		local s = tostring(v)
		local mantissa, sign, digits = string.match(s, "^(.-)e([%+%-])0*(%d+)$")
		if mantissa and sign and digits then
			return mantissa .. "e" .. sign .. digits
		end
		return s
	elseif type(v) == "string" then
		return v
	elseif type(v) == "boolean" then
		return if v then "true" else "false"
	end
	return nil
end

-- parseFloat: the longest numeric prefix of a string.
local function parseFloat(v: any): number?
	if type(v) == "number" then
		return v
	elseif type(v) == "boolean" then
		return nil
	elseif type(v) ~= "string" then
		return nil
	end
	local s = string.match(v, "^%s*(.-)$") or ""
	local lower = string.lower(s)
	if string.sub(lower, 1, 8) == "infinity" or string.sub(lower, 1, 9) == "+infinity" then
		return math.huge
	elseif string.sub(lower, 1, 9) == "-infinity" then
		return -math.huge
	end
	local num = string.match(s, "^[%+%-]?%d+%.?%d*[eE][%+%-]?%d+")
		or string.match(s, "^[%+%-]?%.%d+[eE][%+%-]?%d+")
		or string.match(s, "^[%+%-]?%d+%.?%d*")
		or string.match(s, "^[%+%-]?%.%d+")
	return if num then tonumber(num) else nil
end

local function isNull(v: any): boolean
	return v == nil or v == Frame.NULL
end

function M.apply(mappings: { Mapping }, value: any): Result?
	local null = isNull(value)
	for _, m in mappings do
		if m.kind == "value" then
			if null then
				continue
			end
			local k = M.key(value)
			local r = if k then m.options[k] else nil
			if r then
				return r
			end
		elseif m.kind == "range" then
			if null then
				continue
			end
			local n = parseFloat(value)
			if n == nil or n ~= n then
				continue
			end
			if n < (m.from or -math.huge) or n > (m.to or math.huge) then
				continue
			end
			return m.result
		elseif m.kind == "regex" then
			if null or type(value) ~= "string" or m.regex == nil then
				continue
			end
			local re = m.regex :: Regex.Regex
			if Regex.test(re, value) then
				local r = table.clone(m.result)
				if r.text ~= nil then
					r.text = (Regex.replace(re, value, m.result.text or ""))
				end
				return r
			end
		else
			local match = m.match
			local nan = type(value) == "number" and value ~= value
			if
				(match == "null" and null)
				or (match == "nan" and nan)
				or (match == "null+nan" and (null or nan))
				or (match == "true" and (value == true or value == "true"))
				or (match == "false" and (value == false or value == "false"))
				or (match == "empty" and value == "")
			then
				return m.result
			end
		end
	end
	return nil
end

return M
