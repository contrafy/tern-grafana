--!strict
-- renameByRegex: packages/grafana-data/src/transformations/transformers/
-- renameByRegex.ts (https://raw.githubusercontent.com/grafana/grafana/main/
-- packages/grafana-data/src/transformations/transformers/renameByRegex.ts).
-- Every field whose display name the regex matches gets
-- `displayName.replace(regex, renamePattern)` as its display name. The regex
-- goes through stringToJsRegex: text not starting with "/" matches the whole
-- name (`^text$`), "/body/flags" is used as written (the g flag replaces
-- every match); the pattern expands $1, $&, $<name> like String.replace.
-- Defaults are Grafana's: regex "(.*)", renamePattern "$1".

local FieldConfig = require("../fieldconfig")
local Frame = require("../../frame/types")
local Json = require("../json")
local Regex = require("../../regex")
local Shared = require("./shared")
local Tbl = require("../../tbl")

type Frame = Frame.Frame
type Field = Frame.Field
type Ctx = Shared.Ctx

local M = {}

local DEFAULT_REGEX = "(.*)"
local DEFAULT_PATTERN = "$1"

local function regexOf(options: any, ctx: Ctx): string
	return Json.str(ctx.env, Json.path(ctx.env, options, "regex")) or DEFAULT_REGEX
end

-- A regex Tern's engine cannot compile (lookbehind, the sticky flag) is
-- unsupported; one with a dashboard variable is only known once
-- interpolated, and fails then by leaving the names alone.
function M.unsupported(options: any, ctx: Ctx): string?
	local source = regexOf(options, ctx)
	if string.find(source, "$", 1, true) then
		return nil
	end
	local re, err = Regex.parseJs(source)
	if re == nil then
		return "regex " .. tostring(err)
	end
	return nil
end

function M.apply(data: { Frame }, options: any, ctx: Ctx): { Frame }
	if #data == 0 then
		return data
	end
	local re = Regex.parseJs(regexOf(options, ctx))
	if re == nil then
		return data
	end
	local pattern = Json.str(ctx.env, Json.path(ctx.env, options, "renamePattern")) or DEFAULT_PATTERN
	local out: { Frame } = table.create(#data)
	for i, frame in data do
		local fields: { Field } = table.create(#frame.fields)
		for k, field in frame.fields do
			local name = FieldConfig.displayName(field, frame)
			if not Regex.test(re, name) then
				fields[k] = field
				continue
			end
			local renamed, err = Regex.replace(re, name, pattern)
			if err ~= nil then
				fields[k] = field
				continue
			end
			local copy = Tbl.copy(field)
			local config: Frame.FieldConfig = if field.config then Tbl.copy(field.config) else {}
			config.displayName = renamed
			copy.config = config
			fields[k] = copy
		end
		out[i] = Shared.withFields(frame, fields)
	end
	return out
end

return M
