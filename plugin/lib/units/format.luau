--!strict
-- Grafana value formatting by unit id. A port of grafana/grafana
-- packages/grafana-data/src/valueFormats (valueFormats.ts getValueFormat,
-- categories.ts, baseFormatters.ts toFixed/getDecimalsForValue/scaledUnits,
-- symbolFormatters.ts, arithmeticFormatters.ts, dateTimeFormatters.ts), so a
-- panel reads the same in Tern as in Grafana.
--
-- Deliberate differences from Grafana:
-- - NaN, +Inf and -Inf render as "NaN", "∞" and "-∞" with no prefix or suffix
--   for every unit (Grafana is inconsistent per formatter, e.g. "∞ years").
-- - "us" is accepted as an alias of Grafana's "µs".
-- - "locale" always groups like en-US.

export type Formatted = { text: string, prefix: string, suffix: string }

type Formatter = (value: number, decimals: number?) -> Formatted

local M = {}

local LN10 = 2.302585092994046

local function result(text: string, prefix: string?, suffix: string?): Formatted
	return { text = text, prefix = prefix or "", suffix = suffix or "" }
end

-- Math.round: halves go toward +Inf.
local function jsRound(x: number): number
	local f = math.floor(x)
	if x - f >= 0.5 then
		return f + 1
	end
	return f
end

-- String(n) in JavaScript; Luau already picks the same shortest digits and the
-- same switch to exponent form, but pads the exponent ("1e-07").
local function jsString(n: number): string
	if n == 0 then
		return "0"
	end
	local s = tostring(n)
	local mantissa, sign, digits = string.match(s, "^(.-)e([%+%-])0*(%d+)$")
	if mantissa and sign and digits then
		return mantissa .. "e" .. sign .. digits
	end
	return s
end

-- Grafana's automatic decimals: integers get none, other values keep three
-- significant digits (its "norm > 2.25" branch always fires).
function M.decimalsFor(value: number): number
	if value ~= value or value == math.huge or value == -math.huge or value % 1 == 0 then
		return 0
	end
	local log10 = math.floor(math.log(math.abs(value)) / LN10)
	return math.max(0, 2 - log10)
end

function M.toFixed(value: number, decimals: number?): string
	if value ~= value then
		return "NaN"
	elseif value == math.huge then
		return "∞"
	elseif value == -math.huge then
		return "-∞"
	end
	local d = if decimals == nil then M.decimalsFor(value) else math.clamp(math.floor(decimals), 0, 100)
	if value == 0 then
		return if d > 0 then "0." .. string.rep("0", d) else "0"
	end
	local factor = if d > 0 then 10 ^ d else 1
	local rounded = jsRound(value * factor) / factor
	if rounded ~= rounded or rounded == math.huge or rounded == -math.huge then
		rounded = value
	end
	local s = jsString(rounded)
	if string.find(s, "e", 1, true) then
		return s
	end
	local dot = string.find(s, ".", 1, true)
	local precision = if dot then #s - dot else 0
	if precision < d then
		return (if precision > 0 then s else s .. ".") .. string.rep("0", d - precision)
	end
	return s
end

local function fixedUnit(unit: string, asPrefix: boolean): Formatter
	return function(value: number, decimals: number?): Formatted
		local text = M.toFixed(value, decimals)
		if unit == "" then
			return result(text)
		elseif asPrefix then
			return result(text, unit)
		end
		return result(text, nil, " " .. unit)
	end
end

local function scaledUnits(factor: number, exts: { string }, offset: number): Formatter
	local logFactor = math.log10(factor)
	local top = #exts - 1
	return function(value: number, decimals: number?): Formatted
		local index = if value == 0 then 0 else math.floor(math.log10(math.abs(value)) / logFactor)
		local suffix = exts[math.clamp(offset + index, 0, top) + 1]
		local scaled = value / factor ^ math.clamp(index, -offset, top - offset)
		return result(M.toFixed(scaled, decimals), nil, suffix)
	end
end

local SI_PREFIXES = { "f", "p", "n", "µ", "m", "", "k", "M", "G", "T", "P", "E", "Z", "Y" }
local SI_BASE_INDEX = 5
local BIN_PREFIXES = { "", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi", "Yi" }

local function prefixed(prefixes: { string }, unit: string): { string }
	local out = table.create(#prefixes)
	for i, p in prefixes do
		out[i] = " " .. p .. unit
	end
	return out
end

local function siPrefix(unit: string): Formatter
	return scaledUnits(1000, prefixed(SI_PREFIXES, unit), SI_BASE_INDEX)
end

local function binaryPrefix(unit: string): Formatter
	return scaledUnits(1024, prefixed(BIN_PREFIXES, unit), 0)
end

local COUNT_EXTS = { "", "K", "M", "B", "T" }

local function countUnit(symbol: string): Formatter
	local scaler = scaledUnits(1000, COUNT_EXTS, 0)
	return function(value: number, decimals: number?): Formatted
		local f = scaler(value, decimals)
		f.suffix ..= " " .. symbol
		return f
	end
end

local function currency(symbol: string): Formatter
	local scaler = scaledUnits(1000, COUNT_EXTS, 0)
	return function(value: number, decimals: number?): Formatted
		local f = scaler(math.abs(value), decimals)
		f.prefix = if value < 0 then "-" .. symbol else symbol
		return f
	end
end

local PLURAL: { [string]: boolean } =
	{ [" min"] = true, [" hour"] = true, [" day"] = true, [" week"] = true, [" year"] = true }

local function fixedScaled(value: number, decimals: number?, ext: string): Formatted
	local suffix = if math.abs(value) > 1 and PLURAL[ext] then ext .. "s" else ext
	return result(M.toFixed(value, decimals), nil, suffix)
end

local function nanoseconds(size: number, decimals: number?): Formatted
	local a = math.abs(size)
	if a < 1000 then
		return result(M.toFixed(size, decimals), nil, " ns")
	elseif a < 1e6 then
		return fixedScaled(size / 1000, decimals, " µs")
	elseif a < 1e9 then
		return fixedScaled(size / 1e6, decimals, " ms")
	elseif a < 60e9 then
		return fixedScaled(size / 1e9, decimals, " s")
	elseif a < 3600e9 then
		return fixedScaled(size / 60e9, decimals, " min")
	elseif a < 86400e9 then
		return fixedScaled(size / 3600e9, decimals, " hour")
	end
	return fixedScaled(size / 86400e9, decimals, " day")
end

local function microseconds(size: number, decimals: number?): Formatted
	local a = math.abs(size)
	if a < 1000 then
		return result(M.toFixed(size, decimals), nil, " µs")
	elseif a < 1e6 then
		return fixedScaled(size / 1000, decimals, " ms")
	end
	return fixedScaled(size / 1e6, decimals, " s")
end

local function milliseconds(size: number, decimals: number?): Formatted
	local a = math.abs(size)
	if a < 1000 then
		return result(M.toFixed(size, decimals), nil, " ms")
	elseif a < 60000 then
		return fixedScaled(size / 1000, decimals, " s")
	elseif a < 3600000 then
		return fixedScaled(size / 60000, decimals, " min")
	elseif a < 86400000 then
		return fixedScaled(size / 3600000, decimals, " hour")
	elseif a < 31536000000 then
		return fixedScaled(size / 86400000, decimals, " day")
	end
	return fixedScaled(size / 31536000000, decimals, " year")
end

local function seconds(size: number, decimals: number?): Formatted
	if size == 0 then
		return result("0", nil, " s")
	end
	local a = math.abs(size)
	if a < 0.000001 then
		return fixedScaled(size * 1e9, decimals, " ns")
	elseif a < 0.001 then
		return fixedScaled(size * 1e6, decimals, " µs")
	elseif a < 1 then
		return fixedScaled(size * 1e3, decimals, " ms")
	elseif a < 60 then
		return result(M.toFixed(size, decimals), nil, " s")
	elseif a < 3600 then
		return fixedScaled(size / 60, decimals, " min")
	elseif a < 86400 then
		return fixedScaled(size / 3600, decimals, " hour")
	elseif a < 604800 then
		return fixedScaled(size / 86400, decimals, " day")
	elseif a < 31536000 then
		return fixedScaled(size / 604800, decimals, " week")
	end
	return fixedScaled(size / 3.15569e7, decimals, " year")
end

local function minutes(size: number, decimals: number?): Formatted
	local a = math.abs(size)
	if a < 60 then
		return result(M.toFixed(size, decimals), nil, " min")
	elseif a < 1440 then
		return fixedScaled(size / 60, decimals, " hour")
	elseif a < 10080 then
		return fixedScaled(size / 1440, decimals, " day")
	elseif a < 604800 then
		return fixedScaled(size / 10080, decimals, " week")
	end
	return fixedScaled(size / 5.25948e5, decimals, " year")
end

local function hours(size: number, decimals: number?): Formatted
	local a = math.abs(size)
	if a < 24 then
		return result(M.toFixed(size, decimals), nil, " hour")
	elseif a < 168 then
		return fixedScaled(size / 24, decimals, " day")
	elseif a < 8760 then
		return fixedScaled(size / 168, decimals, " week")
	end
	return fixedScaled(size / 8760, decimals, " year")
end

local function days(size: number, decimals: number?): Formatted
	local a = math.abs(size)
	if a < 7 then
		return fixedScaled(size, decimals, " day")
	elseif a < 365 then
		return fixedScaled(size / 7, decimals, " week")
	end
	return fixedScaled(size / 365, decimals, " year")
end

-- dateTimeFormatters.ts toDuration: largest unit first, then `decimals` more units.
local DURATION_UNITS: { { name: string, seconds: number } } = {
	{ name = "year", seconds = 31536000 },
	{ name = "month", seconds = 2592000 },
	{ name = "week", seconds = 604800 },
	{ name = "day", seconds = 86400 },
	{ name = "hour", seconds = 3600 },
	{ name = "minute", seconds = 60 },
	{ name = "second", seconds = 1 },
	{ name = "millisecond", seconds = 0.001 },
}

local function duration(size: number, decimals: number?, scaleSeconds: number, scaleName: string): Formatted
	if size == 0 then
		return result("0", nil, " " .. scaleName .. "s")
	elseif size < 0 then
		local f = duration(-size, decimals, scaleSeconds, scaleName)
		f.suffix ..= " ago"
		return f
	end
	local ms = size * scaleSeconds * 1000
	local parts: { string } = {}
	local started = false
	local remaining = decimals or 0
	for _, u in DURATION_UNITS do
		if remaining < 0 then
			break
		end
		local unitMs = u.seconds * 1000
		local v = ms / unitMs
		if v >= 1 or started then
			started = true
			local whole = math.floor(v)
			table.insert(parts, string.format("%d %s%s", whole, u.name, if whole ~= 1 then "s" else ""))
			ms = math.fmod(ms, unitMs)
			remaining -= 1
		end
	end
	return result(table.concat(parts, ", "))
end

local function pad2(n: number): string
	return if n > 9 then tostring(n) else "0" .. tostring(n)
end

local function hms(size: number): Formatted
	if size < 0 then
		local f = hms(-size)
		f.suffix ..= " ago"
		return f
	end
	local h = math.floor(size / 3600)
	local m = math.floor(math.fmod(size, 3600) / 60)
	local s = math.floor(math.fmod(math.fmod(size, 3600), 60))
	return result(pad2(h) .. ":" .. pad2(m) .. ":" .. pad2(s))
end

local function dhms(size: number): Formatted
	if size < 0 then
		local f = dhms(-size)
		f.suffix ..= " ago"
		return f
	end
	local d = math.floor(size / 86400)
	local head = if d > 0 then tostring(d) .. " d " else ""
	return result(head .. hms(size - d * 86400).text)
end

local function group(digits: string): string
	local head = #digits % 3
	local parts: { string } = {}
	if head > 0 then
		table.insert(parts, string.sub(digits, 1, head))
	end
	for i = head + 1, #digits, 3 do
		table.insert(parts, string.sub(digits, i, i + 2))
	end
	return table.concat(parts, ",")
end

-- Number.prototype.toLocaleString (en-US): grouped, at most `decimals` (default
-- 3) fraction digits, halves away from zero, trailing zeros dropped.
local function localeText(value: number, decimals: number?): Formatted
	local d = math.clamp(math.floor(decimals or 3), 0, 20)
	local digits = string.format("%.0f", jsRound(math.abs(value) * 10 ^ d))
	if #digits <= d then
		digits = string.rep("0", d - #digits + 1) .. digits
	end
	local int = string.sub(digits, 1, #digits - d)
	local frac = string.gsub(string.sub(digits, #digits - d + 1), "0+$", "")
	local text = group(int) .. (if frac ~= "" then "." .. frac else "")
	return result(if value < 0 then "-" .. text else text)
end

local FORMATS: { [string]: Formatter } = {
	none = fixedUnit("", false),
	short = scaledUnits(1000, { "", " K", " Mil", " Bil", " Tri", " Quadr", " Quint", " Sext", " Sept" }, 0),
	percent = function(v: number, d: number?): Formatted
		return result(M.toFixed(v, d), nil, "%")
	end,
	percentunit = function(v: number, d: number?): Formatted
		return result(M.toFixed(100 * v, d), nil, "%")
	end,
	locale = localeText,
	bytes = binaryPrefix("B"),
	decbytes = siPrefix("B"),
	bits = binaryPrefix("b"),
	decbits = siPrefix("b"),
	bps = siPrefix("b/s"),
	Bps = siPrefix("B/s"),
	binBps = binaryPrefix("B/s"),
	binbps = binaryPrefix("b/s"),
	ns = nanoseconds,
	["µs"] = microseconds,
	us = microseconds,
	ms = milliseconds,
	s = seconds,
	m = minutes,
	h = hours,
	d = days,
	dtdurationms = function(v: number, d: number?): Formatted
		return duration(v, d, 0.001, "millisecond")
	end,
	dtdurations = function(v: number, d: number?): Formatted
		return duration(v, d, 1, "second")
	end,
	dthms = function(v: number): Formatted
		return hms(v)
	end,
	dtdhms = function(v: number): Formatted
		return dhms(v)
	end,
	reqps = countUnit("req/s"),
	rps = countUnit("rd/s"),
	ops = countUnit("ops/s"),
	wps = countUnit("wr/s"),
	rpm = countUnit("rd/m"),
	hertz = siPrefix("Hz"),
	celsius = fixedUnit("°C", false),
	fahrenheit = fixedUnit("°F", false),
	farenheit = fixedUnit("°F", false),
	currencyUSD = currency("$"),
}

local custom: { [string]: Formatter } = {}

-- getValueFormat: known ids, then "prefix:"/"suffix:", else the id itself as a suffix.
local function formatter(unit: string?): Formatter
	if unit == nil or unit == "" then
		return FORMATS.none
	end
	local known = FORMATS[unit] or custom[unit]
	if known then
		return known
	end
	local key, sub = string.match(unit, "^([^:]+):(.*)$")
	local f = if key == "prefix" and sub
		then fixedUnit(sub, true)
		elseif key == "suffix" and sub then fixedUnit(sub, false)
		else fixedUnit(unit, false)
	custom[unit] = f
	return f
end

function M.format(value: number?, unit: string?, decimals: number?): Formatted
	if value == nil then
		return result("")
	elseif value ~= value then
		return result("NaN")
	elseif value == math.huge then
		return result("∞")
	elseif value == -math.huge then
		return result("-∞")
	end
	return formatter(unit)(value, decimals)
end

function M.join(f: Formatted): string
	return f.prefix .. f.text .. f.suffix
end

function M.text(value: number?, unit: string?, decimals: number?): string
	return M.join(M.format(value, unit, decimals))
end

return M
