--!strict
-- The field display processor (lib/panels/fieldconfig; field/
-- displayProcessor.ts, field/scale.ts, field/fieldColor.ts): one value as
-- text and a color, and the resolved field config types.

local ClockFormat = require("./clock_format")
local Env = require("../env")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Mappings = require("./mappings")
local Range = require("../time/range")
local Reduce = require("./reduce")
local Thresholds = require("../units/thresholds")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field

export type Config = {
	unit: string?,
	decimals: number?,
	min: number?,
	max: number?,
	display_name: string?,
	no_value: string?,
	thresholds: Thresholds.Thresholds,
	mappings: { Mappings.Mapping },
	-- fieldColor mode id ("thresholds", "fixed", "palette-classic", "shades",
	-- "continuous-GrYlRd", ...) and its fixed color.
	color_mode: string,
	fixed_color: string?,
	-- Reducer that picks a by-value series color (color.seriesBy, default last).
	series_by: string?,
	-- fieldConfig `custom.*`, merged defaults then overrides.
	custom: { [string]: any },
	null_mode: Reduce.NullMode?,
	field_min_max: boolean,
}

export type Item = {
	frame: Frame,
	field: Field,
	frame_index: number,
	field_index: number,
	-- Display name after overrides (Grafana getFieldDisplayName).
	name: string,
	config: Config,
	-- 1-based position among non-time fields across frames (palette colors).
	series_index: number,
	-- field.state.range: the scale for percent and gauges.
	range_min: number?,
	range_max: number?,
}

export type Display = {
	text: string,
	prefix: string,
	suffix: string,
	-- The value as a number (nil when it is not one).
	numeric: number?,
	color: string,
	tone: Thresholds.Tone,
	-- Position in the field's range, 0..1.
	percent: number,
	-- Palette color modes: the series class (tg-s1..tg-s10).
	class: string?,
	icon: string?,
}

-- `now_ms` is the clock dateTimeFromNow and the NoDateIfToday units read;
-- without it they show the full date.
export type Options = { theme: Thresholds.Theme?, offset_min: Range.Offset?, now_ms: number? }

export type Defaults = { color_mode: string? }

local M = {}

-- Palette size of the classic series colors (tg-s1..tg-s10).
M.PALETTE = 10

-- Display processor -----------------------------------------------------------

local ISO = "YYYY-MM-DD HH:mm:ss"
-- localTimeFormat (datetime/formats.ts) of an en-US browser.
local LOCAL = "MM/DD/YYYY, hh:mm:ss A"

-- dateTimeFormatters.ts: each unit's moment pattern, then its pattern for
-- a time on today's date.
local DATE_UNITS: { [string]: { string } } = {
	dateTimeAsIso = { ISO },
	dateTimeAsIsoNoDateIfToday = { ISO, "HH:mm:ss" },
	dateTimeAsUS = { "MM/DD/YYYY h:mm:ss a" },
	dateTimeAsUSNoDateIfToday = { "MM/DD/YYYY h:mm:ss a", "h:mm:ss a" },
	dateTimeAsLocal = { LOCAL },
	dateTimeAsLocalNoDateIfToday = { LOCAL, "hh:mm:ss A" },
	dateTimeAsSystem = { ISO },
	dateTimeFromNow = { ISO },
}

local BOOL_UNITS: { [string]: { string } } = {
	bool = { "True", "False" },
	bool_yes_no = { "Yes", "No" },
	bool_on_off = { "On", "Off" },
}

local function isDateUnit(unit: string?): boolean
	return unit ~= nil and (DATE_UNITS[unit] ~= nil or string.sub(unit, 1, 5) == "time:")
end

-- anyToNumber (packages/grafana-data/src/utils/anyToNumber.ts).
local function anyToNumber(v: any): number
	if type(v) == "number" then
		return v
	elseif type(v) == "boolean" then
		return if v then 1 else 0
	elseif type(v) == "string" then
		local s = string.match(v, "^%s*(.-)%s*$") or ""
		if s == "" then
			return 0 / 0
		end
		return tonumber(s) or 0 / 0
	end
	return 0 / 0
end

local DAY = 86400000

local function civilDate(ms: number, offsetMin: number): (number, number, number)
	local s = Range.formatMs(ms, offsetMin)
	return tonumber(string.sub(s, 1, 4)) :: number,
		tonumber(string.sub(s, 6, 7)) :: number,
		tonumber(string.sub(s, 9, 10)) :: number
end

-- moment's add(n, "M") at a fixed offset: the day clamped to the target
-- month's length, the time of day kept.
local function addMonths(ms: number, n: number, offsetMin: number): number
	local y, m, d = civilDate(ms, offsetMin)
	local index = y * 12 + (m - 1) + n
	local ty, tm = index // 12, index % 12 + 1
	local nextY, nextM = if tm == 12 then ty + 1 else ty, if tm == 12 then 1 else tm + 1
	local first = Range.parse(string.format("%04d-%02d-01", ty, tm), false, { now_ms = 0, offset_min = offsetMin })
	local after =
		Range.parse(string.format("%04d-%02d-01", nextY, nextM), false, { now_ms = 0, offset_min = offsetMin })
	local length = ((after :: number) - (first :: number)) // DAY
	local wall = ms + offsetMin * 60000
	return (first :: number) + (math.min(d, length) - 1) * DAY + (wall - (wall // DAY) * DAY)
end

-- moment's from(now) (fromNow, en locale): the difference as calendar
-- months plus milliseconds (momentsDifference), then Duration#humanize with
-- the default thresholds.
local function fromNow(ms: number, now: number, offsetMin: number): string
	local base, other = math.min(ms, now), math.max(ms, now)
	local by, bm = civilDate(base, offsetMin)
	local oy, om = civilDate(other, offsetMin)
	local months = (oy - by) * 12 + (om - bm)
	if addMonths(base, months, offsetMin) > other then
		months -= 1
	end
	local rest = other - addMonths(base, months, offsetMin)
	local function round(x: number): number
		return math.floor(x + 0.5)
	end
	local days = round(months * 146097 / 4800)
	local monthsAll = months + rest / DAY * 4800 / 146097
	local seconds = round(days * 86400 + rest / 1000)
	local minutes = round(days * 1440 + rest / 60000)
	local hours = round(days * 24 + rest / 3600000)
	local wholeDays = round(days + rest / DAY)
	local wholeMonths = round(monthsAll)
	local years = round(monthsAll / 12)
	local text
	if seconds <= 44 then
		text = "a few seconds"
	elseif seconds < 45 then
		text = seconds .. " seconds"
	elseif minutes <= 1 then
		text = "a minute"
	elseif minutes < 45 then
		text = minutes .. " minutes"
	elseif hours <= 1 then
		text = "an hour"
	elseif hours < 22 then
		text = hours .. " hours"
	elseif wholeDays <= 1 then
		text = "a day"
	elseif wholeDays < 26 then
		text = wholeDays .. " days"
	elseif wholeMonths <= 1 then
		text = "a month"
	elseif wholeMonths < 11 then
		text = wholeMonths .. " months"
	elseif years <= 1 then
		text = "a year"
	else
		text = years .. " years"
	end
	return if ms > now then "in " .. text else text .. " ago"
end

-- moment's fromNow at a display offset ("2 hours ago", "in a day").
M.fromNow = fromNow

-- The current day of the last `now` and zone asked about: a table formats
-- every row against the same clock.
local nowDay: { now: number, zone: Range.Offset, day: string } = { now = 0 / 0, zone = 0, day = "" }

local function sameDay(ms: number, now: number, zone: Range.Offset): boolean
	if nowDay.now ~= now or nowDay.zone ~= zone then
		nowDay.now, nowDay.zone, nowDay.day = now, zone, string.sub(Range.formatMs(now, zone), 1, 10)
	end
	return string.sub(Range.formatMs(ms, zone), 1, 10) == nowDay.day
end

-- A date unit's text (dateTimeFormatters.ts) at the display offset: a
-- "time:" moment pattern, the unit's pattern (its today pattern on the
-- current day), moment's fromNow, or the system format with milliseconds
-- for a time field spanning under a minute.
local function formatDate(ms: number, unit: string, o: Options, showMs: boolean): string
	local zone: Range.Offset = o.offset_min or 0
	local offset = Range.offsetAt(zone, ms)
	local now = o.now_ms
	local pattern: string
	if string.sub(unit, 1, 5) == "time:" then
		pattern = string.sub(unit, 6)
	elseif unit == "dateTimeFromNow" and now then
		return fromNow(ms, now, offset)
	elseif unit == "dateTimeAsSystem" and showMs then
		pattern = ISO .. ".SSS"
	else
		local p = DATE_UNITS[unit]
		local today = p[2]
		pattern = if today and now ~= nil and sameDay(ms, now, zone) then today else p[1]
	end
	return ClockFormat.format(pattern, ms, offset, "")
end

-- Grafana's continuous color schemes, read as severity along the scale.
local function continuousTone(mode: string, percent: number): Thresholds.Tone
	local scheme = string.sub(mode, 12)
	local p = math.clamp(percent, 0, 1)
	if scheme == "GrYlRd" then
		return if p < 1 / 3 then "success" elseif p < 2 / 3 then "warning" else "error"
	elseif scheme == "RdYlGr" then
		return if p < 1 / 3 then "error" elseif p < 2 / 3 then "warning" else "success"
	elseif scheme == "BlYlRd" then
		return if p < 1 / 3 then "info" elseif p < 2 / 3 then "warning" else "error"
	elseif scheme == "YlRd" then
		return if p < 0.5 then "warning" else "error"
	elseif scheme == "BlPu" then
		return if p < 0.5 then "info" else "accent"
	elseif scheme == "YlBl" then
		return if p < 0.5 then "warning" else "info"
	elseif scheme == "blues" then
		return "info"
	elseif scheme == "reds" then
		return "error"
	elseif scheme == "greens" then
		return "success"
	elseif scheme == "purples" then
		return "accent"
	end
	return "accent"
end

-- The series class of a palette position (lib/render/svg_timeseries).
function M.paletteClass(seriesIndex: number): string
	return "tg-s" .. tostring((seriesIndex - 1) % M.PALETTE + 1)
end

export type Scale = { color: string, tone: Thresholds.Tone, percent: number, class: string? }

local function scale(item: Item, value: number, o: Options): Scale
	local cfg = item.config
	local lo, hi = item.range_min, item.range_max
	local percent = 0
	if value ~= -math.huge then
		local lo_ = lo or 0
		local delta = (hi or 100) - lo_
		percent = (value - lo_) / delta
		if percent ~= percent then
			percent = 0
		end
	end
	local mode = cfg.color_mode
	if mode == "fixed" or mode == "shades" then
		local name = cfg.fixed_color
		return { color = Thresholds.color(name, o.theme), tone = Thresholds.tone(name), percent = percent }
	elseif mode == "palette-classic" or mode == "palette-classic-by-name" then
		local class = M.paletteClass(item.series_index)
		return { color = "", tone = "neutral", percent = percent, class = class }
	elseif string.sub(mode, 1, 11) == "continuous-" then
		return { color = "", tone = continuousTone(mode, percent), percent = percent }
	end
	local probe: number? = if value == -math.huge then nil else value
	local a = Thresholds.active(probe, cfg.thresholds, lo, hi, o.theme)
	return { color = a.color, tone = a.tone, percent = percent }
end

-- getDisplayProcessor(field)(value): mappings first, then the unit, then the
-- color scale; no value reads as the field's noValue (or "").
function M.display(item: Item, value: any, opts: Options?): Display
	local o: Options = opts or {}
	local cfg = item.config
	local fieldType = item.field.type
	local unit = cfg.unit
	local hasDate = isDateUnit(unit)
	local showMs = false
	if fieldType == "time" and not hasDate then
		unit = "dateTimeAsSystem"
		hasDate = true
		local values = item.field.values
		local first, last = values[1], values[#values]
		if #values > 1 and type(first) == "number" and type(last) == "number" then
			showMs = math.abs(last - first) < 60000
		end
	elseif fieldType == "boolean" and (unit == nil or BOOL_UNITS[unit] == nil) then
		unit = "bool"
	elseif unit == nil and fieldType == "string" then
		unit = "string"
	end
	if value == Frame.NULL then
		value = nil
	end
	local numeric = if unit == "string" then 0 / 0 else anyToNumber(value)
	if value == nil then
		numeric = 0 / 0
	end
	local text: string?, prefix: string?, suffix: string? = nil, nil, nil
	local color: string?, tone: Thresholds.Tone?, class: string? = nil, nil, nil
	local icon: string? = nil
	local percent = 0
	if #cfg.mappings > 0 then
		local r = Mappings.apply(cfg.mappings, value)
		if r then
			text = r.text
			if r.color then
				color = Thresholds.color(r.color, o.theme)
				tone = Thresholds.tone(r.color)
			end
			icon = r.icon
		end
	end
	if numeric == numeric then
		if text == nil and type(value) ~= "boolean" then
			local u = unit :: string?
			if u and hasDate then
				text = formatDate(numeric, u, o, showMs)
			elseif u and BOOL_UNITS[u] then
				local labels = BOOL_UNITS[u]
				text = if numeric ~= 0 then labels[1] else labels[2]
			else
				local f = Format.format(numeric, u, cfg.decimals)
				text, prefix, suffix = f.text, f.prefix, f.suffix
			end
		end
		-- getDisplayProcessor: the scale's percent always, its color unless a
		-- mapping set one.
		local s = scale(item, numeric, o)
		percent = s.percent
		if color == nil then
			color, tone, class = s.color, s.tone, s.class
		end
	end
	if text == nil and type(value) == "boolean" then
		local labels = BOOL_UNITS[unit or "bool"] or BOOL_UNITS.bool
		text = if value then labels[1] else labels[2]
	end
	if text == nil then
		text = if value == nil then "" elseif type(value) == "string" then value else tostring(value)
		if text == "" then
			text = cfg.no_value or ""
		end
	end
	if color == nil then
		local s = scale(item, -math.huge, o)
		color, tone, class, percent = s.color, s.tone, s.class, s.percent
	end
	return {
		text = text :: string,
		prefix = prefix or "",
		suffix = suffix or "",
		numeric = if numeric == numeric then numeric else nil,
		color = color :: string,
		tone = tone or "neutral",
		percent = percent,
		class = class,
		icon = icon,
	}
end

-- getFieldSeriesColor: the one color a whole series is drawn in. Palette
-- modes give the series class; by-value modes (thresholds, continuous)
-- color it by the `seriesBy` reduction (default: the raw last value).
function M.seriesColor(item: Item, opts: Options?): Scale
	local o: Options = opts or {}
	local mode = item.config.color_mode
	if mode == "fixed" or mode == "shades" or mode == "palette-classic" or mode == "palette-classic-by-name" then
		return scale(item, 0, o)
	end
	local by = item.config.series_by or "last"
	local v = Reduce.reduce(item.field.values, by, item.field.type, item.config.null_mode)
	return scale(item, if type(v) == "number" then v else 0, o)
end

function M.joined(d: Display): string
	return d.prefix .. d.text .. d.suffix
end

-- Fields Grafana hides from a visualization: `custom.hidden` (tables, and
-- the converters' labelTypes) or `custom.hideFrom.viz`.
function M.hidden(item: Item): boolean
	local custom = item.config.custom
	if custom.hidden == true then
		return true
	end
	local hideFrom = custom.hideFrom
	return type(hideFrom) == "table" and hideFrom.viz == true
end

return M
