--!strict
-- The `logs` section of the config file (docs/logs.md): defaults for the Logs
-- block. config/validate keeps the section as decoded, so every key is
-- checked here; a bad value falls back to its default and is reported as a
-- problem rather than breaking the block.

local Range = require("../time/range")
local Step = require("../time/step")
local Types = require("../config/types")

type Problem = Types.Problem

export type Options = {
	-- `from` of a new query's range (`to` is "now").
	default_range: string,
	-- Most lines a query (and the tail buffer) holds.
	limit: number,
	-- Tail polling interval.
	tail_ms: number,
	-- Show the volume bars above the lines.
	volume: boolean,
}

local M = {}

M.DEFAULT_RANGE = "now-1h"
M.LIMIT = 500
M.MIN_LIMIT = 1
-- Each line is a text node; past this the view stops being cheap.
M.MAX_LIMIT = 5000
M.TAIL_MS = 2000
M.MIN_TAIL_MS = 1000
M.MAX_TAIL_MS = 60000

local KEYS: { [string]: boolean } = { default_range = true, limit = true, tail_interval = true, volume = true }

function M.defaults(): Options
	return { default_range = M.DEFAULT_RANGE, limit = M.LIMIT, tail_ms = M.TAIL_MS, volume = true }
end

-- Options from the decoded section (nil when absent) and what was wrong with it.
function M.read(section: any): (Options, { Problem })
	local o = M.defaults()
	local problems: { Problem } = {}
	local function bad(key: string, message: string)
		table.insert(problems, { path = "logs." .. key, message = message })
	end
	if section == nil then
		return o, problems
	end
	if type(section) ~= "table" then
		table.insert(problems, { path = "logs", message = "must be an object" })
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

	local limit = section.limit
	if limit ~= nil then
		if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < M.MIN_LIMIT or limit > M.MAX_LIMIT then
			bad("limit", string.format("must be a whole number from %d to %d", M.MIN_LIMIT, M.MAX_LIMIT))
		else
			o.limit = limit
		end
	end

	local tail = section.tail_interval
	if tail ~= nil then
		local ms = if type(tail) == "string" then Step.parseDuration(tail) else nil
		if ms == nil or ms < M.MIN_TAIL_MS or ms > M.MAX_TAIL_MS then
			bad("tail_interval", 'must be a duration from 1s to 1m, like "2s"')
		else
			o.tail_ms = ms
		end
	end

	local volume = section.volume
	if volume ~= nil then
		if type(volume) ~= "boolean" then
			bad("volume", "must be true or false")
		else
			o.volume = volume
		end
	end
	return o, problems
end

return M
