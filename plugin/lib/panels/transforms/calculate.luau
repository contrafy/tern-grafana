--!strict
-- calculateField ("Add field from calculation"): packages/grafana-data/src/
-- transformations/transformers/calculateField.ts with utils/
-- binaryOperators.ts and utils/unaryOperators.ts.
--
-- Modes: reduceRow (any lib/panels/reduce reducer over the row's number
-- fields or `include`d fields), binary (field or number operands; a byType
-- left operand applies to every field of that type), unary, index,
-- cumulativeFunctions and windowFunctions. Unless `timeSeries` is false,
-- frames sharing a time field are first joined into one (ensureColumns),
-- except for a binary operation with a number on the right. The values
-- follow JavaScript: a null operand counts as 0, a join gap as NaN.

local Join = require("./join")
local Json = require("../json")
local Frame = require("../../frame/types")
local Reduce = require("../reduce")
local ReduceT = require("./reduce")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local NAN = 0 / 0

local MODES: { [string]: boolean } = {
	reduceRow = true,
	cumulativeFunctions = true,
	windowFunctions = true,
	binary = true,
	unary = true,
	index = true,
}

type BinaryValue = { fixed: any, matcher: { id: string?, options: any }? }

local BINARY: { [string]: (any, any) -> any } = {
	["+"] = Shared.jsAdd,
	["-"] = function(a: any, b: any): any
		return Shared.jsNumber(a) - Shared.jsNumber(b)
	end,
	["*"] = function(a: any, b: any): any
		return Shared.jsNumber(a) * Shared.jsNumber(b)
	end,
	["/"] = function(a: any, b: any): any
		local x, y = Shared.jsNumber(a), Shared.jsNumber(b)
		if y == 0 then
			-- IEEE division: 1/0 = Infinity, 0/0 = NaN.
			if x ~= x or x == 0 then
				return NAN
			end
			local negZero = 1 / y < 0
			return if (x > 0) ~= negZero then math.huge else -math.huge
		end
		return x / y
	end,
}

local function jsRound(x: number): number
	return math.floor(x + 0.5)
end

local UNARY: { [string]: (number, number) -> number } = {
	abs = function(v: number): number
		return math.abs(v)
	end,
	exp = function(v: number): number
		return math.exp(v)
	end,
	ln = function(v: number): number
		if v < 0 then
			return NAN
		end
		return math.log(v)
	end,
	round = function(v: number): number
		return if v ~= v or v == math.huge or v == -math.huge then v else jsRound(v)
	end,
	floor = function(v: number): number
		return if v ~= v or v == math.huge or v == -math.huge then v else math.floor(v)
	end,
	ceil = function(v: number): number
		return if v ~= v or v == math.huge or v == -math.huge then v else math.ceil(v)
	end,
	percent = function(v: number, total: number): number
		return v / (if total ~= 0 and total == total then total else 1)
	end,
}

local function isNaNNumber(v: any): boolean
	local n = Shared.jsNumber(v)
	return n ~= n
end

-- checkBinaryValueType: the pre-10.3 string operand is a field name unless it
-- reads as a number that is not also a field name.
local function binaryValue(env: any, raw: any, names: { [string]: boolean }): BinaryValue?
	if raw == nil or raw == env.null then
		raw = ""
	end
	if type(raw) == "string" then
		if isNaNNumber(raw) or names[raw] then
			return { matcher = { id = "byName", options = raw } }
		end
		return { fixed = raw }
	elseif type(raw) == "table" then
		local m = Json.tbl(env, raw.matcher)
		local fixed = if raw.fixed == env.null then nil else raw.fixed
		return {
			fixed = fixed,
			matcher = if m
				then { id = Json.str(env, m.id), options = if m.options == env.null then nil else m.options }
				else nil,
		}
	end
	return nil
end

local function operandText(v: BinaryValue?): any
	if v == nil then
		return ""
	end
	local m = v.matcher
	if m and m.options ~= nil then
		return m.options
	end
	if v.fixed ~= nil then
		return v.fixed
	end
	return ""
end

-- findFieldValuesWithNameOrConstant.
local function operandValues(v: BinaryValue?, frame: Frame, frames: { Frame }): { any }?
	if v == nil then
		return nil
	end
	local m = v.matcher
	if m and m.id == "byName" then
		local name = if m.options ~= nil then m.options else ""
		for _, f in frame.fields do
			if name == Shared.displayName(f, frame, frames) then
				if f.type == "boolean" then
					local out: { any } = table.create(#f.values)
					for i, x in f.values do
						out[i] = if Shared.truthy(x) then 1 else 0
					end
					return out
				end
				return f.values
			end
		end
	end
	local src: any = v.fixed
	if src == nil then
		src = if m and m.options ~= nil then m.options else ""
	end
	local n = Shared.jsParseFloat(src)
	if n == n then
		return table.create(Shared.length(frame), n)
	end
	return nil
end

local function applyBinary(op: (any, any) -> any, left: { any }, right: { any }): { any }
	local out: { any } = table.create(#left)
	for i = 1, #left do
		local a, b = left[i], right[i]
		out[i] = op(if a == nil then Shared.GAP else a, if b == nil then Shared.GAP else b)
	end
	return out
end

-- getNameFromOptions (after the binary operands are normalized).
local function nameOf(
	env: any,
	options: any,
	mode: string,
	binary: { left: BinaryValue?, right: BinaryValue?, operator: string }?
): string
	local alias = Json.str(env, Json.path(env, options, "alias"))
	if alias and alias ~= "" then
		return alias
	end
	if mode == "cumulativeFunctions" then
		local c = Json.obj(env, Json.path(env, options, "cumulative"))
		local field = Json.str(env, c.field)
		return "cumulative "
			.. (Json.str(env, c.reducer) or "")
			.. (if field and field ~= "" then "(" .. field .. ")" else "")
	elseif mode == "windowFunctions" then
		local w = Json.obj(env, Json.path(env, options, "window"))
		local field = Json.str(env, w.field)
		return (Json.str(env, w.windowAlignment) or "")
			.. " moving "
			.. (Json.str(env, w.reducer) or "")
			.. (if field and field ~= "" then "(" .. field .. ")" else "")
	elseif mode == "unary" then
		local u = Json.obj(env, Json.path(env, options, "unary"))
		local field = Json.str(env, u.fieldName)
		return (Json.str(env, u.operator) or "") .. (if field and field ~= "" then "(" .. field .. ")" else "")
	elseif mode == "binary" then
		local left = if binary then operandText(binary.left) else ""
		local right = if binary then operandText(binary.right) else ""
		local ls, rs = Shared.jsString(left), Shared.jsString(right)
		if string.find(ls, "$", 1, true) or string.find(rs, "$", 1, true) then
			return ""
		end
		local operator = if binary then binary.operator else "+"
		return if Shared.truthy(left) and Shared.truthy(right) then ls .. " " .. operator .. " " .. rs else ""
	elseif mode == "reduceRow" then
		local id = Json.str(env, Json.path(env, options, "reduce", "reducer"))
		if id and ReduceT.supports(id) then
			return ReduceT.name(id)
		end
	elseif mode == "index" then
		return "Row"
	end
	return "math"
end

type Creator = (Frame) -> { any }?

local function reduceRowCreator(env: any, options: any, frames: { Frame }): Creator
	local r = Json.obj(env, Json.path(env, options, "reduce"))
	local include = Json.list(env, r.include)
	local matcher: Shared.FieldMatcher = if #include > 0 then Shared.byNames(env, include) else Shared.numeric
	local reducer = Json.str(env, r.reducer) or "sum"
	local nvm = Json.str(env, r.nullValueMode)
	local nullMode: Reduce.NullMode = if nvm == "connected"
		then "connected"
		elseif nvm == "null as zero" then "null as zero"
		else "null"
	return function(frame: Frame): { any }?
		local columns: { { any } } = {}
		for _, f in frame.fields do
			if matcher(f, frame, frames) then
				table.insert(columns, f.values)
			end
		end
		local n = Shared.length(frame)
		local out: { any } = table.create(n)
		local row: { any } = table.create(#columns)
		for i = 1, n do
			for j, col in columns do
				row[j] = Shared.stored(col[i])
			end
			local v = if Reduce.supports(reducer)
				then Reduce.reduce(row, reducer, "number", nullMode)
				else ReduceT.reduceField(Frame.field("temp", "number", table.clone(row)), { reducer })[reducer]
			out[i] = if v == nil then Frame.NULL else v
		end
		return out
	end
end

local function selectField(env: any, name: string?, frame: Frame, frames: { Frame }): Field?
	local matcher: Shared.FieldMatcher = if name and name ~= "" then Shared.byNames(env, { name }) else Shared.numeric
	for _, f in frame.fields do
		if matcher(f, frame, frames) then
			return f
		end
	end
	return nil
end

local function cumulativeCreator(env: any, options: any, frames: { Frame }): Creator
	local c = Json.obj(env, Json.path(env, options, "cumulative"))
	local reducer = Json.str(env, c.reducer) or "sum"
	local name = Json.str(env, c.field)
	return function(frame: Frame): { any }?
		local field = selectField(env, name, frame, frames)
		if field == nil then
			return nil
		end
		local n = Shared.length(frame)
		local out: { any } = table.create(n)
		local total: any = 0
		for i = 1, n do
			local v = field.values[i]
			total = Shared.jsAdd(total, if Shared.nullish(v) then 0 else v)
			out[i] = if reducer == "sum" then total else Shared.jsNumber(total) / i
		end
		return out
	end
end

local function variance(vals: { any }): number
	local squareSum, mean, count = 0, 0, 0
	for _, v in vals do
		if not Shared.nullish(v) then
			local x = Shared.jsNumber(v)
			count += 1
			local old = mean
			mean += (x - old) / count
			squareSum += (x - old) * (x - mean)
		end
	end
	if count == 0 then
		return 0
	end
	return squareSum / count
end

local function slice(values: { any }, first: number, last: number): { any }
	local out: { any } = {}
	for i = math.max(1, first), math.min(last, #values) do
		table.insert(out, values[i])
	end
	return out
end

local function windowCreator(env: any, options: any, frames: { Frame }): Creator
	local w = Json.obj(env, Json.path(env, options, "window"))
	local reducer = Json.str(env, w.reducer) or "mean"
	local alignment = Json.str(env, w.windowAlignment) or "trailing"
	local sizeMode = Json.str(env, w.windowSizeMode) or "percentage"
	local size = Json.num(env, w.windowSize) or 0.1
	local name = Json.str(env, w.field)
	return function(frame: Frame): { any }?
		local n = Shared.length(frame)
		local window = math.ceil(size * (if sizeMode == "percentage" then n else 1))
		local field = selectField(env, name, frame, frames)
		if field == nil then
			return nil
		end
		local values = field.values
		local out: { any } = table.create(n)
		local sum, count = 0, 0
		if alignment == "centered" then
			local leading = math.ceil(window / 2) - 1
			local trailing = window // 2
			for i0 = 0, n - 1 do
				local first = i0 - trailing
				local last = i0 + leading
				if reducer == "mean" then
					if i0 == 0 then
						local x = 0
						while x < leading + 1 and x < #values do
							if not Shared.nullish(values[x + 1]) then
								sum += Shared.jsNumber(values[x + 1])
								count += 1
							end
							x += 1
						end
					else
						if last < #values and not Shared.nullish(values[last + 1]) then
							sum += Shared.jsNumber(values[last + 1])
							count += 1
						end
						if first > 0 and not Shared.nullish(values[first]) then
							sum -= Shared.jsNumber(values[first])
							count -= 1
						end
					end
					out[i0 + 1] = if count == 0 then 0 else sum / count
				else
					local v = variance(slice(values, first + 1, last + 1))
					out[i0 + 1] = if reducer == "variance" then v else math.sqrt(v)
				end
			end
		else
			for i0 = 0, n - 1 do
				if reducer == "mean" then
					local cur = values[i0 + 1]
					if not Shared.nullish(cur) then
						count += 1
						sum += Shared.jsNumber(cur)
						if i0 > window - 1 then
							local old = values[i0 - window + 1]
							if not Shared.nullish(old) then
								sum -= Shared.jsNumber(old)
								count -= 1
							end
						end
					end
					out[i0 + 1] = if count == 0 then 0 else sum / count
				else
					local v = variance(slice(values, i0 - window + 2, i0 + 1))
					out[i0 + 1] = if reducer == "variance" then v else math.sqrt(v)
				end
			end
		end
		return out
	end
end

local function unaryCreator(env: any, options: any, frames: { Frame }): Creator
	local u = Json.obj(env, Json.path(env, options, "unary"))
	local opId = Json.str(env, u.operator) or "abs"
	local op = UNARY[opId]
	local name = Json.str(env, u.fieldName) or ""
	return function(frame: Frame): { any }?
		local values: { any } = {}
		for _, f in frame.fields do
			if name == Shared.displayName(f, frame, frames) and f.type == "number" then
				values = f.values
			end
		end
		if #values == 0 or op == nil then
			return nil
		end
		local sum = 0
		if opId == "percent" then
			for _, v in values do
				if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
					sum += v
				end
			end
		end
		local out: { any } = table.create(#values)
		for i, v in values do
			out[i] = op(Shared.jsNumber(if v == nil then Shared.GAP else v), sum)
		end
		return out
	end
end

function M.unsupported(options: any, ctx: Ctx): string?
	local env = ctx.env
	local mode = Json.str(env, Json.path(env, options, "mode")) or "reduceRow"
	if not MODES[mode] then
		return "mode " .. mode
	end
	if mode == "reduceRow" then
		local id = Json.str(env, Json.path(env, options, "reduce", "reducer")) or "sum"
		if not ReduceT.supports(id) then
			return "reducer " .. id
		end
	elseif mode == "cumulativeFunctions" then
		local id = Json.str(env, Json.path(env, options, "cumulative", "reducer")) or "sum"
		if id ~= "sum" and id ~= "mean" then
			return "cumulative reducer " .. id
		end
	elseif mode == "windowFunctions" then
		local id = Json.str(env, Json.path(env, options, "window", "reducer")) or "mean"
		if id ~= "mean" and id ~= "stdDev" and id ~= "variance" then
			return "window reducer " .. id
		end
		local size = Json.num(env, Json.path(env, options, "window", "windowSize")) or 0.1
		if size <= 0 then
			return "window size " .. Shared.jsString(size)
		end
	end
	return nil
end

function M.apply(input: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local mode = Json.str(env, Json.path(env, options, "mode")) or "reduceRow"
	local timeSeries = Json.bool(env, Json.path(env, options, "timeSeries")) ~= false
	local replace = Json.bool(env, Json.path(env, options, "replaceFields")) == true
	local rawBinary = Json.obj(env, Json.path(env, options, "binary"))
	local right = rawBinary.right
	local rightVal: any = nil
	if type(right) == "string" then
		rightVal = right
	elseif type(right) == "table" and right ~= env.null then
		rightVal = if right.fixed == env.null then nil else right.fixed
	end
	local isBinaryFixed = mode == "binary" and not isNaNNumber(if rightVal == nil then Shared.GAP else rightVal)
	local data: { Frame } = if timeSeries and not isBinaryFixed then Join.ensureColumns(input, ctx) else input

	local creator: Creator? = nil
	local binary: { left: BinaryValue?, right: BinaryValue?, operator: string }? = nil
	if mode == "reduceRow" then
		creator = reduceRowCreator(env, options, data)
	elseif mode == "cumulativeFunctions" then
		creator = cumulativeCreator(env, options, data)
	elseif mode == "windowFunctions" then
		creator = windowCreator(env, options, data)
	elseif mode == "unary" then
		creator = unaryCreator(env, options, data)
	elseif mode == "binary" then
		local names: { [string]: boolean } = {}
		for _, frame in data do
			for _, f in frame.fields do
				names[f.name] = true
			end
		end
		local b = {
			left = binaryValue(env, rawBinary.left, names),
			operator = Json.str(env, rawBinary.operator) or "+",
			right = binaryValue(env, rawBinary.right, names),
		}
		binary = b
		local op = BINARY[b.operator]
		local leftMatcher = if b.left then b.left.matcher else nil
		if leftMatcher and leftMatcher.id == "byType" then
			local fieldType = leftMatcher.options
			local suffix = Shared.jsString(
				if b.right
						and b.right.matcher
						and b.right.matcher.options ~= nil
					then b.right.matcher.options
					elseif b.right then b.right.fixed
					else nil
			)
			local out: { Frame } = {}
			for _, frame in data do
				local tf = Shared.timeField(frame)
				local fields: { Field } = {}
				local added = false
				if tf and timeSeries then
					table.insert(fields, tf)
				end
				for _, field in frame.fields do
					if not replace and not table.find(fields, field) then
						table.insert(fields, field)
					end
					if field.type == fieldType then
						local rightValues = operandValues(b.right, frame, data)
						if rightValues and op then
							local f = Tbl.copy(field)
							f.name = field.name .. " " .. b.operator .. " " .. suffix
							f.values = applyBinary(op, field.values, rightValues)
							table.insert(fields, f)
							added = true
						end
					end
				end
				if not (replace and not added) then
					table.insert(out, Shared.withFields(frame, fields))
				end
			end
			return out
		end
		creator = function(frame: Frame): { any }?
			local l = operandValues(b.left, frame, data)
			local r = operandValues(b.right, frame, data)
			if l == nil or r == nil or op == nil then
				return nil
			end
			return applyBinary(op, l, r)
		end
	elseif mode == "index" then
		local asPercentile = Json.bool(env, Json.path(env, options, "index", "asPercentile")) == true
		local aliasRaw = Json.path(env, options, "alias")
		local name = if type(aliasRaw) == "string" then aliasRaw else "Row"
		local out: { Frame } = {}
		for _, frame in data do
			local n = Shared.length(frame)
			local values: { any } = table.create(n)
			for i = 1, n do
				values[i] = if asPercentile then (i - 1) / n else i - 1
			end
			local f = Frame.field(name, "number", values, nil, if asPercentile then { unit = "percentunit" } else {})
			local fields: { Field } = if replace then {} else Tbl.copy(frame.fields)
			table.insert(fields, f)
			table.insert(out, Shared.withFields(frame, fields))
		end
		return out
	end
	if creator == nil then
		return data
	end
	local name = nameOf(env, options, mode, binary)
	local alias = Json.str(env, Json.path(env, options, "alias"))
	local out: { Frame } = {}
	for _, frame in data do
		local values = creator(frame)
		if values == nil then
			if not replace then
				table.insert(out, frame)
			end
			continue
		end
		local config: Frame.FieldConfig = {}
		if alias and alias ~= "" then
			-- An explicit alias stops downstream auto-renames.
			config.displayName = alias
		end
		local field = Frame.field(name, "number", values, nil, config)
		local fields: { Field }
		if replace then
			local tf = Shared.timeField(frame)
			fields = if tf and timeSeries then { tf, field } else { field }
		else
			fields = Tbl.copy(frame.fields)
			table.insert(fields, field)
		end
		table.insert(out, Shared.withFields(frame, fields))
	end
	return out
end

return M
