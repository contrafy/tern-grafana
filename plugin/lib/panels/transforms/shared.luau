--!strict
-- What the ported Grafana transformers (packages/grafana-data/src/
-- transformations/transformers/*.ts, public/app/features/transformers/**)
-- share: the JavaScript value semantics their arithmetic and string
-- templates rely on, field matchers (matchers/nameMatcher.ts,
-- predicates.ts, fieldTypeMatcher.ts), frame sorting (dataframe/
-- processDataFrame.ts sortDataFrameByFields, field/fieldComparers.ts) and
-- the dynamic refIds of transformers/utils.ts.
--
-- JavaScript tells `null` (a missing value the datasource sent) from
-- `undefined` (an alignment gap a join created): `null + 1` is 1 but
-- `undefined + 1` is NaN. Frames carry Frame.NULL for the first; joins here
-- write GAP for the second, and the transform pipeline turns every GAP back
-- into Frame.NULL before the frames leave it.

local Env = require("../../env")
local FieldConfig = require("../fieldconfig")
local Frame = require("../../frame/types")
local Json = require("../json")
local Tbl = require("../../tbl")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field

export type Ctx = {
	env: Env,
	-- Dashboard variable interpolation (TemplateSrv.replace), when known.
	interpolate: ((string) -> string)?,
}

export type FieldMatcher = (Field, Frame, { Frame }) -> boolean

local M = {}

M.NULL = Frame.NULL
-- JavaScript `undefined` in a column (see the header).
M.GAP = newproxy(false) :: any

function M.nullish(v: any): boolean
	return v == nil or v == Frame.NULL or v == M.GAP
end

-- The value as the rest of the plugin stores it (GAP and nil -> NULL).
function M.stored(v: any): any
	if v == nil or v == M.GAP then
		return Frame.NULL
	end
	return v
end

-- A column with GAP and nil as Frame.NULL, for lib/panels/reduce.
function M.storedColumn(values: { any }, n: number?): { any }
	local len = n or #values
	local out: { any } = table.create(len)
	for i = 1, len do
		out[i] = M.stored(values[i])
	end
	return out
end

function M.length(frame: Frame): number
	local first = frame.fields[1]
	return if first then #first.values else 0
end

-- getTimeField: the first time field.
function M.timeField(frame: Frame): (Field?, number?)
	for i, f in frame.fields do
		if f.type == "time" then
			return f, i
		end
	end
	return nil, nil
end

function M.withFields(frame: Frame, fields: { Field }): Frame
	local copy = Tbl.copy(frame)
	copy.fields = fields
	return copy
end

function M.withValues(field: Field, values: { any }, fieldType: Frame.FieldType?): Field
	local copy = Tbl.copy(field)
	copy.values = values
	if fieldType then
		copy.type = fieldType
	end
	return copy
end

-- JavaScript values -------------------------------------------------------------

local NAN = 0 / 0

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) :: string
end

-- Number(v).
function M.jsNumber(v: any): number
	local t = type(v)
	if t == "number" then
		return v
	elseif v == Frame.NULL then
		return 0
	elseif t == "boolean" then
		return if v then 1 else 0
	elseif t == "string" then
		local s = trim(v)
		if s == "" then
			return 0
		elseif s == "Infinity" or s == "+Infinity" then
			return math.huge
		elseif s == "-Infinity" then
			return -math.huge
		end
		local hex = string.match(s, "^0[xX](%x+)$")
		if hex then
			return tonumber(hex, 16) :: number
		end
		if
			string.match(s, "^[+-]?%d+%.?%d*[eE][+-]?%d+$")
			or string.match(s, "^[+-]?%.%d+[eE][+-]?%d+$")
			or string.match(s, "^[+-]?%d+%.?%d*$")
			or string.match(s, "^[+-]?%.%d+$")
		then
			return tonumber(s) :: number
		end
		return NAN
	end
	return NAN
end

-- parseFloat(v): the longest numeric prefix after leading whitespace.
function M.jsParseFloat(v: any): number
	if type(v) == "number" then
		return v
	end
	local s = M.jsString(v)
	s = string.match(s, "^%s*(.*)$") :: string
	local sign, rest = string.match(s, "^([+-]?)(.*)$")
	if string.sub(rest :: string, 1, 8) == "Infinity" then
		return if sign == "-" then -math.huge else math.huge
	end
	local num = string.match(s, "^[+-]?%d+%.?%d*[eE][+-]?%d+")
		or string.match(s, "^[+-]?%.%d+[eE][+-]?%d+")
		or string.match(s, "^[+-]?%d+%.?%d*")
		or string.match(s, "^[+-]?%.%d+")
	if num then
		return tonumber(num) :: number
	end
	return NAN
end

-- String(v) / `${v}`.
function M.jsString(v: any): string
	local t = type(v)
	if t == "string" then
		return v
	elseif t == "number" then
		if v ~= v then
			return "NaN"
		elseif v == math.huge then
			return "Infinity"
		elseif v == -math.huge then
			return "-Infinity"
		elseif v == math.floor(v) and math.abs(v) < 1e21 then
			return string.format("%.0f", v)
		end
		local s = tostring(v)
		-- JavaScript writes exponents without zero padding: 1e-7, 1e+21.
		local mant, esign, digits = string.match(s, "^(.-)e([+-])0*(%d+)$")
		if mant then
			return (mant :: string) .. "e" .. (esign :: string) .. (digits :: string)
		end
		return s
	elseif t == "boolean" then
		return if v then "true" else "false"
	elseif v == Frame.NULL then
		return "null"
	elseif v == nil or v == M.GAP then
		return "undefined"
	elseif t == "table" then
		if #v > 0 or next(v) == nil then
			local parts: { string } = {}
			for _, x in v do
				table.insert(parts, if M.nullish(x) then "" else M.jsString(x))
			end
			return table.concat(parts, ",")
		end
		return "[object Object]"
	end
	return tostring(v)
end

-- JavaScript truthiness.
function M.truthy(v: any): boolean
	if M.nullish(v) or v == false or v == "" or v == 0 then
		return false
	end
	return not (type(v) == "number" and v ~= v)
end

-- a + b: string concatenation when either side is a string.
function M.jsAdd(a: any, b: any): any
	if type(a) == "string" or type(b) == "string" or type(a) == "table" or type(b) == "table" then
		return M.jsString(a) .. M.jsString(b)
	end
	return M.jsNumber(a) + M.jsNumber(b)
end

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
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. out .. '"'
end

-- JSON.stringify(v); nil for `undefined`.
function M.jsonStringify(v: any, env: Env): string?
	local t = type(v)
	if v == nil or v == M.GAP then
		return nil
	elseif v == Frame.NULL or v == env.null then
		return "null"
	elseif t == "string" then
		return jsonString(v)
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "null"
		end
		return M.jsString(v)
	elseif t == "boolean" then
		return if v then "true" else "false"
	elseif t == "table" then
		local ok, s = pcall(env.encode, v)
		return if ok and type(s) == "string" then s else nil
	end
	return nil
end

-- Field matchers -----------------------------------------------------------------

-- byName: the field name or display name (with the dataplane fallbacks).
function M.byName(env: Env, name: any): FieldMatcher
	local m = if type(name) == "string" then FieldConfig.matcherFor(env, { id = "byName", options = name }) else nil
	if m then
		return m
	end
	return function(): boolean
		return false
	end
end

-- byNames (include): any of the names, as byName matches each.
function M.byNames(env: Env, names: { any }): FieldMatcher
	local list: { FieldMatcher } = {}
	for _, n in names do
		if type(n) == "string" then
			table.insert(list, M.byName(env, n))
		end
	end
	return function(field: Field, frame: Frame, frames: { Frame }): boolean
		for _, m in list do
			if m(field, frame, frames) then
				return true
			end
		end
		return false
	end
end

function M.numeric(field: Field, _frame: Frame?, _frames: { Frame }?): boolean
	return field.type == "number"
end

function M.notTime(field: Field, _frame: Frame?, _frames: { Frame }?): boolean
	return field.type ~= "time"
end

local PREDICATES: { [string]: FieldMatcher } = {
	numeric = function(field: Field): boolean
		return field.type == "number"
	end,
	time = function(field: Field): boolean
		return field.type == "time"
	end,
	first = function(field: Field, frame: Frame): boolean
		return frame.fields[1] == field
	end,
	firstTimeField = function(field: Field, frame: Frame): boolean
		return field.type == "time" and (M.timeField(frame)) == field
	end,
}

local NAMED: { [string]: boolean } =
	{ byName = true, byRegexp = true, byFrameRefID = true, byType = true, byNames = true, byRegexpOrNames = true }

-- Whether getFieldMatcher knows this matcher config here.
function M.knownMatcher(env: Env, raw: any): boolean
	local id = Json.str(env, Json.path(env, raw, "id"))
	return id ~= nil and (NAMED[id] == true or PREDICATES[id] ~= nil)
end

-- getFieldMatcher(config).
function M.fieldMatcher(env: Env, raw: any): FieldMatcher?
	local id = Json.str(env, Json.path(env, raw, "id"))
	if id == nil then
		return nil
	end
	local p = PREDICATES[id]
	if p then
		return p
	elseif id == "byName" then
		return M.byName(env, Json.path(env, raw, "options"))
	elseif id == "byNames" then
		local o = Json.obj(env, Json.path(env, raw, "options"))
		local inner = M.byNames(env, Json.list(env, o.names))
		if Json.str(env, o.mode) == "exclude" then
			return function(field: Field, frame: Frame, frames: { Frame }): boolean
				return not inner(field, frame, frames)
			end
		end
		return inner
	end
	return FieldConfig.matcherFor(env, raw)
end

-- Sorting --------------------------------------------------------------------------

type Comparer = (number, number) -> number

local function falsy(a: any, b: any): number
	local ta, tb = M.truthy(a), M.truthy(b)
	if not ta and tb then
		return 1
	elseif ta and not tb then
		return -1
	end
	return 0
end

local function numericDiff(a: any, b: any): number
	local d = M.jsNumber(a) - M.jsNumber(b)
	return if d ~= d then 0 else d
end

-- Intl.Collator("en", { sensitivity: "base" }): case-insensitive.
local function stringCompare(a: any, b: any): number
	if not M.truthy(a) or not M.truthy(b) then
		return falsy(a, b)
	end
	local la, lb = string.lower(M.jsString(a)), string.lower(M.jsString(b))
	if la < lb then
		return -1
	elseif la > lb then
		return 1
	end
	return 0
end

local function timeCompare(a: any, b: any): number
	if not M.truthy(a) or not M.truthy(b) then
		return falsy(a, b)
	end
	if type(a) == "number" and type(b) == "number" then
		return a - b
	end
	return 0
end

-- fieldIndexComparer.
function M.comparer(field: Field, desc: boolean?): Comparer
	local values = field.values
	local mult = if desc then -1 else 1
	if field.type == "number" then
		return function(a: number, b: number): number
			return mult * numericDiff(values[a], values[b])
		end
	elseif field.type == "string" then
		return function(a: number, b: number): number
			return mult * stringCompare(values[a], values[b])
		end
	elseif field.type == "boolean" then
		return function(a: number, b: number): number
			return mult * falsy(values[a], values[b])
		end
	elseif field.type == "time" then
		if type(values[1]) == "number" then
			return function(a: number, b: number): number
				return mult * numericDiff(values[a], values[b])
			end
		end
		return function(a: number, b: number): number
			return mult * timeCompare(values[a], values[b])
		end
	end
	return function(a: number, b: number): number
		return mult * (a - b)
	end
end

local COMPARABLE: { [string]: boolean } = { number = true, string = true, boolean = true, time = true }

export type SortField = { index: number, desc: boolean? }

-- sortDataFrameByFields: earlier fields win, later ones break ties; field
-- types without a comparer only order rows when nothing else can. Stable.
function M.sortByFields(frame: Frame, sorts: { SortField }): Frame
	local candidates: { { field: Field, desc: boolean? } } = {}
	for _, s in sorts do
		local f = frame.fields[s.index]
		if f then
			table.insert(candidates, { field = f, desc = s.desc })
		end
	end
	local chained: { { field: Field, desc: boolean? } } = {}
	for _, c in candidates do
		if COMPARABLE[c.field.type] then
			table.insert(chained, c)
		end
	end
	if #chained == 0 and candidates[1] then
		chained = { candidates[1] }
	end
	if #chained == 0 then
		return frame
	end
	local comparers: { Comparer } = {}
	for _, c in chained do
		table.insert(comparers, M.comparer(c.field, c.desc))
	end
	local n = M.length(frame)
	local index: { number } = table.create(n)
	for i = 1, n do
		index[i] = i
	end
	table.sort(index, function(a: number, b: number): boolean
		for _, cmp in comparers do
			local r = cmp(a, b)
			if r ~= 0 then
				return r < 0
			end
		end
		return a < b
	end)
	local fields: { Field } = {}
	for _, f in frame.fields do
		local vals: { any } = table.create(#f.values)
		for i = 1, #f.values do
			local v = f.values[index[i]]
			vals[i] = if v == nil then M.GAP else v
		end
		table.insert(fields, M.withValues(f, vals))
	end
	return M.withFields(frame, fields)
end

-- isLikelyAscendingVector (joinDataFrames.ts), 50 samples.
function M.isLikelyAscending(data: { any }): boolean
	local len = #data
	if len <= 1 then
		return true
	end
	local first, last = 1, len
	while first <= last and M.nullish(data[first]) do
		first += 1
	end
	while last >= first and M.nullish(data[last]) do
		last -= 1
	end
	if last <= first then
		return true
	end
	local stride = math.max(1, (last - first + 1) // 50)
	local prev = data[first]
	local i = first + stride
	while i <= last do
		local v = data[i]
		if not M.nullish(v) and not M.nullish(prev) then
			if M.jsNumber(v) <= M.jsNumber(prev) or (type(v) == "string" and v <= prev) then
				return false
			end
			prev = v
		end
		i += stride
	end
	return true
end

-- maybeSortFrame: sort by the field unless it is a string or ascending.
function M.maybeSort(frame: Frame, index: number): Frame
	local f = frame.fields[index]
	if f and f.type ~= "string" and not M.isLikelyAscending(f.values) then
		return M.sortByFields(frame, { { index = index } })
	end
	return frame
end

-- refIds ----------------------------------------------------------------------------

-- getTransformationDynamicRefId.
function M.dynamicRefId(id: string, frames: { Frame }): string
	local parts: { string } = {}
	for _, f in frames do
		table.insert(parts, f.refId or "")
	end
	return id .. "-" .. table.concat(parts, "-")
end

-- applyStaticRefId: name the single frame a transformation passes through.
function M.staticRefId(frames: { Frame }, refId: string?): { Frame }
	if refId == nil or refId == "" or #frames ~= 1 or frames[1].refId == refId then
		return frames
	end
	local copy = Tbl.copy(frames[1])
	copy.refId = refId
	return { copy }
end

-- Display name -----------------------------------------------------------------------

function M.displayName(field: Field, frame: Frame, frames: { Frame }?): string
	return FieldConfig.displayName(field, frame, frames)
end

return M
