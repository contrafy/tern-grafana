--!strict
-- Query interval and step math, as Grafana computes it:
-- - interval / roundInterval: packages/grafana-data/src/datetime/rangeutil.ts
--   calculateInterval, the panel interval Grafana sends as intervalMs.
-- - promStep / roundStep / formatInterval: pkg/promlib/models/query.go
--   calculatePrometheusInterval with grafana-plugin-sdk-go backend/gtime
--   RoundInterval and FormatInterval, the step Grafana sends to Prometheus.
-- - rateInterval, macros, interpolate: query.go calculateRateInterval and
--   InterpolateVariables. $__rate_interval is written in Prometheus duration
--   form ("1m") where Go writes "1m0s"; Prometheus reads both.
-- - align: query.go AlignTimeRange.
-- - parseDuration / formatDuration: Prometheus common/model ParseDuration and
--   Duration.String, plus bare (float) seconds as the HTTP API accepts.
-- All durations are milliseconds.

export type Interval = { interval_ms: number, interval_str: string }
export type Macros = {
	interval: string,
	interval_ms: string,
	range: string,
	range_s: string,
	range_ms: string,
	rate_interval: string,
	rate_interval_ms: string,
}

local M = {}

local SECOND = 1000
local MINUTE = 60 * SECOND
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR
local WEEK = 7 * DAY
local YEAR = 365 * DAY

-- Grafana's default scrape interval and Prometheus' safe resolution.
local DEFAULT_SCRAPE_MS = 15 * SECOND
local DEFAULT_RESOLUTION = 1500
local SAFE_RESOLUTION = 11000

-- A terminal cell is roughly 8 px wide at 1x; Grafana asks for one point per px.
local DEFAULT_PX_PER_CELL = 8

-- { exclusive upper edge, rounded value }
local FRONTEND_TABLE: { { number } } = {
	{ 10, 1 },
	{ 15, 10 },
	{ 35, 20 },
	{ 75, 50 },
	{ 150, 100 },
	{ 350, 200 },
	{ 750, 500 },
	{ 1500, 1000 },
	{ 3500, 2000 },
	{ 7500, 5000 },
	{ 12500, 10000 },
	{ 17500, 15000 },
	{ 25000, 20000 },
	{ 45000, 30000 },
	{ 90000, 60000 },
	{ 210000, 120000 },
	{ 450000, 300000 },
	{ 750000, 600000 },
	{ 1050000, 900000 },
	{ 1500000, 1200000 },
	{ 2700000, 1800000 },
	{ 5400000, 3600000 },
	{ 9000000, 7200000 },
	{ 16200000, 10800000 },
	{ 32400000, 21600000 },
	{ 86400000, 43200000 },
	{ 604800000, 86400000 },
	{ 1814400000, 604800000 },
	{ 3628800000, 2592000000 },
}

-- { inclusive upper edge, rounded value }
local BACKEND_TABLE: { { number } } = {
	{ 10, 1 },
	{ 15, 10 },
	{ 35, 20 },
	{ 75, 50 },
	{ 150, 100 },
	{ 350, 200 },
	{ 750, 500 },
	{ 1500, 1000 },
	{ 3500, 2000 },
	{ 7500, 5000 },
	{ 12500, 10000 },
	{ 17500, 15000 },
	{ 25000, 20000 },
	{ 45000, 30000 },
	{ 90000, 60000 },
	{ 210000, 120000 },
	{ 450000, 300000 },
	{ 750000, 600000 },
	{ 1050000, 900000 },
	{ 1500000, 1200000 },
	{ 2700000, 1800000 },
	{ 5400000, 3600000 },
	{ 9000000, 7200000 },
	{ 16200000, 10800000 },
	{ 32400000, 21600000 },
	{ 86400000, 43200000 },
	{ 172800000, 86400000 },
	{ 604800000, 86400000 },
	{ 1814400000, 604800000 },
}

function M.roundInterval(ms: number): number
	for _, row in FRONTEND_TABLE do
		if ms < row[1] then
			return row[2]
		end
	end
	return YEAR
end

function M.roundStep(ms: number): number
	for _, row in BACKEND_TABLE do
		if ms <= row[1] then
			return row[2]
		end
	end
	return if ms < 2 * YEAR then 30 * DAY else YEAR
end

local INTERVAL_UNITS: { { number | string } } = {
	{ YEAR, "y" },
	{ DAY, "d" },
	{ HOUR, "h" },
	{ MINUTE, "m" },
	{ SECOND, "s" },
	{ 1, "ms" },
}

-- The largest whole unit only (gtime.FormatInterval, rangeutil secondsToHms).
function M.formatInterval(ms: number): string
	for _, u in INTERVAL_UNITS do
		local size = u[1] :: number
		if ms >= size then
			return tostring(ms // size) .. (u[2] :: string)
		end
	end
	return "1ms"
end

function M.interval(range_ms: number, max_data_points: number, min_interval_ms: number?): Interval
	local ms = M.roundInterval(range_ms / max_data_points)
	local low = min_interval_ms or 1
	if low > ms then
		ms = low
	end
	return { interval_ms = ms, interval_str = M.formatInterval(ms) }
end

-- Durations in Go are integer nanoseconds; divisions truncate there.
local function truncNs(ms: number): number
	return math.floor(ms * 1e6) / 1e6
end

-- `min_step_ms` is the query's min step, else the datasource scrape interval,
-- else Grafana's 15s default. `max_data_points` 0 means Grafana's 1500.
function M.promStep(range_ms: number, max_data_points: number, min_step_ms: number?, interval_factor: number?): number
	local resolution = if max_data_points > 0 then max_data_points else DEFAULT_RESOLUTION
	local minStep = min_step_ms or DEFAULT_SCRAPE_MS
	local calculated = truncNs(range_ms / resolution)
	calculated = if calculated < minStep then minStep else M.roundStep(calculated)
	local safe = M.roundStep(truncNs(range_ms / SAFE_RESOLUTION))
	local factor = if interval_factor and interval_factor > 0 then interval_factor else 1
	return math.max(calculated, safe) * factor
end

-- `interval_ms` is the panel interval (M.interval), not the Prometheus step.
function M.rateInterval(interval_ms: number, scrape_ms: number?): number
	local scrape = scrape_ms or DEFAULT_SCRAPE_MS
	return math.max(interval_ms + scrape, 4 * scrape)
end

-- Start and end floored to multiples of the step in a UTC offset (seconds east).
function M.align(start_ms: number, end_ms: number, step_ms: number, offset_s: number?): (number, number)
	local off = (offset_s or 0) * SECOND
	return (start_ms + off) // step_ms * step_ms - off, (end_ms + off) // step_ms * step_ms - off
end

-- Go math.Round: halves away from zero.
local function roundHalfAway(x: number): number
	return if x < 0 then -math.floor(-x + 0.5) else math.floor(x + 0.5)
end

function M.macros(range_ms: number, step_ms: number, interval_ms: number, scrape_ms: number?): Macros
	local rangeS = tostring(roundHalfAway(range_ms / SECOND))
	local rate = M.rateInterval(interval_ms, scrape_ms)
	return {
		interval = M.formatInterval(step_ms),
		interval_ms = tostring(math.floor(step_ms)),
		range = rangeS .. "s",
		range_s = rangeS,
		range_ms = tostring(math.floor(range_ms)),
		rate_interval = M.formatDuration(rate),
		rate_interval_ms = tostring(math.floor(rate)),
	}
end

-- InterpolateVariables' replacement order: each name before its prefixes.
local VARIABLES: { string } = {
	"interval_ms",
	"interval",
	"range_ms",
	"range_s",
	"range",
	"rate_interval_ms",
	"rate_interval",
}

local function replaceAll(s: string, needle: string, value: string): string
	local escaped = string.gsub(needle, "[%^%$%(%)%%%.%[%]%*%+%-%?{}]", "%%%0")
	local replacement = string.gsub(value, "%%", "%%%%")
	return (string.gsub(s, escaped, replacement))
end

function M.interpolate(expr: string, macros: Macros): string
	local values = macros :: { [string]: string }
	for _, name in VARIABLES do
		expr = replaceAll(expr, "$__" .. name, values[name])
	end
	for _, name in VARIABLES do
		expr = replaceAll(expr, "${__" .. name .. "}", values[name])
	end
	return expr
end

local DURATION_UNITS: { [string]: number } = { y = YEAR, w = WEEK, d = DAY, h = HOUR, m = MINUTE, s = SECOND, ms = 1 }
local DURATION_ORDER: { string } = { "y", "w", "d", "h", "m", "s", "ms" }
local DURATION_RANK: { [string]: number } = {}
for i, unit in DURATION_ORDER do
	DURATION_RANK[unit] = i
end

function M.parseDuration(text: string): number?
	if text == "0" then
		return 0
	end
	if string.match(text, "^%d+$") or string.match(text, "^%d+%.%d+$") then
		return math.floor((tonumber(text) :: number) * SECOND + 0.5)
	end
	if text == "" then
		return nil
	end
	local total = 0
	local lastRank = 0
	local pos = 1
	while pos <= #text do
		local digits, unit, stop = string.match(text, "^(%d+)(ms)()", pos)
		if digits == nil then
			digits, unit, stop = string.match(text, "^(%d+)([ywdhms])()", pos)
		end
		if digits == nil or unit == nil or stop == nil then
			return nil
		end
		local rank = DURATION_RANK[unit]
		if rank <= lastRank then
			return nil
		end
		lastRank = rank
		total += (tonumber(digits) :: number) * DURATION_UNITS[unit]
		pos = stop
	end
	return total
end

function M.formatDuration(ms: number): string
	ms = math.floor(ms)
	if ms == 0 then
		return "0s"
	end
	local parts: { string } = {}
	for _, unit in DURATION_ORDER do
		local size = DURATION_UNITS[unit]
		local exactOnly = unit == "y" or unit == "w"
		if not (exactOnly and ms % size ~= 0) then
			local n = ms // size
			if n > 0 then
				table.insert(parts, tostring(n) .. unit)
				ms -= n * size
			end
		end
	end
	return table.concat(parts)
end

-- Grafana's maxDataPoints is the panel width in px; a pane is `cols` cells.
function M.maxPoints(cols: number, px_per_cell: number?): number
	return math.max(1, math.floor(cols * (px_per_cell or DEFAULT_PX_PER_CELL)))
end

return M
