--!strict
-- Keeps refreshes from producing new chart bytes when nothing visible moved.
-- Tern keeps every distinct blob file for the session (docs/performance.md),
-- so a chart whose data did not change must render to the same bytes.
--
-- A range ending at "now" moves by milliseconds on every refresh, and
-- Grafana (and the Query block, lib/query/state.luau) align a range query to
-- its step, so between two step boundaries the answer is byte-identical while
-- the drawn x axis would still shift. Drawing the range with its end snapped
-- down to the step (the last sample Grafana returns sits there) keeps the
-- picture, and its blob, identical until a new sample can exist. The shift
-- is under one step: a few pixels at most, since the step is at least the
-- range over the panel's max data points.

local M = {}

-- `from_ms..to_ms` moved back so `to_ms` is a multiple of `step_ms`, width
-- kept; unchanged for a step that is not positive.
function M.snapRange(from_ms: number, to_ms: number, step_ms: number?): (number, number)
	if step_ms == nil or step_ms <= 0 then
		return from_ms, to_ms
	end
	local shift = to_ms % step_ms
	return from_ms - shift, to_ms - shift
end

-- Whether a Grafana range string is relative to now (an end at "now" or
-- "now-5m" moves with time; an absolute one does not and is never snapped).
function M.relative(to: string?): boolean
	return to ~= nil and string.find(to, "now", 1, true) ~= nil
end

return M
