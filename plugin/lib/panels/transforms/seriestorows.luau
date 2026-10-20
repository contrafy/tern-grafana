--!strict
-- seriesToRows: packages/grafana-data/src/transformations/transformers/
-- seriesToRows.ts (https://raw.githubusercontent.com/grafana/grafana/main/
-- packages/grafana-data/src/transformations/transformers/seriesToRows.ts),
-- also what an old table panel's "timeseries_to_rows" migrates to. Time
-- series frames become one table: Time, Metric (the frame's display name,
-- getFrameDisplayName in field/fieldState.ts) and Value, newest row first.
-- Time and Value take the type and config (minus display names) of the first
-- time and first other field seen; each frame contributes its last time
-- field and the field right after it (or the first one when time is not
-- first). Empty frames are dropped; when any frame left is not a time series
-- (dataframe/utils.ts isTimeSeriesFrame: a number field and a time field
-- ascending over its first 100 values) the frames pass through.

local FieldConfig = require("../fieldconfig")
local Frame = require("../../frame/types")
local Json = require("../json")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local MAX_TIME_COMPARISONS = 100

-- `a > b` for the values a time field holds.
local function greater(a: any, b: any): boolean
	if type(a) == "number" and type(b) == "number" then
		return a > b
	elseif type(a) == "string" and type(b) == "string" then
		return a > b
	end
	return Shared.jsNumber(a) > Shared.jsNumber(b)
end

-- isTimeSeriesField.
local function ascendingTime(field: Field): boolean
	if field.type ~= "time" then
		return false
	end
	local greatest: any = nil
	for i = 1, math.min(#field.values, MAX_TIME_COMPARISONS) do
		local t = field.values[i]
		t = if Shared.nullish(t) then nil else t
		if greatest == nil or (t ~= nil and greater(t, greatest)) then
			greatest = t
		else
			return false
		end
	end
	return true
end

-- isTimeSeriesFrame.
local function isTimeSeries(frame: Frame): boolean
	if #frame.fields < 2 then
		return false
	end
	local number, time = false, false
	for _, f in frame.fields do
		number = number or f.type == "number"
		time = time or ascendingTime(f)
	end
	return number and time
end

-- getFrameDisplayName(frame) for a frame with fields: its name, else its
-- non-time fields' display names joined.
local function frameName(frame: Frame): string
	if frame.name and frame.name ~= "" then
		return frame.name
	end
	local names: { string } = {}
	for _, f in frame.fields do
		if f.type ~= "time" then
			table.insert(names, FieldConfig.displayName(f, frame))
		end
	end
	return table.concat(names, ", ")
end

-- copyFieldStructure: the field without values, labels and display names.
local function structure(field: Field, name: string): Field
	local copy = Tbl.copy(field)
	copy.name = name
	copy.values = {}
	copy.labels = nil
	local config: Frame.FieldConfig = if field.config then Tbl.copy(field.config) else {}
	config.displayName = nil
	copy.config = config
	return copy
end

function M.unsupported(_options: any, _ctx: Ctx): string?
	return nil
end

function M.apply(frames: { Frame }, options: any, ctx: Ctx): { Frame }
	if #frames == 0 then
		return frames
	end
	local refId = Json.str(ctx.env, Json.path(ctx.env, options, "refId"))
	local data: { Frame } = {}
	for _, f in frames do
		if Shared.length(f) > 0 then
			table.insert(data, f)
		end
	end
	for _, f in data do
		if not isTimeSeries(f) then
			return Shared.staticRefId(data, refId)
		end
	end
	local timeIndex: { [number]: number } = {}
	local fields: { Field } = {}
	local time: Field?, value: Field? = nil, nil
	local metric = Frame.field("Metric", "string", {}, nil, {})
	for fi, frame in data do
		for xi, field in frame.fields do
			if field.type == "time" then
				timeIndex[fi] = xi
				if time == nil then
					time = structure(field, "Time")
					table.insert(fields, time :: Field)
					table.insert(fields, metric)
				end
			elseif value == nil then
				value = structure(field, "Value")
				table.insert(fields, value :: Field)
			end
		end
	end
	local times: { any } = if time then time.values else {}
	local values: { any } = if value then value.values else {}
	for fi, frame in data do
		local ti = timeIndex[fi]
		local tv = frame.fields[ti].values
		local vv = frame.fields[if ti == 1 then 2 else 1].values
		local name = frameName(frame)
		for row = 1, Shared.length(frame) do
			local t, v = tv[row], vv[row]
			table.insert(times, if t == nil then Shared.GAP else t)
			table.insert(metric.values, name)
			table.insert(values, if v == nil then Shared.GAP else v)
		end
	end
	local out: Frame = { refId = refId or Shared.dynamicRefId("seriesToRows", data), fields = fields }
	return { Shared.sortByFields(out, { { index = 1, desc = true } }) }
end

return M
