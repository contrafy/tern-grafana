--!strict
-- Grafana field configuration for panels: panel `fieldConfig.defaults` and
-- `overrides` resolved per field (packages/grafana-data/src/field/
-- fieldOverrides.ts applyFieldOverrides), field display names
-- (field/fieldState.ts calculateFieldDisplayName), override matchers
-- (transformations/matchers/nameMatcher.ts, fieldTypeMatcher.ts,
-- refIdMatcher.ts, fieldValueMatcher.ts with compareValues.ts) and the
-- display processor that turns one value into
-- text and a color (field/displayProcessor.ts, field/scale.ts,
-- field/fieldColor.ts).
--
-- Colors end as Tern tones (lib/units/thresholds tone table): Tern paints
-- with theme variables, so a threshold step's severity survives a theme
-- switch where its exact hue would not.

local Env = require("../env")
local FieldDisplay = require("./fielddisplay")
local FieldMatch = require("./fieldmatch")
local FieldName = require("./fieldname")
local Frame = require("../frame/types")
local Json = require("./json")
local Mappings = require("./mappings")
local Reduce = require("./reduce")
local Thresholds = require("../units/thresholds")
local Tbl = require("../tbl")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field

-- Names, matchers and the display processor live in fieldname, fieldmatch
-- and fielddisplay; this module's API keeps them.
export type Config = FieldDisplay.Config
export type Item = FieldDisplay.Item
export type Display = FieldDisplay.Display
export type Options = FieldDisplay.Options
export type Defaults = FieldDisplay.Defaults
export type Scale = FieldDisplay.Scale

local M = {}

-- Grafana's standard thresholds default (OptionsUI/registry.tsx).
function M.defaultThresholds(): Thresholds.Thresholds
	return { mode = "absolute", steps = { { color = "green" }, { color = "red", value = 80 } } }
end

M.PALETTE = FieldDisplay.PALETTE

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
	local out = Tbl.copy(c)
	out.custom = Tbl.copy(c.custom)
	return out
end
M.displayName = FieldName.displayName
M.withVariables = FieldName.withVariables
M.compareValues = FieldMatch.compareValues
M.matcherFor = FieldMatch.matcherFor
M.paletteClass = FieldDisplay.paletteClass
M.display = FieldDisplay.display
M.seriesColor = FieldDisplay.seriesColor
M.joined = FieldDisplay.joined
M.hidden = FieldDisplay.hidden

-- Panel types whose renderer honors custom.transform (negative-Y, constant)
-- and log/symlog scaleDistribution (lib/render/svg_timeseries).
local GRAPH_NATIVE: { [string]: boolean } = { timeseries = true }

-- Properties that change what a panel means and that the native renderers
-- cannot honor; any of them sends the panel down the ladder.
local function unsupportedProperty(env: Env, id: string, value: any, graph: boolean): string?
	if id == "custom.transform" then
		local s = Json.str(env, value)
		if not graph and (s == "negative-Y" or s == "constant") then
			return "custom.transform " .. s
		end
	elseif id == "custom.scaleDistribution" then
		local kind = Json.str(env, Json.path(env, value, "type"))
		if kind and kind ~= "linear" and not (graph and (kind == "log" or kind == "symlog")) then
			return "custom.scaleDistribution " .. kind
		end
	end
	return nil
end

-- Why the panel's field config cannot be rendered natively, or nil.
function M.unsupported(panel: any, env: Env): string?
	local graph = GRAPH_NATIVE[Json.str(env, Json.path(env, panel, "type")) or ""] == true
	local defaults = Json.obj(env, Json.path(env, panel, "fieldConfig", "defaults"))
	local custom = Json.obj(env, defaults.custom)
	for _, key in { "transform", "scaleDistribution" } do
		local why = unsupportedProperty(env, "custom." .. key, custom[key], graph)
		if why then
			return "field config " .. why .. " is not supported"
		end
	end
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		local matcher = Json.tbl(env, Json.path(env, o, "matcher"))
		local id = if matcher then Json.str(env, matcher.id) else nil
		if id == nil or not FieldMatch.MATCHERS[id] then
			return string.format("override matcher %s is not supported", tostring(id))
		end
		if id == "byValue" then
			local reducer = Json.str(env, Json.path(env, matcher, "options", "reducer"))
			if reducer and reducer ~= "" and not Reduce.supports(reducer) then
				return string.format("override matcher byValue reducer %s is not supported", reducer)
			end
		end
		for _, p in Json.list(env, Json.path(env, o, "properties")) do
			local pid = Json.str(env, Json.path(env, p, "id"))
			local why = if pid then unsupportedProperty(env, pid, Json.path(env, p, "value"), graph) else nil
			if why then
				return "override " .. why .. " is not supported"
			end
		end
	end
	return nil
end

-- Resolution ------------------------------------------------------------------

type Override = { match: FieldMatch.Matcher, properties: { { id: string, value: any } } }

local function overridesOf(panel: any, env: Env): { Override }
	local out: { Override } = {}
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		local match = FieldMatch.matcherFor(env, Json.path(env, o, "matcher"))
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
				local min, max = Reduce.minMax(field.values)
				if min ~= nil and (lo == nil or min < lo) then
					lo = min
				end
				if max ~= nil and (hi == nil or max > hi) then
					hi = max
				end
			end
		end
	end
	return lo, hi
end

-- Whether a datasource field config sets anything resolve copies.
local function dsTouches(ds: Frame.FieldConfig): boolean
	return ds.unit ~= nil
		or ds.decimals ~= nil
		or ds.min ~= nil
		or ds.max ~= nil
		or ds.custom ~= nil
		or ds.thresholds ~= nil
		or ds.mappings ~= nil
		or ds.color ~= nil
end

local function resolveAll(
	env: Env,
	base: Config,
	overrides: { Override },
	frames: { Frame },
	items: { Item },
	firstOnly: boolean
)
	local seriesIndex = 0
	local gLo: number?, gHi: number?
	local gDone = false
	for fi, frame in frames do
		if firstOnly and fi > 1 then
			break
		end
		for xi, field in frame.fields do
			-- Fields nothing changes share the panel defaults (Items are read
			-- only); a copy is made before the first write.
			local cfg = base
			local ds = field.config
			if ds and dsTouches(ds) then
				cfg = cloneConfig(base)
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
				if ds.thresholds ~= nil then
					applyProperty(env, cfg, "thresholds", ds.thresholds)
				end
				if ds.mappings ~= nil then
					applyProperty(env, cfg, "mappings", ds.mappings)
				end
				if ds.color ~= nil then
					applyProperty(env, cfg, "color", ds.color)
				end
			end
			for _, o in overrides do
				if o.match(field, frame, frames) then
					if cfg == base then
						cfg = cloneConfig(base)
					end
					for _, p in o.properties do
						applyProperty(env, cfg, p.id, p.value)
					end
				end
			end
			local scoped = if cfg.display_name
				then FieldName.scoped(cfg.display_name, field, frame, fi, frames)
				else nil
			local name: string = scoped or M.displayName(field, frame, frames)
			local lo, hi = cfg.min, cfg.max
			if field.type == "number" and (lo == nil or hi == nil) then
				if cfg.field_min_max then
					local min, max = Reduce.minMax(field.values)
					lo, hi = lo or min, hi or max
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
end

-- Every field of every frame with its resolved config, display name and
-- range: datasource config first, panel defaults fill what it leaves unset
-- (setFieldConfigDefaults), overrides apply in order. The panel's
-- displayName replaces the datasource's, as displayName outranks
-- displayNameFromDS in Grafana. `firstOnly` returns the first frame's items
-- only (names and ranges still see every frame).
function M.resolve(panel: any, frames: { Frame }, env: Env, d: Defaults?, firstOnly: boolean?): { Item }
	local base = M.defaults(panel, env, d)
	local overrides = overridesOf(panel, env)
	local items: { Item } = {}
	FieldName.within(frames, resolveAll :: any, env, base, overrides, frames, items, firstOnly == true)
	return items
end

-- The field with the resolved display name and unit/decimals/min/max baked
-- into its config, for renderers that read Frame configs (lib/render).
function M.bake(item: Item): Field
	local f = Tbl.copy(item.field)
	local c: Frame.FieldConfig = if f.config then Tbl.copy(f.config) else {}
	c.displayName = item.name
	c.unit = item.config.unit
	c.decimals = item.config.decimals
	c.min = item.config.min
	c.max = item.config.max
	f.config = c
	return f
end

return M
