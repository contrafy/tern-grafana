--!strict
-- Grafana field configuration for panels: panel `fieldConfig.defaults` and
-- `overrides` resolved per field (packages/grafana-data/src/field/
-- fieldOverrides.ts applyFieldOverrides), field display names
-- (field/fieldState.ts calculateFieldDisplayName), override matchers
-- (transformations/matchers/nameMatcher.ts, fieldTypeMatcher.ts,
-- refIdMatcher.ts) and the display processor that turns one value into
-- text and a color (field/displayProcessor.ts, field/scale.ts,
-- field/fieldColor.ts).
--
-- Colors end as Tern tones (lib/units/thresholds tone table): Tern paints
-- with theme variables, so a threshold step's severity survives a theme
-- switch where its exact hue would not.

local Env = require("../env")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Json = require("./json")
local Mappings = require("./mappings")
local Range = require("../time/range")
local Reduce = require("./reduce")
local Regex = require("../regex")
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

-- Grafana's standard thresholds default (OptionsUI/registry.tsx).
function M.defaultThresholds(): Thresholds.Thresholds
	return { mode = "absolute", steps = { { color = "green" }, { color = "red", value = 80 } } }
end

M.PALETTE = 10

local function parseThresholds(env: Env, raw: any): Thresholds.Thresholds?
	local t = Json.tbl(env, raw)
	if t == nil then
		return nil
	end
	local steps: { Thresholds.Step } = {}
	for _, s in Json.list(env, t.steps) do
		local st = Json.tbl(env, s)
		if st then
			local color = Json.str(env, st.color) or ""
			local value = Json.num(env, st.value)
			table.insert(steps, { color = color, value = value })
		end
	end
	return { mode = Json.str(env, t.mode) or "absolute", steps = steps }
end

local function setCustom(cfg: Config, path: string, value: any)
	cfg.custom[path] = value
end

-- One fieldConfig property (a defaults key or an override property id).
local function applyProperty(env: Env, cfg: Config, id: string, value: any)
	local v = if value == env.null then nil else value
	if id == "unit" then
		local s = Json.str(env, v)
		cfg.unit = if s and s ~= "" then s else nil
	elseif id == "decimals" then
		cfg.decimals = Json.num(env, v)
	elseif id == "min" then
		cfg.min = Json.num(env, v)
	elseif id == "max" then
		cfg.max = Json.num(env, v)
	elseif id == "displayName" then
		local s = Json.str(env, v)
		cfg.display_name = if s and s ~= "" then s else nil
	elseif id == "noValue" then
		cfg.no_value = Json.str(env, v)
	elseif id == "thresholds" then
		local t = parseThresholds(env, v)
		if t then
			cfg.thresholds = t
		end
	elseif id == "mappings" then
		cfg.mappings = Mappings.parse(v, env)
	elseif id == "color" then
		local c = Json.tbl(env, v)
		if c then
			cfg.color_mode = Json.str(env, c.mode) or cfg.color_mode
			cfg.fixed_color = Json.str(env, c.fixedColor) or cfg.fixed_color
			cfg.series_by = Json.str(env, c.seriesBy) or cfg.series_by
		end
	elseif id == "nullValueMode" then
		local s = Json.str(env, v)
		if s == "connected" or s == "null" or s == "null as zero" then
			cfg.null_mode = s
		end
	elseif id == "fieldMinMax" then
		cfg.field_min_max = Json.bool(env, v) == true
	elseif id == "custom" then
		local c = Json.tbl(env, v)
		if c then
			for k, cv in c do
				if type(k) == "string" then
					setCustom(cfg, k, cv)
				end
			end
		end
	elseif string.sub(id, 1, 7) == "custom." then
		setCustom(cfg, string.sub(id, 8), v)
	end
end

local DEFAULT_KEYS =
	{ "unit", "decimals", "min", "max", "displayName", "noValue", "mappings", "color", "nullValueMode", "fieldMinMax" }

-- The panel's `fieldConfig.defaults` with Grafana's standard defaults for
-- what it leaves out (thresholds green/red at 80, no mappings, the panel
-- type's color mode).
function M.defaults(panel: any, env: Env, d: Defaults?): Config
	local raw = Json.obj(env, Json.path(env, panel, "fieldConfig", "defaults"))
	local cfg: Config = {
		thresholds = M.defaultThresholds(),
		mappings = {},
		color_mode = (d and d.color_mode) or "thresholds",
		custom = {},
		field_min_max = false,
	}
	for _, k in DEFAULT_KEYS do
		if raw[k] ~= nil then
			applyProperty(env, cfg, k, raw[k])
		end
	end
	local t = parseThresholds(env, raw.thresholds)
	if t then
		cfg.thresholds = t
	end
	applyProperty(env, cfg, "custom", raw.custom)
	return cfg
end

local function cloneConfig(c: Config): Config
	local out = table.clone(c)
	out.custom = table.clone(c.custom)
	return out
end

-- Display names ---------------------------------------------------------------

-- Grafana formatLabels: every label, sorted, `{a="1", b="2"}`.
local function formatLabels(labels: { [string]: string }): string
	local keys: { string } = {}
	for k in labels do
		table.insert(keys, k)
	end
	if #keys == 0 then
		return ""
	end
	table.sort(keys)
	local parts: { string } = table.create(#keys)
	for i, k in keys do
		parts[i] = string.format('%s="%s"', k, labels[k])
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- getSingleLabelName: the label key when every labeled field across the
-- frames has that one key only.
local function singleLabelName(frames: { Frame }): string?
	local single: string? = nil
	for _, frame in frames do
		for _, field in frame.fields do
			if field.labels then
				for k in field.labels do
					if single == nil then
						single = k
					elseif k ~= single then
						return nil
					end
				end
			end
		end
	end
	return single
end

-- calculateFieldDisplayName. The frame converters store Grafana's
-- displayNameFromDS in config.displayName, so it comes first here exactly
-- as it does in Grafana (a panel displayName replaces it beforehand).
function M.displayName(field: Field, frame: Frame?, frames: { Frame }?): string
	local config = field.config
	if config and config.displayName and config.displayName ~= "" then
		return config.displayName
	end
	if field.type == "time" and field.labels == nil then
		return if field.name ~= "" then field.name else "Time"
	end
	local all = frames or (if frame then { frame } else {})
	local parts: { string } = {}
	local namesDiffer = false
	for i = 2, #all do
		if all[i].name ~= all[i - 1].name then
			namesDiffer = true
			break
		end
	end
	local frameNameAdded, labelsAdded = false, false
	if namesDiffer and frame and frame.name and frame.name ~= "" then
		table.insert(parts, frame.name)
		frameNameAdded = true
	end
	if field.name ~= "" and field.name ~= "Value" then
		table.insert(parts, field.name)
	end
	if field.labels and frame then
		local single = singleLabelName(all)
		if single == nil then
			local text = formatLabels(field.labels)
			if text ~= "" then
				table.insert(parts, text)
				labelsAdded = true
			end
		elseif field.labels[single] and field.labels[single] ~= "" then
			table.insert(parts, field.labels[single])
			labelsAdded = true
		end
	end
	if frame and not frameNameAdded and not labelsAdded and field.name == "Value" then
		if frame.name and frame.name ~= "" then
			table.insert(parts, frame.name)
		end
	end
	if #parts > 0 then
		return table.concat(parts, " ")
	elseif field.name ~= "" then
		return field.name
	end
	return "Value"
end

-- Matchers --------------------------------------------------------------------

type Matcher = (field: Field, frame: Frame, frames: { Frame }) -> boolean

local MATCHERS: { [string]: boolean } = {
	byName = true,
	byRegexp = true,
	byFrameRefID = true,
	byType = true,
	byNames = true,
	byRegexpOrNames = true,
}

local function regexMatcher(pattern: string?): Matcher
	local re = if pattern and pattern ~= "" then Regex.parseJs(pattern) else nil
	return function(field: Field, frame: Frame, frames: { Frame }): boolean
		return re ~= nil and (Regex.test(re, M.displayName(field, frame, frames)))
	end
end

local function namesMatcher(names: { string }): Matcher
	local set: { [string]: boolean } = {}
	for _, n in names do
		set[n] = true
	end
	return function(field: Field, frame: Frame, frames: { Frame }): boolean
		return set[M.displayName(field, frame, frames)] == true
	end
end

local function matcherFor(env: Env, raw: any): Matcher?
	local m = Json.tbl(env, raw)
	if m == nil then
		return nil
	end
	local id = Json.str(env, m.id)
	local options = if m.options == env.null then nil else m.options
	if id == "byName" then
		local name = Json.str(env, options)
		if name == nil then
			return nil
		end
		local n = name :: string
		return function(field: Field, frame: Frame, frames: { Frame }): boolean
			if n == field.name or n == M.displayName(field, frame, frames) then
				return true
			end
			-- fieldNameFallback: names saved before the dataplane rename.
			if n == "Value" then
				return field.labels ~= nil and field.labels.__name__ == field.name
			elseif n == "Time" or n == "time" then
				return field.type == "time" and (frame.meta == nil or frame.meta.type == nil)
			end
			return false
		end
	elseif id == "byRegexp" then
		return regexMatcher(Json.str(env, options))
	elseif id == "byFrameRefID" then
		local ref = Json.str(env, options)
		return function(_field: Field, frame: Frame): boolean
			return ref ~= nil and frame.refId == ref
		end
	elseif id == "byType" then
		local kind = Json.str(env, options)
		return function(field: Field): boolean
			return field.type == kind
		end
	elseif id == "byNames" then
		local o = Json.obj(env, options)
		local names: { string } = {}
		for _, n in Json.list(env, o.names) do
			if type(n) == "string" then
				table.insert(names, n)
			end
		end
		local inner = namesMatcher(names)
		if Json.str(env, o.mode) == "exclude" then
			return function(field: Field, frame: Frame, frames: { Frame }): boolean
				return not inner(field, frame, frames)
			end
		end
		return inner
	elseif id == "byRegexpOrNames" then
		local o = Json.obj(env, options)
		local names: { string } = {}
		for _, n in Json.list(env, o.names) do
			if type(n) == "string" then
				table.insert(names, n)
			end
		end
		local byNames = namesMatcher(names)
		local byRegex = regexMatcher(Json.str(env, o.pattern))
		return function(field: Field, frame: Frame, frames: { Frame }): boolean
			return byNames(field, frame, frames) or byRegex(field, frame, frames)
		end
	end
	return nil
end

M.matcherFor = matcherFor

-- Properties that change what a panel means and that the native renderers
-- cannot honor; any of them sends the panel down the ladder.
local function unsupportedProperty(env: Env, id: string, value: any): string?
	if id == "custom.transform" then
		local s = Json.str(env, value)
		if s == "negative-Y" or s == "constant" then
			return "custom.transform " .. s
		end
	elseif id == "custom.scaleDistribution" then
		local kind = Json.str(env, Json.path(env, value, "type"))
		if kind and kind ~= "linear" then
			return "custom.scaleDistribution " .. kind
		end
	end
	return nil
end

-- Why the panel's field config cannot be rendered natively, or nil.
function M.unsupported(panel: any, env: Env): string?
	local defaults = Json.obj(env, Json.path(env, panel, "fieldConfig", "defaults"))
	local custom = Json.obj(env, defaults.custom)
	for _, key in { "transform", "scaleDistribution" } do
		local why = unsupportedProperty(env, "custom." .. key, custom[key])
		if why then
			return "field config " .. why .. " is not supported"
		end
	end
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		local matcher = Json.tbl(env, Json.path(env, o, "matcher"))
		local id = if matcher then Json.str(env, matcher.id) else nil
		if id == nil or not MATCHERS[id] then
			return string.format("override matcher %s is not supported", tostring(id))
		end
		for _, p in Json.list(env, Json.path(env, o, "properties")) do
			local pid = Json.str(env, Json.path(env, p, "id"))
			local why = if pid then unsupportedProperty(env, pid, Json.path(env, p, "value")) else nil
			if why then
				return "override " .. why .. " is not supported"
			end
		end
	end
	return nil
end

-- Resolution ------------------------------------------------------------------

type Override = { match: Matcher, properties: { { id: string, value: any } } }

local function overridesOf(panel: any, env: Env): { Override }
	local out: { Override } = {}
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		local match = matcherFor(env, Json.path(env, o, "matcher"))
		if match then
			local props: { { id: string, value: any } } = {}
			for _, p in Json.list(env, Json.path(env, o, "properties")) do
				local id = Json.str(env, Json.path(env, p, "id"))
				if id then
					local pt = Json.obj(env, p)
					table.insert(props, { id = id, value = pt.value })
				end
			end
			table.insert(out, { match = match, properties = props })
		end
	end
	return out
end

-- findNumericFieldMinMax over every number field of every frame.
local function globalRange(frames: { Frame }): (number?, number?)
	local lo: number?, hi: number? = nil, nil
	for _, frame in frames do
		for _, field in frame.fields do
			if field.type == "number" then
				local c = Reduce.calcs(field.values, {}, "number")
				if c.min ~= nil and (lo == nil or c.min < lo) then
					lo = c.min
				end
				if c.max ~= nil and (hi == nil or c.max > hi) then
					hi = c.max
				end
			end
		end
	end
	return lo, hi
end

-- Every field of every frame with its resolved config, display name and
-- range: datasource config first, panel defaults fill what it leaves unset
-- (setFieldConfigDefaults), overrides apply in order. The panel's
-- displayName replaces the datasource's, as displayName outranks
-- displayNameFromDS in Grafana.
function M.resolve(panel: any, frames: { Frame }, env: Env, d: Defaults?): { Item }
	local base = M.defaults(panel, env, d)
	local overrides = overridesOf(panel, env)
	local items: { Item } = {}
	local seriesIndex = 0
	local gLo: number?, gHi: number?
	local gDone = false
	for fi, frame in frames do
		for xi, field in frame.fields do
			local cfg = cloneConfig(base)
			local ds = field.config
			if ds then
				cfg.unit = ds.unit or cfg.unit
				if ds.decimals ~= nil then
					cfg.decimals = ds.decimals
				end
				if ds.min ~= nil then
					cfg.min = ds.min
				end
				if ds.max ~= nil then
					cfg.max = ds.max
				end
				if ds.custom then
					for k, v in ds.custom do
						if cfg.custom[k] == nil then
							cfg.custom[k] = v
						end
					end
				end
			end
			for _, o in overrides do
				if o.match(field, frame, frames) then
					for _, p in o.properties do
						applyProperty(env, cfg, p.id, p.value)
					end
				end
			end
			local name = cfg.display_name or M.displayName(field, frame, frames)
			local lo, hi = cfg.min, cfg.max
			if field.type == "number" and (lo == nil or hi == nil) then
				if cfg.field_min_max then
					local c = Reduce.calcs(field.values, {}, "number")
					lo, hi = lo or c.min, hi or c.max
				else
					if not gDone then
						gLo, gHi = globalRange(frames)
						gDone = true
					end
					lo, hi = lo or gLo, hi or gHi
				end
			end
			if field.type ~= "time" then
				seriesIndex += 1
			end
			table.insert(items, {
				frame = frame,
				field = field,
				frame_index = fi,
				field_index = xi,
				name = name,
				config = cfg,
				series_index = seriesIndex,
				range_min = lo,
				range_max = hi,
			})
		end
	end
	return items
end

-- The field with the resolved display name and unit/decimals/min/max baked
-- into its config, for renderers that read Frame configs (lib/render).
function M.bake(item: Item): Field
	local f = table.clone(item.field)
	local c: Frame.FieldConfig = if f.config then table.clone(f.config) else {}
	c.displayName = item.name
	c.unit = item.config.unit
	c.decimals = item.config.decimals
	c.min = item.config.min
	c.max = item.config.max
	f.config = c
	return f
end

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
