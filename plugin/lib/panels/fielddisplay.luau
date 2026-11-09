--!strict
-- The field display processor (lib/panels/fieldconfig; field/
-- displayProcessor.ts, field/scale.ts, field/fieldColor.ts): one value as
-- text and a color, and the resolved field config types.

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

export type Options = { theme: Thresholds.Theme?, offset_min: number? }

export type Defaults = { color_mode: string? }

local M = {}

-- Palette size of the classic series colors (tg-s1..tg-s10).
M.PALETTE = 10

-- Display processor -----------------------------------------------------------

local DATE_UNITS: { [string]: boolean } = {
	dateTimeAsIso = true,
	dateTimeAsIsoNoDateIfToday = true,
	dateTimeAsUS = true,
	dateTimeAsUSNoDateIfToday = true,
	dateTimeAsLocal = true,
	dateTimeAsLocalNoDateIfToday = true,
	dateTimeAsSystem = true,
	dateTimeFromNow = true,
}

local BOOL_UNITS: { [string]: { string } } = {
	bool = { "True", "False" },
	bool_yes_no = { "Yes", "No" },
	bool_on_off = { "On", "Off" },
}

local function isDateUnit(unit: string?): boolean
	return unit ~= nil and (DATE_UNITS[unit] == true or string.sub(unit, 1, 5) == "time:")
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

local function formatDate(ms: number, unit: string, offsetMin: number?): string
	local iso = Range.formatMs(ms, offsetMin)
	if unit == "dateTimeAsUS" or unit == "dateTimeAsUSNoDateIfToday" then
		-- MM/DD/YYYY h:mm:ss a
		local Y, Mo, D = string.sub(iso, 1, 4), string.sub(iso, 6, 7), string.sub(iso, 9, 10)
		local h = tonumber(string.sub(iso, 12, 13)) :: number
		local rest = string.sub(iso, 14)
		local ampm = if h >= 12 then "pm" else "am"
		local h12 = h % 12
		if h12 == 0 then
			h12 = 12
		end
		return string.format("%s/%s/%s %d%s %s", Mo, D, Y, h12, rest, ampm)
	end
	return iso
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
	if fieldType == "time" and not hasDate then
		unit = "dateTimeAsSystem"
		hasDate = true
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
				text = formatDate(numeric, u, o.offset_min)
			elseif u and BOOL_UNITS[u] then
				local labels = BOOL_UNITS[u]
				text = if numeric ~= 0 then labels[1] else labels[2]
			else
				local f = Format.format(numeric, u, cfg.decimals)
				text, prefix, suffix = f.text, f.prefix, f.suffix
			end
		end
		if color == nil then
			local s = scale(item, numeric, o)
			color, tone, class, percent = s.color, s.tone, s.class, s.percent
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
