--!strict
-- convertFieldType and formatTime: packages/grafana-data/src/
-- transformations/transformers/convertFieldType.ts and formatTime.ts, with
-- datetime/parser.ts dateTimeParse. Times are parsed the way moment parses
-- them without strict mode (a format's tokens are searched left to right,
-- skipping what does not match; missing date parts default as moment
-- defaults them) and formatted with lib/panels/clock's moment formatter.
-- Zones: "utc", IANA names lib/panels/clock knows, else the viewer's offset
-- (Grafana's "browser" default).
--
-- Destination types: number, string, time, boolean, other (JSON.parse) and
-- enum (indexes into `enumConfig.text`, shown through a value mapping, as
-- Grafana's display processor shows an enum field's text).

local Clock = require("../clock")
local Json = require("../json")
local Frame = require("../../frame/types")
local Range = require("../../time/range")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local NAN = 0 / 0
local MINUTE = 60000
local DAY = 86400000

local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z: number): (number, number, number)
	z += 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return (if m <= 2 then y + 1 else y), m, d
end

local function daysInMonth(y: number, m: number): number
	if m == 2 then
		return if (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 then 29 else 28
	end
	return if m == 4 or m == 6 or m == 9 or m == 11 then 30 else 31
end

-- Zones ----------------------------------------------------------------------------

export type Zone = { utc: boolean, zone: Clock.Zone }

local function zoneOf(tz: string?, env: any): Zone
	local t = tz or ""
	local lower = string.lower(t)
	local localMin = env.local_offset_min or 0
	if lower == "utc" then
		return { utc = true, zone = Clock.zone("utc", localMin) }
	end
	return { utc = false, zone = Clock.zone(if lower == "browser" then "" else t, localMin) }
end

local function offsetAt(z: Zone, ms: number): (number, string)
	return Clock.zoneAt(z.zone, ms)
end

-- Wall-clock ms in the zone to epoch ms.
local function fromWall(z: Zone, wall: number): number
	local guess = wall - z.zone.std * MINUTE
	local off = offsetAt(z, guess)
	return wall - off * MINUTE
end

-- moment format tokens ---------------------------------------------------------------

-- formattingTokens alternatives, in regex order.
local TOKENS: { string } = {
	"Mo",
	"MMMM",
	"MMM",
	"MM",
	"M",
	"Do",
	"DDDo",
	"DDDD",
	"DDD",
	"DD",
	"D",
	"dddd",
	"ddd",
	"dd",
	"do",
	"d",
	"wo",
	"ww",
	"w",
	"Wo",
	"WW",
	"W",
	"Qo",
	"Q",
	"NNNNN",
	"NNNN",
	"NNN",
	"NN",
	"N",
	"YYYYYY",
	"YYYYY",
	"YYYY",
	"YY",
	"yyyy",
	"yyy",
	"yy",
	"yo",
	"y",
	"ggggg",
	"gggg",
	"gg",
	"GGGGG",
	"GGGG",
	"GG",
	"e",
	"E",
	"a",
	"A",
	"hh",
	"h",
	"HH",
	"H",
	"kk",
	"k",
	"mm",
	"m",
	"ss",
	"s",
	"x",
	"X",
	"zz",
	"z",
	"ZZ",
	"Z",
}

local PARSEABLE: { [string]: boolean } = {
	YYYY = true,
	YY = true,
	M = true,
	MM = true,
	MMM = true,
	MMMM = true,
	D = true,
	DD = true,
	Do = true,
	H = true,
	HH = true,
	h = true,
	hh = true,
	k = true,
	kk = true,
	m = true,
	mm = true,
	s = true,
	ss = true,
	a = true,
	A = true,
	Z = true,
	ZZ = true,
	X = true,
	x = true,
	Q = true,
	d = true,
	dd = true,
	ddd = true,
	dddd = true,
}

type Token = { token: string?, literal: string? }

local function tokenize(fmt: string): { Token }
	local out: { Token } = {}
	local i = 1
	local n = #fmt
	while i <= n do
		local c = string.sub(fmt, i, i)
		if c == "[" then
			local close = string.find(fmt, "]", i + 1, true)
			local inner = string.find(fmt, "[", i + 1, true)
			if close and (inner == nil or inner > close) then
				table.insert(out, { literal = string.sub(fmt, i + 1, close - 1) })
				i = close + 1
				continue
			end
		elseif c == "\\" and i < n then
			table.insert(out, { literal = string.sub(fmt, i + 1, i + 1) })
			i += 2
			continue
		end
		local found: string? = nil
		local s = string.match(fmt, "^S+", i)
		if s then
			found = string.sub(s, 1, 9)
		else
			for _, t in TOKENS do
				if string.sub(fmt, i, i + #t - 1) == t then
					found = t
					break
				end
			end
		end
		if found then
			table.insert(out, { token = found })
			i += #found
		else
			table.insert(out, { literal = c })
			i += 1
		end
	end
	return out
end

-- The first token of `fmt` a time cannot be parsed with here, or nil.
function M.unparseableToken(fmt: string): string?
	if string.find(fmt, "L", 1, true) then
		for _, t in tokenize(fmt) do
			if t.literal == "L" then
				return "L"
			end
		end
	end
	for _, t in tokenize(fmt) do
		local tok = t.token
		if tok and not PARSEABLE[tok] and string.sub(tok, 1, 1) ~= "S" then
			return tok
		end
	end
	return nil
end

local MONTHS = { "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" }
local MONTH_NAMES = {
	"january",
	"february",
	"march",
	"april",
	"may",
	"june",
	"july",
	"august",
	"september",
	"october",
	"november",
	"december",
}

-- The Lua pattern standing for a token's parse regex (non-strict).
local function tokenPattern(tok: string): string
	if tok == "YYYY" then
		return "%d%d?%d?%d?"
	elseif tok == "X" then
		return "[%+%-]?%d+%.?%d?%d?%d?"
	elseif tok == "x" then
		return "[%+%-]?%d+"
	elseif tok == "Q" then
		return "%d"
	elseif tok == "MMM" or tok == "MMMM" or tok == "ddd" or tok == "dddd" or tok == "dd" then
		return "%a+"
	elseif tok == "Do" then
		return "%d%d?%a?%a?"
	elseif tok == "a" or tok == "A" then
		return "[aApP]%.?[mM]?%.?"
	elseif tok == "Z" or tok == "ZZ" then
		return "[Zz%+%-]%d?%d?:?%d?%d?"
	elseif tok == "d" then
		return "%d"
	elseif string.sub(tok, 1, 1) == "S" then
		return if #tok <= 3 then "%d%d?%d?" else "%d+"
	end
	return "%d%d?"
end

-- moment(text, format) without strict mode: epoch ms or nil (invalid).
function M.parseWithFormat(text: string, fmt: string, z: Zone, env: any): number?
	local parts: { [string]: number } = {}
	local rest = text
	local any = false
	local pm: boolean? = nil
	local offsetMin: number? = nil
	local stamp: number? = nil
	for _, t in tokenize(fmt) do
		local tok = t.token
		if tok == nil then
			local lit = t.literal :: string
			local at = string.find(rest, lit, 1, true)
			if at then
				rest = string.sub(rest, at + #lit)
			end
			continue
		end
		local s, e = string.find(rest, tokenPattern(tok))
		local input = if s then string.sub(rest, s :: number, e :: number) else nil
		if tok == "Z" or tok == "ZZ" then
			-- matchShortOffset: Z or +-HH(:?MM)?.
			if input and string.lower(string.sub(input, 1, 1)) == "z" then
				input = string.sub(input, 1, 1)
				e = s
			elseif input and not string.match(input, "^[%+%-]%d%d") then
				input = nil
			end
		end
		if input == nil then
			continue
		end
		rest = string.sub(rest, (e :: number) + 1)
		any = true
		if tok == "YYYY" then
			parts.year = tonumber(input) :: number
		elseif tok == "YY" then
			local n = tonumber(input) :: number
			parts.year = n + (if n > 68 then 1900 else 2000)
		elseif tok == "M" or tok == "MM" then
			parts.month = (tonumber(input) :: number) - 1
		elseif tok == "MMM" or tok == "MMMM" then
			local lower = string.lower(input)
			local found: number? = nil
			for i, name in MONTH_NAMES do
				if lower == name or lower == MONTHS[i] then
					found = i - 1
					break
				end
			end
			if found == nil then
				return nil
			end
			parts.month = found
		elseif tok == "Q" then
			parts.month = ((tonumber(input) :: number) - 1) * 3
		elseif tok == "D" or tok == "DD" or tok == "Do" then
			parts.date = tonumber(string.match(input, "^%d+") :: string) :: number
		elseif tok == "H" or tok == "HH" or tok == "k" or tok == "kk" or tok == "h" or tok == "hh" then
			parts.hour = tonumber(input) :: number
		elseif tok == "m" or tok == "mm" then
			parts.minute = tonumber(input) :: number
		elseif tok == "s" or tok == "ss" then
			parts.second = tonumber(input) :: number
		elseif string.sub(tok, 1, 1) == "S" then
			parts.ms = math.floor((tonumber("0." .. input) :: number) * 1000 + 1e-9)
		elseif tok == "a" or tok == "A" then
			pm = string.lower(string.sub(input, 1, 1)) == "p"
		elseif tok == "Z" or tok == "ZZ" then
			if string.lower(input) == "z" then
				offsetMin = 0
			else
				local sign, hh, mm = string.match(input, "^([%+%-])(%d%d):?(%d?%d?)$")
				if sign == nil then
					return nil
				end
				local m = (tonumber(hh :: string) :: number) * 60 + (tonumber(mm :: string) or 0)
				offsetMin = if sign == "-" then -m else m
			end
		elseif tok == "X" then
			stamp = (tonumber(input) :: number) * 1000
		elseif tok == "x" then
			stamp = tonumber(input) :: number
		end
	end
	if stamp then
		return stamp
	end
	if not any then
		return nil
	end
	if pm ~= nil and parts.hour then
		if pm and parts.hour < 12 then
			parts.hour += 12
		elseif not pm and parts.hour == 12 then
			parts.hour = 0
		end
	end
	-- Missing leading date parts are today's; the rest default to the start.
	local nowMs = env.now_ms
	local off = if z.utc then 0 else (offsetAt(z, nowMs))
	local cy, cm, cd = civilFromDays((nowMs + off * MINUTE) // DAY)
	local year, month, date = parts.year, parts.month, parts.date
	if year == nil then
		year = cy
		if month == nil then
			month = cm - 1
			if date == nil then
				date = cd
			end
		end
	end
	month = month or 0
	date = date or 1
	local hour, minute, second, ms = parts.hour or 0, parts.minute or 0, parts.second or 0, parts.ms or 0
	if month < 0 or month > 11 then
		return nil
	end
	if date < 1 or date > daysInMonth(year :: number, month + 1) then
		return nil
	end
	if hour > 24 or (hour == 24 and (minute ~= 0 or second ~= 0 or ms ~= 0)) or minute > 59 or second > 59 then
		return nil
	end
	local wall = daysFromCivil(year :: number, month + 1, date) * DAY
		+ hour * 3600000
		+ minute * MINUTE
		+ second * 1000
		+ ms
	if offsetMin then
		return wall - offsetMin * MINUTE
	end
	if z.utc then
		return wall
	end
	return fromWall(z, wall)
end

local FULL_DATE = "YYYY-MM-DD HH:mm:ss"
local ISO_FORMAT = "YYYY-MM-DDTHH:mm:ss.SSSZ"

-- dateTimeParse(v, { format, timeZone }).valueOf(): epoch ms, NaN when
-- invalid. `undefined` is now, as moment(undefined) is.
function M.parse(v: any, fmt: string?, tz: string?, env: any): number
	if v == nil or v == Shared.GAP then
		return env.now_ms
	end
	local t = type(v)
	if t == "number" then
		return v
	elseif t == "string" then
		if string.find(v, "now", 1, true) then
			local ms = Range.parse(v, false, { now_ms = env.now_ms, offset_min = env.local_offset_min })
			return ms or env.now_ms
		end
		local format = fmt or FULL_DATE
		local z = zoneOf(tz, env)
		if string.sub(v, -1) == "Z" then
			format = ISO_FORMAT
			z = zoneOf("utc", env)
		end
		local ms = M.parseWithFormat(v, format, z, env)
		if ms == nil and string.match(v, "^%d+$") then
			return tonumber(v) :: number
		end
		return ms or NAN
	end
	return NAN
end

-- DateTime.format(fmt) for epoch ms (NaN: "Invalid date").
function M.format(ms: number, fmt: string?, tz: string?, env: any): string
	if ms ~= ms or ms == math.huge or ms == -math.huge then
		return "Invalid date"
	end
	local z = zoneOf(tz, env)
	local f = fmt
	if f == nil or f == "" then
		f = if z.utc then "YYYY-MM-DDTHH:mm:ss[Z]" else "YYYY-MM-DDTHH:mm:ssZ"
	end
	local off, abbr = 0, "UTC"
	if not z.utc then
		off, abbr = offsetAt(z, ms)
	end
	return Clock.format(f :: string, ms, off, abbr)
end

-- Conversions -----------------------------------------------------------------------

local function isIso8601(s: string): boolean
	local date, _time, rest = string.match(s, "^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d:%d%d)(.*)$")
	if not date then
		return false
	end
	local r = rest :: string
	local frac = string.match(r, "^%.%d%d%d+")
	if frac then
		r = string.sub(r, #frac + 1)
	end
	return r == "Z" or string.match(r, "^[%+%-]%d%d:?%d%d$") ~= nil
end

local function toTime(field: Field, fmt: string?, tz: string?, env: any): Field
	local format = if fmt and fmt ~= "" then fmt else nil
	local values: { any } = table.create(#field.values)
	local first: any = nil
	for _, v in field.values do
		if not Shared.nullish(v) then
			first = v
			break
		end
	end
	local toMs = type(first) == "number" and fmt == "X"
	local iso = type(first) == "string" and isIso8601(first)
	for i, v in field.values do
		if Shared.truthy(v) then
			local parsed: number
			if iso then
				local ms, absolute = Clock.parseTime(Shared.jsString(v))
				parsed = if ms and absolute then ms else NAN
			else
				parsed = M.parse(v, format, tz, env)
			end
			if parsed == parsed and parsed ~= math.huge and parsed ~= -math.huge then
				values[i] = if toMs then parsed * 1000 else parsed
			else
				values[i] = Frame.NULL
			end
		else
			values[i] = Frame.NULL
		end
	end
	return Shared.withValues(field, values, "time")
end

-- ensureTimeField.
function M.ensureTime(field: Field, fmt: string?, tz: string?, env: any): Field
	local firstIsNumber = type(field.values[1]) == "number"
	if field.type == "time" and firstIsNumber then
		return field
	end
	if firstIsNumber and fmt ~= "X" then
		return Shared.withValues(field, field.values, "time")
	end
	return toTime(field, fmt, tz, env)
end

local function toNumber(field: Field): Field
	local values: { any } = table.create(#field.values)
	for i, v in field.values do
		if type(v) == "string" then
			v = string.gsub(v, ",", "")
		end
		if Shared.nullish(v) or v == "" then
			values[i] = Frame.NULL
			continue
		end
		local n = Shared.jsNumber(v)
		values[i] = if n == n and n ~= math.huge and n ~= -math.huge then n else Frame.NULL
	end
	return Shared.withValues(field, values, "number")
end

local function toBoolean(field: Field): Field
	local values: { any } = table.create(#field.values)
	for i, v in field.values do
		values[i] = Shared.truthy(v)
	end
	return Shared.withValues(field, values, "boolean")
end

-- fieldToStringField.
function M.toString(field: Field, fmt: string?, tz: string?, joinWith: string?, env: any): Field
	local values: { any } = table.create(#field.values)
	for i, v in field.values do
		if field.type == "time" then
			values[i] = M.format(if v == Frame.NULL then NAN else M.parse(v, nil, tz, env), fmt, tz, env)
		elseif field.type == "string" or field.type == "other" then
			if joinWith and joinWith ~= "" and type(v) == "table" then
				local parts: { string } = {}
				for _, x in v do
					table.insert(parts, if Shared.nullish(x) or x == env.null then "" else Shared.jsString(x))
				end
				values[i] = table.concat(parts, joinWith)
			else
				local s = Shared.jsonStringify(v, env)
				values[i] = if s == nil then Shared.GAP else s
			end
		else
			values[i] = Shared.jsString(v)
		end
	end
	return Shared.withValues(field, values, "string")
end

local function decoded(v: any, env: any): any
	if v == env.null then
		return Frame.NULL
	end
	return v
end

local function toOther(field: Field, env: any): Field
	local values: { any } = table.create(#field.values)
	for i, v in field.values do
		if v == nil or v == Shared.GAP then
			values[i] = Frame.NULL
			continue
		end
		local ok, out = pcall(env.decode, if v == Frame.NULL then "null" else Shared.jsString(v))
		values[i] = if ok and out ~= nil then decoded(out, env) else Frame.NULL
	end
	return Shared.withValues(field, values, "other")
end

-- An enum field: the text's index per value, and a value mapping that shows
-- the text (and color) for each index.
local function toEnum(field: Field, enumConfig: any, env: any): Field
	local text = Json.list(env, Json.path(env, enumConfig, "text"))
	if #text == 0 then
		return field
	end
	local colors = Json.list(env, Json.path(env, enumConfig, "color"))
	local lookup: { [any]: number } = {}
	-- Map.set keeps the last index for a repeated text.
	for i, t in text do
		lookup[t] = i - 1
	end
	local values: { any } = table.create(#field.values)
	for i, v in field.values do
		local idx = lookup[v]
		values[i] = if idx == nil then Shared.GAP else idx
	end
	local options: { [string]: any } = {}
	for i, t in text do
		local color = colors[i]
		options[tostring(i - 1)] = {
			text = Shared.jsString(t),
			color = if type(color) == "string" then color else nil,
			index = i - 1,
		}
	end
	local copy = Shared.withValues(field, values, "number")
	local config: Frame.FieldConfig = if field.config then Tbl.copy(field.config) else {}
	config.mappings = { { type = "value", options = options } }
	copy.config = config
	return copy
end

local TYPES: { [string]: boolean } =
	{ time = true, number = true, string = true, boolean = true, enum = true, other = true }

-- convertFieldType(field, conversion).
function M.convertField(field: Field, conversion: any, env: any): Field
	local dest = Json.str(env, Json.path(env, conversion, "destinationType"))
	local fmt = Json.str(env, Json.path(env, conversion, "dateFormat"))
	local tz = Json.str(env, Json.path(env, conversion, "timezone"))
	if dest == "time" then
		return M.ensureTime(field, fmt, tz, env)
	elseif dest == "number" then
		return toNumber(field)
	elseif dest == "string" then
		return M.toString(field, fmt, tz, Json.str(env, Json.path(env, conversion, "joinWith")), env)
	elseif dest == "boolean" then
		return toBoolean(field)
	elseif dest == "enum" then
		return toEnum(field, Json.path(env, conversion, "enumConfig"), env)
	elseif dest == "other" then
		return toOther(field, env)
	end
	return field
end

function M.unsupported(options: any, ctx: Ctx): string?
	local env = ctx.env
	for _, c in Json.list(env, Json.path(env, options, "conversions")) do
		local dest = Json.str(env, Json.path(env, c, "destinationType"))
		if dest and not TYPES[dest] then
			return "destination type " .. dest
		end
		local fmt = Json.str(env, Json.path(env, c, "dateFormat"))
		if dest == "time" and fmt and fmt ~= "" then
			local tok = M.unparseableToken(fmt)
			if tok then
				return "dateFormat token " .. tok
			end
		end
	end
	return nil
end

function M.apply(frames: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local conversions = Json.list(env, Json.path(env, options, "conversions"))
	if #frames == 0 or #conversions == 0 then
		return frames
	end
	local copies: { Frame } = {}
	for _, f in frames do
		table.insert(copies, Tbl.copy(f))
	end
	for _, c in conversions do
		local target = Json.str(env, Json.path(env, c, "targetField"))
		if target == nil or target == "" then
			continue
		end
		local matches = Shared.byName(env, target)
		for _, frame in copies do
			local fields: { Field } = {}
			for _, field in frame.fields do
				table.insert(fields, if matches(field, frame, copies) then M.convertField(field, c, env) else field)
			end
			frame.fields = fields
		end
	end
	return copies
end

-- formatTime: the field whose display name is `timeField`, as text.
function M.formatTime(frames: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	if #frames == 0 then
		return frames
	end
	local timeField = Json.str(env, Json.path(env, options, "timeField")) or ""
	local fmt = Json.str(env, Json.path(env, options, "outputFormat")) or ""
	local tz = Json.str(env, Json.path(env, options, "timezone"))
	local out: { Frame } = {}
	for _, frame in frames do
		local fields: { Field } = {}
		for _, field in frame.fields do
			if Shared.displayName(field, frame, frames) == timeField then
				table.insert(fields, M.toString(field, fmt, tz, nil, env))
			else
				table.insert(fields, field)
			end
		end
		table.insert(out, Shared.withFields(frame, fields))
	end
	return out
end

return M
