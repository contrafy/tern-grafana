--!strict
-- groupingToMatrix: packages/grafana-data/src/transformations/transformers/
-- groupingToMatrix.ts (https://raw.githubusercontent.com/grafana/grafana/
-- main/packages/grafana-data/src/transformations/transformers/
-- groupingToMatrix.ts). One frame becomes a matrix: a `<row>\<column>` field
-- with the distinct row values, then one field per distinct column value
-- holding the value field's value for each row (the last one when a
-- row/column pair repeats). Fields are found by name (byName, so display
-- names and the dataplane fallbacks match); `columnField`, `rowField` and
-- `valueField` default to Time, Time and Value. Anything but exactly one
-- frame, or a field not found, passes the data through.
--
-- Grafana quirks kept on purpose:
-- - the matrix is keyed by String(value), so the column value 1 and "1"
--   share their cells while still making two columns;
-- - an empty cell, and a null value too (`??`), reads as `emptyValue`:
--   "" (empty, the default and any unknown value), null, true, false or 0;
-- - the column fields share the value field's config without its display
--   name, and are named String(value) (a null column value: no name, which
--   reads as "Value"); the output frame has no name and no refId.
-- Grafana's nested-frame value fields (empty cells left undefined) do not
-- occur in Tern's frames.

local Frame = require("../../frame/types")
local Json = require("../json")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local DEFAULT_COLUMN = "Time"
local DEFAULT_ROW = "Time"
local DEFAULT_VALUE = "Value"

-- getSpecialValue.
local function specialValue(id: string?): any
	if id == "false" then
		return false
	elseif id == "true" then
		return true
	elseif id == "null" then
		return Frame.NULL
	elseif id == "zero" then
		return 0
	end
	return ""
end

-- `options.x || default`.
local function nameOption(ctx: Ctx, options: any, key: string, default: string): string
	local v = Json.path(ctx.env, options, key)
	return if Shared.truthy(v) then Shared.jsString(v) else default
end

local function findKeyField(frame: Frame, name: string, ctx: Ctx): Field?
	local matcher = Shared.byName(ctx.env, name)
	local frames = { frame }
	for _, field in frame.fields do
		if matcher(field, frame, frames) then
			return field
		end
	end
	return nil
end

local NAN_KEY = newproxy(false)

-- Array.from(new Set(values)): SameValueZero, first-seen order.
local function uniqueValues(values: { any }): { any }
	local seen: { [any]: boolean } = {}
	local out: { any } = {}
	for i = 1, #values do
		local v = values[i]
		if v == nil then
			v = Shared.GAP
		end
		local key = if type(v) == "number" and v ~= v then NAN_KEY else v
		if not seen[key] then
			seen[key] = true
			table.insert(out, v)
		end
	end
	return out
end

function M.unsupported(_options: any, _ctx: Ctx): string?
	return nil
end

function M.apply(data: { Frame }, options: any, ctx: Ctx): { Frame }
	local columnMatch = nameOption(ctx, options, "columnField", DEFAULT_COLUMN)
	local rowMatch = nameOption(ctx, options, "rowField", DEFAULT_ROW)
	local valueMatch = nameOption(ctx, options, "valueField", DEFAULT_VALUE)
	local raw = Json.path(ctx.env, options, "emptyValue")
	local empty = specialValue(if Shared.truthy(raw) then Shared.jsString(raw) else nil)
	if #data ~= 1 then
		return data
	end
	local frame = data[1]
	local columnField = findKeyField(frame, columnMatch, ctx)
	local rowField = findKeyField(frame, rowMatch, ctx)
	local valueField = findKeyField(frame, valueMatch, ctx)
	if columnField == nil or rowField == nil or valueField == nil then
		return data
	end
	local columns = uniqueValues(columnField.values)
	local rows = uniqueValues(rowField.values)
	local matrix: { [string]: { [string]: any } } = {}
	for i = 1, #valueField.values do
		local column = Shared.jsString(columnField.values[i])
		local cells = matrix[column]
		if cells == nil then
			cells = {}
			matrix[column] = cells
		end
		cells[Shared.jsString(rowField.values[i])] = valueField.values[i]
	end
	local fields: { Field } = {
		Frame.field(
			rowMatch .. "\\" .. columnMatch,
			rowField.type,
			rows,
			nil,
			if rowField.config then Tbl.copy(rowField.config) else {}
		),
	}
	-- The columns' names are the column values, never the display name.
	local config: Frame.FieldConfig = if valueField.config then Tbl.copy(valueField.config) else {}
	config.displayName = nil
	for _, column in columns do
		local cells = matrix[Shared.jsString(column)]
		local values: { any } = table.create(#rows)
		for r, row in rows do
			local v = cells[Shared.jsString(row)]
			values[r] = if Shared.nullish(v) then empty else v
		end
		local name = if Shared.nullish(column) then "" else Shared.jsString(column)
		table.insert(fields, Frame.field(name, valueField.type, values, nil, config))
	end
	return { { fields = fields } }
end

return M
