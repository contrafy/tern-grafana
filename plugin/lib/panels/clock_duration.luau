--!strict
-- grafana-clock-panel's durations (lib/panels/clock): moment.duration,
-- humanize and moment-duration-format 2.x.

local Zone = require("./clock_zone")

local M = {}

local SECOND, MINUTE, HOUR, DAY = Zone.SECOND, Zone.MINUTE, Zone.HOUR, Zone.DAY

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

return M
