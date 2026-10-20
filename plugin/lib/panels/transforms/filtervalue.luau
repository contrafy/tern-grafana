--!strict
-- filterByValue ("Filter data by values"): packages/grafana-data/src/
-- transformations/transformers/filterByValue.ts and the value matchers of
-- matchers/valueMatchers/*.ts (greater, greaterOrEqual, lower, lowerOrEqual,
-- equal, notEqual, between, regex, isNull, isNotNull, substring,
-- notSubstring, inSet in raw mode). Comparisons follow JavaScript (`>`
-- coerces mixed types, `==` is loose), as the matchers are plain JS.

local Json = require("../json")
local Frame = require("../../frame/types")
local Regex = require("../../regex")
local Shared = require("./shared")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

type ValueMatcher = (number, Field) -> boolean

local function isNaNValue(v: any): boolean
	local n = Shared.jsNumber(if v == nil then Shared.GAP else v)
	return n ~= n
end

-- The abstract relational comparison behind a < b (nil: undefined result).
local function jsLess(a: any, b: any): boolean?
	if type(a) == "string" and type(b) == "string" then
		return a < b
	end
	local x, y = Shared.jsNumber(a), Shared.jsNumber(b)
	if x ~= x or y ~= y then
		return nil
	end
	return x < y
end

local function gt(a: any, b: any): boolean
	return jsLess(b, a) == true
end

local function ge(a: any, b: any): boolean
	local r = jsLess(a, b)
	return r == false
end

-- a == b.
local function looseEqual(a: any, b: any): boolean
	local an, bn = Shared.nullish(a), Shared.nullish(b)
	if an or bn then
		return an and bn
	end
	local ta, tb = type(a), type(b)
	if ta == tb then
		return a == b
	end
	if ta == "table" or tb == "table" then
		return Shared.jsString(a) == Shared.jsString(b)
	end
	return Shared.jsNumber(a) == Shared.jsNumber(b)
end

-- parseInt(v, 10).
local function parseInt(v: any): number
	local s = string.match(Shared.jsString(v), "^%s*([+-]?%d+)")
	return if s then tonumber(s) :: number else 0 / 0
end

local KNOWN: { [string]: boolean } = {
	greater = true,
	greaterOrEqual = true,
	lower = true,
	lowerOrEqual = true,
	equal = true,
	notEqual = true,
	between = true,
	regex = true,
	isNull = true,
	isNotNull = true,
	substring = true,
	notSubstring = true,
	inSet = true,
}

local function valueMatcher(env: any, config: any): ValueMatcher
	local id = Json.str(env, Json.path(env, config, "id")) or ""
	local o = Json.obj(env, Json.path(env, config, "options"))
	local value = if o.value == env.null then Frame.NULL else o.value
	if value == nil then
		value = Shared.GAP
	end
	if id == "greater" or id == "greaterOrEqual" or id == "lower" or id == "lowerOrEqual" then
		return function(i: number, field: Field): boolean
			local v = field.values[i]
			if isNaNValue(v) then
				return false
			end
			if id == "greater" then
				return gt(v, value)
			elseif id == "greaterOrEqual" then
				return ge(v, value)
			elseif id == "lower" then
				return gt(value, v)
			end
			return ge(value, v)
		end
	elseif id == "equal" or id == "notEqual" then
		return function(i: number, field: Field): boolean
			local eq = looseEqual(field.values[i], value)
			return if id == "equal" then eq else not eq
		end
	elseif id == "isNull" or id == "isNotNull" then
		return function(i: number, field: Field): boolean
			local null = Shared.nullish(field.values[i])
			return if id == "isNull" then null else not null
		end
	elseif id == "between" then
		local from = if o.from == env.null then Frame.NULL else o.from
		local to = if o.to == env.null then Frame.NULL else o.to
		local inclusive = Shared.truthy(o.inclusive)
		local open = Shared.truthy(o.allowOpenBounds)
		local missing = if type(o.includeMissing) == "boolean" then o.includeMissing else nil
		local fromVal = if type(from) == "number" then from else parseInt(from)
		local toVal = if type(to) == "number" then to else parseInt(to)
		return function(i: number, field: Field): boolean
			local v = field.values[i]
			local finite = type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
			if missing ~= nil and not finite then
				return missing
			end
			if isNaNValue(v) then
				return false
			end
			local x = Shared.jsNumber(v)
			local above = (open and from == nil) or (if inclusive then x >= fromVal else x > fromVal)
			local below = (open and to == nil) or (if inclusive then x <= toVal else x < toVal)
			return above and below
		end
	elseif id == "regex" then
		local re = Regex.compile(Shared.jsString(value))
		return function(i: number, field: Field): boolean
			local v = field.values[i]
			if re == nil or Shared.nullish(v) then
				return false
			end
			return (Regex.test(re, Shared.jsString(v)))
		end
	elseif id == "substring" or id == "notSubstring" then
		local needle = if type(value) == "string" then string.lower(value) else nil
		return function(i: number, field: Field): boolean
			local v = field.values[i]
			local has = type(v) == "string"
				and v ~= ""
				and needle ~= nil
				and needle ~= ""
				and string.find(string.lower(v), needle, 1, true) ~= nil
			if id == "substring" then
				return has or value == ""
			end
			return type(v) == "string" and v ~= "" and needle ~= nil and needle ~= "" and not has
		end
	elseif id == "inSet" then
		local set: { [any]: boolean } = {}
		local nan = false
		for _, x in Json.list(env, o.values) do
			if type(x) == "number" and x ~= x then
				nan = true
			else
				set[if x == env.null then Frame.NULL else x] = true
			end
		end
		return function(i: number, field: Field): boolean
			local v = field.values[i]
			if type(v) == "number" and v ~= v then
				return nan
			end
			return v ~= nil and set[v] == true
		end
	end
	return function(): boolean
		return false
	end
end

function M.unsupported(options: any, ctx: Ctx): string?
	local env = ctx.env
	for _, f in Json.list(env, Json.path(env, options, "filters")) do
		local id = Json.str(env, Json.path(env, f, "config", "id"))
		if id == nil or not KNOWN[id] then
			return "value matcher " .. tostring(id)
		end
		if id == "inSet" and Json.str(env, Json.path(env, f, "config", "options", "mode")) == "display" then
			return "value matcher inSet on display values"
		end
	end
	return nil
end

local function sameLabels(a: { [string]: string }?, b: any, env: any): boolean
	local bt = Json.tbl(env, b)
	local an = a == nil or next(a) == nil
	local bn = bt == nil or next(bt) == nil
	if an or bn then
		return an and bn
	end
	for k, v in a :: { [string]: string } do
		if (bt :: any)[k] ~= v then
			return false
		end
	end
	for k in bt :: any do
		if (a :: any)[k] == nil then
			return false
		end
	end
	return true
end

local function filterFrame(frame: Frame, options: any, data: { Frame }, env: any): Frame
	local indexByName: { [string]: number } = {}
	for i, f in frame.fields do
		indexByName[Shared.displayName(f, frame, data)] = i
	end
	local ignoreMissing = Json.str(env, Json.path(env, options, "missingField")) == "ignore"
	local matchers: { (number) -> boolean } = {}
	for _, filter in Json.list(env, Json.path(env, options, "filters")) do
		local identity = Json.tbl(env, Json.path(env, filter, "field"))
		local fieldIndex: number? = nil
		if identity then
			for i, f in frame.fields do
				if f.name == identity.name and sameLabels(f.labels, identity.labels, env) then
					fieldIndex = i
					break
				end
			end
		else
			local name = Json.path(env, filter, "fieldName")
			fieldIndex = if type(name) == "string" then indexByName[name] else nil
		end
		if fieldIndex == nil then
			if not ignoreMissing then
				table.insert(matchers, function(): boolean
					return false
				end)
			end
			continue
		end
		local m = valueMatcher(env, Json.path(env, filter, "config"))
		local field = frame.fields[fieldIndex]
		table.insert(matchers, function(i: number): boolean
			return m(i, field)
		end)
	end
	-- Ignoring a stale target must not exclude everything.
	if #matchers == 0 and ignoreMissing then
		return frame
	end
	local matchAll = Json.str(env, Json.path(env, options, "match")) == "all"
	local include = (Json.str(env, Json.path(env, options, "type")) or "include") == "include"
	local keep: { number } = {}
	for i = 1, Shared.length(frame) do
		local hit: boolean
		if matchAll then
			hit = true
			for _, m in matchers do
				if not m(i) then
					hit = false
					break
				end
			end
		else
			hit = false
			for _, m in matchers do
				if m(i) then
					hit = true
					break
				end
			end
		end
		if hit == include then
			table.insert(keep, i)
		end
	end
	local fields: { Field } = {}
	for _, f in frame.fields do
		local vals: { any } = table.create(#keep)
		for k, i in keep do
			vals[k] = f.values[i]
		end
		table.insert(fields, Shared.withValues(f, vals))
	end
	return Shared.withFields(frame, fields)
end

function M.apply(frames: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	if #Json.list(env, Json.path(env, options, "filters")) == 0 then
		return frames
	end
	local out: { Frame } = {}
	for _, frame in frames do
		table.insert(out, filterFrame(frame, options, frames, env))
	end
	return out
end

return M
