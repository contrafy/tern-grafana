--!strict
-- Log volume: the metric query counting lines per level over fixed buckets,
-- and its answer (one series per level, Loki direct or through Grafana) as
-- per-bucket totals for `chart` bars plus totals per level.

local Frame = require("../frame/types")
local LogQL = require("./logql")
local LogsPanel = require("../panels/logs")
local Step = require("../time/step")

type Frame = Frame.Frame
type Level = LogsPanel.Level

-- Counts by level name (lib/panels/logs Level).
export type Bucket = { t_ms: number, total: number, levels: { [string]: number } }

export type Volume = {
	step_ms: number,
	buckets: { Bucket },
	totals: { [string]: number },
	total: number,
	-- Largest bucket total (0 when empty).
	max: number,
}

local M = {}

-- About this many bars across the range.
M.BUCKETS = 60
-- Grouping labels: `level` (an indexed label) and Loki's own detected_level.
M.BY = "level, detected_level"
M.LEVEL_ORDER = table.freeze({ "critical", "error", "warning", "info", "debug", "trace", "unknown" })

-- Bucket width for a range: a round interval, at least a second.
function M.step(span_ms: number): number
	return math.max(1000, Step.interval(math.max(1, span_ms), M.BUCKETS).interval_ms)
end

function M.query(expr: string, step_ms: number): string
	return LogQL.volume(expr, M.BY, Step.formatInterval(step_ms))
end

local function levelOf(labels: { [string]: string }?): Level
	local key = if labels then labels.detected_level or labels.level else nil
	if key == nil or key == "" then
		return "unknown"
	end
	return LogsPanel.levelFromKey(key)
end

-- Buckets from `from_ms` to `to_ms` (aligned to the step) with the counts of
-- every series frame added up.
function M.build(frames: { Frame }, from_ms: number, to_ms: number, step_ms: number): Volume
	local first = math.floor(from_ms / step_ms) * step_ms
	local buckets: { Bucket } = {}
	local t = first
	while t <= to_ms and #buckets < 2000 do
		table.insert(buckets, { t_ms = t, total = 0, levels = {} })
		t += step_ms
	end
	local totals: { [string]: number } = {}
	local total = 0
	for _, frame in frames do
		local time = Frame.timeField(frame)
		if time == nil then
			continue
		end
		for _, f in Frame.numberFields(frame) do
			local level = levelOf(f.labels)
			for j, v in f.values do
				local n = Frame.finite(v)
				local at = time.values[j]
				if n == nil or n == 0 or type(at) ~= "number" then
					continue
				end
				-- Loki stamps a count with its bucket's end.
				local index = math.floor((at - 1 - first) / step_ms) + 1
				local b = buckets[math.clamp(index, 1, math.max(1, #buckets))]
				if b == nil then
					continue
				end
				b.total += n
				b.levels[level] = (b.levels[level] or 0) + n
				totals[level] = (totals[level] or 0) + n
				total += n
			end
		end
	end
	local max = 0
	for _, b in buckets do
		max = math.max(max, b.total)
	end
	return { step_ms = step_ms, buckets = buckets, totals = totals, total = total, max = max }
end

return M
