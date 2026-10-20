--!strict
-- reduce: packages/grafana-data/src/transformations/transformers/reduce.ts.
-- seriesToRows (default): one row per matched field, a "Field" name column
-- (or the field name plus one column per label with `labelsToFields`) and a
-- column per reducer, every frame merged into one. reduceFields: each frame
-- keeps its fields, reduced to one value per reducer (a `reducer` label
-- tells several apart). Time fields are skipped unless `fields` matches them
-- or `includeTimeField` is set in reduceFields mode. Reducers are
-- lib/panels/reduce's plus allValues and uniqueValues; nulls are ignored, as
-- reduceField defaults nullValueMode to "connected".

local Json = require("../json")
local Frame = require("../../frame/types")
local Reduce = require("../reduce")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local NAN = 0 / 0

local ARRAY_REDUCERS: { [string]: string } = { allValues = "All values", uniqueValues = "All unique values" }

function M.supports(id: string): boolean
	return Reduce.supports(id) or ARRAY_REDUCERS[id] ~= nil
end

function M.name(id: string): string
	return ARRAY_REDUCERS[id] or Reduce.name(id)
end

-- reduceField: every reducer's value, nil for null.
function M.reduceField(field: Field, ids: { string }): { [string]: any }
	local out: { [string]: any } = {}
	local values = Shared.storedColumn(field.values)
	local standard: { string } = {}
	for _, id in ids do
		if id == "allValues" then
			out[id] = table.clone(values)
		elseif id == "uniqueValues" then
			local seen: { [any]: boolean } = {}
			local list: { any } = {}
			for _, v in values do
				if not seen[v] then
					seen[v] = true
					table.insert(list, v)
				end
			end
			out[id] = list
		else
			table.insert(standard, id)
		end
	end
	if #standard > 0 then
		local calcs = Reduce.calcs(values, standard, field.type, "connected")
		for _, id in standard do
			out[id] = calcs[id]
		end
	end
	return out
end

-- guessFieldTypeForField.
local function guessType(field: Field): Frame.FieldType?
	local lower = string.lower(field.name)
	if lower == "date" or lower == "time" then
		return "time"
	end
	for _, v in field.values do
		if not Shared.nullish(v) then
			local t = type(v)
			if t == "number" then
				return "number"
			elseif t == "string" then
				if tonumber(v) ~= nil and string.match(v, "^%s*[+-]?[%d.]") then
					return "number"
				end
				if v == "true" or v == "TRUE" or v == "True" or v == "false" or v == "FALSE" or v == "False" then
					return "boolean"
				end
				return "string"
			elseif t == "boolean" then
				return "boolean"
			end
			return "other"
		end
	end
	return nil
end

local function reducersOf(env: any, options: any): { string }
	local out: { string } = {}
	for _, id in Json.list(env, Json.path(env, options, "reducers")) do
		if type(id) == "string" and M.supports(id) then
			table.insert(out, id)
		end
	end
	return out
end

function M.unsupported(options: any, ctx: Ctx): string?
	local env = ctx.env
	for _, id in Json.list(env, Json.path(env, options, "reducers")) do
		if type(id) ~= "string" or not M.supports(id) then
			return "reducer " .. tostring(id)
		end
	end
	local fields = Json.path(env, options, "fields")
	if fields ~= nil and not Shared.knownMatcher(env, fields) then
		return "field matcher " .. tostring(Json.path(env, fields, "id"))
	end
	return nil
end

local function seriesToRows(
	data: { Frame },
	matcher: Shared.FieldMatcher,
	ids: { string },
	labelsToFields: boolean
): Frame?
	local labelKeys: { string } = {}
	if labelsToFields then
		local seen: { [string]: boolean } = {}
		for _, frame in data do
			for _, field in frame.fields do
				if field.labels then
					local keys: { string } = {}
					for k in field.labels do
						table.insert(keys, k)
					end
					table.sort(keys)
					for _, k in keys do
						if not seen[k] then
							seen[k] = true
							table.insert(labelKeys, k)
						end
					end
				end
			end
		end
	end
	local processed: { Frame } = {}
	for _, series in data do
		local source: { Field } = {}
		for _, f in series.fields do
			if matcher(f, series, data) then
				table.insert(source, f)
			end
		end
		local size = #source
		local names: { any } = table.create(size)
		local fields: { Field } = { Frame.field("Field", "string", names, nil, {}) }
		local labelCols: { [string]: { any } } = {}
		for _, key in labelKeys do
			local col: { any } = table.create(size, Shared.GAP)
			labelCols[key] = col
			table.insert(fields, Frame.field(key, "string", col, nil, {}))
		end
		local calcs: { [string]: { any } } = {}
		for _, id in ids do
			calcs[id] = table.create(size)
			table.insert(fields, Frame.field(M.name(id), "other", calcs[id], nil, {}))
		end
		for i, field in source do
			local results = M.reduceField(field, ids)
			if labelsToFields then
				names[i] = field.name
				if field.labels then
					for k, v in field.labels do
						labelCols[k][i] = v
					end
				end
			else
				names[i] = Shared.displayName(field, series, data)
			end
			for _, id in ids do
				local v = results[id]
				-- NaN keeps the row index where null would shift it.
				calcs[id][i] = if v == nil then NAN else v
			end
		end
		for _, f in fields do
			if f.type == "other" then
				local t = guessType(f)
				if t then
					f.type = t :: Frame.FieldType
				end
			end
		end
		local copy = Tbl.copy(series)
		copy.fields = fields
		table.insert(processed, copy)
	end
	-- mergeResults.
	local base = processed[1]
	if base == nil then
		return nil
	end
	for s = 2, #processed do
		local series = processed[s]
		for bi, baseField in base.fields do
			for fi, field in series.fields do
				local isFirst = bi == 1 and fi == 1
				local isSame = baseField.type == field.type and baseField.name == field.name
				if isFirst or isSame then
					local merged = table.clone(baseField.values)
					for _, v in field.values do
						table.insert(merged, v)
					end
					baseField.values = merged
				end
			end
		end
	end
	base.name = nil
	return base
end

local function fieldType(id: string, field: Field): Frame.FieldType
	if id == "allValues" or id == "uniqueValues" then
		return "other"
	elseif id == "first" or id == "firstNotNull" or id == "last" or id == "lastNotNull" then
		return field.type
	end
	return "number"
end

local function reduceFields(data: { Frame }, matcher: Shared.FieldMatcher, ids: { string }): { Frame }
	local out: { Frame } = {}
	for _, series in data do
		local fields: { Field } = {}
		for _, field in series.fields do
			if matcher(field, series, data) then
				local results = M.reduceField(field, ids)
				for _, id in ids do
					local copy = Tbl.copy(field)
					local labels: { [string]: string } = if field.labels then Tbl.copy(field.labels) else {}
					if #ids > 1 then
						labels.reducer = M.name(id)
					end
					copy.labels = labels
					copy.type = fieldType(id, field)
					local v = results[id]
					copy.values = { if v == nil then Frame.NULL else v }
					table.insert(fields, copy)
				end
			end
		end
		if #fields > 0 then
			table.insert(out, Shared.withFields(series, fields))
		end
	end
	return out
end

function M.apply(data: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local refId = Json.str(env, Json.path(env, options, "refId"))
	local ids = reducersOf(env, options)
	if #ids == 0 then
		return Shared.staticRefId(data, refId)
	end
	local mode = Json.str(env, Json.path(env, options, "mode"))
	local fieldsCfg = Json.path(env, options, "fields")
	local matcher: Shared.FieldMatcher
	if fieldsCfg ~= nil then
		matcher = Shared.fieldMatcher(env, fieldsCfg) or function(): boolean
			return false
		end
	elseif Json.bool(env, Json.path(env, options, "includeTimeField")) == true and mode == "reduceFields" then
		matcher = function(): boolean
			return true
		end
	else
		matcher = Shared.notTime
	end
	if mode == "reduceFields" then
		return reduceFields(data, matcher, ids)
	end
	local res = seriesToRows(data, matcher, ids, Json.bool(env, Json.path(env, options, "labelsToFields")) == true)
	if res == nil then
		return {}
	end
	res.refId = refId or Shared.dynamicRefId("reduce", data)
	return { res }
end

return M
