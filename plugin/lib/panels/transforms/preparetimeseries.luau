--!strict
-- prepareTimeSeries: public/app/features/transformers/prepareTimeSeries/
-- prepareTimeSeries.ts (https://raw.githubusercontent.com/grafana/grafana/
-- main/public/app/features/transformers/prepareTimeSeries/
-- prepareTimeSeries.ts), with partitionByValues/partitionByValues.ts and
-- partition.ts for the long-to-wide step. `format`:
-- - "long" (toTimeSeriesLong): each frame with a time field becomes one
--   table sorted by time: the time field, the value fields (sorted by name),
--   then a string column per string/boolean field and label key (sorted);
--   one row per time and label set. Field config and labels are dropped, as
--   Grafana rebuilds the frame from names and types only;
-- - "multi" or the deprecated "many" (toTimeSeriesMulti): the long frames
--   split into one [time, value] frame per number/boolean field and
--   distinct string-column values (joined "/"), those values as labels;
-- - "wide" (the default, also for any other value): frames typed
--   timeseries-long are split by their string fields' values (the values
--   become labels), then every frame is outer-joined on its first time field
--   into one frame.
-- Frames without a time field leave "long" and "multi".

local FieldConfig = require("../fieldconfig")
local Frame = require("../../frame/types")
local Join = require("./join")
local Json = require("../json")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local LONG = "timeseries-long"
local MULTI = "timeseries-multi"
local WIDE = "timeseries-wide"

local function withType(frame: Frame, kind: string): Frame.FrameMeta
	local meta: Frame.FrameMeta = if frame.meta then Tbl.copy(frame.meta) else {}
	meta.type = kind
	return meta
end

-- JSON.stringify(labels) as a grouping key (labels sorted, as the backend
-- writes them); "undefined" for none.
local function labelsKey(labels: { [string]: string }?): string
	if labels == nil then
		return "undefined"
	end
	local keys: { string } = {}
	for k in labels do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		table.insert(parts, string.format("%q:%q", k, labels[k]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- MutableDataFrame.add: a string reaching a number or boolean column is
-- parsed (utils/fieldParser.ts makeFieldParser); a missing value is
-- undefined.
local function stored(fieldType: Frame.FieldType, v: any): any
	if v == nil then
		return Shared.GAP
	elseif type(v) == "string" and fieldType ~= "string" then
		if fieldType == "number" then
			return Shared.jsParseFloat(v)
		elseif fieldType == "boolean" then
			local c = string.sub(v, 1, 1)
			return not (c == "F" or c == "f" or c == "0")
		end
	end
	return v
end

local function sortedKeys(set: { [string]: any }): { string }
	local out: { string } = {}
	for k in set do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

-- toTimeSeriesLong for one frame.
local function toLong(frame: Frame): Frame?
	local timeField: Field? = nil
	local valueNames: { string } = {}
	local valueTypes: { [string]: Frame.FieldType } = {}
	local labelKeys: { [string]: boolean } = {}
	local wideByLabels: { [string]: { number } } = {}
	local factorIndex: { [string]: number } = {}
	local factorOrder: { string } = {}
	for i, field in frame.fields do
		local t = field.type
		if t == "string" or t == "boolean" then
			if factorIndex[field.name] == nil then
				factorIndex[field.name] = i
				table.insert(factorOrder, field.name)
				labelKeys[field.name] = true
			end
			continue
		elseif t == "time" and timeField == nil then
			timeField = field
			continue
		end
		local known = valueTypes[field.name]
		if known == nil then
			valueTypes[field.name] = field.type
			table.insert(valueNames, field.name)
		elseif known ~= t then
			continue
		end
		local key = labelsKey(field.labels)
		local list = wideByLabels[key]
		if list == nil then
			wideByLabels[key] = { i }
		else
			table.insert(list, i)
		end
		if field.labels then
			for k in field.labels do
				labelKeys[k] = true
			end
		end
	end
	if timeField == nil then
		return nil
	end
	local tf = timeField :: Field
	local n = Shared.length(frame)
	local rows: { number } = table.create(n)
	for i = 1, n do
		rows[i] = i
	end
	-- (a, b) => a.time - b.time, stable: null is 0, a NaN difference ties.
	table.sort(rows, function(a: number, b: number): boolean
		local d = Shared.jsNumber(tf.values[a]) - Shared.jsNumber(tf.values[b])
		if d ~= d or d == 0 then
			return a < b
		end
		return d < 0
	end)
	local groups = sortedKeys(wideByLabels)
	local factors = sortedKeys(labelKeys)
	table.sort(valueNames)
	local fields: { Field } = { Frame.field(tf.name, tf.type, {}, nil, {}) }
	for _, name in valueNames do
		table.insert(fields, Frame.field(name, valueTypes[name], {}, nil, {}))
	end
	for _, name in factors do
		table.insert(fields, Frame.field(name, "string", {}, nil, {}))
	end
	for _, row in rows do
		for _, group in groups do
			local values: { [string]: any } = {}
			for _, name in factorOrder do
				values[name] = frame.fields[factorIndex[name]].values[row]
			end
			for k, wi in wideByLabels[group] do
				local wide = frame.fields[wi]
				if k == 1 and wide.labels then
					for lk, lv in wide.labels do
						values[lk] = lv
					end
				end
				values[wide.name] = wide.values[row]
			end
			values[tf.name] = tf.values[row]
			for _, f in fields do
				table.insert(f.values, stored(f.type, values[f.name]))
			end
		end
	end
	return { name = frame.name, refId = frame.refId, meta = withType(frame, LONG), fields = fields }
end

function M.toTimeSeriesLong(data: { Frame }): { Frame }
	local out: { Frame } = {}
	for _, frame in data do
		local long = toLong(frame)
		if long then
			table.insert(out, long)
		end
	end
	return out
end

type Builder = { time: { any }, value: { any }, labels: { [string]: string } }

function M.toTimeSeriesMulti(data: { Frame }): { Frame }
	local out: { Frame } = {}
	for _, frame in M.toTimeSeriesLong(data) do
		local timeField = frame.fields[1]
		if timeField == nil or timeField.type ~= "time" then
			continue
		end
		local valueFields: { Field } = {}
		local labelFields: { Field } = {}
		for _, f in frame.fields do
			if f.type == "number" or f.type == "boolean" then
				table.insert(valueFields, f)
			elseif f.type == "string" then
				table.insert(labelFields, f)
			end
		end
		local meta = withType(frame, MULTI)
		for _, field in valueFields do
			if #labelFields == 0 then
				table.insert(
					out,
					{ name = frame.name, refId = frame.refId, meta = meta, fields = { timeField, field } }
				)
				continue
			end
			local order: { Builder } = {}
			local builders: { [string]: Builder } = {}
			for i = 1, Shared.length(frame) do
				local t, v = timeField.values[i], field.values[i]
				-- Skip the gaps a join left (undefined values, missing times).
				if v == nil or v == Shared.GAP or Shared.nullish(t) then
					continue
				end
				local parts: { string } = table.create(#labelFields)
				for k, lf in labelFields do
					local x = lf.values[i]
					parts[k] = if Shared.nullish(x) then "" else Shared.jsString(x)
				end
				local key = table.concat(parts, "/")
				local b = builders[key]
				if b == nil then
					local labels: { [string]: string } = {}
					for _, lf in labelFields do
						labels[lf.name] = Shared.jsString(lf.values[i])
					end
					b = { time = {}, value = {}, labels = labels }
					builders[key] = b
					table.insert(order, b)
				end
				table.insert(b.time, t)
				table.insert(b.value, v)
			end
			for _, b in order do
				local tcopy = Shared.withValues(timeField, b.time)
				local vcopy = Shared.withValues(field, b.value)
				vcopy.labels = b.labels
				table.insert(out, { name = frame.name, refId = frame.refId, meta = meta, fields = { tcopy, vcopy } })
			end
		end
	end
	return out
end

local NAN_KEY = newproxy(false)

type Node = { keys: { any }, children: { [any]: any } }

-- partition: row indices grouped by the key columns' values, groups in
-- first-seen order at each key level (nested Maps in Grafana).
local function partition(columns: { { any } }, n: number): { { number } }
	local root: Node = { keys = {}, children = {} }
	local depth = #columns
	for i = 1, n do
		local cur = root
		for j, col in columns do
			local v = col[i]
			if v == nil then
				v = Shared.GAP
			end
			local key = if type(v) == "number" and v ~= v then NAN_KEY else v
			local nextNode = cur.children[key]
			if nextNode == nil then
				nextNode = if j == depth then {} else { keys = {}, children = {} }
				cur.children[key] = nextNode
				table.insert(cur.keys, key)
			end
			if j == depth then
				table.insert(nextNode, i)
			else
				cur = nextNode
			end
		end
	end
	local out: { { number } } = {}
	local function dig(node: any, level: number)
		if level == 0 then
			table.insert(out, node)
			return
		end
		for _, k in node.keys do
			dig(node.children[k], level - 1)
		end
	end
	dig(root, depth)
	return out
end

-- longToMultiTimeSeries: partitionByValues on the string fields, the values
-- as labels, the key fields dropped. Fields renamed by the datasource are
-- split under that name and get their full display name back as it.
local function longToMulti(frame: Frame): { Frame }
	local renamed: { [string]: string } = {}
	local source: { Field } = {}
	for i, f in frame.fields do
		local to = f.config and f.config.displayName
		if to and to ~= "" then
			local copy = Tbl.copy(f)
			local config = Tbl.copy(f.config :: Frame.FieldConfig)
			config.displayName = nil
			copy.config = config
			copy.name = to
			renamed[to] = f.name
			source[i] = copy
		else
			source[i] = f
		end
	end
	local keyFields: { Field } = {}
	local keyNames: { [string]: boolean } = {}
	for _, f in source do
		if f.type == "string" then
			table.insert(keyFields, f)
			keyNames[f.name] = true
		end
	end
	local meta = withType(frame, MULTI)
	local out: { Frame } = {}
	if #keyFields == 0 then
		local copy = Shared.withFields(frame, source)
		copy.meta = meta
		out[1] = copy
	else
		local columns: { { any } } = {}
		for _, f in keyFields do
			table.insert(columns, f.values)
		end
		for _, idxs in partition(columns, Shared.length(frame)) do
			local labels: { [string]: string } = {}
			for _, kf in keyFields do
				labels[kf.name] = Shared.jsString(kf.values[idxs[1]])
			end
			local fields: { Field } = {}
			for _, f in source do
				if keyNames[f.name] then
					continue
				end
				local values: { any } = table.create(#idxs)
				for k, i in idxs do
					local v = f.values[i]
					values[k] = if v == nil then Shared.GAP else v
				end
				local merged: { [string]: string } = if f.labels then Tbl.copy(f.labels) else {}
				for k, v in labels do
					merged[k] = v
				end
				table.insert(
					fields,
					Frame.field(f.name, f.type, values, merged, if f.config then Tbl.copy(f.config) else {})
				)
			end
			table.insert(out, {
				name = frame.name,
				refId = Shared.jsString(frame.refId) .. "-" .. Shared.jsString(frame.name),
				meta = meta,
				fields = fields,
			})
		end
	end
	if next(renamed) == nil then
		return out
	end
	-- cacheFieldDisplayNames over every split frame, then the names back.
	local names: { { string } } = {}
	for fi, f in out do
		names[fi] = {}
		for xi, field in f.fields do
			names[fi][xi] = FieldConfig.displayName(field, f, out)
		end
	end
	for fi, f in out do
		for xi, field in f.fields do
			local original = renamed[field.name]
			if original then
				local copy = Tbl.copy(field)
				local config: Frame.FieldConfig = if field.config then Tbl.copy(field.config) else {}
				config.displayName = names[fi][xi]
				copy.config = config
				copy.name = original
				f.fields[xi] = copy
			end
		end
	end
	return out
end

function M.unsupported(_options: any, _ctx: Ctx): string?
	return nil
end

function M.apply(data: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local format = Json.str(env, Json.path(env, options, "format")) or "wide"
	if format == "many" or format == "multi" then
		return M.toTimeSeriesMulti(data)
	elseif format == "long" then
		return M.toTimeSeriesLong(data)
	end
	if #data == 0 then
		return {}
	end
	local join: { Frame } = {}
	for _, df in data do
		if df.meta and df.meta.type == LONG then
			for _, f in longToMulti(df) do
				table.insert(join, f)
			end
		else
			table.insert(join, df)
		end
	end
	local frame = Join.joinDataFrames({
		frames = join,
		joinBy = Shared.fieldMatcher(env, { id = "firstTimeField" }),
	})
	if frame == nil then
		return {}
	end
	local copy = Tbl.copy(frame)
	copy.meta = withType(frame, WIDE)
	return { copy }
end

return M
