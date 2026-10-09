--!strict
-- Grafana time ranges. Relative expressions port
-- packages/grafana-data/src/datetime/datemath.ts (parseDateMath, roundToFiscal)
-- with moment's startOf/endOf/add semantics; display strings port
-- datetime/rangeutil.ts (describeTimeRange, describeTextRange); zoom and shift
-- port getZoomedTimeRange/getShiftedTimeRange from the dashboard time service.
--
-- Times are epoch milliseconds. A timezone is a fixed offset in minutes east
-- of UTC (default 0), so rounding never meets a DST transition.
--
-- Deliberate differences from Grafana:
-- - Absolute numbers below 1e11 are epoch seconds (Prometheus, promtool);
--   Grafana reads every number as milliseconds.
-- - "/fM" and other fiscal units besides y and Q are rejected instead of ignored.
-- - A range mixing an absolute and a relative end shows the relative end raw
--   ("2024-03-15 13:45:30 to now") instead of moment's "a few seconds ago".

export type Options = {
	now_ms: number,
	-- Minutes east of UTC.
	offset_min: number?,
	-- 0 = Sunday (Grafana's default) .. 6 = Saturday.
	week_start: number?,
	-- 0 = January.
	fiscal_year_start_month: number?,
}

export type Range = { from_ms: number, to_ms: number }

local M = {}

local SECOND = 1000
local MINUTE = 60 * SECOND
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR
local MAX_MATH_DIGITS = 5

local FIXED_UNITS: { [string]: number } = { s = SECOND, m = MINUTE, h = HOUR, d = DAY, w = 7 * DAY }
local MONTH_UNITS: { [string]: number } = { M = 1, Q = 3, y = 12 }

-- Howard Hinnant's days_from_civil / civil_from_days (proleptic Gregorian).
local function daysFromCivil(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
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
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	local y = yoe + era * 400
	return if m <= 2 then y + 1 else y, m, d
end

local function isLeap(y: number): boolean
	return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function daysInMonth(y: number, m: number): number
	return if m == 2 and isLeap(y) then 29 else MONTH_DAYS[m]
end

-- All math below works on "local" milliseconds: epoch ms shifted by the offset.

local function addMonths(local_ms: number, n: number): number
	local days = local_ms // DAY
	local rem = local_ms - days * DAY
	local y, m, d = civilFromDays(days)
	local total = y * 12 + (m - 1) + n
	local ny, nm = total // 12, total % 12 + 1
	return daysFromCivil(ny, nm, math.min(d, daysInMonth(ny, nm))) * DAY + rem
end

local function startOf(local_ms: number, unit: string, weekStart: number): number
	local fixed = FIXED_UNITS[unit]
	if fixed and unit ~= "w" then
		return local_ms // fixed * fixed
	end
	local days = local_ms // DAY
	if unit == "w" then
		local weekday = (days + 4) % 7 -- 1970-01-01 was a Thursday
		return (days - (weekday - weekStart) % 7) * DAY
	end
	local y, m = civilFromDays(days)
	if unit == "Q" then
		m = (m - 1) // 3 * 3 + 1
	elseif unit == "y" then
		m = 1
	end
	return daysFromCivil(y, m, 1) * DAY
end

local function add(local_ms: number, n: number, unit: string): number
	local fixed = FIXED_UNITS[unit]
	if fixed then
		return local_ms + n * fixed
	end
	return addMonths(local_ms, n * MONTH_UNITS[unit])
end

local function endOf(local_ms: number, unit: string, weekStart: number): number
	return add(startOf(local_ms, unit, weekStart), 1, unit) - 1
end

local function roundFiscal(local_ms: number, unit: string, roundUp: boolean, fyStart: number): number
	local _, m = civilFromDays(local_ms // DAY)
	local span = if unit == "y" then 12 else 3
	local down = startOf(addMonths(local_ms, -((m - 1 - fyStart + 12) % span)), "M", 0)
	if roundUp then
		return endOf(addMonths(down, span - 1), "M", 0)
	end
	return down
end

local function applyMath(local_ms: number, math_: string, roundUp: boolean, opts: Options): number?
	local s = string.gsub(math_, "%s", "")
	local weekStart = opts.week_start or 0
	local fyStart = opts.fiscal_year_start_month or 0
	local result = local_ms
	local i = 1
	local len = #s
	while i <= len do
		local op = string.sub(s, i, i)
		i += 1
		if op ~= "/" and op ~= "+" and op ~= "-" then
			return nil
		end
		local digits = string.match(s, "^%d+", i)
		local num = 1
		if digits then
			if #digits > MAX_MATH_DIGITS then
				return nil
			end
			num = tonumber(digits) :: number
			i += #digits
		end
		if op == "/" and num ~= 1 then
			return nil
		end
		local unit = string.sub(s, i, i)
		i += 1
		local fiscal = false
		if unit == "f" then
			unit = string.sub(s, i, i)
			i += 1
			fiscal = true
		end
		if FIXED_UNITS[unit] == nil and MONTH_UNITS[unit] == nil then
			return nil
		end
		if op == "/" then
			if fiscal then
				if unit ~= "y" and unit ~= "Q" then
					return nil
				end
				result = roundFiscal(result, unit, roundUp, fyStart)
			elseif roundUp then
				result = endOf(result, unit, weekStart)
			else
				result = startOf(result, unit, weekStart)
			end
		else
			result = add(result, if op == "+" then num else -num, unit)
		end
	end
	return result
end

local function civilMs(y: number, mo: number, d: number, h: number, mi: number, sec: number, ms: number): number?
	if mo < 1 or mo > 12 or d < 1 or d > daysInMonth(y, mo) or h > 23 or mi > 59 or sec > 59 then
		return nil
	end
	return daysFromCivil(y, mo, d) * DAY + h * HOUR + mi * MINUTE + sec * SECOND + ms
end

-- RFC 3339 / ISO 8601 subset: date, optional [Tt ]hh:mm[:ss[.fff]], optional Z or +-hh[:]mm.
-- Returns epoch ms; zoneless input is read in `offset` minutes.
local function parseIso(text: string, offset: number): number?
	local y, mo, d, rest = string.match(text, "^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
	if not (y and mo and d and rest) then
		return nil
	end
	local h, mi, sec, ms = 0, 0, 0, 0
	local zone = rest
	if rest ~= "" then
		local hh, mm, tail = string.match(rest, "^[Tt ](%d%d):(%d%d)(.*)$")
		if not (hh and mm and tail) then
			return nil
		end
		h, mi = tonumber(hh) :: number, tonumber(mm) :: number
		local ss, after = string.match(tail, "^:(%d%d)(.*)$")
		if ss and after then
			sec = tonumber(ss) :: number
			tail = after
			local frac, afterFrac = string.match(tail, "^%.(%d+)(.*)$")
			if frac and afterFrac then
				ms = math.floor(tonumber("0." .. frac) :: number * 1000 + 0.5)
				tail = afterFrac
			end
		end
		zone = tail
	end
	local zoneMin = offset
	if zone == "Z" or zone == "z" then
		zoneMin = 0
	elseif zone ~= "" then
		local sign, zh, zm = string.match(zone, "^([%+%-])(%d%d):?(%d%d)$")
		if not (sign and zh and zm) then
			return nil
		end
		zoneMin = (tonumber(zh) :: number) * 60 + (tonumber(zm) :: number)
		if sign == "-" then
			zoneMin = -zoneMin
		end
	end
	local local_ms = civilMs(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number, h, mi, sec, ms)
	if local_ms == nil then
		return nil
	end
	return local_ms - zoneMin * MINUTE
end

local function parseAbsolute(text: string, offset: number): number?
	if string.match(text, "^%d+$") then
		if #text == 8 then
			local y, mo, d = string.match(text, "^(%d%d%d%d)(%d%d)(%d%d)$")
			return civilMs(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number, 0, 0, 0, 0)
		end
		local n = tonumber(text) :: number
		return if n < 1e11 then n * SECOND else n
	end
	if string.match(text, "^%d+%.%d+$") then
		return math.floor((tonumber(text) :: number) * SECOND + 0.5)
	end
	local y, mo, d, h, mi, sec = string.match(text, "^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)$")
	if y and mo and d and h and mi and sec then
		return civilMs(
			tonumber(y) :: number,
			tonumber(mo) :: number,
			tonumber(d) :: number,
			tonumber(h) :: number,
			tonumber(mi) :: number,
			tonumber(sec) :: number,
			0
		)
	end
	return parseIso(text, offset)
end

function M.isRelative(text: string): boolean
	return string.find(text, "now", 1, true) ~= nil
end

-- Epoch ms for one end of a range; `roundUp` is true for `to`, so "/d" means
-- the day's last millisecond there.
function M.parse(text: string, roundUp: boolean, opts: Options): (number?, string?)
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	local offset = opts.offset_min or 0
	local anchor: number?
	local math_ = ""
	if string.sub(trimmed, 1, 3) == "now" then
		anchor = opts.now_ms
		math_ = string.sub(trimmed, 4)
	else
		local bar = string.find(trimmed, "||", 1, true)
		local head = if bar then string.sub(trimmed, 1, bar - 1) else trimmed
		if bar then
			math_ = string.sub(trimmed, bar + 2)
		end
		anchor = parseAbsolute(head, offset)
	end
	if anchor == nil then
		return nil, "invalid time: " .. text
	end
	if math_ == "" then
		return anchor, nil
	end
	local result = applyMath(anchor + offset * MINUTE, math_, roundUp, opts)
	if result == nil then
		return nil, "invalid time: " .. text
	end
	return result - offset * MINUTE, nil
end

function M.resolve(from: string, to: string, opts: Options): (Range?, string?)
	local fromMs, fromErr = M.parse(from, false, opts)
	if fromMs == nil then
		return nil, "from: " .. (fromErr or "invalid")
	end
	local toMs, toErr = M.parse(to, true, opts)
	if toMs == nil then
		return nil, "to: " .. (toErr or "invalid")
	end
	if fromMs > toMs then
		return nil, "from is after to"
	end
	return { from_ms = fromMs, to_ms = toMs }, nil
end

function M.formatMs(ms: number, offset_min: number?): string
	local local_ms = math.floor(ms) + (offset_min or 0) * MINUTE
	local days = local_ms // DAY
	local rem = local_ms - days * DAY
	local y, m, d = civilFromDays(days)
	return string.format(
		"%04d-%02d-%02d %02d:%02d:%02d",
		y,
		m,
		d,
		rem // HOUR,
		rem % HOUR // MINUTE,
		rem % MINUTE // SECOND
	)
end

-- rangeutil.ts getBaseRangeOptions + getHiddenRangeOptions, keyed "from|to".
local QUICK: { [string]: string } = {
	["now/d|now/d"] = "Today",
	["now/d|now"] = "Today so far",
	["now/w|now/w"] = "This week",
	["now/w|now"] = "This week so far",
	["now/M|now/M"] = "This month",
	["now/M|now"] = "This month so far",
	["now/y|now/y"] = "This year",
	["now/y|now"] = "This year so far",
	["now-1d/d|now-1d/d"] = "Yesterday",
	["now-2d/d|now-2d/d"] = "Day before yesterday",
	["now-7d/d|now-7d/d"] = "This day last week",
	["now-1w/w|now-1w/w"] = "Previous week",
	["now-1M/M|now-1M/M"] = "Previous month",
	["now-1Q/fQ|now-1Q/fQ"] = "Previous fiscal quarter",
	["now-1y/y|now-1y/y"] = "Previous year",
	["now-1y/fy|now-1y/fy"] = "Previous fiscal year",
	["now/fQ|now"] = "This fiscal quarter so far",
	["now/fQ|now/fQ"] = "This fiscal quarter",
	["now/fy|now"] = "This fiscal year so far",
	["now/fy|now/fy"] = "This fiscal year",
}

local SPANS: { [string]: string } = {
	s = "second",
	m = "minute",
	h = "hour",
	d = "day",
	w = "week",
	M = "month",
	Q = "quarter",
	y = "year",
	fQ = "fiscal quarter",
	fy = "fiscal year",
}

-- describeTextRange for a range ending now; Grafana's quick "Last N"
-- options all read the same as this spelled-out form.
local function describeText(from: string, to: string): string
	local sign, amount, rest = string.match(from, "^now([%-%+])(%d+)(.*)$")
	if sign and amount and rest then
		local unit = string.match(rest, "^f[Qy]") or string.match(rest, "^[yMwdhmsQ]")
		local span = if unit then SPANS[unit] else nil
		if span then
			local n = tonumber(amount) :: number
			return "Last " .. tostring(n) .. " " .. span .. (if n > 1 then "s" else "")
		end
	end
	return from .. " to " .. to
end

-- getHiddenRangeOptions: only these "Next N" ranges have a name.
for _, ahead in
	{ "1m", "5m", "15m", "30m", "1h", "3h", "6h", "12h", "24h", "2d", "7d", "30d", "90d", "6M", "1y", "2y", "5y" }
do
	local amount, unit = string.match(ahead, "^(%d+)(%a)$")
	local n = tonumber(amount) :: number
	QUICK["now|now+" .. ahead] = "Next " .. tostring(n) .. " " .. SPANS[unit :: string] .. (if n > 1 then "s" else "")
end

function M.describe(from: string, to: string, offset_min: number?): string
	local quick = QUICK[from .. "|" .. to]
	if quick then
		return quick
	end
	local fromAbs = if M.isRelative(from) then nil else parseAbsolute(from, offset_min or 0)
	local toAbs = if M.isRelative(to) then nil else parseAbsolute(to, offset_min or 0)
	if fromAbs or toAbs then
		local a = if fromAbs then M.formatMs(fromAbs, offset_min) else from
		local b = if toAbs then M.formatMs(toAbs, offset_min) else to
		return a .. " to " .. b
	end
	if to == "now" then
		return describeText(from, to)
	end
	return from .. " to " .. to
end

function M.zoom(r: Range, factor: number): Range
	local span = r.to_ms - r.from_ms
	local center = r.to_ms - span / 2
	return {
		from_ms = math.floor(center - span * factor / 2),
		to_ms = math.floor(center + span * factor / 2),
	}
end

function M.zoomOut(r: Range): Range
	return M.zoom(r, 2)
end

-- direction -1 moves back in time, +1 forward, by half the span.
function M.shift(r: Range, direction: number): Range
	local half = (r.to_ms - r.from_ms) / 2 * (if direction < 0 then -1 else 1)
	return { from_ms = math.floor(r.from_ms + half), to_ms = math.floor(r.to_ms + half) }
end

return M
