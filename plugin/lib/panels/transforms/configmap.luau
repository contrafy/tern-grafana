--!strict
-- Field config from data: rowsToFields and configFromData
-- (public/app/features/transformers/rowsToFields/rowsToFields.ts,
-- configFromQuery/configFromQuery.ts, fieldToConfigMapping/
-- fieldToConfigMapping.ts). A field's display name, or its `mappings`
-- entry, picks a handler: field.name / field.value / field.label /
-- __ignore, or a config property (min, max, unit, decimals, displayName,
-- color, threshold1, mappings.value/color/text). Handler names match the
-- lower-cased display name automatically ("Unit", "Max").
--
-- rowsToFields: each row becomes a one-value field named by the name field
-- (first string field by default), valued by the value field (first number
-- field), configured by the row's other columns. configFromData: the frame
-- with refId `configRefId` is reduced (lastNotNull by default) into config
-- for the fields `applyTo` matches (number fields by default) of the other
-- frames.

local Json = require("../json")
local Frame = require("../../frame/types")
local Reducer = require("./reduce")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local MAX_DECIMALS = 15

type Context = { values: { any }?, colors: { any }?, texts: { any }? }
type Handler = {
	key: string,
	target: string?,
	defaultReducer: string?,
	process: ((any, { [string]: any }, Context, any) -> any)?,
}

-- anyToNumber.
local function anyToNumber(v: any): number
	if type(v) == "number" then
		return v
	elseif type(v) == "string" then
		local n = tonumber((string.match(v, "^%s*(.-)%s*$")))
		return if n then n else 0 / 0
	elseif type(v) == "boolean" then
		return if v then 1 else 0
	end
	return 0 / 0
end

local function numericOrNil(v: any): any
	local n = anyToNumber(v)
	return if n == n then n else nil
end

-- CSS named colors (what tinycolor resolves a non-palette name to).
local CSS_COLORS: { [string]: boolean } = {}
for name in
	string.gmatch(
		"aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown "
			.. "burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan "
			.. "darkgoldenrod darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid "
			.. "darkred darksalmon darkseagreen darkslateblue darkslategray darkslategrey darkturquoise darkviolet "
			.. "deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro "
			.. "ghostwhite gold goldenrod gray green greenyellow grey honeydew hotpink indianred indigo ivory khaki "
			.. "lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow "
			.. "lightgray lightgreen lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray "
			.. "lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine "
			.. "mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen "
			.. "mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace "
			.. "olive olivedrab orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred "
			.. "papayawhip peachpuff peru pink plum powderblue purple rebeccapurple red rosybrown royalblue "
			.. "saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray slategrey "
			.. "snow springgreen steelblue tan teal thistle tomato turquoise violet wheat white whitesmoke yellow "
			.. "yellowgreen transparent text",
		"%S+"
	)
do
	CSS_COLORS[name] = true
end
for _, hue in { "red", "orange", "yellow", "green", "blue", "purple" } do
	for _, shade in { "super-light-", "light-", "semi-dark-", "dark-" } do
		CSS_COLORS[shade .. hue] = true
	end
end

-- toFixedColorOrUndefined: a palette or CSS color name, #hex, or
-- rgb()/rgba()/hsl()/hsla() with numeric channels; anything the panel would
-- fail to resolve is skipped.
local function fixedColor(v: any): any
	if type(v) ~= "string" then
		return nil
	end
	local s = string.lower(v)
	local ok = string.match(s, "^#%x%x%x%x?$") ~= nil
		or string.match(s, "^#%x%x%x%x%x%x$") ~= nil
		or string.match(s, "^#%x%x%x%x%x%x%x%x$") ~= nil
		or string.match(s, "^rgba?%(%s*[%d%.]+%s*,%s*[%d%.]+%s*,%s*[%d%.]+%s*,?%s*[%d%.]*%s*%)$") ~= nil
		or string.match(s, "^hsla?%(%s*[%d%.]+%s*,%s*[%d%.]+%%%s*,%s*[%d%.]+%%%s*,?%s*[%d%.]*%s*%)$") ~= nil
		or CSS_COLORS[s] == true
	if not ok then
		return nil
	end
	return { fixedColor = v, mode = "fixed" }
end

local function text(v: any): string
	return Shared.jsString(v)
end

local HANDLERS: { Handler } = {
	{ key = "field.name" },
	{ key = "field.value" },
	{ key = "field.label" },
	{ key = "__ignore" },
	{ key = "max", process = numericOrNil },
	{ key = "min", process = numericOrNil },
	{ key = "unit", process = text },
	{
		key = "decimals",
		process = function(v: any): any
			local n = anyToNumber(v)
			if n ~= n or n % 1 ~= 0 or n < 0 or n > MAX_DECIMALS then
				return nil
			end
			return n
		end,
	},
	{ key = "displayName", process = text },
	{ key = "color", process = fixedColor },
	{
		key = "threshold1",
		target = "thresholds",
		process = function(v: any, config: { [string]: any }, _ctx: Context, args: any): any
			local n = anyToNumber(v)
			if n ~= n then
				return nil
			end
			if config.thresholds == nil then
				config.thresholds = { mode = "absolute", steps = {} }
			end
			local color = if type(args) == "table" and type(args.threshold) == "table"
				then args.threshold.color
				else nil
			table.insert(
				config.thresholds.steps,
				{ value = n, color = if type(color) == "string" then color else "red" }
			)
			return config.thresholds
		end,
	},
	{
		key = "mappings.value",
		target = "mappings",
		defaultReducer = "allValues",
		process = function(v: any, config: { [string]: any }, ctx: Context): any
			if type(v) ~= "table" then
				return nil
			end
			ctx.values = v
			return config.mappings
		end,
	},
	{
		key = "mappings.color",
		target = "mappings",
		defaultReducer = "allValues",
		process = function(v: any, config: { [string]: any }, ctx: Context): any
			if type(v) ~= "table" then
				return nil
			end
			ctx.colors = v
			return config.mappings
		end,
	},
	{
		key = "mappings.text",
		target = "mappings",
		defaultReducer = "allValues",
		process = function(v: any, config: { [string]: any }, ctx: Context): any
			if type(v) ~= "table" then
				return nil
			end
			ctx.texts = v
			return config.mappings
		end,
	},
}

local INDEX: { [string]: Handler } = {}
for _, h in HANDLERS do
	INDEX[h.key] = h
end

local function handlerFor(key: any): Handler?
	if type(key) ~= "string" or key == "" then
		return nil
	end
	return INDEX[key]
end

type Mapping = { fieldName: any, reducerId: string?, handlerKey: any, handlerArguments: any }
type Evaluated = { handler: Handler?, args: any, reducer: string }
type Result = { index: { [string]: Evaluated }, nameField: Field?, valueField: Field? }

local function mappingsOf(env: any, options: any): { Mapping }
	local out: { Mapping } = {}
	for _, m in Json.list(env, Json.path(env, options, "mappings")) do
		local t = Json.tbl(env, m)
		if t then
			local key = t.handlerKey
			table.insert(out, {
				fieldName = t.fieldName,
				reducerId = Json.str(env, t.reducerId),
				handlerKey = if key == env.null then nil else key,
				handlerArguments = Json.tbl(env, t.handlerArguments),
			})
		end
	end
	return out
end

-- evaluateFieldMappings.
local function evaluate(frame: Frame, mappings: { Mapping }, withNameAndValue: boolean): Result
	local result: Result = { index = {} }
	local nameMapping, valueMapping = false, false
	for _, m in mappings do
		if m.handlerKey == "field.name" then
			nameMapping = true
		elseif m.handlerKey == "field.value" then
			valueMapping = true
		end
	end
	for _, field in frame.fields do
		local name = Shared.displayName(field, frame)
		local mapping: Mapping? = nil
		for _, m in mappings do
			if m.fieldName == name then
				mapping = m
				break
			end
		end
		local key = if mapping then mapping.handlerKey else string.lower(name)
		local handler = handlerFor(key)
		if withNameAndValue then
			if handler then
				if handler.key == "field.name" then
					result.nameField = field
				end
				if handler.key == "field.value" then
					result.valueField = field
				end
			elseif mapping == nil then
				if result.nameField == nil and not nameMapping and field.type == "string" then
					result.nameField = field
					handler = INDEX["field.name"]
				end
				if result.valueField == nil and not valueMapping and field.type == "number" then
					result.valueField = field
					handler = INDEX["field.value"]
				end
			end
		end
		if handler == nil and withNameAndValue then
			handler = INDEX["field.label"]
		end
		result.index[name] = {
			handler = handler,
			args = if mapping then mapping.handlerArguments else nil,
			reducer = (if mapping then mapping.reducerId else nil)
				or (if handler then handler.defaultReducer else nil)
				or "lastNotNull",
		}
	end
	return result
end

local function combineMappings(ctx: Context): { any }
	local values = ctx.values
	if values == nil then
		return {}
	end
	local options: { [string]: any } = {}
	for i, v in values do
		if not Shared.nullish(v) then
			options[Shared.jsString(v)] = {
				color = if ctx.colors then ctx.colors[i] else nil,
				text = if ctx.texts then ctx.texts[i] else nil,
				index = i - 1,
			}
		end
	end
	return { { type = "value", options = options } }
end

-- getFieldConfigFromFrame: the config the row's handled fields produce.
local function configFromRow(frame: Frame, row: number, result: Result): { [string]: any }
	local config: { [string]: any } = {}
	local ctx: Context = {}
	for _, field in frame.fields do
		local e = result.index[Shared.displayName(field, frame)]
		local handler = if e then e.handler else nil
		if handler == nil or handler.process == nil then
			continue
		end
		local v = field.values[row]
		if Shared.nullish(v) then
			continue
		end
		local process = handler.process :: (any, { [string]: any }, Context, any) -> any
		local out = process(v, config, ctx, if e then e.args else nil)
		if out ~= nil then
			config[handler.target or handler.key] = out
		end
	end
	if ctx.values then
		config.mappings = combineMappings(ctx)
	end
	if config.thresholds then
		-- sortThresholds: ascending, a step without value (-Infinity) first.
		table.sort(config.thresholds.steps, function(a: any, b: any): boolean
			local x = if a.value == nil then -math.huge else a.value
			local y = if b.value == nil then -math.huge else b.value
			return x < y
		end)
	end
	return config
end

-- Frame field config from a handler config (keys outside the Frame model
-- are dropped).
local KEYS: { string } = { "unit", "displayName", "decimals", "min", "max", "thresholds", "mappings", "color" }

local function merged(base: Frame.FieldConfig?, config: { [string]: any }): Frame.FieldConfig
	local out: { [string]: any } = if base then Tbl.copy(base) :: any else {}
	for _, k in KEYS do
		if config[k] ~= nil then
			out[k] = config[k]
		end
	end
	return out :: Frame.FieldConfig
end

local function rowLabels(frame: Frame, row: number, result: Result): { [string]: string }
	local labels: { [string]: string } = {}
	local nf = result.nameField
	if nf and nf.labels then
		for k, v in nf.labels do
			labels[k] = v
		end
	end
	for _, field in frame.fields do
		local name = Shared.displayName(field, frame)
		local e = result.index[name]
		if e and e.handler and e.handler.key ~= "field.label" then
			continue
		end
		local v = field.values[row]
		if not Shared.nullish(v) then
			labels[name] = Shared.jsString(v)
		end
	end
	return labels
end

local function reducersOk(env: any, options: any): string?
	for _, m in mappingsOf(env, options) do
		if m.reducerId and not Reducer.supports(m.reducerId) then
			return "reducer " .. m.reducerId
		end
	end
	return nil
end

function M.rowsToFieldsUnsupported(options: any, ctx: Ctx): string?
	return reducersOk(ctx.env, options)
end

function M.rowsToFields(frames: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local mappings = mappingsOf(env, options)
	local out: { Frame } = {}
	for _, frame in frames do
		local result = evaluate(frame, mappings, true)
		local nf, vf = result.nameField, result.valueField
		if nf == nil or vf == nil then
			table.insert(out, frame)
			continue
		end
		local fields: { Field } = {}
		for row = 1, #nf.values do
			local config = merged(nil, configFromRow(frame, row, result))
			local v = vf.values[row]
			table.insert(
				fields,
				Frame.field(
					Shared.jsString(nf.values[row]),
					vf.type,
					{ if v == nil then Shared.GAP else v },
					rowLabels(frame, row, result),
					config
				)
			)
		end
		table.insert(out, { fields = fields, refId = "rowsToFields-" .. Shared.jsString(frame.refId) })
	end
	return out
end

function M.configFromDataUnsupported(options: any, ctx: Ctx): string?
	local env = ctx.env
	local applyTo = Json.path(env, options, "applyTo")
	if applyTo ~= nil and not Shared.knownMatcher(env, applyTo) then
		return "applyTo matcher " .. tostring(Json.path(env, applyTo, "id"))
	end
	return reducersOk(env, options)
end

function M.configFromData(data: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local configRefId = Json.path(env, options, "configRefId")
	if configRefId == nil then
		configRefId = "config"
	end
	local configFrame: Frame? = nil
	for _, f in data do
		if f.refId == configRefId then
			configFrame = f
			break
		end
	end
	if configFrame == nil then
		return data
	end
	local cf = configFrame :: Frame
	local result = evaluate(cf, mappingsOf(env, options), false)
	local reduced: Frame = { fields = {} }
	for _, field in cf.fields do
		local e = result.index[Shared.displayName(field, cf)]
		local id = if e then e.reducer else "lastNotNull"
		local v = Reducer.reduceField(field, { id })[id]
		table.insert(reduced.fields, Shared.withValues(field, { if v == nil then Frame.NULL else v }))
	end
	local applyTo = Json.path(env, options, "applyTo")
	local matcher: Shared.FieldMatcher = (if applyTo ~= nil then Shared.fieldMatcher(env, applyTo) else nil)
		or Shared.numeric
	local out: { Frame } = {}
	for _, frame in data do
		if frame == cf and #data > 1 then
			continue
		end
		local fields: { Field } = {}
		for _, field in frame.fields do
			if matcher(field, frame, data) then
				local copy = Tbl.copy(field)
				copy.config = merged(field.config, configFromRow(reduced, 1, result))
				table.insert(fields, copy)
			else
				table.insert(fields, field)
			end
		end
		table.insert(out, Shared.withFields(frame, fields))
	end
	return out
end

return M
