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

local ClockDuration = require("./clock_duration")
local ClockFormat = require("./clock_format")
local Range = require("../time/range")
local ClockZone = require("./clock_zone")
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

local MINUTE, HOUR = ClockZone.MINUTE, ClockZone.HOUR

-- Calendar, timezones, moment formatting and durations live in clock_zone,
-- clock_format and clock_duration; the panel's API keeps them here too.
export type Zone = ClockZone.Zone
export type DurationData = ClockDuration.DurationData
M.zone = ClockZone.zone
M.zoneAt = ClockZone.zoneAt
M.format = ClockFormat.format
M.parseTime = ClockFormat.parseTime
M.duration = ClockDuration.duration
M.humanize = ClockDuration.humanize
M.formatDuration = ClockDuration.formatDuration

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
	local localMin = opts.local_offset_min or env.local_offset_min or 0
	local dashMin = if opts.offset_min ~= nil then Range.offsetAt(opts.offset_min, now) else nil

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
	local zone = M.zone(tz, localMin, opts.timezone, dashMin)
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
