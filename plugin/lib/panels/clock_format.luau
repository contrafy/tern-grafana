--!strict
-- grafana-clock-panel's moment formatting (en locale) and input time
-- parsing (lib/panels/clock).

local Zone = require("./clock_zone")

local M = {}

local SECOND, MINUTE, HOUR, DAY = Zone.SECOND, Zone.MINUTE, Zone.HOUR, Zone.DAY
local daysFromCivil, civilFromDays = Zone.daysFromCivil, Zone.civilFromDays
local isLeap, daysInMonth, weekday = Zone.isLeap, Zone.daysInMonth, Zone.weekday

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

-- A format string split once into literal text and tokens; `text` is what a
-- token reads when tokenValue has no value for it (removeFormattingTokens:
-- backslashes dropped, text kept).
type Piece = { tok: string?, text: string }

local function tokenize(source: string): { Piece }
	local fmt = source
	for _ = 1, 5 do
		local expanded = expandLong(fmt)
		if expanded == fmt then
			break
		end
		fmt = expanded
	end
	local pieces: { Piece } = {}
	local i = 1
	local n = #fmt
	while i <= n do
		local c = string.sub(fmt, i, i)
		if c == "[" then
			local close = string.find(fmt, "]", i + 1, true)
			local open = string.find(fmt, "[", i + 1, true)
			if close and (open == nil or open > close) then
				table.insert(pieces, { text = string.sub(fmt, i + 1, close - 1) })
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
		table.insert(pieces, { tok = if escaped then nil else t, text = (string.gsub(t, "\\", "")) })
		i = at + math.max(#t, 1)
	end
	return pieces
end

-- Tokenized formats by format string: a clock panel formats the same one or
-- two strings every second.
local tokenCache: { [string]: { Piece } } = {}
local tokenCacheSize = 0
local TOKEN_CACHE_MAX = 128

-- `ms` (epoch ms) formatted with a moment format string in a zone at
-- `offset` minutes east with abbreviation `abbr`.
function M.format(fmt: string, ms: number, offset: number, abbr: string): string
	local pieces = tokenCache[fmt]
	if pieces == nil then
		pieces = tokenize(fmt)
		if tokenCacheSize >= TOKEN_CACHE_MAX then
			table.clear(tokenCache)
			tokenCacheSize = 0
		end
		tokenCache[fmt] = pieces
		tokenCacheSize += 1
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
	local list = pieces :: { Piece }
	local out: { string } = table.create(#list)
	for k, piece in list do
		local tok = piece.tok
		out[k] = (if tok then tokenValue(tok, p) else nil) or piece.text
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

return M
