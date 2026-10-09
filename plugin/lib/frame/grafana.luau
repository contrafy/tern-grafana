--!strict
-- Grafana data frames (the JSON of /api/ds/query `results[refId].frames`) to
-- Frames. JSON cannot carry NaN or +-Inf, so Grafana sends null in `values`
-- and lists the indices in `entities` ({NaN = {0, 3}, Inf = {...}, NegInf =
-- {...}, Undefined = {...}}, zero-based); those are restored here, or a
-- Prometheus NaN would read as a gap. `nanos` carries the sub-millisecond part
-- of time values. Grafana 11 and 12 send the same shape (12 adds
-- meta.custom.calculatedMinStep, kept verbatim).

local Env = require("../env")
local Frame = require("./types")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field

local M = {}

local FIELD_TYPES: { [string]: Frame.FieldType } = {
	time = "time",
	number = "number",
	string = "string",
	boolean = "boolean",
}

local ENTITY_VALUES: { [string]: any } = {
	NaN = 0 / 0,
	Inf = math.huge,
	NegInf = -math.huge,
	Undefined = Frame.NULL,
}

local function str(env: Env, v: any): string?
	v = Env.value(env, v)
	return if type(v) == "string" then v else nil
end

local function num(env: Env, v: any): number?
	v = Env.value(env, v)
	return if type(v) == "number" then v else nil
end

-- Decoded JSON tables stay `any`: their shape is checked field by field.
local function object(env: Env, v: any): any
	v = Env.value(env, v)
	return if type(v) == "table" then v else nil
end

local function labels(env: Env, raw: any): { [string]: string }?
	local t = object(env, raw)
	if t == nil then
		return nil
	end
	local out: { [string]: string } = {}
	for k, v in t do
		if type(k) == "string" and not Env.isNull(env, v) then
			out[k] = tostring(v)
		end
	end
	return out
end

local function fieldConfig(env: Env, raw: any): Frame.FieldConfig?
	local c = object(env, raw)
	if c == nil then
		return nil
	end
	local displayName = str(env, c.displayName)
	if displayName == nil or displayName == "" then
		displayName = str(env, c.displayNameFromDS)
	end
	local config: Frame.FieldConfig = {
		unit = str(env, c.unit),
		displayName = if displayName ~= "" then displayName else nil,
		decimals = num(env, c.decimals),
		min = num(env, c.min),
		max = num(env, c.max),
		interval = num(env, c.interval),
		custom = object(env, c.custom),
	}
	if next(config :: any) == nil then
		return nil
	end
	return config
end

local function notices(env: Env, raw: any): { Frame.Notice }?
	local list = object(env, raw)
	if list == nil then
		return nil
	end
	local out: { Frame.Notice } = {}
	for _, n in list do
		local text = if type(n) == "table" then str(env, n.text) else nil
		if text and text ~= "" then
			table.insert(out, { severity = str(env, n.severity) or "info", text = text })
		end
	end
	return if #out > 0 then out else nil
end

local function frameMeta(env: Env, raw: any): Frame.FrameMeta?
	local m = object(env, raw)
	if m == nil then
		return nil
	end
	return {
		type = str(env, m.type),
		executedQueryString = str(env, m.executedQueryString),
		notices = notices(env, m.notices),
		custom = object(env, m.custom),
	}
end

local function column(env: Env, raw: any, length: number): { any }
	local out: { any } = table.create(length)
	local src = object(env, raw)
	for i = 1, length do
		local v = if src then src[i] else nil
		out[i] = if Env.isNull(env, v) then Frame.NULL else v
	end
	return out
end

local function restoreEntities(env: Env, values: { any }, raw: any)
	local entities = object(env, raw)
	if entities == nil then
		return
	end
	for name, indices in entities do
		local value = ENTITY_VALUES[name]
		if value == nil or type(indices) ~= "table" then
			continue
		end
		for _, index in indices do
			if type(index) == "number" and values[index + 1] ~= nil then
				values[index + 1] = value
			end
		end
	end
end

local function addNanos(env: Env, values: { any }, raw: any)
	local nanos = object(env, raw)
	if nanos == nil then
		return
	end
	for i, ns in nanos do
		local v = values[i]
		if type(ns) == "number" and type(v) == "number" then
			values[i] = v + ns / 1e6
		end
	end
end

-- One data frame `{schema, data}`.
function M.frame(raw: any, env: Env): Frame
	local schema = object(env, raw.schema) or {}
	local data = object(env, raw.data) or {}
	local rawFields = object(env, schema.fields) or {}
	local rawValues = object(env, data.values) or {}
	local rawEntities = object(env, data.entities) or {}
	local rawNanos = object(env, data.nanos) or {}
	local fields: { Field } = {}
	for i, f in rawFields do
		local col = object(env, rawValues[i])
		local values = column(env, col, if col then #col else 0)
		restoreEntities(env, values, rawEntities[i])
		local fieldType: Frame.FieldType = FIELD_TYPES[str(env, f.type) or ""] or "other"
		if fieldType == "time" then
			addNanos(env, values, rawNanos[i])
		end
		table.insert(
			fields,
			Frame.field(str(env, f.name) or "", fieldType, values, labels(env, f.labels), fieldConfig(env, f.config))
		)
	end
	local name = str(env, schema.name)
	return {
		name = if name ~= "" then name else nil,
		refId = str(env, schema.refId),
		fields = fields,
		meta = frameMeta(env, schema.meta),
	}
end

function M.frames(list: any, env: Env): { Frame }
	local out: { Frame } = {}
	local frames = object(env, list)
	if frames then
		for _, raw in frames do
			if type(raw) == "table" then
				table.insert(out, M.frame(raw, env))
			end
		end
	end
	return out
end

local function warnings(frames: { Frame }): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, f in frames do
		local list = if f.meta then f.meta.notices else nil
		if list then
			for _, n in list do
				if not seen[n.text] then
					seen[n.text] = true
					table.insert(out, n.text)
				end
			end
		end
	end
	return out
end

-- A data frame with no fields is Grafana's placeholder on errors and empty
-- results; it renders as nothing and only hides "no data".
local function nonEmpty(frames: { Frame }): { Frame }
	local out: { Frame } = {}
	for _, f in frames do
		if #f.fields > 0 then
			table.insert(out, f)
		end
	end
	return out
end

-- The decoded /api/ds/query body to a result per refId; one failed query
-- never hides the others.
function M.parseResults(doc: any, env: Env): { [string]: Frame.QueryResult }
	local out: { [string]: Frame.QueryResult } = {}
	local results = if type(doc) == "table" then object(env, doc.results) else nil
	if results == nil then
		return out
	end
	for ref, r in results do
		if type(ref) ~= "string" or type(r) ~= "table" then
			continue
		end
		local message = str(env, r.error)
		local status = num(env, r.status)
		if message and message ~= "" then
			out[ref] = { ok = false, error = { kind = "query", message = message, status = status } }
		elseif status and status >= 400 then
			out[ref] = {
				ok = false,
				error = {
					kind = "query",
					message = string.format("query %s failed (status %d)", ref, status),
					status = status,
				},
			}
		else
			local frames = M.frames(r.frames, env)
			out[ref] = { ok = true, frames = nonEmpty(frames), warnings = warnings(frames) }
		end
	end
	return out
end

return M
