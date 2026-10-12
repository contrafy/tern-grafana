--!strict
-- The grafana-clock-panel plugin, version 2.1.8 (github.com/grafana/clock-panel
-- at v2.1.8: src/ClockPanel.tsx, src/components/CalculateClockOptions.ts,
-- RenderTime.tsx, RenderDate.tsx, RenderZone.tsx, RenderDescription.tsx,
-- src/options.ts for the defaults, src/migrations.ts, src/utils.ts), drawn
-- natively and redrawn every second (liveMs) without re-querying.
--
-- Modes: time (moment format "HH:mm:ss", "h:mm:ss A" or timeSettings.
-- customFormat), countdown and countup (from an input time or a query field
-- reduced by queryCalculation). The countdown text is the panel's own
-- "2 years, 5 months, 16 days, 4 hours, 15 minutes, 10 seconds" built from
-- moment.duration (whole-millisecond durations: months are 146097/4800 days,
-- so it does not follow calendar months), customFormat "auto" or a template
-- goes through moment-duration-format 2.x (src/external in the plugin). Date
-- and time formats are moment's en tokens; dateSettings.locale is ignored
-- (always en).
--
-- Timezones follow moment-timezone: "" is the viewer's zone, "dashboard"
-- the dashboard's, a name unknown to moment ("browser") stays in local time.
-- UTC/GMT aliases and Etc/GMT+-N are exact; a table of common IANA zones
-- carries their current standard offset and DST rule (US, EU, Israel,
-- southern Australia, New Zealand). Any other IANA name uses the dashboard
-- offset when it is the dashboard's timezone, else the local offset.
--
-- Known differences from the browser: an input time with an explicit offset
-- is re-read as local wall time with the viewer's offset at now (moment uses
-- the offset at that instant); the viewer's zone name is not known to the
-- plugin, so zoneFormat "name" shows "Local" and its abbreviation is empty
-- for timezone "".

local Env = require("../env")
local Frame = require("../frame/types")
local Thresholds = require("../units/thresholds")
local Common = require("./common")
local Json = require("./json")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node

local M = {}

M.types = { "grafana-clock-panel" }

local SECOND = 1000
local MINUTE = 60 * SECOND
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR

------------------------------------------------------------------------------
-- Civil calendar (Howard Hinnant's days_from_civil / civil_from_days).

local function daysFromCivil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = y // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z: number): (number, number, number)
	z += 719468
	local era = z // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return if m <= 2 then y + 1 else y, m, d
end

local function isLeap(y: number): boolean
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function daysInMonth(y: number, m: number): number
	if m == 2 then
		return if isLeap(y) then 29 else 28
	end
	return if m == 4 or m == 6 or m == 9 or m == 11 then 30 else 31
end

-- 0 = Sunday (1970-01-01 was a Thursday).
local function weekday(days: number): number
	return (days + 4) % 7
end

local function nthSunday(y: number, m: number, n: number): number
	local first = daysFromCivil(y, m, 1)
	return first + (7 - weekday(first)) % 7 + 7 * (n - 1)
end

local function lastSunday(y: number, m: number): number
	local last = daysFromCivil(y, m, daysInMonth(y, m))
	return last - weekday(last)
end

------------------------------------------------------------------------------
-- Timezones.

export type Zone = {
	-- What zoneFormat "name" shows (moment-timezone's zone name, or the raw
	-- timezone string when moment has no such zone).
	name: string,
	-- Standard offset, minutes east of UTC.
	std: number,
	rule: string?,
	abbr: string,
	dst_abbr: string?,
	-- Offset not from tz rules: the dashboard's or the viewer's.
	approx: boolean?,
}

-- Current rules: names (first is canonical-cased, the rest links), standard
-- offset, DST rule, abbreviations as moment-timezone prints them.
local ZONE_LIST: { { any } } = {
	{ "UTC Etc/UTC UCT Etc/UCT Universal Etc/Universal Zulu Etc/Zulu", 0, nil, "UTC" },
	{ "GMT Etc/GMT GMT0 Etc/GMT0 GMT+0 Etc/GMT+0 GMT-0 Etc/GMT-0 Greenwich Etc/Greenwich", 0, nil, "GMT" },
	{
		"America/New_York US/Eastern EST5EDT America/Detroit America/Toronto America/Montreal America/Nassau "
			.. "America/Indiana/Indianapolis America/Indianapolis America/Kentucky/Louisville America/Louisville "
			.. "Canada/Eastern US/Michigan",
		-300,
		"us",
		"EST",
		"EDT",
	},
	{
		"America/Chicago US/Central CST6CDT America/Winnipeg Canada/Central America/Indiana/Knox America/Menominee "
			.. "America/Matamoros",
		-360,
		"us",
		"CST",
		"CDT",
	},
	{
		"America/Denver US/Mountain MST7MDT America/Edmonton America/Boise Canada/Mountain America/Ciudad_Juarez",
		-420,
		"us",
		"MST",
		"MDT",
	},
	{ "America/Phoenix US/Arizona MST America/Creston", -420, nil, "MST" },
	{
		"America/Los_Angeles US/Pacific PST8PDT America/Vancouver America/Tijuana Canada/Pacific",
		-480,
		"us",
		"PST",
		"PDT",
	},
	{ "America/Anchorage US/Alaska America/Juneau America/Sitka America/Nome", -540, "us", "AKST", "AKDT" },
	{ "Pacific/Honolulu US/Hawaii HST", -600, nil, "HST" },
	{ "Pacific/Pago_Pago US/Samoa Pacific/Midway", -660, nil, "SST" },
	{ "America/Halifax Canada/Atlantic Atlantic/Bermuda America/Glace_Bay America/Moncton", -240, "us", "AST", "ADT" },
	{ "America/St_Johns Canada/Newfoundland", -210, "us", "NST", "NDT" },
	{
		"America/Regina Canada/Saskatchewan America/Mexico_City Mexico/General America/Monterrey America/Merida "
			.. "America/Guatemala America/Costa_Rica America/El_Salvador America/Tegucigalpa America/Managua "
			.. "America/Belize",
		-360,
		nil,
		"CST",
	},
	{ "America/Panama America/Jamaica America/Cancun America/Cayman EST", -300, nil, "EST" },
	{ "America/Puerto_Rico America/Santo_Domingo America/Barbados America/Martinique", -240, nil, "AST" },
	{ "America/Bogota America/Lima America/Guayaquil", -300, nil, "-05" },
	{ "America/Caracas America/La_Paz America/Manaus", -240, nil, "-04" },
	{
		"America/Sao_Paulo Brazil/East America/Argentina/Buenos_Aires America/Buenos_Aires America/Montevideo "
			.. "America/Cayenne America/Fortaleza America/Recife America/Bahia",
		-180,
		nil,
		"-03",
	},
	{ "America/Noronha", -120, nil, "-02" },
	{ "America/Nuuk America/Godthab", -120, "eu", "-02", "-01" },
	{ "Atlantic/Cape_Verde", -60, nil, "-01" },
	{ "Atlantic/Azores", -60, "eu", "-01", "+00" },
	{
		"Europe/London GB Europe/Belfast Europe/Guernsey Europe/Isle_of_Man Europe/Jersey",
		0,
		"eu",
		"GMT",
		"BST",
	},
	{ "Europe/Dublin Eire", 0, "eu", "GMT", "IST" },
	{
		"Europe/Lisbon Portugal Atlantic/Madeira Atlantic/Canary Atlantic/Faroe Atlantic/Faeroe WET",
		0,
		"eu",
		"WET",
		"WEST",
	},
	{
		"Africa/Abidjan Africa/Accra Africa/Dakar Africa/Bamako Africa/Monrovia Atlantic/Reykjavik Iceland",
		0,
		nil,
		"GMT",
	},
	{
		"Europe/Paris Europe/Berlin Europe/Madrid Europe/Rome Europe/Amsterdam Europe/Brussels Europe/Vienna "
			.. "Europe/Zurich Europe/Stockholm Europe/Oslo Europe/Copenhagen Europe/Prague Europe/Warsaw Poland "
			.. "Europe/Budapest Europe/Belgrade Europe/Zagreb Europe/Ljubljana Europe/Bratislava Europe/Sarajevo "
			.. "Europe/Skopje Europe/Podgorica Europe/Tirane Europe/Luxembourg Europe/Monaco Europe/Malta "
			.. "Europe/Andorra Europe/Gibraltar Europe/Vaduz Europe/San_Marino Europe/Vatican Europe/Busingen "
			.. "Arctic/Longyearbyen Africa/Ceuta CET",
		60,
		"eu",
		"CET",
		"CEST",
	},
	{ "Africa/Algiers Africa/Tunis", 60, nil, "CET" },
	{ "Africa/Lagos Africa/Kinshasa Africa/Luanda Africa/Douala Africa/Niamey", 60, nil, "WAT" },
	{
		"Europe/Athens Europe/Helsinki Europe/Kyiv Europe/Kiev Europe/Bucharest Europe/Sofia Europe/Riga "
			.. "Europe/Tallinn Europe/Vilnius Europe/Mariehamn Europe/Uzhgorod Europe/Zaporozhye Asia/Nicosia "
			.. "Europe/Nicosia Asia/Famagusta EET",
		120,
		"eu",
		"EET",
		"EEST",
	},
	{ "Africa/Johannesburg Africa/Maseru Africa/Mbabane", 120, nil, "SAST" },
	{
		"Africa/Maputo Africa/Harare Africa/Lusaka Africa/Kigali Africa/Blantyre Africa/Gaborone",
		120,
		nil,
		"CAT",
	},
	{ "Asia/Jerusalem Asia/Tel_Aviv Israel", 120, "il", "IST", "IDT" },
	{ "Europe/Moscow W-SU Europe/Simferopol Europe/Kirov Europe/Volgograd", 180, nil, "MSK" },
	{
		"Europe/Istanbul Turkey Asia/Istanbul Europe/Minsk Asia/Riyadh Asia/Kuwait Asia/Baghdad Asia/Qatar "
			.. "Asia/Bahrain Asia/Aden",
		180,
		nil,
		"+03",
	},
	{ "Africa/Nairobi Africa/Addis_Ababa Africa/Dar_es_Salaam Africa/Kampala Africa/Mogadishu", 180, nil, "EAT" },
	{ "Asia/Tehran Iran", 210, nil, "+0330" },
	{ "Asia/Dubai Asia/Muscat Asia/Baku Asia/Tbilisi Asia/Yerevan Europe/Samara", 240, nil, "+04" },
	{ "Asia/Kabul", 270, nil, "+0430" },
	{ "Asia/Karachi", 300, nil, "PKT" },
	{
		"Asia/Tashkent Asia/Samarkand Asia/Yekaterinburg Asia/Dushanbe Asia/Ashgabat Indian/Maldives Asia/Almaty "
			.. "Asia/Qyzylorda Asia/Aqtobe",
		300,
		nil,
		"+05",
	},
	{ "Asia/Kolkata Asia/Calcutta", 330, nil, "IST" },
	{ "Asia/Colombo", 330, nil, "+0530" },
	{ "Asia/Kathmandu Asia/Katmandu", 345, nil, "+0545" },
	{ "Asia/Dhaka Asia/Dacca Asia/Thimphu Asia/Bishkek Asia/Omsk", 360, nil, "+06" },
	{ "Asia/Yangon Asia/Rangoon", 390, nil, "+0630" },
	{
		"Asia/Bangkok Asia/Ho_Chi_Minh Asia/Saigon Asia/Phnom_Penh Asia/Vientiane Asia/Novosibirsk "
			.. "Asia/Krasnoyarsk",
		420,
		nil,
		"+07",
	},
	{ "Asia/Jakarta Asia/Pontianak", 420, nil, "WIB" },
	{ "Asia/Shanghai PRC Asia/Chongqing Asia/Harbin Asia/Taipei ROC Asia/Macau", 480, nil, "CST" },
	{ "Asia/Hong_Kong Hongkong", 480, nil, "HKT" },
	{ "Asia/Singapore Singapore Asia/Kuala_Lumpur Asia/Brunei Asia/Irkutsk Asia/Ulaanbaatar", 480, nil, "+08" },
	{ "Asia/Manila", 480, nil, "PST" },
	{ "Asia/Makassar", 480, nil, "WITA" },
	{ "Australia/Perth Australia/West", 480, nil, "AWST" },
	{ "Asia/Tokyo Japan", 540, nil, "JST" },
	{ "Asia/Seoul ROK", 540, nil, "KST" },
	{ "Asia/Jayapura", 540, nil, "WIT" },
	{ "Asia/Yakutsk Asia/Chita Pacific/Palau", 540, nil, "+09" },
	{ "Australia/Darwin Australia/North", 570, nil, "ACST" },
	{ "Australia/Adelaide Australia/South Australia/Broken_Hill", 570, "au", "ACST", "ACDT" },
	{ "Australia/Brisbane Australia/Queensland Australia/Lindeman", 600, nil, "AEST" },
	{
		"Australia/Sydney Australia/Melbourne Australia/Hobart Australia/Canberra Australia/ACT Australia/NSW "
			.. "Australia/Victoria Australia/Tasmania",
		600,
		"au",
		"AEST",
		"AEDT",
	},
	{ "Pacific/Guam Pacific/Saipan", 600, nil, "ChST" },
	{ "Asia/Vladivostok Pacific/Port_Moresby", 600, nil, "+10" },
	{ "Asia/Magadan Asia/Sakhalin Pacific/Guadalcanal Pacific/Noumea", 660, nil, "+11" },
	{ "Pacific/Auckland NZ Antarctica/McMurdo Antarctica/South_Pole", 720, "nz", "NZST", "NZDT" },
	{ "Pacific/Fiji Asia/Kamchatka Pacific/Tarawa Pacific/Majuro", 720, nil, "+12" },
	{ "Pacific/Tongatapu Pacific/Apia", 780, nil, "+13" },
	{ "Pacific/Kiritimati", 840, nil, "+14" },
}

local ZONES: { [string]: Zone } = {}
for _, row in ZONE_LIST do
	for name in string.gmatch(row[1] :: string, "%S+") do
		ZONES[string.lower(name)] = {
			name = name,
			std = row[2] :: number,
			rule = row[3] :: string?,
			abbr = row[4] :: string,
			dst_abbr = row[5] :: string?,
		}
	end
end

-- Whether a rule's DST is in effect at `ms` (epoch ms).
local function dstActive(rule: string, std: number, ms: number): boolean
	local y = civilFromDays((ms + std * MINUTE) // DAY)
	local stdShift = std * MINUTE
	local dstShift = (std + 60) * MINUTE
	if rule == "us" then
		local start = nthSunday(y, 3, 2) * DAY + 2 * HOUR - stdShift
		local stop = nthSunday(y, 11, 1) * DAY + 2 * HOUR - dstShift
		return ms >= start and ms < stop
	elseif rule == "eu" then
		return ms >= lastSunday(y, 3) * DAY + HOUR and ms < lastSunday(y, 10) * DAY + HOUR
	elseif rule == "il" then
		local start = (lastSunday(y, 3) - 2) * DAY + 2 * HOUR - stdShift
		local stop = lastSunday(y, 10) * DAY + 2 * HOUR - dstShift
		return ms >= start and ms < stop
	elseif rule == "au" then
		local stop = nthSunday(y, 4, 1) * DAY + 3 * HOUR - dstShift
		local start = nthSunday(y, 10, 1) * DAY + 2 * HOUR - stdShift
		return ms < stop or ms >= start
	elseif rule == "nz" then
		local stop = nthSunday(y, 4, 1) * DAY + 3 * HOUR - dstShift
		local start = lastSunday(y, 9) * DAY + 2 * HOUR - stdShift
		return ms < stop or ms >= start
	end
	return false
end

-- The zone's offset (minutes east) and abbreviation at `ms`.
function M.zoneAt(zone: Zone, ms: number): (number, string)
	local rule = zone.rule
	if rule and dstActive(rule, zone.std, ms) then
		return zone.std + 60, zone.dst_abbr or zone.abbr
	end
	return zone.std, zone.abbr
end

-- moment-timezone's numeric abbreviation: "+05", "-0330".
local function numericAbbr(min: number): string
	local sign = if min < 0 then "-" else "+"
	local a = math.abs(min)
	if a % 60 == 0 then
		return string.format("%s%02d", sign, a // 60)
	end
	return string.format("%s%02d%02d", sign, a // 60, a % 60)
end

-- The clock's zone for a timezone option value (after "dashboard" and
-- variable interpolation): `localMin` is the viewer's offset, `dashTz` and
-- `dashMin` the dashboard's timezone and display offset.
function M.zone(tz: string, localMin: number, dashTz: string?, dashMin: number?): Zone
	if tz == "" then
		return { name = "Local", std = localMin, abbr = "", approx = true }
	end
	local known = ZONES[string.lower(tz)]
	if known then
		return known
	end
	local sign, hours = string.match(string.lower(tz), "^etc/gmt([%+%-])(%d%d?)$")
	if sign and hours then
		local h = tonumber(hours) :: number
		-- POSIX style: Etc/GMT+5 is five hours west.
		local min = if sign == "+" then -h * 60 else h * 60
		if h <= 14 then
			return { name = "Etc/GMT" .. sign .. hours, std = min, abbr = numericAbbr(min) }
		end
	end
	-- An IANA-looking name outside the table: moment knows it, we do not.
	if string.match(tz, "^%a[%w_%-]*/[%w_%-+/]+$") then
		local min = if dashTz == tz and dashMin then dashMin else localMin
		return { name = tz, std = min, abbr = "", approx = true }
	end
	-- moment-timezone has no such zone: the moment stays in local time, its
	-- abbreviation is empty and zoneFormat "name" falls back to the string.
	return { name = tz, std = localMin, abbr = "", approx = true }
end

------------------------------------------------------------------------------
-- moment format (en locale).

local MONTHS = {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}
local WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

local LONG_FORMATS: { [string]: string } = {
	LTS = "h:mm:ss A",
	LT = "h:mm A",
	L = "MM/DD/YYYY",
	LL = "MMMM D, YYYY",
	LLL = "MMMM D, YYYY h:mm A",
	LLLL = "dddd, MMMM D, YYYY h:mm A",
	l = "M/D/YYYY",
	ll = "MMM D, YYYY",
	lll = "MMM D, YYYY h:mm A",
	llll = "ddd, MMM D, YYYY h:mm A",
}

local function ordinal(n: number): string
	local b = n % 10
	local suffix = if (n % 100) // 10 == 1
		then "th"
		elseif b == 1 then "st"
		elseif b == 2 then "nd"
		elseif b == 3 then "rd"
		else "th"
	return tostring(n) .. suffix
end

local function zeroFill(n: number, width: number, forceSign: boolean?): string
	local a = math.abs(n)
	local s = string.format("%0" .. width .. "d", a)
	if n < 0 then
		return "-" .. s
	end
	return if forceSign then "+" .. s else s
end

local function daysInYear(y: number): number
	return if isLeap(y) then 366 else 365
end

-- moment's firstWeekOffset / weekOfYear (dow: first day of week, doy: the
-- January day that is always in week 1, as 7 + dow - doy).
local function firstWeekOffset(year: number, dow: number, doy: number): number
	local fwd = 7 + dow - doy
	local fwdlw = (7 + weekday(daysFromCivil(year, 1, fwd)) - dow) % 7
	return -fwdlw + fwd - 1
end

local function weeksInYear(year: number, dow: number, doy: number): number
	return (daysInYear(year) - firstWeekOffset(year, dow, doy) + firstWeekOffset(year + 1, dow, doy)) / 7
end

local function weekOfYear(year: number, dayOfYear: number, dow: number, doy: number): (number, number)
	local week = (dayOfYear - firstWeekOffset(year, dow, doy) - 1) // 7 + 1
	if week < 1 then
		return week + weeksInYear(year - 1, dow, doy), year - 1
	elseif week > weeksInYear(year, dow, doy) then
		return week - weeksInYear(year, dow, doy), year + 1
	end
	return week, year
end

-- moment's formattingTokens alternatives, in regex order (the first that
-- matches wins, not the longest).
local TOKEN_PATTERNS = {
	"^[Hh]mmss",
	"^[Hh]mm",
	"^Mo",
	"^MMMM",
	"^MMM",
	"^MM",
	"^M",
	"^Do",
	"^DDDo",
	"^DDDD",
	"^DDD",
	"^DD",
	"^D",
	"^dddd",
	"^ddd",
	"^dd",
	"^do",
	"^d",
	"^w[o|w]",
	"^w",
	"^W[o|W]",
	"^W",
	"^Qo",
	"^Q",
	"^NNNNN",
	"^NNNN",
	"^NNN",
	"^NN",
	"^N",
	"^YYYYYY",
	"^YYYYY",
	"^YYYY",
	"^YY",
	"^yyyy",
	"^yyy",
	"^yy",
	"^yo",
	"^y",
	"^ggggg",
	"^gggg",
	"^gg",
	"^GGGGG",
	"^GGGG",
	"^GG",
	"^e",
	"^E",
	"^a",
	"^A",
	"^hh",
	"^h",
	"^HH",
	"^H",
	"^kk",
	"^k",
	"^mm",
	"^m",
	"^ss",
	"^s",
	"^S+",
	"^x",
	"^X",
	"^zz",
	"^z",
	"^ZZ",
	"^Z",
}

type Parts = {
	ms: number,
	offset: number,
	abbr: string,
	y: number,
	mo: number,
	d: number,
	h: number,
	mi: number,
	s: number,
	milli: number,
	wd: number,
	doy: number,
}

local function offsetText(offset: number, sep: string): string
	local sign = if offset < 0 then "-" else "+"
	local a = math.abs(offset)
	return string.format("%s%02d%s%02d", sign, a // 60, sep, a % 60)
end

local function tokenValue(tok: string, p: Parts): string?
	local h12 = if p.h % 12 == 0 then 12 else p.h % 12
	local c = string.sub(tok, 1, 1)
	if tok == "Hmmss" or tok == "hmmss" then
		return tostring(if c == "H" then p.h else h12) .. string.format("%02d%02d", p.mi, p.s)
	elseif tok == "Hmm" or tok == "hmm" then
		return tostring(if c == "H" then p.h else h12) .. string.format("%02d", p.mi)
	elseif tok == "M" then
		return tostring(p.mo)
	elseif tok == "Mo" then
		return ordinal(p.mo)
	elseif tok == "MM" then
		return zeroFill(p.mo, 2)
	elseif tok == "MMM" then
		return string.sub(MONTHS[p.mo], 1, 3)
	elseif tok == "MMMM" then
		return MONTHS[p.mo]
	elseif tok == "D" then
		return tostring(p.d)
	elseif tok == "Do" then
		return ordinal(p.d)
	elseif tok == "DD" then
		return zeroFill(p.d, 2)
	elseif tok == "DDD" then
		return tostring(p.doy)
	elseif tok == "DDDo" then
		return ordinal(p.doy)
	elseif tok == "DDDD" then
		return zeroFill(p.doy, 3)
	elseif tok == "d" or tok == "e" then
		return tostring(p.wd)
	elseif tok == "do" then
		return ordinal(p.wd)
	elseif tok == "dd" then
		return string.sub(WEEKDAYS[p.wd + 1], 1, 2)
	elseif tok == "ddd" then
		return string.sub(WEEKDAYS[p.wd + 1], 1, 3)
	elseif tok == "dddd" then
		return WEEKDAYS[p.wd + 1]
	elseif tok == "E" then
		return tostring(if p.wd == 0 then 7 else p.wd)
	elseif tok == "w" or tok == "wo" or tok == "ww" then
		local w = weekOfYear(p.y, p.doy, 0, 6)
		return if tok == "w" then tostring(w) elseif tok == "wo" then ordinal(w) else zeroFill(w, 2)
	elseif tok == "W" or tok == "Wo" or tok == "WW" then
		local w = weekOfYear(p.y, p.doy, 1, 4)
		return if tok == "W" then tostring(w) elseif tok == "Wo" then ordinal(w) else zeroFill(w, 2)
	elseif tok == "gg" or tok == "gggg" or tok == "ggggg" or tok == "GG" or tok == "GGGG" or tok == "GGGGG" then
		local iso = c == "G"
		local _, wy = weekOfYear(p.y, p.doy, if iso then 1 else 0, if iso then 4 else 6)
		if #tok == 2 then
			return zeroFill(wy % 100, 2)
		end
		return zeroFill(wy, #tok)
	elseif tok == "Q" then
		return tostring((p.mo - 1) // 3 + 1)
	elseif tok == "Qo" then
		return ordinal((p.mo - 1) // 3 + 1)
	elseif c == "N" then
		return if #tok == 4 then "Anno Domini" else "AD"
	elseif tok == "Y" then
		return if p.y <= 9999 then zeroFill(p.y, 4) else "+" .. tostring(p.y)
	elseif tok == "YY" then
		return zeroFill(p.y % 100, 2)
	elseif tok == "YYYY" then
		return if p.y <= 9999 then zeroFill(p.y, 4) else "+" .. tostring(p.y)
	elseif tok == "YYYYY" then
		return zeroFill(p.y, 5)
	elseif tok == "YYYYYY" then
		return zeroFill(p.y, 6, true)
	elseif tok == "y" then
		return tostring(p.y)
	elseif tok == "yo" then
		return ordinal(p.y)
	elseif tok == "yy" or tok == "yyy" or tok == "yyyy" then
		return zeroFill(p.y, #tok)
	elseif tok == "a" then
		return if p.h < 12 then "am" else "pm"
	elseif tok == "A" then
		return if p.h < 12 then "AM" else "PM"
	elseif tok == "H" then
		return tostring(p.h)
	elseif tok == "HH" then
		return zeroFill(p.h, 2)
	elseif tok == "h" then
		return tostring(h12)
	elseif tok == "hh" then
		return zeroFill(h12, 2)
	elseif tok == "k" or tok == "kk" then
		local k = if p.h == 0 then 24 else p.h
		return if tok == "k" then tostring(k) else zeroFill(k, 2)
	elseif tok == "m" then
		return tostring(p.mi)
	elseif tok == "mm" then
		return zeroFill(p.mi, 2)
	elseif tok == "s" then
		return tostring(p.s)
	elseif tok == "ss" then
		return zeroFill(p.s, 2)
	elseif c == "S" and #tok <= 9 then
		local n = #tok
		if n <= 3 then
			return zeroFill(p.milli // 10 ^ (3 - n), n)
		end
		return zeroFill(p.milli, 3) .. string.rep("0", n - 3)
	elseif tok == "x" then
		return string.format("%d", p.ms)
	elseif tok == "X" then
		return string.format("%d", p.ms // SECOND)
	elseif tok == "z" or tok == "zz" then
		return p.abbr
	elseif tok == "Z" then
		return offsetText(p.offset, ":")
	elseif tok == "ZZ" then
		return offsetText(p.offset, "")
	end
	return nil
end

local LONG_KEYS = { "LTS", "LT", "LLLL", "LLL", "LL", "L", "llll", "lll", "ll", "l" }

-- One pass of moment's localFormattingTokens replacement.
local function expandLong(fmt: string): string
	local out = {}
	local i = 1
	local n = #fmt
	while i <= n do
		local c = string.sub(fmt, i, i)
		if c == "[" then
			local close = string.find(fmt, "]", i + 1, true)
			local open = string.find(fmt, "[", i + 1, true)
			if close and (open == nil or open > close) then
				table.insert(out, string.sub(fmt, i, close))
				i = close + 1
				continue
			end
		end
		local escaped = c == "\\"
		local at = if escaped then i + 1 else i
		local matched: string? = nil
		for _, key in LONG_KEYS do
			if string.sub(fmt, at, at + #key - 1) == key then
				matched = key
				break
			end
		end
		if matched then
			table.insert(out, if escaped then "\\" .. matched else LONG_FORMATS[matched])
			i = at + #matched
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

-- `ms` (epoch ms) formatted with a moment format string in a zone at
-- `offset` minutes east with abbreviation `abbr`.
function M.format(fmt: string, ms: number, offset: number, abbr: string): string
	for _ = 1, 5 do
		local expanded = expandLong(fmt)
		if expanded == fmt then
			break
		end
		fmt = expanded
	end
	local wall = ms + offset * MINUTE
	local days = wall // DAY
	local rem = wall - days * DAY
	local y, mo, d = civilFromDays(days)
	local p: Parts = {
		ms = ms,
		offset = offset,
		abbr = abbr,
		y = y,
		mo = mo,
		d = d,
		h = rem // HOUR,
		mi = rem % HOUR // MINUTE,
		s = rem % MINUTE // SECOND,
		milli = rem % SECOND // 1,
		wd = weekday(days),
		doy = days - daysFromCivil(y, 1, 1) + 1,
	}
	local out = {}
	local i = 1
	local n = #fmt
	while i <= n do
		local c = string.sub(fmt, i, i)
		if c == "[" then
			local close = string.find(fmt, "]", i + 1, true)
			local open = string.find(fmt, "[", i + 1, true)
			if close and (open == nil or open > close) then
				table.insert(out, string.sub(fmt, i + 1, close - 1))
				i = close + 1
				continue
			end
		end
		local escaped = c == "\\"
		local at = if escaped then i + 1 else i
		local tok: string? = nil
		for _, pat in TOKEN_PATTERNS do
			local m = string.match(fmt, pat, at)
			if m then
				tok = m
				break
			end
		end
		if tok == nil then
			-- Any other single character (the regex's `.`), or a lone
			-- trailing backslash.
			tok = string.sub(fmt, at, at)
		end
		local t = tok :: string
		local v = if escaped then nil else tokenValue(t, p)
		if v then
			table.insert(out, v)
		else
			-- removeFormattingTokens: backslashes dropped, text kept.
			table.insert(out, (string.gsub(t, "\\", "")))
		end
		i = at + math.max(#t, 1)
	end
	return table.concat(out)
end

------------------------------------------------------------------------------
-- Parsing input times (moment(string): ISO 8601, else the Date fallback for
-- "YYYY/MM/DD HH:mm:ss").

-- (epoch ms, true) for a time with an offset, (local wall ms, false) for one
-- without, nil when moment would make an invalid date.
function M.parseTime(text: string): (number?, boolean)
	local s = string.match(text, "^%s*(.-)$") or text
	local y, mo, d, rest = string.match(s, "^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
	if not y then
		y, mo, d, rest = string.match(s, "^(%d%d%d%d)(%d%d)(%d%d)(.*)$")
	end
	if not y then
		y, mo, rest = string.match(s, "^(%d%d%d%d)%-(%d%d)(.*)$")
		d = if y then "01" else nil
		if y and rest ~= "" then
			return nil, false
		end
	end
	local slash = false
	if not y then
		y, mo, d, rest = string.match(s, "^(%d%d%d%d)/(%d%d?)/(%d%d?)(.*)$")
		slash = y ~= nil
	end
	if not (y and mo and d and rest) then
		return nil, false
	end
	local yy, mm, dd = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	if mm < 1 or mm > 12 or dd < 1 or dd > daysInMonth(yy, mm) then
		return nil, false
	end
	local h, mi, sec, milli = 0, 0, 0, 0
	local zone: string? = nil
	local tail = rest :: string
	if tail ~= "" then
		local sep = string.sub(tail, 1, 1)
		if sep ~= "T" and sep ~= " " or (slash and sep ~= " ") then
			return nil, false
		end
		tail = string.sub(tail, 2)
		local hh, after = string.match(tail, "^(%d%d)(.*)$")
		if slash and not hh then
			hh, after = string.match(tail, "^(%d)(.*)$")
		end
		if not (hh and after) then
			return nil, false
		end
		h = tonumber(hh) :: number
		tail = after
		local mn, after2 = string.match(tail, "^:(%d%d)(.*)$")
		if mn and after2 then
			mi = tonumber(mn) :: number
			tail = after2
			local ss, after3 = string.match(tail, "^:(%d%d)(.*)$")
			if ss and after3 then
				sec = tonumber(ss) :: number
				tail = after3
				local frac, after4 = string.match(tail, "^[%.,](%d+)(.*)$")
				if frac and after4 then
					-- moment keeps milliseconds, truncating the rest.
					milli = tonumber(string.sub(frac .. "00", 1, 3)) :: number
					tail = after4
				end
			end
		end
		if tail ~= "" and not slash then
			if string.match(tail, "^%s*Z$") then
				zone = "+00:00"
			else
				local zs, zh, zm = string.match(tail, "^([%+%-])(%d%d):?(%d%d)$")
				if not zs then
					zs, zh = string.match(tail, "^([%+%-])(%d%d)$")
					zm = "00"
				end
				if not (zs and zh and zm) then
					return nil, false
				end
				zone = zs .. zh .. ":" .. zm
			end
		elseif tail ~= "" then
			return nil, false
		end
		if h == 24 and (mi ~= 0 or sec ~= 0 or milli ~= 0) or h > 24 or mi > 59 or sec > 59 then
			return nil, false
		end
	end
	local wall = daysFromCivil(yy, mm, dd) * DAY + h * HOUR + mi * MINUTE + sec * SECOND + milli
	if zone then
		local sign = if string.sub(zone, 1, 1) == "-" then -1 else 1
		local zmin = (tonumber(string.sub(zone, 2, 3)) :: number) * 60 + (tonumber(string.sub(zone, 5, 6)) :: number)
		return wall - sign * zmin * MINUTE, true
	end
	return wall, false
end

------------------------------------------------------------------------------
-- moment.duration from milliseconds.

export type DurationData = {
	years: number,
	months: number,
	days: number,
	hours: number,
	minutes: number,
	seconds: number,
	milliseconds: number,
}

local function daysToMonths(days: number): number
	return days * 4800 / 146097
end

local function monthsToDays(months: number): number
	return months * 146097 / 4800
end

-- moment's Duration#_bubble for a non-negative millisecond duration.
function M.duration(ms: number): DurationData
	local seconds = ms // SECOND
	local minutes = seconds // 60
	local hours = minutes // 60
	local days = hours // 24
	local monthsFromDays = daysToMonths(days) // 1
	days -= math.ceil(monthsToDays(monthsFromDays))
	return {
		years = monthsFromDays // 12,
		months = monthsFromDays % 12,
		days = days,
		hours = hours % 24,
		minutes = minutes % 60,
		seconds = seconds % 60,
		milliseconds = ms % SECOND,
	}
end

-- RenderTime getCountdownText / getCountupText without a customFormat.
function M.humanize(ms: number): string
	local d = M.duration(ms)
	local out = ""
	local previous = ""
	if d.years > 0 then
		out = if d.years == 1 then "1 year, " else d.years .. " years, "
		previous = "years"
	end
	if d.months > 0 or previous == "years" then
		out ..= if d.months == 1 then "1 month, " else d.months .. " months, "
		previous = "months"
	end
	if d.days > 0 or previous == "months" then
		out ..= if d.days == 1 then "1 day, " else d.days .. " days, "
		previous = "days"
	end
	if d.hours > 0 or previous == "days" then
		out ..= if d.hours == 1 then "1 hour, " else d.hours .. " hours, "
		previous = "hours"
	end
	if d.minutes > 0 or previous == "hours" then
		out ..= if d.minutes == 1 then "1 minute, " else d.minutes .. " minutes, "
	end
	-- The trailing space after "1 second" is the plugin's.
	out ..= if d.seconds == 1 then "1 second " else d.seconds .. " seconds"
	return out
end

------------------------------------------------------------------------------
-- moment-duration-format 2.x, Duration#format(template) with the default
-- settings (precision 0 rounded, trim "large", usePlural, useGrouping en).

local DUR_TYPES = { "years", "months", "weeks", "days", "hours", "minutes", "seconds", "milliseconds" }
local DUR_KEY: { [string]: string } = {
	years = "y",
	months = "M",
	weeks = "w",
	days = "d",
	hours = "h",
	minutes = "m",
	seconds = "s",
	milliseconds = "S",
}
local DUR_CLASS: { [string]: string } = {
	Y = "years",
	y = "years",
	M = "months",
	W = "weeks",
	w = "weeks",
	D = "days",
	d = "days",
	H = "hours",
	h = "hours",
	m = "minutes",
	s = "seconds",
	S = "milliseconds",
}
local LABELS_STANDARD: { [string]: string } = {
	S = "millisecond",
	SS = "milliseconds",
	s = "second",
	ss = "seconds",
	m = "minute",
	mm = "minutes",
	h = "hour",
	hh = "hours",
	d = "day",
	dd = "days",
	w = "week",
	ww = "weeks",
	M = "month",
	MM = "months",
	y = "year",
	yy = "years",
}
local LABELS_SHORT: { [string]: string } = {
	S = "msec",
	SS = "msecs",
	s = "sec",
	ss = "secs",
	m = "min",
	mm = "mins",
	h = "hr",
	hh = "hrs",
	d = "dy",
	dd = "dys",
	w = "wk",
	ww = "wks",
	M = "mo",
	MM = "mos",
	y = "yr",
	yy = "yrs",
}
local BUBBLES: { { type: string, targets: { { type: string, value: number } } } } = {
	{
		type = "seconds",
		targets = {
			{ type = "minutes", value = 60 },
			{ type = "hours", value = 3600 },
			{ type = "days", value = 86400 },
			{ type = "weeks", value = 604800 },
			{ type = "months", value = 2678400 },
			{ type = "years", value = 31536000 },
		},
	},
	{
		type = "minutes",
		targets = {
			{ type = "hours", value = 60 },
			{ type = "days", value = 1440 },
			{ type = "weeks", value = 10080 },
			{ type = "months", value = 44640 },
			{ type = "years", value = 525600 },
		},
	},
	{
		type = "hours",
		targets = {
			{ type = "days", value = 24 },
			{ type = "weeks", value = 168 },
			{ type = "months", value = 744 },
			{ type = "years", value = 8760 },
		},
	},
	{
		type = "days",
		targets = { { type = "weeks", value = 7 }, { type = "months", value = 31 }, { type = "years", value = 365 } },
	},
	{ type = "months", targets = { { type = "years", value = 12 } } },
}

-- A moment Duration's raw fields (the remainders the plugin subtracts from).
type Dur = { ms: number, days: number, months: number }

local function jsRound(x: number): number
	return math.floor(x + 0.5)
end

local function durAs(d: Dur, unit: string): number
	if unit == "months" or unit == "years" then
		local months = d.months + daysToMonths(d.days + d.ms / DAY)
		return if unit == "months" then months else months / 12
	end
	local days = d.days + jsRound(monthsToDays(d.months))
	if unit == "weeks" then
		return days / 7 + d.ms / (7 * DAY)
	elseif unit == "days" then
		return days + d.ms / DAY
	elseif unit == "hours" then
		return days * 24 + d.ms / HOUR
	elseif unit == "minutes" then
		return days * 1440 + d.ms / MINUTE
	elseif unit == "seconds" then
		return days * 86400 + d.ms / SECOND
	end
	return math.floor(days * DAY) + d.ms
end

local function durSubtract(d: Dur, n: number, unit: string)
	if unit == "years" then
		d.months -= 12 * n
	elseif unit == "months" then
		d.months -= n
	elseif unit == "weeks" then
		d.days -= 7 * n
	elseif unit == "days" then
		d.days -= n
	elseif unit == "hours" then
		d.ms -= n * HOUR
	elseif unit == "minutes" then
		d.ms -= n * MINUTE
	elseif unit == "seconds" then
		d.ms -= n * SECOND
	else
		d.ms -= n
	end
end

-- toLocaleString("en", { minimumIntegerDigits, useGrouping }) of an integer.
local function formatInt(value: number, minDigits: number, grouping: boolean): string
	local s = string.format("%d", value)
	if #s < minDigits then
		s = string.rep("0", minDigits - #s) .. s
	end
	if not grouping or #s <= 3 then
		return s
	end
	local parts = {}
	local head = #s % 3
	if head > 0 then
		table.insert(parts, string.sub(s, 1, head))
	end
	for i = head + 1, #s, 3 do
		table.insert(parts, string.sub(s, i, i + 2))
	end
	return table.concat(parts, ",")
end

local function replaceFirst(s: string, find: string, repl: string): string
	local i, j = string.find(s, find, 1, true)
	if i == nil then
		return s
	end
	return string.sub(s, 1, i - 1) .. repl .. string.sub(s, (j :: number) + 1)
end

-- defaultFormatTemplate: the template and trim setting for format() with no
-- template (customFormat "auto").
local function defaultTemplate(ms: number): (string, string?)
	local data = M.duration(ms)
	local present: { string } = {}
	for _, t in DUR_TYPES do
		local v = (data :: any)[t]
		if v ~= nil and v ~= 0 then
			table.insert(present, t)
		end
	end
	local first, last = present[1], present[#present]
	if first == "milliseconds" then
		return "S __", nil
	elseif first == "seconds" or first == "minutes" then
		return "*_MS_", nil
	elseif first == "hours" then
		return "_HMS_", nil
	elseif first == "days" then
		if first == last then
			return "d __", nil
		end
		return "w __, d __, h __", "both"
	elseif first == "months" or first == "years" then
		if first == last then
			return if first == "months" then "M __" else "y __", nil
		end
		return "y __, M __, d __", "both"
	end
	return "y __, d __, h __, m __, s __", "both"
end

type DurToken = { text: string, type: string?, length: number }
type MomentType = {
	type: string,
	rawValue: number,
	wholeValue: number,
	decimalValue: number,
	isSmallest: boolean,
	isLargest: boolean,
	tokenLength: number,
	value: number,
	formatted: string,
	formattedEn: string,
}

local function durTokens(template: string, stopTrim: { [string]: boolean }): { DurToken }
	local raw: { DurToken } = {}
	local i = 1
	local n = #template
	while i <= n do
		local c = string.sub(template, i, i)
		if c == "[" then
			local close = string.find(template, "]", i + 2, true)
			if close then
				table.insert(raw, { text = string.sub(template, i + 1, close - 1), length = close - i + 1 })
				i = close + 1
				continue
			end
		end
		local star = c == "*"
		local at = if star then i + 1 else i
		local cls = DUR_CLASS[string.sub(template, at, at)]
		if cls then
			local j = at
			while j + 1 <= n and DUR_CLASS[string.sub(template, j + 1, j + 1)] == cls do
				j += 1
			end
			if star then
				stopTrim[cls] = true
			end
			table.insert(raw, { text = "", type = cls, length = j - at + 1 })
			i = j + 1
		else
			table.insert(raw, { text = c, length = 1 })
			i += 1
		end
	end
	-- Text after a moment token belongs to it (its units).
	local tokens: { DurToken } = {}
	local current: DurToken = { text = "", length = 0 }
	for _, tok in raw do
		if tok.type then
			if current.type or current.text ~= "" then
				table.insert(tokens, current)
			end
			current = { text = "", type = tok.type, length = tok.length }
		else
			current.text ..= tok.text
		end
	end
	if current.type or current.text ~= "" then
		table.insert(tokens, current)
	end
	return tokens
end

local function labelsFor(key: string): { { kind: string, key: string, label: string } }
	local out = {}
	local sets: { { kind: string, labels: { [string]: string } } } =
		{ { kind = "standard", labels = LABELS_STANDARD }, { kind = "short", labels = LABELS_SHORT } }
	for _, set in sets do
		for _, k in { key, key .. key } do
			table.insert(out, { kind = set.kind, key = k, label = set.labels[k] })
		end
	end
	return out
end

-- Duration#format(template) of a non-negative millisecond duration; nil
-- template is format() (the plugin's customFormat "auto").
function M.formatDuration(ms: number, template: string?): string
	local trim: string? = nil
	local tpl: string
	if template == nil then
		tpl, trim = defaultTemplate(ms)
	else
		tpl = template
	end
	tpl = replaceFirst(tpl, "_HMS_", "h:mm:ss")
	tpl = replaceFirst(tpl, "_HM_", "h:mm")
	tpl = replaceFirst(tpl, "_MS_", "m:ss")
	local trimMode = trim or "large"
	local trimSmall = trimMode == "both"

	local stopTrim: { [string]: boolean } = {}
	local tokens = durTokens(tpl, stopTrim)
	local seen: { [string]: number } = {}
	for _, tok in tokens do
		if tok.type and seen[tok.type] == nil then
			seen[tok.type] = tok.length
		end
	end
	local present: { string } = {}
	for _, t in DUR_TYPES do
		if seen[t] then
			table.insert(present, t)
		end
	end
	if #present == 0 then
		local parts = {}
		for _, tok in tokens do
			table.insert(parts, tok.text)
		end
		return table.concat(parts)
	end

	local remainder: Dur = { ms = ms, days = 0, months = 0 }
	local remainderMonths: Dur = { ms = 0, days = 0, months = daysToMonths(ms / DAY) }
	local forceLength: boolean? = nil
	local types: { MomentType } = {}
	for index, t in present do
		local raw = if t == "years" or t == "months" then durAs(remainderMonths, t) else durAs(remainder, t)
		local whole = math.floor(raw)
		local isSmallest = index == #present
		local isLargest = index == 1
		if isLargest and forceLength == nil and seen[t] > 1 then
			forceLength = true
		end
		durSubtract(remainder, whole, t)
		durSubtract(remainderMonths, whole, t)
		table.insert(types, {
			type = t,
			rawValue = raw,
			wholeValue = whole,
			decimalValue = if isSmallest then raw - whole else 0,
			isSmallest = isSmallest,
			isLargest = isLargest,
			tokenLength = seen[t],
			value = 0,
			formatted = "",
			formattedEn = "",
		})
	end

	local function formatValues()
		local foundFirst = false
		for _, mt in types do
			mt.value = if mt.isSmallest then jsRound(mt.wholeValue + mt.decimalValue) else mt.wholeValue
			local minDigits = if mt.tokenLength > 1 and (forceLength or foundFirst) then mt.tokenLength else 1
			if not foundFirst and (mt.value > 0 or stopTrim[mt.type]) then
				foundFirst = true
			end
			mt.formatted = formatInt(mt.value, minDigits, true)
			mt.formattedEn = formatInt(mt.value, minDigits, false)
		end
	end
	formatValues()

	-- Bubble rounded values (60 seconds -> 1 minute, ...).
	local byType: { [string]: MomentType } = {}
	for _, mt in types do
		byType[mt.type] = mt
	end
	local bubbled = false
	if #types > 1 then
		for _, b in BUBBLES do
			local from = byType[b.type]
			if from then
				for _, target in b.targets do
					local to = byType[target.type]
					if to and tonumber(from.formattedEn) == target.value then
						from.rawValue, from.wholeValue, from.decimalValue = 0, 0, 0
						to.rawValue += 1
						to.wholeValue += 1
						to.decimalValue = 0
						to.formattedEn = tostring(to.wholeValue)
						bubbled = true
					end
				end
			end
		end
	end
	if bubbled then
		formatValues()
	end

	-- Trim large: leading zero tokens; trim small ("both"): trailing ones.
	local first = 1
	while first < #types and types[first].wholeValue == 0 and not stopTrim[types[first].type] do
		first += 1
	end
	local last = #types
	if trimSmall and last - first + 1 > 1 then
		while
			last > first
			and types[last].wholeValue == 0
			and not stopTrim[types[last].type]
			and not types[last].isLargest
		do
			last -= 1
		end
	end
	local kept: { [string]: MomentType } = {}
	for i = first, last do
		kept[types[i].type] = types[i]
	end

	local out = {}
	for _, tok in tokens do
		local ty = tok.type
		if ty == nil then
			table.insert(out, tok.text)
			continue
		end
		local mt = kept[ty]
		if mt == nil then
			continue
		end
		local text = tok.text
		local key = DUR_KEY[ty]
		local pluralKey = if tonumber(mt.formattedEn) == 1 then key else key .. key
		local labels = labelsFor(key)
		local pluralized: { [string]: string } = {}
		local localized = false
		for _, kind in { { "standard", "__" }, { "short", "_" } } do
			for _, l in labels do
				if l.kind == kind[1] and l.key == pluralKey then
					pluralized[l.kind] = l.label
					if string.find(text, kind[2], 1, true) then
						text = replaceFirst(text, kind[2], l.label)
						localized = true
					end
				end
			end
		end
		if not localized then
			-- Longest label first (stable), so "seconds" is seen before "second".
			local sorted = table.clone(labels)
			for i = 2, #sorted do
				local v = sorted[i]
				local j = i - 1
				while j >= 1 and #sorted[j].label < #v.label do
					sorted[j + 1] = sorted[j]
					j -= 1
				end
				sorted[j + 1] = v
			end
			for _, l in sorted do
				if pluralized[l.kind] == l.label then
					if string.find(text, l.label, 1, true) then
						break
					end
				elseif string.find(text, l.label, 1, true) then
					text = replaceFirst(text, l.label, pluralized[l.kind])
					break
				end
			end
		end
		local value = mt.formatted
		if ty == "milliseconds" and tok.length == 2 then
			value = string.sub(formatInt(mt.value, 3, false), 1, 2)
		end
		table.insert(out, value .. text)
	end
	local s = table.concat(out)
	s = string.gsub(s, "[, :%.]*$", "")
	s = string.gsub(s, "^[, :%.]*", "")
	return s
end

------------------------------------------------------------------------------
-- Options (src/options.ts defaults, which Grafana merges into saved options).

type Section = { [string]: any }

local function section(env: Env, options: any, name: string): Section
	return Json.obj(env, Json.path(env, options, name))
end

local function str(env: Env, t: Section, key: string, default: string): string
	return Json.str(env, Json.path(env, t, key)) or default
end

local function mode(env: Env, options: any): string
	local m = Json.str(env, Json.path(env, options, "mode"))
	return if m == "countdown" or m == "countup" then m else "time"
end

-- The active countdown/countup settings with their mode's field names.
local function clockSettings(env: Env, options: any, m: string): (Section, string, string)
	if m == "countdown" then
		return section(env, options, "countdownSettings"), "endCountdownTime", "endText"
	end
	return section(env, options, "countupSettings"), "beginCountupTime", "beginText"
end

-- Whether the panel reads its query (utils.ts isQueryDrivenOptions, narrowed
-- to what CalculateClockOptions consumes: the active mode's source; a
-- description query is only read alongside it).
function M.queries(panel: any): boolean
	local options = if type(panel) == "table" then panel.options else nil
	if type(options) ~= "table" then
		return false
	end
	local m = options.mode
	local settings = if m == "countdown"
		then options.countdownSettings
		elseif m == "countup" then options.countupSettings
		else nil
	return type(settings) == "table" and settings.source == "query"
end

function M.supports(panel: any, env: Env): (boolean, string?)
	local style = Json.str(env, Json.path(env, panel, "options", "style"))
	if style == "digital" then
		return false, "the digital clock style (clock panel 3.x) is not rendered natively"
	end
	return true, nil
end

-- refresh "sec" ticks every second; "dashboard" (or the pre-2.0
-- refreshSettings.syncWithDashboard) only redraws with the dashboard.
function M.liveMs(panel: any, env: Env): number?
	local options = Json.path(env, panel, "options")
	if
		Json.bool(env, Json.path(env, options, "refreshSettings", "syncWithDashboard"))
		or Json.bool(env, Json.path(env, panel, "refreshSettings", "syncWithDashboard"))
	then
		return nil
	end
	local refresh = Json.str(env, Json.path(env, options, "refresh")) or "sec"
	return if refresh == "sec" then 1000 else nil
end

------------------------------------------------------------------------------
-- CalculateClockOptions.

export type Result = {
	-- The time display, or the error text shown in its place.
	time: string,
	date: string?,
	zone: { string }?,
	description: string?,
}

local function falsy(v: any): boolean
	return v == nil or v == Frame.NULL or v == false or v == "" or v == 0 or v ~= v
end

-- A query value as moment(value): epoch ms for numbers, a parsed string,
-- nil when invalid.
local function momentOf(v: any, localMin: number): number?
	if type(v) == "number" then
		return if v == v and v ~= math.huge and v ~= -math.huge then v else nil
	elseif type(v) == "string" then
		local ms, hasOffset = M.parseTime(v)
		if ms == nil then
			return nil
		end
		return if hasOffset then ms else ms - localMin * MINUTE
	end
	return nil
end

local function findField(frames: { Frame.Frame }, name: string?): Frame.Field?
	if name == nil or name == "" then
		return nil
	end
	for _, f in frames do
		for _, field in f.fields do
			if field.name == name then
				return field
			end
		end
	end
	return nil
end

local function textOf(v: any): string?
	if v == nil or v == Frame.NULL then
		return nil
	elseif type(v) == "number" then
		return if v == math.floor(v) and math.abs(v) < 1e15 then string.format("%d", v) else tostring(v)
	end
	return tostring(v)
end

type Target = { time: number?, invalid: boolean, description: string? }

-- The target time from a query (nil time: no value; invalid: invalid value).
local function fromQuery(
	frames: { Frame.Frame },
	settings: Section,
	descField: string?,
	calc: string,
	env: Env,
	now: number,
	localMin: number
): Target?
	local queryField = Json.str(env, settings.queryField)
	local timeField = findField(frames, queryField)
	if #frames == 0 or timeField == nil or #timeField.values == 0 then
		return nil
	end
	local field = timeField :: Frame.Field
	local descValues = findField(frames, descField)
	local function desc(i: number): string?
		return if descValues then textOf(descValues.values[i]) else nil
	end
	local rows: { { time: number?, description: string? } } = {}
	for i, v in field.values do
		if v ~= nil and v ~= Frame.NULL and v == v then
			table.insert(rows, { time = momentOf(v, localMin), description = desc(i) })
		end
	end
	local function sorted(list: { { time: number?, description: string? } })
		local valid = {}
		for _, r in list do
			if r.time then
				table.insert(valid, r)
			end
		end
		table.sort(valid, function(a, b)
			return (a.time :: number) < (b.time :: number)
		end)
		return valid
	end
	local pick: { time: number?, description: string? }? = nil
	local n = #field.values
	if calc == "lastNotNull" then
		pick = rows[#rows]
	elseif calc == "firstNotNull" then
		pick = rows[1]
	elseif calc == "last" or calc == "first" then
		local i = if calc == "last" then n else 1
		local v = field.values[i]
		return {
			time = if falsy(v) then nil else momentOf(v, localMin),
			invalid = falsy(v) or momentOf(v, localMin) == nil,
			description = desc(i),
		}
	elseif calc == "min" or calc == "max" then
		local s = sorted(rows)
		pick = if calc == "min" then s[1] else s[#s]
	elseif calc == "minFuture" or calc == "maxPast" then
		local filtered = {}
		for _, r in rows do
			local t = r.time
			if t and ((calc == "minFuture" and t > now) or (calc == "maxPast" and t < now)) then
				table.insert(filtered, r)
			end
		end
		local s = sorted(filtered)
		pick = if calc == "minFuture" then s[1] else s[#s]
	else
		return nil
	end
	if pick == nil then
		return { time = nil, invalid = false, description = nil }
	end
	local p = pick :: { time: number?, description: string? }
	return { time = p.time, invalid = p.time == nil, description = p.description }
end

-- What the panel shows at env.now_ms, before layout.
function M.compute(panel: any, frames: { Frame.Frame }, env: Env, opts: Common.Options): Result
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local interpolate = opts.interpolate or function(s: string): string
		return s
	end
	local now = env.now_ms
	local localMin = opts.local_offset_min or env.local_offset_min or opts.offset_min or 0

	local tzOption = Json.str(env, options.timezone) or ""
	local dashTz = opts.timezone or ""
	if dashTz == "" then
		-- Grafana's dashboard default is the browser's zone.
		dashTz = "browser"
	end
	local tz = if tzOption == "dashboard" then dashTz else tzOption
	if tz ~= "" then
		tz = interpolate(tz)
	end
	local zone = M.zone(tz, localMin, opts.timezone, opts.offset_min)
	local offset, abbr = M.zoneAt(zone, now)

	local m = mode(env, options)
	local desc = section(env, options, "descriptionSettings")
	local descSource = str(env, desc, "source", "none")
	local descNoValue = str(env, desc, "noValueText", "no description found")
	local description = if descSource == "query" then descNoValue else str(env, desc, "descriptionText", "")

	local timeText: string
	if m == "time" then
		local clockType = str(env, options :: Section, "clockType", "24 hour")
		local custom = Json.str(env, Json.path(env, options, "timeSettings", "customFormat"))
		local fmt = if clockType == "custom"
				and custom
				and custom ~= ""
			then custom
			elseif clockType == "12 hour" then "h:mm:ss A"
			else "HH:mm:ss"
		timeText = M.format(fmt, now, offset, abbr)
	else
		local settings, timeKey, endKey = clockSettings(env, options, m)
		local noValue = str(env, settings, "noValueText", "no value found")
		local invalidValue = str(env, settings, "invalidValueText", "invalid value")
		local source = str(env, settings, "source", "input")
		local target: number? = nil
		local err: string? = nil
		if source == "query" then
			local calc = str(env, settings, "queryCalculation", "last")
			local descField = Json.str(env, desc.queryField)
			local got = fromQuery(frames, settings, descField, calc, env, now, localMin)
			if got == nil then
				err = noValue
			else
				local g = got :: Target
				if descSource == "query" then
					description = g.description or descNoValue
				end
				if g.invalid then
					err = invalidValue
				elseif g.time == nil then
					err = noValue
				else
					target = g.time
				end
			end
		else
			local input: any = Json.path(env, settings, timeKey)
			local text: string?
			if input == nil then
				-- options.ts default: six hours from when the editor loaded.
				text = M.format("YYYY-MM-DDTHH:mm:ssZ", now + 6 * HOUR, localMin, "")
			elseif type(input) == "string" then
				text = input
			elseif type(input) == "number" then
				text = nil
				target = input - offset * MINUTE + localMin * MINUTE
			end
			if text == "" then
				err = noValue
			elseif text then
				local ms, hasOffset = M.parseTime(interpolate(text :: string))
				if ms == nil then
					err = invalidValue
				else
					-- moment(input) is local time; utcOffset(clockZ, true)
					-- keeps that wall time in the clock's offset.
					local wall = if hasOffset then ms + localMin * MINUTE else ms
					target = wall - offset * MINUTE
				end
			elseif target == nil then
				err = invalidValue
			end
		end
		if err then
			timeText = err
		else
			local diff = if m == "countdown" then (target :: number) - now else now - (target :: number)
			diff = math.floor(diff)
			if diff <= 0 then
				timeText = str(env, settings, endKey, "00:00:00")
			else
				local custom = Json.str(env, settings.customFormat)
				if custom == "auto" then
					timeText = M.formatDuration(diff, nil)
				elseif custom and custom ~= "" then
					timeText = M.formatDuration(diff, custom)
				else
					timeText = M.humanize(diff)
				end
			end
		end
	end

	local result: Result = { time = timeText }
	local dateSettings = section(env, options, "dateSettings")
	if Json.bool(env, dateSettings.showDate) then
		result.date = M.format(str(env, dateSettings, "dateFormat", "YYYY-MM-DD"), now, offset, abbr)
	end
	local zoneSettings = section(env, options, "timezoneSettings")
	if Json.bool(env, zoneSettings.showTimezone) then
		local zf = str(env, zoneSettings, "zoneFormat", "offsetAbbv")
		local z = M.format("Z", now, offset, abbr)
		if zf == "offsetAbbv" then
			result.zone = { z .. " " .. abbr }
		elseif zf == "offset" then
			result.zone = { z }
		elseif zf == "abbv" then
			result.zone = { abbr }
		elseif zf == "nameOffset" then
			result.zone = { zone.name, "(" .. z .. " " .. abbr .. ")" }
		else
			result.zone = { zone.name }
		end
	end
	if descSource ~= "none" then
		result.description = description
	end
	return result
end

------------------------------------------------------------------------------
-- View.

-- Font size classes (panels2.css: tgp-clock-fs<N>, N px); a size snaps to the
-- nearest.
M.FONT_SIZES = {
	8,
	9,
	10,
	11,
	12,
	13,
	14,
	16,
	18,
	20,
	22,
	24,
	26,
	28,
	32,
	36,
	40,
	44,
	48,
	54,
	60,
	64,
	72,
	80,
	88,
	96,
	112,
	128,
	144,
	160,
	192,
	224,
	256,
}

-- Grafana's h2/h3/h4 sizes, for an empty or unreadable fontSize.
local HEADING_PX: { [string]: number } = { h2 = 24, h3 = 21, h4 = 18 }

-- A CSS font-size ("36px", "2rem", "1.5em", "18pt") in px (rem/em at
-- Grafana's 14 px root), nil when unreadable.
function M.fontPx(size: string?): number?
	if size == nil then
		return nil
	end
	local n, unit = string.match(string.lower(size), "^%s*([%d%.]+)%s*(%a*)%s*$")
	local v = if n then tonumber(n) else nil
	if v == nil then
		return nil
	end
	if unit == "px" or unit == "" then
		return v
	elseif unit == "rem" or unit == "em" then
		return v * 14
	elseif unit == "pt" then
		return v * 4 / 3
	end
	return nil
end

function M.fontClass(size: string?, heading: string): string
	local px = M.fontPx(size) or HEADING_PX[heading]
	local best = M.FONT_SIZES[1]
	for _, s in M.FONT_SIZES do
		if math.abs(s - px) < math.abs(best - px) then
			best = s
		end
	end
	return "tgp-clock-fs" .. best
end

local NAMED_BG: { [string]: boolean } = {}
for _, hue in { "red", "orange", "yellow", "green", "blue", "purple" } do
	for _, shade in { "super-light-", "light-", "", "semi-dark-", "dark-" } do
		NAMED_BG[shade .. hue] = true
	end
end
NAMED_BG.text = true

-- The container's background classes for options.bgColor: none for "" (the
-- theme's panel background) and transparent, a palette class for Grafana's
-- named colors, the closest tone tint for any other CSS color.
function M.bgClass(bg: string?): string?
	if bg == nil or bg == "" or bg == "transparent" then
		return nil
	end
	if NAMED_BG[bg] then
		return "tgp-clock-bg-" .. bg
	end
	local tone: Thresholds.Tone = Thresholds.tone(bg)
	if tone == "neutral" or tone == "muted" then
		return nil
	end
	return "tgp-bg " .. Common.toneClass(tone)
end

-- One heading of the panel (h2 time, h3 date/description, h4 zone). A
-- missing fontSize takes options.ts's default; an unreadable one the
-- heading's own size, as the browser ignores the invalid CSS.
local function block(key: string, kind: string, settings: Section, heading: string, lines: { string }, env: Env): Node
	local raw = Json.path(env, settings, "fontSize")
	local size = if raw == nil then (if kind == "date" then "20px" else "12px") else Json.str(env, raw)
	local classes = { "tgp-clock-" .. kind, M.fontClass(size, heading) }
	if Json.str(env, settings.fontWeight) == "bold" then
		table.insert(classes, "tgp-clock-bold")
	end
	local children: { Node } = table.create(#lines)
	for i, l in lines do
		children[i] = ui.text({ l }, { key = "l" .. i, wrap = "word" })
	end
	return ui.el("div", { key = key, class = table.concat(classes, " ") }, children)
end

function M.view(panel: any, frames: { Frame.Frame }, env: Env, opts: Common.Options): Node
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local r = M.compute(panel, frames, env, opts)
	local children: { Node } = {}
	if r.date then
		table.insert(children, block("date", "date", section(env, options, "dateSettings"), "h3", { r.date }, env))
	end
	table.insert(children, block("time", "time", section(env, options, "timeSettings"), "h2", { r.time }, env))
	if r.zone then
		table.insert(children, block("zone", "zone", section(env, options, "timezoneSettings"), "h4", r.zone, env))
	end
	if r.description then
		table.insert(
			children,
			block("desc", "desc", section(env, options, "descriptionSettings"), "h3", { r.description }, env)
		)
	end
	local classes = { "tgp-clock" }
	if Json.bool(env, options.fontMono) then
		table.insert(classes, "tgp-clock-mono")
	end
	local bg = M.bgClass(Json.str(env, options.bgColor))
	if bg then
		table.insert(classes, bg)
	end
	return ui.el("div", { key = opts.key, class = table.concat(classes, " ") }, children)
end

return M
