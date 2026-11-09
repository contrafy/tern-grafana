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

-- The ids of `lines`, for merge's `seen`.
function M.ids(lines: { Line }): { [string]: boolean }
	local seen: { [string]: boolean } = {}
	for _, l in lines do
		seen[l.id] = true
	end
	return seen
end

-- `incoming` (any order) merged into `lines` (newest first): new ids only,
-- newest first (a new line before a shown one of the same nanosecond), at
-- most `limit` (the oldest drop). Returns the merged list (`lines` itself
-- when nothing is new), how many lines were new and the lines dropped.
-- `seen` (the ids of `lines`, see M.ids) is kept up to date when given, so
-- a caller polling again needs no rebuild.
function M.merge(
	lines: { Line },
	incoming: { Line },
	limit: number,
	seen: { [string]: boolean }?
): ({ Line }, number, { Line })
	local ids = seen or M.ids(lines)
	local fresh: { Line } = {}
	for _, l in incoming do
		if not ids[l.id] then
			ids[l.id] = true
			table.insert(fresh, l)
		end
	end
	if #fresh == 0 then
		return lines, 0, {}
	end
	FrameLoki.sort(fresh)
	local nf, nl = #fresh, #lines
	local total = nf + nl
	local keep = math.min(total, limit)
	local merged: { Line } = table.create(keep)
	local i, j = 1, 1
	for k = 1, keep do
		local a, b = fresh[i], lines[j]
		if a and (b == nil or FrameLoki.compareNs(a.ts_ns, b.ts_ns) >= 0) then
			merged[k] = a
			i += 1
		else
			merged[k] = b
			j += 1
		end
	end
	local dropped: { Line } = {}
	for k = i, nf do
		table.insert(dropped, fresh[k])
	end
	for k = j, nl do
		table.insert(dropped, lines[k])
	end
	for _, l in dropped do
		ids[l.id] = nil
	end
	return merged, nf, dropped
end

return M
