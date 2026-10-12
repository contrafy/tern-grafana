--!strict
-- The `annotations` section of the config file (docs/annotations.md). Off
-- until `enabled` is true. A bad value falls back to its default with a
-- problem naming the path; a bad `enabled` keeps the feature off.

local Command = require("./command")
local Types = require("../config/types")
local Tbl = require("../tbl")

type Config = Types.Config
type Problem = Types.Problem

export type On = "success" | "always"

export type Settings = {
	enabled: boolean,
	-- Which finished commands are annotated: exit 0 only, or any status.
	on: On,
	-- As configured (or the defaults), and compiled.
	patterns: { string },
	compiled: { Command.Pattern },
	tags: { string },
	-- Context to annotate; nil means the (host's) default context.
	context: string?,
	dashboard_uid: string?,
	panel_id: number?,
}

local M = {}

M.DEFAULT_TAGS = table.freeze({ "tern", "deploy" })
M.MAX_PATTERNS = 64
M.MAX_TAGS = 16

local KNOWN = { "context", "dashboard_uid", "enabled", "on", "panel_id", "patterns", "tags" }

local function problem(problems: { Problem }, section: string, path: string, message: string)
	table.insert(problems, { path = if path == "" then section else section .. "." .. path, message = message })
end

-- Shared by the impact section: a list of non-empty strings.
function M.stringList(raw: any, section: string, path: string, problems: { Problem }): { string }?
	if type(raw) ~= "table" then
		problem(problems, section, path, "must be a list of strings")
		return nil
	end
	local out: { string } = {}
	for _, v in raw do
		if type(v) ~= "string" or string.match(v, "^%s*$") then
			problem(problems, section, path, "must be a list of non-empty strings")
			return nil
		end
		table.insert(out, v)
	end
	return out
end

function M.readOn(raw: any, section: string, problems: { Problem }): On?
	if raw == "success" or raw == "always" then
		return raw
	end
	problem(problems, section, "on", 'must be "success" or "always"')
	return nil
end

function M.readContext(raw: any, config: Config?, section: string, problems: { Problem }): string?
	if type(raw) ~= "string" then
		problem(problems, section, "context", "must be a context name")
		return nil
	end
	if config and config.contexts[raw] == nil then
		problem(problems, section, "context", string.format("no context named %q", raw))
		return nil
	end
	return raw
end

function M.read(config: Config?): (Settings, { Problem })
	local problems: { Problem } = {}
	local settings: Settings = {
		enabled = false,
		on = "success",
		patterns = Tbl.copy(Command.DEFAULT_PATTERNS),
		compiled = Command.compileAll(Command.DEFAULT_PATTERNS),
		tags = Tbl.copy(M.DEFAULT_TAGS),
		context = nil,
		dashboard_uid = nil,
		panel_id = nil,
	}
	local raw = if config then config.annotations else nil
	if raw == nil then
		return settings, problems
	end
	if type(raw) ~= "table" then
		problem(problems, "annotations", "", "must be an object")
		return settings, problems
	end
	for key in raw do
		if not table.find(KNOWN, key) then
			problem(problems, "annotations", tostring(key), "unknown key (known: " .. table.concat(KNOWN, ", ") .. ")")
		end
	end
	if raw.enabled ~= nil then
		if type(raw.enabled) == "boolean" then
			settings.enabled = raw.enabled
		else
			problem(problems, "annotations", "enabled", "must be true or false")
		end
	end
	if raw.on ~= nil then
		settings.on = M.readOn(raw.on, "annotations", problems) or settings.on
	end
	if raw.patterns ~= nil then
		local list = M.stringList(raw.patterns, "annotations", "patterns", problems)
		if list and #list > M.MAX_PATTERNS then
			problem(problems, "annotations", "patterns", string.format("at most %d patterns", M.MAX_PATTERNS))
		elseif list then
			settings.patterns = list
			settings.compiled = Command.compileAll(list)
		end
	end
	if raw.tags ~= nil then
		local list = M.stringList(raw.tags, "annotations", "tags", problems)
		if list and #list > M.MAX_TAGS then
			problem(problems, "annotations", "tags", string.format("at most %d tags", M.MAX_TAGS))
		elseif list then
			settings.tags = list
		end
	end
	if raw.context ~= nil then
		settings.context = M.readContext(raw.context, config, "annotations", problems)
	end
	if raw.dashboard_uid ~= nil then
		local v = raw.dashboard_uid
		if type(v) == "string" and string.match(v, "^[%w_%-]+$") and #v <= 128 then
			settings.dashboard_uid = v
		else
			problem(problems, "annotations", "dashboard_uid", "must be a dashboard uid")
		end
	end
	if raw.panel_id ~= nil then
		local v = raw.panel_id
		if type(v) == "number" and v == math.floor(v) and v >= 1 then
			settings.panel_id = v
		else
			problem(problems, "annotations", "panel_id", "must be a positive whole number")
		end
		if settings.dashboard_uid == nil then
			problem(problems, "annotations", "panel_id", "needs dashboard_uid")
			settings.panel_id = nil
		end
	end
	return settings, problems
end

-- Whether a command that ended with `status` qualifies.
function M.gate(on: On, status: number): boolean
	return on == "always" or status == 0
end

return M
