--!strict
-- Field display names and field macros (lib/panels/fieldconfig):
-- calculateFieldDisplayName (field/fieldState.ts), ${__field.*} /
-- ${__series.name} in a displayName, and dashboard variables in field
-- config displayName strings.

local Env = require("../env")
local Frame = require("../frame/types")
local Interpolate = require("../dashboard/interpolate")
local Json = require("./json")
local Tbl = require("../tbl")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field

local M = {}

-- Display names ---------------------------------------------------------------

-- Grafana formatLabels (utils/labels.ts): every label, sorted,
-- `{a="1", b="2"}`; without the braces for `${__field.labels}`.
local function formatLabels(labels: { [string]: string }, withoutBraces: boolean?): string
	local keys: { string } = {}
	for k in labels do
		table.insert(keys, k)
	end
	if #keys == 0 then
		return ""
	end
	table.sort(keys)
	local parts: { string } = table.create(#keys)
	for i, k in keys do
		parts[i] = string.format('%s="%s"', k, labels[k])
	end
	local text = table.concat(parts, ", ")
	return if withoutBraces then text else "{" .. text .. "}"
end

-- getSingleLabelName: the label key when every labeled field across the
-- frames has that one key only.
local function singleLabelName(frames: { Frame }): string?
	local single: string? = nil
	for _, frame in frames do
		for _, field in frame.fields do
			if field.labels then
				for k in field.labels do
					if single == nil then
						single = k
					elseif k ~= single then
						return nil
					end
				end
			end
		end
	end
	return single
end

-- getUniqueFieldName (field/fieldState.ts): a name other fields of the
-- frame share gets " <n>", n counting the duplicates up to this field.
local function uniqueName(field: Field, frame: Frame?): string
	if frame == nil then
		return field.name
	end
	local dupes, foundSelf = 0, false
	for _, other in frame.fields do
		if other == field then
			foundSelf = true
			if dupes > 0 then
				dupes += 1
				break
			end
		elseif other.name == field.name then
			dupes += 1
			if foundSelf then
				break
			end
		end
	end
	return if dupes > 0 then field.name .. " " .. dupes else field.name
end

-- Names of one M.resolve pass: the frames-wide facts (namesDiffer, the
-- single label key) and every field's name are computed once instead of per
-- matcher call. Only consulted for the exact `frames` table being resolved.
type NameMemo = {
	frames: { Frame },
	names: { [Field]: string },
	differ: boolean?,
	single: string | false | nil,
}

local active: NameMemo? = nil

local function computeName(field: Field, frame: Frame?, frames: { Frame }?, memo: NameMemo?): string
	local config = field.config
	if config and config.displayName and config.displayName ~= "" then
		return config.displayName
	end
	if field.type == "time" and field.labels == nil then
		return if field.name ~= "" then field.name else "Time"
	end
	local all = frames or (if frame then { frame } else {})
	local parts: { string } = {}
	local namesDiffer = if memo then memo.differ else nil
	if namesDiffer == nil then
		namesDiffer = false
		for i = 2, #all do
			if all[i].name ~= all[i - 1].name then
				namesDiffer = true
				break
			end
		end
		if memo then
			memo.differ = namesDiffer
		end
	end
	local frameNameAdded, labelsAdded = false, false
	if namesDiffer and frame and frame.name and frame.name ~= "" then
		table.insert(parts, frame.name)
		frameNameAdded = true
	end
	if field.name ~= "" and field.name ~= "Value" then
		table.insert(parts, field.name)
	end
	if field.labels and frame then
		local single: string?
		if memo and memo.single ~= nil then
			single = memo.single or nil
		else
			single = singleLabelName(all)
			if memo then
				memo.single = single or false
			end
		end
		if single == nil then
			local text = formatLabels(field.labels)
			if text ~= "" then
				table.insert(parts, text)
				labelsAdded = true
			end
		elseif field.labels[single] and field.labels[single] ~= "" then
			table.insert(parts, field.labels[single])
			labelsAdded = true
		end
	end
	if frame and not frameNameAdded and not labelsAdded and field.name == "Value" then
		if frame.name and frame.name ~= "" then
			table.insert(parts, frame.name)
		end
	end
	local name = if #parts > 0 then table.concat(parts, " ") elseif field.name ~= "" then field.name else "Value"
	-- "Ensure unique field name": a joined table's two Time columns read
	-- "Time 1" and "Time 2", the names organize/rename/sortBy refer to.
	if name == field.name then
		return uniqueName(field, frame)
	end
	return name
end

-- calculateFieldDisplayName. The frame converters store Grafana's
-- displayNameFromDS in config.displayName, so it comes first here exactly
-- as it does in Grafana (a panel displayName replaces it beforehand).
function M.displayName(field: Field, frame: Frame?, frames: { Frame }?): string
	local memo = active
	if memo and frames ~= nil and frames == memo.frames then
		local hit = memo.names[field]
		if hit == nil then
			hit = computeName(field, frame, frames, memo)
			memo.names[field] = hit
		end
		return hit :: string
	end
	return computeName(field, frame, frames, nil)
end

-- Field macros ----------------------------------------------------------------

-- getFrameDisplayName (field/fieldState.ts) of the frame at 0-based `index`:
-- its name, else its one value field's display name, else "Series (refId)",
-- else "Series (index)".
local function frameDisplayName(frame: Frame, index: number): string
	if frame.name and frame.name ~= "" then
		return frame.name
	end
	local names: { string } = {}
	for _, f in frame.fields do
		if f.type ~= "time" then
			if #names > 1 then
				break
			end
			table.insert(names, M.displayName(f, frame))
		end
	end
	if #names == 1 then
		return names[1]
	end
	if frame.refId and frame.refId ~= "" then
		return "Series (" .. frame.refId .. ")"
	end
	return "Series (" .. tostring(index) .. ")"
end

-- The data macros a display name can use (public/app/features/templating/
-- dataMacros.ts fieldMacro and seriesNameMacro over templateProxies.ts
-- getTemplateProxyForField): `${__field.name}`, `${__field.displayName}`,
-- `${__field.labels}` (`a="1", b="2"`), `${__field.labels.<key>}`,
-- `${__field.labels.__values}` (the sorted values) and `${__series.name}`.
-- Another `__field` path reads "" (lodash property finds nothing); a
-- reference without a path stays as written.
local function fieldMacro(field: Field, frame: Frame, frameIndex: number, frames: { Frame })
	return function(name: string, path: string?): Interpolate.Var?
		if path == nil or path == "" then
			return nil
		elseif name == "__series" then
			return if path == "name" then Interpolate.value(frameDisplayName(frame, frameIndex - 1)) else nil
		elseif name ~= "__field" then
			return nil
		end
		local labels = field.labels
		local text = ""
		if path == "name" then
			text = field.name
		elseif path == "displayName" then
			text = M.displayName(field, frame, frames)
		elseif path == "labels" or path == "formattedLabels" then
			text = if labels then formatLabels(labels, true) else ""
		else
			local key = string.match(path, "^labels%.(.+)$") or string.match(path, "^formattedLabels%.(.+)$")
			if key == "__values" and labels then
				local values: { string } = {}
				for _, v in labels do
					table.insert(values, v)
				end
				table.sort(values)
				text = table.concat(values, ", ")
			elseif key and labels then
				text = labels[key] or ""
			end
		end
		return Interpolate.value(text)
	end
end

local NO_SCOPE: Interpolate.Scope = table.freeze({})

-- A displayName with the field's macros replaced (stringOverrideProcessor
-- with the field's scopedVars); nil when it reads "", which Grafana treats
-- as no displayName.
local function scopedName(text: string, field: Field, frame: Frame, frameIndex: number, frames: { Frame }): string?
	if not string.find(text, "${__", 1, true) then
		return text
	end
	local out = Interpolate.replace(text, NO_SCOPE, { macro = fieldMacro(field, frame, frameIndex, frames) })
	return if out ~= "" then out else nil
end

-- The panel with its displayName strings (fieldConfig defaults and
-- overrides; the one standard field option registered with
-- expandTemplateVars, public/app/core/components/OptionsUI/registry.tsx)
-- passed through `replace`, the dashboard variables. Field macros are left
-- for resolve, which knows each field. The panel itself when none changes.
function M.withVariables(panel: any, env: Env, replace: (string) -> string): any
	local fc = Json.tbl(env, Json.path(env, panel, "fieldConfig"))
	if fc == nil then
		return panel
	end
	local changed = false
	local function sub(t: { [any]: any }, key: string): { [any]: any }
		local v = t[key]
		local s = if type(v) == "string" then replace(v) else v
		if s == v then
			return t
		end
		changed = true
		local c = Tbl.copy(t)
		c[key] = s
		return c
	end
	local newFc = Tbl.copy(fc)
	local defaults = Json.tbl(env, fc.defaults)
	if defaults then
		newFc.defaults = sub(defaults, "displayName")
	end
	local overrides: { any } = {}
	for i, o in Json.list(env, fc.overrides) do
		local ot = Json.tbl(env, o)
		if ot == nil then
			overrides[i] = o
			continue
		end
		local props: { any } = {}
		for j, p in Json.list(env, ot.properties) do
			local pt = Json.tbl(env, p)
			props[j] = if pt and pt.id == "displayName" then sub(pt, "value") else p
		end
		local no = Tbl.copy(ot)
		no.properties = props
		overrides[i] = no
	end
	if not changed then
		return panel
	end
	newFc.overrides = overrides
	local out = Tbl.copy(panel)
	out.fieldConfig = newFc
	return out
end

M.scoped = scopedName

-- Runs fn(...) with the names over `frames` memoized: one M.resolve pass
-- names every field once instead of once per override matcher.
function M.within(frames: { Frame }, fn: (...any) -> (), ...: any)
	local outer = active
	active = { frames = frames, names = {} }
	local ok, err = pcall(fn :: any, ...)
	active = outer
	if not ok then
		error(err, 0)
	end
end

return M
