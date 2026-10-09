--!strict
-- What happens to a panel's frames between the query and the visualization
-- in Grafana's frontend:
-- 1. the Prometheus datasource's own post-processing (packages/
--    grafana-prometheus/src/result_transformer.ts transformV2): exemplar
--    frames leave the data, and every refId whose target says
--    `format: "table"` becomes one table frame (Time, label columns,
--    Value or `Value #<refId>`), transformDFToTable;
-- 2. the panel's `transformations`, in order, for the supported subset:
--    organize, filterFieldsByName, filterByRefId (packages/grafana-data/src/
--    transformations/transformers/{organize,filterByName,filterByRefId,
--    order,rename,filter}.ts).
-- Anything else is reported by `unsupported` so the panel falls down the
-- rendering ladder instead of showing data Grafana would not.

local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local Regex = require("../regex")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field

local M = {}

local SUPPORTED: { [string]: boolean } = { organize = true, filterFieldsByName = true, filterByRefId = true }

local function isPrometheus(frame: Frame): boolean
	local custom = frame.meta and frame.meta.custom
	local rt = if custom then custom.resultType else nil
	return rt == "matrix" or rt == "vector" or rt == "scalar" or rt == "string"
end

local function tableRefIds(panel: any, env: Env): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, t in Json.list(env, Json.path(env, panel, "targets")) do
		local ref = Json.str(env, Json.path(env, t, "refId"))
		if ref and Json.str(env, Json.path(env, t, "format")) == "table" then
			out[ref] = true
		end
	end
	return out
end

-- transformDFToTable for the frames of the refIds in `refs`.
local function toTables(frames: { Frame }): { Frame }
	local order: { string } = {}
	local byRef: { [string]: { Frame } } = {}
	for _, f in frames do
		local ref = f.refId or ""
		if byRef[ref] == nil then
			byRef[ref] = {}
			table.insert(order, ref)
		end
		table.insert(byRef[ref], f)
	end
	local out: { Frame } = {}
	for _, ref in order do
		local group = byRef[ref]
		local labelNames: { string } = {}
		local seen: { [string]: boolean } = {}
		for _, df in group do
			local vf = df.fields[2]
			local keys: { string } = {}
			if vf and vf.labels then
				for k in vf.labels do
					table.insert(keys, k)
				end
			end
			table.sort(keys)
			for _, k in keys do
				if not seen[k] then
					seen[k] = true
					table.insert(labelNames, k)
				end
			end
		end
		local times: { any } = {}
		local values: { any } = {}
		local labelValues: { { any } } = {}
		for i = 1, #labelNames do
			labelValues[i] = {}
		end
		local interval: number? = nil
		local needsSort = false
		local prev = -math.huge
		for _, df in group do
			local tf, vf = df.fields[1], df.fields[2]
			if interval == nil and tf and tf.config then
				interval = tf.config.interval
			end
			local timeValues: { any } = if tf then tf.values else {}
			for _, t in timeValues do
				table.insert(times, t)
				if type(t) == "number" then
					if t < prev then
						needsSort = true
					end
					prev = t
				end
			end
			local labels: { [string]: string } = if vf and vf.labels then vf.labels else {}
			local sampleValues: { any } = if vf then vf.values else {}
			for _, v in sampleValues do
				table.insert(values, v)
				for i, name in labelNames do
					table.insert(labelValues[i], labels[name] or "")
				end
			end
		end
		if needsSort then
			local idx: { number } = table.create(#times)
			for i = 1, #times do
				idx[i] = i
			end
			table.sort(idx, function(a: number, b: number): boolean
				local ta, tb = times[a], times[b]
				if ta == tb then
					return a < b
				end
				return (if type(ta) == "number" then ta else -math.huge)
					< (if type(tb) == "number" then tb else -math.huge)
			end)
			local function reorder(col: { any }): { any }
				local c: { any } = table.create(#idx)
				for k, i in idx do
					c[k] = col[i]
				end
				return c
			end
			times, values = reorder(times), reorder(values)
			for i = 1, #labelValues do
				labelValues[i] = reorder(labelValues[i])
			end
		end
		local fields: { Field } =
			{ Frame.field("Time", "time", times, nil, if interval then { interval = interval } else nil) }
		for i, name in labelNames do
			table.insert(fields, Frame.field(name, "string", labelValues[i]))
		end
		table.insert(fields, Frame.field(if #order > 1 then "Value #" .. ref else "Value", "number", values))
		table.insert(out, { refId = if ref ~= "" then ref else nil, fields = fields, meta = group[1].meta })
	end
	return out
end

-- Frame matcher byRefId (matchers/refIdMatcher.ts).
local function refIdMatcher(pattern: string): (Frame) -> boolean
	local re: Regex.Regex? = nil
	if string.sub(pattern, 1, 1) == "/" then
		re = (Regex.parseJs(pattern))
	elseif string.find(pattern, "|", 1, true) then
		local parts: { string } = {}
		for piece in string.gmatch(pattern, "[^|]*") do
			table.insert(parts, Regex.escape(piece))
		end
		re = (Regex.compile("^(?:" .. table.concat(parts, "|") .. ")$"))
	end
	return function(frame: Frame): boolean
		if re then
			return (Regex.test(re, frame.refId or ""))
		end
		return frame.refId == pattern
	end
end

type FieldMatcher = (Field, Frame, { Frame }) -> boolean

-- getMatcherConfig: names -> byNames, pattern -> byRegexp, both -> either.
local function namesOrPattern(env: Env, raw: any): FieldMatcher?
	local o = Json.tbl(env, raw)
	if o == nil then
		return nil
	end
	local names: { string } = {}
	for _, n in Json.list(env, o.names) do
		if type(n) == "string" then
			table.insert(names, n)
		end
	end
	local pattern = Json.str(env, o.pattern)
	if #names == 0 and (pattern == nil or pattern == "") then
		return nil
	end
	local options: { [string]: any } = { names = names }
	local id = "byNames"
	if pattern and pattern ~= "" then
		if #names == 0 then
			return FieldConfig.matcherFor(env, { id = "byRegexp", options = pattern })
		end
		id = "byRegexpOrNames"
		options.pattern = pattern
	end
	return FieldConfig.matcherFor(env, { id = id, options = options })
end

local function filterFields(frames: { Frame }, include: FieldMatcher?, exclude: FieldMatcher?): { Frame }
	if include == nil and exclude == nil then
		return frames
	end
	local out: { Frame } = {}
	for _, frame in frames do
		local fields: { Field } = {}
		for _, field in frame.fields do
			if exclude then
				if exclude(field, frame, frames) then
					continue
				end
				if include == nil then
					table.insert(fields, field)
				end
			end
			if include and include(field, frame, frames) then
				table.insert(fields, field)
			end
		end
		if #fields > 0 then
			local copy = table.clone(frame)
			copy.fields = fields
			table.insert(out, copy)
		end
	end
	return out
end

local function trueKeys(env: Env, raw: any): { string }?
	local t = Json.tbl(env, raw)
	if t == nil then
		return nil
	end
	local out: { string } = {}
	for k, v in t do
		if type(k) == "string" and v == true then
			table.insert(out, k)
		end
	end
	table.sort(out)
	return if #out > 0 then out else nil
end

local function organize(frames: { Frame }, options: any, env: Env): { Frame }
	local include = trueKeys(env, Json.path(env, options, "includeByName"))
	local exclude = trueKeys(env, Json.path(env, options, "excludeByName"))
	local result = filterFields(
		frames,
		if include then namesOrPattern(env, { names = include }) else nil,
		if exclude then namesOrPattern(env, { names = exclude }) else nil
	)
	-- order (manual): indexByName on display names, stable.
	local index = Json.tbl(env, Json.path(env, options, "indexByName"))
	if index and next(index) ~= nil then
		local ordered: { Frame } = {}
		for _, frame in result do
			local keyed: { { pos: number, at: number, field: Field } } = {}
			for i, field in frame.fields do
				local n = index[FieldConfig.displayName(field, frame, result)]
				local pos = if type(n) == "number" and n % 1 == 0 then n else math.huge
				table.insert(keyed, { pos = pos, at = i, field = field })
			end
			table.sort(keyed, function(a, b): boolean
				if a.pos ~= b.pos then
					return a.pos < b.pos
				end
				return a.at < b.at
			end)
			local copy = table.clone(frame)
			copy.fields = {}
			for _, k in keyed do
				table.insert(copy.fields, k.field)
			end
			table.insert(ordered, copy)
		end
		result = ordered
	end
	-- rename: renameByName on display names sets the field's displayName.
	local rename = Json.tbl(env, Json.path(env, options, "renameByName"))
	if rename and next(rename) ~= nil then
		local renamed: { Frame } = {}
		for _, frame in result do
			local copy = table.clone(frame)
			copy.fields = {}
			for _, field in frame.fields do
				local to = rename[FieldConfig.displayName(field, frame)]
				if type(to) == "string" and to ~= "" then
					local f = table.clone(field)
					local c: Frame.FieldConfig = if f.config then table.clone(f.config) else {}
					c.displayName = to
					f.config = c
					table.insert(copy.fields, f)
				else
					table.insert(copy.fields, field)
				end
			end
			table.insert(renamed, copy)
		end
		result = renamed
	end
	return result
end

local function filterByRefId(frames: { Frame }, options: any, env: Env): { Frame }
	local include = Json.str(env, Json.path(env, options, "include"))
	local exclude = Json.str(env, Json.path(env, options, "exclude"))
	local inc = if include and include ~= "" then refIdMatcher(include) else nil
	local exc = if exclude and exclude ~= "" then refIdMatcher(exclude) else nil
	if inc == nil and exc == nil then
		return frames
	end
	local out: { Frame } = {}
	for _, frame in frames do
		if exc then
			if exc(frame) then
				continue
			end
			if inc == nil then
				table.insert(out, frame)
			end
		end
		if inc and inc(frame) then
			table.insert(out, frame)
		end
	end
	return out
end

local function active(env: Env, t: any): boolean
	return Json.bool(env, Json.path(env, t, "disabled")) ~= true
end

-- The first transformation Tern cannot apply, as a reason, or nil.
function M.unsupported(panel: any, env: Env): string?
	for _, t in Json.list(env, Json.path(env, panel, "transformations")) do
		if not active(env, t) then
			continue
		end
		local id = Json.str(env, Json.path(env, t, "id"))
		if id == nil or not SUPPORTED[id] then
			return string.format("transformation %s is not supported", tostring(id))
		end
		local filter = Json.tbl(env, Json.path(env, t, "filter"))
		if filter and Json.str(env, filter.id) ~= "byRefId" then
			return string.format("transformation %s with a %s filter is not supported", id, tostring(filter.id))
		end
		if id == "filterFieldsByName" and Json.bool(env, Json.path(env, t, "options", "byVariable")) == true then
			return "transformation filterFieldsByName by variable is not supported"
		end
	end
	return nil
end

-- Frames as the panel's visualization receives them.
function M.prepare(panel: any, frames: { Frame }, env: Env): { Frame }
	local data: { Frame } = {}
	local tables: { Frame } = {}
	local refs = tableRefIds(panel, env)
	for _, f in frames do
		local custom = f.meta and f.meta.custom
		if custom and custom.resultType == "exemplar" then
			continue
		end
		if isPrometheus(f) and f.refId and refs[f.refId] then
			table.insert(tables, f)
		else
			table.insert(data, f)
		end
	end
	if #tables > 0 then
		for _, t in toTables(tables) do
			table.insert(data, t)
		end
	end
	for _, t in Json.list(env, Json.path(env, panel, "transformations")) do
		if not active(env, t) then
			continue
		end
		local id = Json.str(env, Json.path(env, t, "id"))
		local options = Json.path(env, t, "options")
		local apply: (({ Frame }) -> { Frame })? = nil
		if id == "organize" then
			apply = function(fs: { Frame }): { Frame }
				return organize(fs, options, env)
			end
		elseif id == "filterFieldsByName" then
			apply = function(fs: { Frame }): { Frame }
				return filterFields(
					fs,
					namesOrPattern(env, Json.path(env, options, "include")),
					namesOrPattern(env, Json.path(env, options, "exclude"))
				)
			end
		elseif id == "filterByRefId" then
			apply = function(fs: { Frame }): { Frame }
				return filterByRefId(fs, options, env)
			end
		end
		if apply == nil then
			continue
		end
		local filter = Json.tbl(env, Json.path(env, t, "filter"))
		local pattern = if filter then Json.str(env, filter.options) else nil
		if pattern then
			-- Apply to the matching frames only; the rest pass through.
			local match = refIdMatcher(pattern)
			local hit: { Frame }, pass: { Frame } = {}, {}
			for _, f in data do
				table.insert(if match(f) then hit else pass, f)
			end
			data = apply(hit)
			for _, f in pass do
				table.insert(data, f)
			end
		else
			data = apply(data)
		end
	end
	return data
end

return M
