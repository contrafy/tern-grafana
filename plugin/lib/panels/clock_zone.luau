--!strict
-- grafana-clock-panel's calendar and timezones (lib/panels/clock): civil
-- date math (Howard Hinnant's days_from_civil / civil_from_days) and the
-- moment-timezone subset the panel needs (see clock.luau's header).

local M = {}

M.SECOND = 1000
M.MINUTE = 60 * M.SECOND
M.HOUR = 60 * M.MINUTE
M.DAY = 24 * M.HOUR

local MINUTE = M.MINUTE
local HOUR = M.HOUR
local DAY = M.DAY

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

M.daysFromCivil = daysFromCivil
M.civilFromDays = civilFromDays
M.isLeap = isLeap
M.daysInMonth = daysInMonth
M.weekday = weekday

return M
