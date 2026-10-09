--!strict
-- The `query` section of the config file (docs/configuration.md): defaults
-- for the Query block. The section is kept as decoded by config/validate, so
-- every key is checked here; a bad value falls back to its default and is
-- reported as a problem rather than breaking the block.

local Range = require("../time/range")
local Step = require("../time/step")
local Types = require("../config/types")

type Problem = Types.Problem

export type Options = {
	-- `from` of a new query's range (`to` is "now").
	default_range: string,
	-- Points per series a range query asks for; sets the step.
	max_points: number,
	-- Auto-refresh interval used when the user turns it on with `a`.
	refresh_ms: number,
}

local M = {}

M.DEFAULT_RANGE = "now-1h"
M.MAX_POINTS = 600
M.REFRESH_MS = 30000
-- Prometheus refuses range queries over 11000 points per series.
M.MAX_POINTS_LIMIT = 11000
M.MIN_POINTS = 10
-- Faster refreshes mint a new chart blob every few seconds (blobs are never
-- evicted within a session).
M.MIN_REFRESH_MS = 5000

local KEYS: { [string]: boolean } = { default_range = true, max_points = true, refresh = true }

function M.defaults(): Options
	return { default_range = M.DEFAULT_RANGE, max_points = M.MAX_POINTS, refresh_ms = M.REFRESH_MS }
end

-- Options from the decoded section (nil when absent) and what was wrong with it.
function M.read(section: any): (Options, { Problem })
	local o = M.defaults()
	local problems: { Problem } = {}
	local function bad(key: string, message: string)
		table.insert(problems, { path = "query." .. key, message = message })
	end
	if section == nil then
		return o, problems
	end
	if type(section) ~= "table" then
		table.insert(problems, { path = "query", message = "must be an object" })
		return o, problems
	end
	local names: { string } = {}
	for k in section do
		if type(k) ~= "string" or not KEYS[k] then
			table.insert(names, tostring(k))
		end
	end
	table.sort(names)
	for _, k in names do
		bad(k, "unknown key")
	end

	local range = section.default_range
	if range ~= nil then
		if type(range) ~= "string" or (Range.parse(range, false, { now_ms = 0 })) == nil then
			bad("default_range", 'must be a Grafana time like "now-1h"')
		else
			o.default_range = range
		end
	end

	local points = section.max_points
	if points ~= nil then
		if
			type(points) ~= "number"
			or points ~= math.floor(points)
			or points < M.MIN_POINTS
			or points > M.MAX_POINTS_LIMIT
		then
			bad("max_points", string.format("must be a whole number from %d to %d", M.MIN_POINTS, M.MAX_POINTS_LIMIT))
		else
			o.max_points = points
		end
	end

	local refresh = section.refresh
	if refresh ~= nil then
		local ms = if type(refresh) == "string" then Step.parseDuration(refresh) else nil
		if ms == nil or ms < M.MIN_REFRESH_MS then
			bad("refresh", string.format('must be a duration of at least %ds, like "30s"', M.MIN_REFRESH_MS // 1000))
		else
			o.refresh_ms = ms
		end
	end
	return o, problems
end

return M
