--!strict
-- The `trace` section of the config file (docs/traces.md). A bad value falls
-- back to its default with a problem that names the path.

local Range = require("../time/range")
local Types = require("../config/types")

type Config = Types.Config
type Problem = Types.Problem

export type Settings = {
	-- Traces one TraceQL search returns.
	search_limit: number,
	-- Start of the search range (its end is "now").
	range: string,
}

local M = {}

M.DEFAULT_LIMIT = 20
M.MAX_LIMIT = 1000
M.DEFAULT_RANGE = "now-1h"

local function problem(problems: { Problem }, path: string, message: string)
	table.insert(problems, { path = "trace." .. path, message = message })
end

function M.read(config: Config?): (Settings, { Problem })
	local problems: { Problem } = {}
	local settings: Settings = { search_limit = M.DEFAULT_LIMIT, range = M.DEFAULT_RANGE }
	local raw = if config then config.trace else nil
	if raw == nil then
		return settings, problems
	end
	if type(raw) ~= "table" then
		problem(problems, "", "must be an object")
		return settings, problems
	end
	for key in raw do
		if key ~= "search_limit" and key ~= "range" then
			problem(problems, tostring(key), "unknown key (known: range, search_limit)")
		end
	end
	local limit = raw.search_limit
	if limit ~= nil then
		if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 1 or limit > M.MAX_LIMIT then
			problem(problems, "search_limit", string.format("must be a whole number from 1 to %d", M.MAX_LIMIT))
		else
			settings.search_limit = limit
		end
	end
	local range = raw.range
	if range ~= nil then
		if
			type(range) ~= "string"
			or not Range.isRelative(range)
			or Range.parse(range, false, { now_ms = 0 }) == nil
		then
			problem(problems, "range", 'must be a relative Grafana time such as "now-1h"')
		else
			settings.range = range
		end
	end
	return settings, problems
end

return M
