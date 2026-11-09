--!strict
-- Field override matchers (lib/panels/fieldconfig; transformations/
-- matchers/nameMatcher.ts, fieldTypeMatcher.ts, refIdMatcher.ts,
-- fieldValueMatcher.ts with compareValues.ts).

local Env = require("../env")
local Frame = require("../frame/types")
local Json = require("./json")
local Reduce = require("./reduce")
local Regex = require("../regex")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field
local FieldName = require("./fieldname")

local M = {}

-- Matchers --------------------------------------------------------------------

export type Matcher = (field: Field, frame: Frame, frames: { Frame }) -> boolean

local MATCHERS: { [string]: boolean } = {
	byName = true,
	byRegexp = true,
	byFrameRefID = true,
	byType = true,
	byNames = true,
	byRegexpOrNames = true,
	byValue = true,
}

-- JS `${v}` for the values a reducer or a matcher option holds.
local function jsString(v: any): string
	if v == nil then
		return "null"
	elseif type(v) == "number" then
		if v ~= v then
			return "NaN"
		elseif v == math.huge then
			return "Infinity"
		elseif v == -math.huge then
			return "-Infinity"
		elseif v == math.floor(v) and math.abs(v) < 1e21 then
			return string.format("%d", v)
		end
	end
	return tostring(v)
end

-- JS relational comparison: strings compare as strings, anything else as
-- numbers (a non-numeric string or "null" is NaN, so never ordered).
local function jsNumber(v: any): number
	if type(v) == "number" then
		return v
	elseif type(v) == "boolean" then
		return if v then 1 else 0
	elseif type(v) == "string" then
		local s = string.match(v, "^%s*(.-)%s*$") or ""
		if s == "" then
			return 0
		end
		return tonumber(s) or 0 / 0
	end
	return 0 / 0
end

-- compareValues (transformations/matchers/compareValues.ts): a missing side
-- reads as "null", and gte/lte against it become equality.
function M.compareValues(left: any, op: string, right: any): boolean
	if left == nil or right == nil then
		left = if left == nil then "null" else left
		right = if right == nil then "null" else right
		if op == "gte" or op == "lte" then
			op = "eq"
		end
	end
	if op == "eq" then
		return jsString(left) == jsString(right)
	elseif op == "neq" then
		return jsString(left) ~= jsString(right)
	end
	local a: any, b: any = left, right
	if type(a) ~= "string" or type(b) ~= "string" then
		a, b = jsNumber(a), jsNumber(b)
	end
	if op == "gt" then
		return a > b
	elseif op == "gte" then
		return a >= b
	elseif op == "lt" then
		return a < b
	elseif op == "lte" then
		return a <= b
	end
	return false
end

local function regexMatcher(pattern: string?): Matcher
	local re = if pattern and pattern ~= "" then Regex.parseJs(pattern) else nil
	return function(field: Field, frame: Frame, frames: { Frame }): boolean
		return re ~= nil and (Regex.test(re, FieldName.displayName(field, frame, frames)))
	end
end

local function namesMatcher(names: { string }): Matcher
	local set: { [string]: boolean } = {}
	for _, n in names do
		set[n] = true
	end
	return function(field: Field, frame: Frame, frames: { Frame }): boolean
		return set[FieldName.displayName(field, frame, frames)] == true
	end
end

local function matcherFor(env: Env, raw: any): Matcher?
	local m = Json.tbl(env, raw)
	if m == nil then
		return nil
	end
	local id = Json.str(env, m.id)
	local options = if m.options == env.null then nil else m.options
	if id == "byName" then
		local name = Json.str(env, options)
		if name == nil then
			return nil
		end
		local n = name :: string
		return function(field: Field, frame: Frame, frames: { Frame }): boolean
			if n == field.name or n == FieldName.displayName(field, frame, frames) then
				return true
			end
			-- fieldNameFallback: names saved before the dataplane rename.
			if n == "Value" then
				return field.labels ~= nil and field.labels.__name__ == field.name
			elseif n == "Time" or n == "time" then
				return field.type == "time" and (frame.meta == nil or frame.meta.type == nil)
			end
			return false
		end
	elseif id == "byRegexp" then
		return regexMatcher(Json.str(env, options))
	elseif id == "byFrameRefID" then
		local ref = Json.str(env, options)
		return function(_field: Field, frame: Frame): boolean
			return ref ~= nil and frame.refId == ref
		end
	elseif id == "byType" then
		local kind = Json.str(env, options)
		return function(field: Field): boolean
			return field.type == kind
		end
	elseif id == "byNames" then
		local o = Json.obj(env, options)
		local names: { string } = {}
		for _, n in Json.list(env, o.names) do
			if type(n) == "string" then
				table.insert(names, n)
			end
		end
		local inner = namesMatcher(names)
		if Json.str(env, o.mode) == "exclude" then
			return function(field: Field, frame: Frame, frames: { Frame }): boolean
				return not inner(field, frame, frames)
			end
		end
		return inner
	elseif id == "byRegexpOrNames" then
		local o = Json.obj(env, options)
		local names: { string } = {}
		for _, n in Json.list(env, o.names) do
			if type(n) == "string" then
				table.insert(names, n)
			end
		end
		local byNames = namesMatcher(names)
		local byRegex = regexMatcher(Json.str(env, o.pattern))
		return function(field: Field, frame: Frame, frames: { Frame }): boolean
			return byNames(field, frame, frames) or byRegex(field, frame, frames)
		end
	elseif id == "byValue" then
		-- fieldValueMatcher.ts: the field reduced by `reducer`, compared to
		-- `value` with `op` (eq when unset); allIsNull/allIsZero match on
		-- their own truth. Fields of every type are reduced, as in Grafana.
		local o = Json.obj(env, options)
		local reducer = Json.str(env, o.reducer)
		if reducer == nil or reducer == "" then
			return function(): boolean
				return false
			end
		end
		local r = reducer :: string
		local op = Json.str(env, o.op) or "eq"
		local value: any = if o.value == env.null then nil else o.value
		local boolean = r == "allIsNull" or r == "allIsZero"
		return function(field: Field): boolean
			local left = Reduce.reduce(field.values, r, field.type)
			if boolean then
				return left == true
			end
			return M.compareValues(left, op, value)
		end
	end
	return nil
end

M.matcherFor = matcherFor
M.MATCHERS = MATCHERS

return M
