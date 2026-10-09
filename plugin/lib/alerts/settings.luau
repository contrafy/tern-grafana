--!strict
-- The `alerts` section of the config file (docs/configuration.md). The
-- validator keeps feature sections as written; this module gives them
-- meaning. A bad value falls back to its default with a problem that names
-- the path, so one typo never silences the inbox or the status segment.

local Types = require("../config/types")

type Config = Types.Config
type Problem = Types.Problem

export type Settings = {
	-- Labels alerts are grouped by in the inbox; {"..."} groups each alert alone.
	group_by: { string },
	-- Seconds between background polls; 0 turns polling (and the status segment) off.
	poll_s: number,
	-- Contexts the background poller watches.
	contexts: { string },
}

local M = {}

M.DEFAULT_POLL_S = 60
M.MIN_POLL_S = 15
-- Bounds the work and the kv payload of one poll.
M.MAX_CONTEXTS = 16

local function problem(problems: { Problem }, path: string, message: string)
	table.insert(problems, { path = "alerts." .. path, message = message })
end

local function stringList(raw: any, path: string, problems: { Problem }): { string }?
	if type(raw) ~= "table" then
		problem(problems, path, "must be a list of strings")
		return nil
	end
	local out: { string } = {}
	for _, v in raw do
		if type(v) ~= "string" or v == "" then
			problem(problems, path, "must be a list of non-empty strings")
			return nil
		end
		table.insert(out, v)
	end
	return out
end

function M.read(config: Config?): (Settings, { Problem })
	local problems: { Problem } = {}
	local settings: Settings = {
		group_by = { "alertname" },
		poll_s = M.DEFAULT_POLL_S,
		contexts = {},
	}
	local default = if config then config.default_context else nil
	if default then
		settings.contexts = { default }
	end
	local raw = if config then config.alerts else nil
	if raw == nil then
		return settings, problems
	end
	if type(raw) ~= "table" then
		problem(problems, "", "must be an object")
		return settings, problems
	end
	for key in raw do
		if key ~= "group_by" and key ~= "poll_s" and key ~= "contexts" then
			problem(problems, tostring(key), "unknown key (known: contexts, group_by, poll_s)")
		end
	end
	if raw.group_by ~= nil then
		local list = stringList(raw.group_by, "group_by", problems)
		if list and #list > 0 then
			settings.group_by = list
		elseif list then
			problem(problems, "group_by", "must name at least one label")
		end
	end
	if raw.poll_s ~= nil then
		local n = raw.poll_s
		if type(n) ~= "number" or n ~= math.floor(n) or n < 0 then
			problem(problems, "poll_s", "must be a whole number of seconds (0 turns polling off)")
		elseif n > 0 and n < M.MIN_POLL_S then
			problem(problems, "poll_s", string.format("must be 0 or at least %d", M.MIN_POLL_S))
			settings.poll_s = M.MIN_POLL_S
		else
			settings.poll_s = n
		end
	end
	if raw.contexts ~= nil then
		local list = stringList(raw.contexts, "contexts", problems)
		if list then
			local known = if config then config.contexts else {}
			local out: { string } = {}
			for _, name in list do
				if known[name] == nil then
					problem(problems, "contexts", string.format("no context named %q", name))
				elseif #out < M.MAX_CONTEXTS and not table.find(out, name) then
					table.insert(out, name)
				end
			end
			if #list > M.MAX_CONTEXTS then
				problem(problems, "contexts", string.format("at most %d contexts are polled", M.MAX_CONTEXTS))
			end
			settings.contexts = out
		end
	end
	return settings, problems
end

return M
