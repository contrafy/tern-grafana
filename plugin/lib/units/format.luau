--!strict
-- Grafana value formatting by unit id. A port of grafana/grafana
-- packages/grafana-data/src/valueFormats (valueFormats.ts getValueFormat,
-- categories.ts, baseFormatters.ts toFixed/getDecimalsForValue/scaledUnits,
-- symbolFormatters.ts, arithmeticFormatters.ts, dateTimeFormatters.ts), so a
-- panel reads the same in Tern as in Grafana.
--
-- Every id of categories.ts is here except the Date & time category
-- (dateTimeAs*, dateTimeFromNow) and "time:" patterns: those need the
-- dashboard timezone and are formatted by lib/panels/fielddisplay.
--
-- Deliberate differences from Grafana:
-- - NaN, +Inf and -Inf render as "NaN", "∞" and "-∞" with no prefix or suffix
--   for every unit (Grafana is inconsistent per formatter, e.g. "∞ years").
-- - "us" is accepted as an alias of Grafana's "µs".
-- - "locale" and "currency:financial:" always group like en-US.

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
	if not string.find(s, "e", 1, true) then
		return s
	end
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

-- `offset` is the index of the first ext for values in 1 <= |v| < factor.
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

-- getOffsetFromSIPrefix: the NFKD form of the micro sign is the Greek mu.
local SI_OFFSETS: { [string]: number } = { ["μ"] = -2 }
for i, p in SI_PREFIXES do
	SI_OFFSETS[p] = i - 1 - SI_BASE_INDEX
end

local function prefixed(prefixes: { string }, unit: string): { string }
	local out = table.create(#prefixes)
	for i, p in prefixes do
		out[i] = " " .. p .. unit
	end
	return out
end

-- `offset` counts SI steps: SIPrefix("B", 3) reads values in GB.
local function siPrefix(unit: string, offset: number?): Formatter
	return scaledUnits(1000, prefixed(SI_PREFIXES, unit), SI_BASE_INDEX + (offset or 0))
end

-- `offset` counts IEC steps: binaryPrefix("B", 3) reads values in GiB.
local function binaryPrefix(unit: string, offset: number?): Formatter
	return scaledUnits(1024, prefixed(BIN_PREFIXES, unit), offset or 0)
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

local function currency(symbol: string, asSuffix: boolean?): Formatter
	local scaler = scaledUnits(1000, COUNT_EXTS, 0)
	return function(value: number, decimals: number?): Formatted
		local f = scaler(math.abs(value), decimals)
		if asSuffix then
			f.suffix ..= symbol
			f.prefix = if value < 0 then "-" else ""
		else
			f.prefix = if value < 0 then "-" .. symbol else symbol
		end
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
			table.insert(parts, jsString(whole) .. " " .. u.name .. (if whole ~= 1 then "s" else ""))
			ms = math.fmod(ms, unitMs)
			remaining -= 1
		end
	end
	if #parts == 0 then
		-- Under a millisecond: a fractional millisecond count that never rounds to 0.
		local text = M.toFixed(ms, decimals)
		if tonumber(text) == 0 then
			text = M.toFixed(ms)
		end
		table.insert(parts, text .. (if tonumber(text) == 1 then " millisecond" else " milliseconds"))
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

-- Intl.NumberFormat("en-US"): grouped, `minFrac` to `maxFrac` fraction
-- digits, halves away from zero.
local function grouped(value: number, minFrac: number, maxFrac: number): string
	local digits = string.format("%.0f", jsRound(math.abs(value) * 10 ^ maxFrac))
	if #digits <= maxFrac then
		digits = string.rep("0", maxFrac - #digits + 1) .. digits
	end
	local int = string.sub(digits, 1, #digits - maxFrac)
	local frac = string.sub(digits, #digits - maxFrac + 1)
	while #frac > minFrac and string.sub(frac, -1) == "0" do
		frac = string.sub(frac, 1, -2)
	end
	local text = group(int) .. (if frac ~= "" then "." .. frac else "")
	return if value < 0 then "-" .. text else text
end

-- Number.prototype.toLocaleString: at most `decimals` (default 3) fraction digits.
local function localeText(value: number, decimals: number?): Formatted
	return result(grouped(value, 0, math.clamp(math.floor(decimals or 3), 0, 20)))
end

-- symbolFormatters.ts fullCurrency: unscaled, one fraction digit at most by
-- default, exactly `decimals` when set.
local function fullCurrency(symbol: string, asSuffix: boolean): Formatter
	return function(value: number, decimals: number?): Formatted
		local d = if decimals == nil then nil else math.clamp(math.floor(decimals), 0, 20)
		local text = if d == nil then grouped(value, 0, 1) else grouped(value, d, d)
		return if asSuffix then result(text, nil, symbol) else result(text, symbol)
	end
end

local HEX_DIGITS = "0123456789ABCDEF"

-- Number.prototype.toString(16), upper-cased: V8's DoubleToRadixCString,
-- fraction digits only up to the double's precision.
local function hexString(value: number): string
	local v = math.abs(value)
	local integer = math.floor(v)
	local fraction = v - integer
	local _, e = math.frexp(v)
	local delta = math.max(0.5 * 2 ^ (e - 53), 2 ^ -1074)
	local frac: { number } = {}
	if fraction >= delta then
		repeat
			fraction *= 16
			delta *= 16
			local digit = math.floor(fraction)
			table.insert(frac, digit)
			fraction -= digit
			if (fraction > 0.5 or (fraction == 0.5 and digit % 2 == 1)) and fraction + delta > 1 then
				while true do
					local last = table.remove(frac)
					if last == nil then
						integer += 1
						break
					elseif last + 1 < 16 then
						table.insert(frac, last + 1)
						break
					end
				end
				break
			end
		until fraction < delta
	end
	local zeros = 0
	while integer / 16 >= 2 ^ 53 do
		integer /= 16
		zeros += 1
	end
	local int: { string } = {}
	repeat
		local r = math.fmod(integer, 16)
		table.insert(int, 1, string.sub(HEX_DIGITS, r + 1, r + 1))
		integer = (integer - r) / 16
	until integer <= 0
	local out = table.concat(int) .. string.rep("0", zeros)
	if #frac > 0 then
		local digits = table.create(#frac)
		for i, d in frac do
			digits[i] = string.sub(HEX_DIGITS, d + 1, d + 1)
		end
		out ..= "." .. table.concat(digits)
	end
	return if value < 0 then "-" .. out else out
end

-- arithmeticFormatters.ts toHex: the value rounded by toFixed, in base 16.
local function hex(value: number, decimals: number?): Formatted
	return result(hexString(tonumber(M.toFixed(value, decimals)) :: number))
end

local function hex0x(value: number, decimals: number?): Formatted
	local text = hex(value, decimals).text
	return result(if string.sub(text, 1, 1) == "-" then "-0x" .. string.sub(text, 2) else "0x" .. text)
end

-- `a` (>= 0) with `d` fraction digits in exponent form. C rounds an exact
-- tie to even; toExponential picks the larger candidate (2.5 -> "3e+0").
local function exponential(a: number, d: number): string
	local full = string.format("%.99e", a)
	local digits = string.gsub(string.match(full, "^([%d%.]+)e") :: string, "%.", "")
	if string.sub(digits, d + 2, d + 2) ~= "5" or not string.find(string.sub(digits, d + 3), "^0*$") then
		return string.format("%." .. d .. "e", a)
	end
	local exp = tonumber(string.match(full, "e([%+%-]%d+)$")) :: number
	local kept = string.sub(digits, 1, d + 1)
	local i = #kept
	while i >= 1 and string.sub(kept, i, i) == "9" do
		i -= 1
	end
	if i == 0 then
		kept = "1" .. string.rep("0", d)
		exp += 1
	else
		local up = tostring((tonumber(string.sub(kept, i, i)) :: number) + 1)
		kept = string.sub(kept, 1, i - 1) .. up .. string.rep("0", #kept - i)
	end
	local mantissa = string.sub(kept, 1, 1) .. (if d > 0 then "." .. string.sub(kept, 2) else "")
	return mantissa .. "e" .. (if exp < 0 then "-" else "+") .. tostring(math.abs(exp))
end

-- Number.prototype.toExponential: the shortest round-trip mantissa without
-- decimals, an unpadded exponent ("1.5e+3").
local function sci(value: number, decimals: number?): Formatted
	local s = ""
	if decimals == nil then
		for k = 0, 16 do
			s = string.format("%." .. k .. "e", value)
			if tonumber(s) == value then
				break
			end
		end
	else
		s = exponential(math.abs(value), math.clamp(math.floor(decimals), 0, 99))
		if value < 0 then
			s = "-" .. s
		end
	end
	local mantissa, sign, digits = string.match(s, "^(.-)e([%+%-])0*(%d+)$")
	return result(if mantissa and sign and digits then mantissa .. "e" .. sign .. digits else s)
end

-- English ordinal plural rules on the rounded value; decimals are ignored.
local function ordinal(value: number): Formatted
	local n = jsRound(value)
	local a = math.abs(n)
	local suffix = "th"
	if a % 10 == 1 and a % 100 ~= 11 then
		suffix = "st"
	elseif a % 10 == 2 and a % 100 ~= 12 then
		suffix = "nd"
	elseif a % 10 == 3 and a % 100 ~= 13 then
		suffix = "rd"
	end
	return result(jsString(n), nil, suffix)
end

local function boolUnit(t: string, f: string): Formatter
	return function(value: number): Formatted
		return result(if value ~= 0 then t else f)
	end
end

-- dateTimeFormatters.ts toClock: a UTC clock reading of `size` ms; decimals
-- 0, 1 and 2 drop the smaller parts. Past the JavaScript Date range the
-- reading is moment's "Invalid date".
local function clock(size: number, decimals: number?): Formatted
	local t = if size < 0 then math.ceil(size) else math.floor(size)
	local valid = math.abs(t) <= 8.64e15
	local ms = if valid then string.format("%03d", t % 1000) .. "ms" else ""
	local s = if valid then pad2(math.floor(t / 1000) % 60) .. "s" else ""
	local m = if valid then pad2(math.floor(t / 60000) % 60) .. "m" else ""
	local function reading(text: string): string
		return if valid then text else "Invalid date"
	end
	if size < 1000 then
		return result(reading(ms))
	elseif size < 60000 then
		return result(reading(if decimals == 0 then s else s .. ":" .. ms))
	elseif size < 3600000 then
		return result(
			reading(if decimals == 0 then m elseif decimals == 1 then m .. ":" .. s else m .. ":" .. s .. ":" .. ms)
		)
	end
	local h = jsString(math.floor(size / 3600000)) .. "h"
	if decimals == 0 then
		return result(h)
	end
	local rest = if decimals == 1 then m elseif decimals == 2 then m .. ":" .. s else m .. ":" .. s .. ":" .. ms
	return result(h .. ":" .. reading(rest))
end

-- categories.ts, category by category (Date & time is fielddisplay's).
local FORMATS: { [string]: Formatter } = {
	-- Misc
	none = fixedUnit("", false),
	string = function(v: number): Formatted
		return result(jsString(v))
	end,
	short = scaledUnits(1000, { "", " K", " Mil", " Bil", " Tri", " Quadr", " Quint", " Sext", " Sept" }, 0),
	sishort = siPrefix(""),
	percent = function(v: number, d: number?): Formatted
		return result(M.toFixed(v, d), nil, "%")
	end,
	percentunit = function(v: number, d: number?): Formatted
		return result(M.toFixed(100 * v, d), nil, "%")
	end,
	humidity = fixedUnit("%H", false),
	dB = fixedUnit("dB", false),
	candela = siPrefix("cd"),
	hex0x = hex0x,
	hex = hex,
	sci = sci,
	locale = localeText,
	ordinal = ordinal,
	pixel = fixedUnit("px", false),
	-- Acceleration
	accMS2 = fixedUnit("m/sec²", false),
	accFS2 = fixedUnit("f/sec²", false),
	accG = fixedUnit("g", false),
	-- Angle
	degree = fixedUnit("°", false),
	radian = fixedUnit("rad", false),
	grad = fixedUnit("grad", false),
	arcmin = fixedUnit("arcmin", false),
	arcsec = fixedUnit("arcsec", false),
	-- Area
	areaM2 = fixedUnit("m²", false),
	areaF2 = fixedUnit("ft²", false),
	areaMI2 = fixedUnit("mi²", false),
	acres = fixedUnit("ac", false),
	hectares = fixedUnit("ha", false),
	-- Computation
	flops = siPrefix("FLOPS"),
	mflops = siPrefix("FLOPS", 2),
	gflops = siPrefix("FLOPS", 3),
	tflops = siPrefix("FLOPS", 4),
	pflops = siPrefix("FLOPS", 5),
	eflops = siPrefix("FLOPS", 6),
	zflops = siPrefix("FLOPS", 7),
	yflops = siPrefix("FLOPS", 8),
	-- Concentration
	ppm = fixedUnit("ppm", false),
	conppb = fixedUnit("ppb", false),
	conngm3 = fixedUnit("ng/m³", false),
	conngNm3 = fixedUnit("ng/Nm³", false),
	["conμgm3"] = fixedUnit("μg/m³", false),
	["conμgNm3"] = fixedUnit("μg/Nm³", false),
	conmgm3 = fixedUnit("mg/m³", false),
	conmgNm3 = fixedUnit("mg/Nm³", false),
	congm3 = fixedUnit("g/m³", false),
	congNm3 = fixedUnit("g/Nm³", false),
	conmgdL = fixedUnit("mg/dL", false),
	conmmolL = fixedUnit("mmol/L", false),
	-- Currency
	currencyUSD = currency("$"),
	currencyGBP = currency("£"),
	currencyEUR = currency("€"),
	currencyJPY = currency("¥"),
	currencyRUB = currency("₽"),
	currencyUAH = currency("₴"),
	currencyBRL = currency("R$"),
	currencyDKK = currency("kr", true),
	currencyISK = currency("kr", true),
	currencyNOK = currency("kr", true),
	currencySEK = currency("kr", true),
	currencyCZK = currency("czk"),
	currencyCHF = currency("CHF"),
	currencyPLN = currency("PLN"),
	currencyBTC = currency("฿"),
	currencymBTC = currency("mBTC"),
	["currencyμBTC"] = currency("μBTC"),
	currencyZAR = currency("R"),
	currencyINR = currency("₹"),
	currencyKRW = currency("₩"),
	currencyIDR = currency("Rp"),
	currencyPHP = currency("PHP"),
	currencyVND = currency("đ", true),
	currencyTRY = currency("₺", true),
	currencyMYR = currency("RM"),
	currencyXPF = currency("XPF"),
	currencyBGN = currency("BGN"),
	currencyPYG = currency("₲"),
	currencyUYU = currency("UYU"),
	currencyILS = currency("₪"),
	-- Data
	bytes = binaryPrefix("B"),
	decbytes = siPrefix("B"),
	bits = binaryPrefix("b"),
	decbits = siPrefix("b"),
	kbytes = binaryPrefix("B", 1),
	deckbytes = siPrefix("B", 1),
	mbytes = binaryPrefix("B", 2),
	decmbytes = siPrefix("B", 2),
	gbytes = binaryPrefix("B", 3),
	decgbytes = siPrefix("B", 3),
	tbytes = binaryPrefix("B", 4),
	dectbytes = siPrefix("B", 4),
	pbytes = binaryPrefix("B", 5),
	decpbytes = siPrefix("B", 5),
	-- Data rate
	pps = siPrefix("p/s"),
	binBps = binaryPrefix("B/s"),
	Bps = siPrefix("B/s"),
	binbps = binaryPrefix("b/s"),
	bps = siPrefix("b/s"),
	KiBs = binaryPrefix("B/s", 1),
	Kibits = binaryPrefix("b/s", 1),
	KBs = siPrefix("B/s", 1),
	Kbits = siPrefix("b/s", 1),
	MiBs = binaryPrefix("B/s", 2),
	Mibits = binaryPrefix("b/s", 2),
	MBs = siPrefix("B/s", 2),
	Mbits = siPrefix("b/s", 2),
	GiBs = binaryPrefix("B/s", 3),
	Gibits = binaryPrefix("b/s", 3),
	GBs = siPrefix("B/s", 3),
	Gbits = siPrefix("b/s", 3),
	TiBs = binaryPrefix("B/s", 4),
	Tibits = binaryPrefix("b/s", 4),
	TBs = siPrefix("B/s", 4),
	Tbits = siPrefix("b/s", 4),
	PiBs = binaryPrefix("B/s", 5),
	Pibits = binaryPrefix("b/s", 5),
	PBs = siPrefix("B/s", 5),
	Pbits = siPrefix("b/s", 5),
	-- Energy
	watt = siPrefix("W"),
	kwatt = siPrefix("W", 1),
	megwatt = siPrefix("W", 2),
	gwatt = siPrefix("W", 3),
	mwatt = siPrefix("W", -1),
	Wm2 = siPrefix("W/m²"),
	voltamp = siPrefix("VA"),
	kvoltamp = siPrefix("VA", 1),
	voltampreact = siPrefix("VAr"),
	kvoltampreact = siPrefix("VAr", 1),
	watth = siPrefix("Wh"),
	watthperkg = siPrefix("Wh/kg"),
	kwatth = siPrefix("Wh", 1),
	kwattm = siPrefix("W-Min", 1),
	mwatth = siPrefix("Wh", 2),
	amph = siPrefix("Ah"),
	kamph = siPrefix("Ah", 1),
	mamph = siPrefix("Ah", -1),
	joule = siPrefix("J"),
	ev = siPrefix("eV"),
	amp = siPrefix("A"),
	kamp = siPrefix("A", 1),
	mamp = siPrefix("A", -1),
	volt = siPrefix("V"),
	kvolt = siPrefix("V", 1),
	mvolt = siPrefix("V", -1),
	dBm = fixedUnit("dbm", false),
	mohm = siPrefix("Ω", -1),
	ohm = siPrefix("Ω"),
	kohm = siPrefix("Ω", 1),
	Mohm = siPrefix("Ω", 2),
	farad = siPrefix("F"),
	["µfarad"] = siPrefix("F", -2),
	nfarad = siPrefix("F", -3),
	pfarad = siPrefix("F", -4),
	ffarad = siPrefix("F", -5),
	henry = siPrefix("H"),
	mhenry = siPrefix("H", -1),
	["µhenry"] = siPrefix("H", -2),
	lumens = siPrefix("Lm"),
	-- Flow
	flowgpm = fixedUnit("gpm", false),
	flowcms = fixedUnit("cms", false),
	flowcfs = fixedUnit("cfs", false),
	flowcfm = fixedUnit("cfm", false),
	litreh = fixedUnit("L/h", false),
	flowlpm = fixedUnit("L/min", false),
	flowmlpm = fixedUnit("mL/min", false),
	lux = fixedUnit("lux", false),
	-- Force
	forceNm = siPrefix("Nm"),
	forcekNm = siPrefix("Nm", 1),
	forceN = siPrefix("N"),
	forcekN = siPrefix("N", 1),
	-- Hash rate
	Hs = siPrefix("H/s"),
	KHs = siPrefix("H/s", 1),
	MHs = siPrefix("H/s", 2),
	GHs = siPrefix("H/s", 3),
	THs = siPrefix("H/s", 4),
	PHs = siPrefix("H/s", 5),
	EHs = siPrefix("H/s", 6),
	-- Mass
	massmg = siPrefix("g", -1),
	massg = siPrefix("g"),
	masslb = fixedUnit("lb", false),
	masskg = siPrefix("g", 1),
	masst = fixedUnit("t", false),
	-- Length
	lengthmm = siPrefix("m", -1),
	lengthcm = fixedUnit("cm", false),
	lengthin = fixedUnit("in", false),
	lengthft = fixedUnit("ft", false),
	lengthm = siPrefix("m"),
	lengthkm = siPrefix("m", 1),
	lengthmi = fixedUnit("mi", false),
	-- Pressure
	pressurembar = siPrefix("bar", -1),
	pressurebar = siPrefix("bar"),
	pressurekbar = siPrefix("bar", 1),
	pressurepa = siPrefix("Pa"),
	pressurehpa = fixedUnit("hPa", false),
	pressurekpa = fixedUnit("kPa", false),
	pressurehg = fixedUnit('"Hg', false),
	pressurepsi = scaledUnits(1000, { "psi", "ksi", "Mpsi" }, 0),
	-- Radiation
	radbq = siPrefix("Bq"),
	radci = siPrefix("Ci"),
	radgy = siPrefix("Gy"),
	radrad = siPrefix("rad"),
	radsv = siPrefix("Sv"),
	radmsv = siPrefix("Sv", -1),
	radusv = siPrefix("Sv", -2),
	radrem = siPrefix("rem"),
	radexpckg = siPrefix("C/kg"),
	radr = siPrefix("R"),
	radsvh = siPrefix("Sv/h"),
	radmsvh = siPrefix("Sv/h", -1),
	radusvh = siPrefix("Sv/h", -2),
	-- Rotational Speed
	rotrpm = fixedUnit("rpm", false),
	rothz = siPrefix("Hz"),
	rotkhz = siPrefix("Hz", 1),
	rotmhz = siPrefix("Hz", 2),
	rotghz = siPrefix("Hz", 3),
	rotrads = fixedUnit("rad/s", false),
	rotdegs = fixedUnit("°/s", false),
	-- Temperature
	celsius = fixedUnit("°C", false),
	fahrenheit = fixedUnit("°F", false),
	farenheit = fixedUnit("°F", false),
	kelvin = fixedUnit("K", false),
	-- Time
	hertz = siPrefix("Hz"),
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
	timeticks = function(v: number, d: number?): Formatted
		return seconds(v / 100, d)
	end,
	clockms = clock,
	clocks = function(v: number, d: number?): Formatted
		return clock(v * 1000, d)
	end,
	-- Throughput
	cps = countUnit("c/s"),
	ops = countUnit("ops/s"),
	reqps = countUnit("req/s"),
	rps = countUnit("rd/s"),
	wps = countUnit("wr/s"),
	iops = countUnit("io/s"),
	eps = countUnit("evt/s"),
	mps = countUnit("msg/s"),
	recps = countUnit("rec/s"),
	rowsps = countUnit("rows/s"),
	cpm = countUnit("c/m"),
	opm = countUnit("ops/m"),
	reqpm = countUnit("req/m"),
	rpm = countUnit("rd/m"),
	wpm = countUnit("wr/m"),
	epm = countUnit("evts/m"),
	mpm = countUnit("msgs/m"),
	recpm = countUnit("rec/m"),
	rowspm = countUnit("rows/m"),
	-- Velocity
	velocityms = fixedUnit("m/s", false),
	velocitykmh = fixedUnit("km/h", false),
	velocitymph = fixedUnit("mph", false),
	velocityknot = fixedUnit("kn", false),
	-- Volume
	mlitre = siPrefix("L", -1),
	litre = siPrefix("L"),
	m3 = fixedUnit("m³", false),
	Nm3 = fixedUnit("Nm³", false),
	dm3 = fixedUnit("dm³", false),
	gallons = fixedUnit("gal", false),
	-- Boolean
	bool = boolUnit("True", "False"),
	bool_yes_no = boolUnit("Yes", "No"),
	bool_on_off = boolUnit("On", "Off"),
}

-- getValueFormat: known ids, then the "prefix:", "suffix:", "si:", "count:",
-- "currency:" and "bool:" families, else the id itself as a suffix.
local function parametric(unit: string): Formatter
	local key, sub = string.match(unit, "^([^:]+):(.*)$")
	if key == nil or sub == nil then
		return fixedUnit(unit, false)
	elseif key == "prefix" then
		return fixedUnit(sub, true)
	elseif key == "suffix" then
		return fixedUnit(sub, false)
	elseif key == "si" then
		local first = string.match(sub, "^" .. utf8.charpattern) or ""
		local offset = SI_OFFSETS[first] or 0
		return siPrefix(if offset == 0 then sub else string.sub(sub, #first + 1), offset)
	elseif key == "count" then
		return countUnit(sub)
	elseif key == "currency" then
		local parts = string.split(sub, ":")
		if parts[1] == "financial" and #parts >= 2 then
			return if parts[2] == "" then FORMATS.none else fullCurrency(parts[2], parts[3] == "suffix")
		end
		return currency(sub)
	elseif key == "bool" then
		local slash = string.find(sub, "/", 1, true)
		if slash then
			return boolUnit(string.sub(sub, 1, slash - 1), string.sub(sub, slash + 1))
		end
		return boolUnit(sub, "-")
	end
	return fixedUnit(unit, false)
end

local custom: { [string]: Formatter } = {}

local function formatter(unit: string?): Formatter
	if unit == nil or unit == "" then
		return FORMATS.none
	end
	local known = FORMATS[unit] or custom[unit]
	if known then
		return known
	end
	local f = parametric(unit)
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
