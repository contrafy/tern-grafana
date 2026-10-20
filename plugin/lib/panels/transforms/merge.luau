--!strict
-- merge ("Merge series/tables"): packages/grafana-data/src/transformations/
-- transformers/merge.ts. Fields are united by name; rows whose values of the
-- fields every frame has (the key) agree, and whose other values do not
-- conflict, become one row. A single frame passes through.

local Json = require("../json")
local Frame = require("../../frame/types")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local GAP = Shared.GAP

function M.unsupported(_options: any, _ctx: Ctx): string?
	return nil
end

-- copyFieldStructure: no values, labels or display name.
local function structure(field: Field, position: number): Field
	local config: Frame.FieldConfig = if field.config then Tbl.copy(field.config) else {}
	config.displayName = nil
	local copy = Tbl.copy(field)
	copy.values = {}
	copy.labels = nil
	copy.config = config
	if copy.name == "" then
		copy.name = "Field " .. position
	end
	return copy
end

type Row = { [string]: any }

-- isMergable: no property both rows set (non-null) to different values.
local function mergeable(existing: Row, value: Row): boolean
	for prop, v in value do
		local e = existing[prop]
		if e == nil or e == GAP or e == Frame.NULL then
			continue
		end
		if e ~= v then
			return false
		end
	end
	return true
end

-- MutableDataFrame.add: a string reaching a typed field is parsed.
local function parsed(field: Field, v: any): any
	if type(v) == "string" then
		if field.type == "number" then
			return Shared.jsParseFloat(v)
		elseif field.type == "boolean" then
			return v == "true" or v == "TRUE" or v == "True" or v == "1"
		end
	end
	return v
end

function M.apply(input: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local refId = Json.str(env, Json.path(env, options, "refId"))
	if #input <= 1 then
		return Shared.staticRefId(input, refId)
	end
	local data: { Frame } = {}
	for _, f in input do
		if #f.fields > 0 then
			table.insert(data, f)
		end
	end
	if #data == 0 then
		return Shared.staticRefId({ input[1] }, refId)
	end
	local fieldNames: { string } = {}
	local seenName: { [string]: boolean } = {}
	local outFields: { Field } = {}
	local indexByName: { [string]: { [number]: number } } = {}
	local keyNames: { string } = {}
	for frameIndex, frame in data do
		for fieldIndex, field in frame.fields do
			if not seenName[field.name] then
				seenName[field.name] = true
				table.insert(fieldNames, field.name)
				table.insert(outFields, structure(field, #outFields + 1))
			end
			local byFrame: { [number]: number } = indexByName[field.name] or {}
			indexByName[field.name] = byFrame
			byFrame[frameIndex] = fieldIndex
			if frameIndex ~= #data then
				continue
			end
			local count = 0
			for _ in byFrame do
				count += 1
			end
			if count == #data then
				table.insert(keyNames, field.name)
			end
		end
	end
	if #keyNames == 0 then
		return input
	end
	-- Per frame, the key field indexes in key order.
	local keyIndexes: { [number]: { number } } = {}
	for _, name in keyNames do
		local byFrame = indexByName[name]
		for frameIndex = 1, #data do
			local fi = byFrame[frameIndex]
			if fi then
				local list: { number } = keyIndexes[frameIndex] or {}
				keyIndexes[frameIndex] = list
				table.insert(list, fi)
			end
		end
	end
	local valuesByKey: { [string]: { Row } } = {}
	local order: { { key: string, index: number } } = {}
	for frameIndex, frame in data do
		local n = Shared.length(frame)
		for row = 1, n do
			local parts: { string } = {}
			local keyList: { number } = keyIndexes[frameIndex] or {}
			for _, fi in keyList do
				table.insert(parts, Shared.jsString(frame.fields[fi].values[row]))
			end
			local key = table.concat(parts)
			local value: Row = {}
			for _, name in fieldNames do
				local fi = indexByName[name][frameIndex]
				if fi then
					local f = frame.fields[fi]
					local v = f.values[row]
					value[name] = if v == nil then GAP else v
				end
			end
			local rows = valuesByKey[key]
			if rows == nil then
				valuesByKey[key] = { value }
				table.insert(order, { key = key, index = 1 })
				continue
			end
			local merged = false
			for i, existing in rows do
				if mergeable(existing, value) then
					merged = true
					local m = Tbl.copy(existing)
					for k, v in value do
						m[k] = v
					end
					rows[i] = m
				end
			end
			if not merged then
				table.insert(rows, value)
				table.insert(order, { key = key, index = #rows })
			end
		end
	end
	for _, p in order do
		local value = valuesByKey[p.key][p.index]
		for _, f in outFields do
			local v = value[f.name]
			table.insert(f.values, if v == nil then GAP else parsed(f, v))
		end
	end
	return { { refId = refId or Shared.dynamicRefId("merge", data), fields = outFields } }
end

return M
