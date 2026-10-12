--!strict
-- Polling tail: each poll asks Loki for the lines since a little before the
-- newest line already shown, so a line ingested late (its timestamp earlier
-- than lines already received) is still caught. The windows overlap on
-- purpose; a line received twice is recognized by its id (nanosecond
-- timestamp plus a hash of its stream and text, lib/frame/loki.luau) and
-- kept once.

local FrameLoki = require("../frame/loki")

type Line = FrameLoki.Line

local M = {}

-- How far before the newest shown line a poll starts, at least.
M.MIN_OVERLAP_MS = 5000

function M.overlapMs(tail_ms: number): number
	return math.max(M.MIN_OVERLAP_MS, 2 * tail_ms)
end

-- Start of the next poll window (epoch ms): the newest line minus the
-- overlap, never before the range start; the range start when nothing is
-- shown yet.
function M.windowStart(lines: { Line }, range_from_ms: number, tail_ms: number): number
	local newest = lines[1]
	if newest == nil then
		return range_from_ms
	end
	return math.max(range_from_ms, math.floor(newest.time_ms) - M.overlapMs(tail_ms))
end

-- `incoming` (any order) merged into `lines` (newest first): new ids only,
-- newest first, at most `limit` (the oldest drop). Returns the merged list
-- and how many lines were new.
function M.merge(lines: { Line }, incoming: { Line }, limit: number): ({ Line }, number)
	local seen: { [string]: boolean } = {}
	for _, l in lines do
		seen[l.id] = true
	end
	local fresh: { Line } = {}
	for _, l in incoming do
		if not seen[l.id] then
			seen[l.id] = true
			table.insert(fresh, l)
		end
	end
	if #fresh == 0 then
		return lines, 0
	end
	local merged = table.clone(fresh)
	table.move(lines, 1, #lines, #merged + 1, merged)
	FrameLoki.sort(merged)
	if #merged > limit then
		for i = #merged, limit + 1, -1 do
			merged[i] = nil
		end
	end
	return merged, #fresh
end

return M
