--!strict
-- groupBy: packages/grafana-data/src/transformations/transformers/groupBy.ts
-- (https://raw.githubusercontent.com/grafana/grafana/main/packages/
-- grafana-data/src/transformations/transformers/groupBy.ts). `fields` maps a
-- field's display name (or, failing that, its name) to an operation:
-- "groupby" fields become the key columns, one row per distinct key in
-- first-seen order; "aggregate" fields get a `<display name> (<reducer id>)`
-- column per reducer, computed over each group's values. A "groupby" field
-- whose only aggregation is count also gets its count column. Frames without
-- a "groupby" field leave the output; with no "groupby" field at all the
-- frames pass through untouched.
--
-- Grafana quirks kept on purpose:
-- - the group key is String([values...]): values joined with "," (null and
--   undefined as ""), so ("a,b", "c") and ("a", "b,c") are one group;
-- - fields are keyed by getFieldDisplayName(field) without the frame, so two
--   fields sharing a display name pool their values;
-- - the key columns keep name, type and config but lose their labels; the
--   aggregate columns get an empty config (no unit) and the reducer's type
--   (getFieldTypeForReducer: counts are numbers, allIsNull/allIsZero
--   booleans, anything else the source field's type);
-- - the output frame carries only the refId (no name, no meta).

local Env = require("../../env")
local FieldConfig = require("../fieldconfig")
local Frame = require("../../frame/types")
local Json = require("../json")
local ReduceT = require("./reduce")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local GROUP_BY = "groupby"
local AGGREGATE = "aggregate"

local NUMBER_REDUCERS: { [string]: boolean } =
	{ count = true, distinctCount = true, changeCount = true, countAll = true }

-- getFieldTypeForReducer.
local function reducerType(id: string, fallback: Frame.FieldType): Frame.FieldType
	if NUMBER_REDUCERS[id] then
		return "number"
	elseif id == "allIsNull" or id == "allIsZero" then
		return "boolean"
	end
	return fallback
end

-- getFieldDisplayName(field), no frame: what groupBy keys fields by.
local function nameOf(field: Field): string
	return FieldConfig.displayName(field)
end

-- `options.fields[displayName] ?? options.fields[field.name]`.
local function configOf(fields: { [any]: any }, field: Field): any
	local cfg = fields[nameOf(field)]
	if cfg == nil then
		cfg = fields[field.name]
	end
	return cfg
end

-- shouldCalculateField: the aggregations to compute for the field, or nil.
local function aggregationsOf(env: Env, fields: { [any]: any }, field: Field): { string }?
	local cfg = configOf(fields, field)
	local operation = Json.str(env, Json.path(env, cfg, "operation"))
	local raw = Json.path(env, cfg, "aggregations")
	local aggregations: { string } = {}
	if raw ~= nil then
		local list = Json.tbl(env, raw)
		if list == nil or (#list == 0 and next(list) ~= nil) then
			return nil
		end
		for _, id in list do
			if type(id) == "string" then
				table.insert(aggregations, id)
			end
		end
	end
	if operation == AGGREGATE then
		return if #aggregations > 0 then aggregations else nil
	elseif operation == GROUP_BY then
		return if #aggregations == 1 and aggregations[1] == "count" then aggregations else nil
	end
	return nil
end

function M.unsupported(options: any, ctx: Ctx): string?
	local env = ctx.env
	for _, cfg in Json.obj(env, Json.path(env, options, "fields")) do
		for _, id in Json.list(env, Json.path(env, cfg, "aggregations")) do
			if type(id) ~= "string" then
				return "aggregation " .. tostring(id)
			end
		end
	end
	return nil
end

-- One group's values per display name, with the first such field's type.
type Column = { type: Frame.FieldType, values: { any } }
type Group = { [string]: Column }

-- String([v1, v2, ...]).
local function groupKey(keyFields: { Field }, row: number): string
	local parts: { string } = table.create(#keyFields)
	for i, f in keyFields do
		local v = f.values[row]
		parts[i] = if Shared.nullish(v) then "" else Shared.jsString(v)
	end
	return table.concat(parts, ",")
end

local function groupFrame(frame: Frame, keyFields: { Field }, fields: { [any]: any }, env: Env): Frame
	-- groupValuesByKey.
	local order: { Group } = {}
	local byKey: { [string]: Group } = {}
	local names: { string } = table.create(#frame.fields)
	for i, field in frame.fields do
		names[i] = nameOf(field)
	end
	for row = 1, Shared.length(frame) do
		local key = groupKey(keyFields, row)
		local group = byKey[key]
		if group == nil then
			group = {}
			byKey[key] = group
			table.insert(order, group)
		end
		for i, field in frame.fields do
			local name = names[i]
			local col = group[name]
			if col == nil then
				col = { type = field.type, values = {} }
				group[name] = col
			end
			local v = field.values[row]
			table.insert(col.values, if v == nil then Shared.GAP else v)
		end
	end
	-- createGroupedFields.
	local out: { Field } = {}
	for _, field in keyFields do
		local name = nameOf(field)
		local values: { any } = table.create(#order)
		for g, group in order do
			values[g] = group[name].values[1]
		end
		table.insert(
			out,
			Frame.field(field.name, field.type, values, nil, if field.config then Tbl.copy(field.config) else {})
		)
	end
	for _, field in frame.fields do
		local aggregations = aggregationsOf(env, fields, field)
		if aggregations == nil then
			continue
		end
		local name = nameOf(field)
		local byAggregation: { [string]: { any } } = {}
		for _, id in aggregations do
			byAggregation[id] = {}
		end
		for _, group in order do
			local col = group[name]
			local results = ReduceT.reduceField(Frame.field(field.name, col.type, col.values), aggregations)
			for _, id in aggregations do
				local list = byAggregation[id]
				local v = results[id]
				list[#list + 1] = if v == nil then Frame.NULL else v
			end
		end
		for _, id in aggregations do
			table.insert(
				out,
				Frame.field(name .. " (" .. id .. ")", reducerType(id, field.type), byAggregation[id], nil, {})
			)
		end
	end
	return { refId = frame.refId, fields = out }
end

function M.apply(data: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local fields = Json.obj(env, Json.path(env, options, "fields"))
	local keyNames: { string } = {}
	for k, cfg in fields do
		if type(k) == "string" and Json.str(env, Json.path(env, cfg, "operation")) == GROUP_BY then
			table.insert(keyNames, k)
		end
	end
	if #keyNames == 0 then
		return data
	end
	local matcher = Shared.byNames(env, keyNames)
	local out: { Frame } = {}
	for _, frame in data do
		local keyFields: { Field } = {}
		for _, field in frame.fields do
			if matcher(field, frame, data) then
				table.insert(keyFields, field)
			end
		end
		if #keyFields > 0 then
			table.insert(out, groupFrame(frame, keyFields, fields, env))
		end
	end
	return out
end

return M
