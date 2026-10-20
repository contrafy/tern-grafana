--!strict
-- labelsToFields: packages/grafana-data/src/transformations/transformers/
-- labelsToFields.ts. Columns mode (default) moves every label of a field into
-- a string field of its own (one per distinct value), or names the value
-- field after `valueLabel`; rows mode turns each labeled field into a
-- `label`/`value` frame. `keepLabels` limits the labels taken. Label keys
-- are visited in sorted order, the order Grafana's backend serializes them.

local Json = require("../json")
local Frame = require("../../frame/types")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local function sortedKeys(labels: { [string]: string }): { string }
	local keys: { string } = {}
	for k in labels do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

local function toRows(frames: { Frame }, keep: { any }?): { Frame }
	local out: { Frame } = {}
	for _, frame in frames do
		for _, field in frame.fields do
			local labels = field.labels
			if labels == nil then
				continue
			end
			local keys: { any } = {}
			local vals: { any } = {}
			if keep then
				for _, key in keep do
					table.insert(keys, key)
					local v = if type(key) == "string" then labels[key] else nil
					table.insert(vals, if v == nil then Shared.GAP else v)
				end
			else
				for _, key in sortedKeys(labels) do
					table.insert(keys, key)
					table.insert(vals, labels[key])
				end
			end
			if #vals > 0 then
				local copy = Tbl.copy(frame)
				copy.name = Shared.displayName(field, frame, frames)
				copy.fields = {
					Frame.field("label", "string", keys, nil, {}),
					Frame.field("value", "string", vals, nil, {}),
				}
				table.insert(out, copy)
			end
		end
	end
	return out
end

function M.unsupported(_options: any, _ctx: Ctx): string?
	return nil
end

function M.apply(frames: { Frame }, options: any, ctx: Ctx): { Frame }
	local env = ctx.env
	local keepRaw = Json.tbl(env, Json.path(env, options, "keepLabels"))
	if Json.str(env, Json.path(env, options, "mode")) == "rows" then
		return toRows(frames, if keepRaw then keepRaw :: { any } else nil)
	end
	local keep: { [string]: boolean }? = nil
	if keepRaw and #keepRaw > 0 then
		local set: { [string]: boolean } = {}
		for _, k in keepRaw do
			if type(k) == "string" then
				set[k] = true
			end
		end
		keep = set
	end
	local valueLabel = Json.str(env, Json.path(env, options, "valueLabel"))
	local out: { Frame } = {}
	for _, frame in frames do
		local fields: { Field } = {}
		local order: { string } = {}
		local unique: { [string]: { values: { string }, seen: { [string]: boolean } } } = {}
		local n = Shared.length(frame)
		for _, field in frame.fields do
			local labels = field.labels
			if labels == nil then
				table.insert(fields, field)
				continue
			end
			local sans = Tbl.copy(field)
			local config: Frame.FieldConfig = if field.config then Tbl.copy(field.config) else {}
			-- Display names can carry label values that no longer apply.
			config.displayName = nil
			sans.config = config
			sans.labels = nil
			table.insert(fields, sans)
			for _, name in sortedKeys(labels) do
				if keep and not keep[name] then
					continue
				end
				if valueLabel == name then
					sans.name = labels[name]
					continue
				end
				local u = unique[name]
				if u == nil then
					u = { values = {}, seen = {} }
					unique[name] = u
					table.insert(order, name)
				end
				local v = labels[name]
				if not u.seen[v] then
					u.seen[v] = true
					table.insert(u.values, v)
				end
			end
		end
		for _, name in order do
			for _, v in unique[name].values do
				table.insert(fields, Frame.field(name, "string", table.create(n, v), nil, {}))
			end
		end
		table.insert(out, Shared.withFields(frame, fields))
	end
	return out
end

return M
