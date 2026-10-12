--!strict
-- The `investigate` section of the config file (docs/configuration.md):
--   range  how far back the alert preview fetches recent values of the
--          alert's query (a duration, default "1h").
-- A bad value falls back to the default with a problem naming the path.

local Step = require("../time/step")
local Types = require("../config/types")

type Config = Types.Config
type Problem = Types.Problem

export type Settings = {
	range: string,
	range_ms: number,
}

local M = {}

M.DEFAULT_RANGE = "1h"
M.DEFAULT_RANGE_MS = 3600000
-- Recent means recent: a week of samples is not a summary.
M.MAX_RANGE_MS = 7 * 86400000

local function problem(problems: { Problem }, path: string, message: string)
	table.insert(problems, { path = "investigate" .. (if path == "" then "" else "." .. path), message = message })
end

function M.read(config: Config?): (Settings, { Problem })
	local problems: { Problem } = {}
	local settings: Settings = { range = M.DEFAULT_RANGE, range_ms = M.DEFAULT_RANGE_MS }
	local raw = if config then (config :: any).investigate else nil
	if raw == nil then
		return settings, problems
	end
	if type(raw) ~= "table" then
		problem(problems, "", "must be an object")
		return settings, problems
	end
	for key in raw do
		if key ~= "range" then
			problem(problems, tostring(key), "unknown key (known: range)")
		end
	end
	if raw.range ~= nil then
		local ms = if type(raw.range) == "string" then Step.parseDuration(raw.range) else nil
		if ms == nil or ms <= 0 or ms > M.MAX_RANGE_MS then
			problem(problems, "range", 'must be a duration between 1s and 7d, such as "1h"')
		else
			settings.range = raw.range
			settings.range_ms = ms
		end
	end
	return settings, problems
end

return M
