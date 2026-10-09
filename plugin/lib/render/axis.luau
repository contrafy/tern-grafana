--!strict
-- Axis ticks as Grafana's time series panel draws them (uPlot axes configured
-- by packages/grafana-ui/src/components/uPlot/config/UPlotAxisBuilder.ts):
-- - y: "nice" steps (1, 2, 2.5, 5 x 10^n) at least 30 px apart (15 px on
--   plots up to 150 px tall), the range widened to whole steps;
-- - x: uPlot's time increments, spaced by the width of a sample label plus
--   18 px, labelled with Grafana's interval formats chosen by formatTime.
-- Text widths are estimated at 7 px per character (12 px axis font).

local Range = require("../time/range")

local M = {}

local SECOND = 1000
local MINUTE = 60 * SECOND
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR
local YEAR = 365 * DAY

M.CHAR_PX = 7
M.Y_SPACE = 30
M.Y_SPACE_SMALL = 15
M.X_MIN_SPACE = 40
M.X_GAP = 18

local function clean(v: number): number
	local n = tonumber(string.format("%.12g", v)) :: number
	return if n == 0 then 0 else n
end

export type Scale = { min: number, max: number, step: number, ticks: { number } }

local MULTIPLES = { 1, 2, 2.5, 5, 10 }

-- Step for a span split into at most `maxTicks` intervals.
function M.niceStep(span: number, maxTicks: number): number
	local rough = span / math.max(1, maxTicks)
	if rough <= 0 or rough ~= rough then
		return 1
	end
	local mag = 10 ^ math.floor(math.log10(rough))
	for _, m in MULTIPLES do
		if m * mag >= rough * (1 - 1e-9) then
			return clean(m * mag)
		end
	end
	return clean(10 * mag)
end

-- Value scale for data in lo..hi on an axis `plotPx` long. `hardMin` and
-- `hardMax` (a panel's min/max) are kept exactly; free ends round outward to
-- whole steps.
function M.niceScale(lo: number, hi: number, plotPx: number, hardMin: number?, hardMax: number?): Scale
	local a, b = hardMin or lo, hardMax or hi
	if a > b then
		a, b = b, a
	end
	if a == b then
		local d = if a == 0 then 1 else math.abs(a) * 0.1
		if hardMin == nil then
			a -= d
		end
		if hardMax == nil or a == b then
			b += d
		end
	end
	local space = if plotPx <= 150 then M.Y_SPACE_SMALL else M.Y_SPACE
	local step = M.niceStep(b - a, math.floor(plotPx / space))
	local lo2 = if hardMin then a else clean(math.floor(a / step + 1e-9) * step)
	local hi2 = if hardMax then b else clean(math.ceil(b / step - 1e-9) * step)
	local ticks: { number } = {}
	for i = math.ceil(lo2 / step - 1e-9), math.floor(hi2 / step + 1e-9) do
		table.insert(ticks, clean(i * step))
	end
	return { min = lo2, max = hi2, step = step, ticks = ticks }
end

-- uPlot's timeIncrsMs (month and year steps are calendar steps).
local TIME_INCRS: { number } = {
	1,
	2,
	5,
	10,
	20,
	50,
	100,
	200,
	500,
	SECOND,
	2 * SECOND,
	5 * SECOND,
	10 * SECOND,
	15 * SECOND,
	30 * SECOND,
	MINUTE,
	2 * MINUTE,
	5 * MINUTE,
	10 * MINUTE,
	15 * MINUTE,
	30 * MINUTE,
	HOUR,
	2 * HOUR,
	3 * HOUR,
	4 * HOUR,
	6 * HOUR,
	8 * HOUR,
	12 * HOUR,
	DAY,
	2 * DAY,
	3 * DAY,
	4 * DAY,
	5 * DAY,
	6 * DAY,
	7 * DAY,
	8 * DAY,
	9 * DAY,
	10 * DAY,
	15 * DAY,
	30 * DAY,
	60 * DAY,
	90 * DAY,
	120 * DAY,
	180 * DAY,
	365 * DAY,
	2 * 365 * DAY,
	5 * 365 * DAY,
	10 * 365 * DAY,
	25 * 365 * DAY,
	50 * 365 * DAY,
	100 * 365 * DAY,
}

M.FORMATS = {
	millisecond = "HH:mm:ss.SSS",
	second = "HH:mm:ss",
	minute = "HH:mm",
	hour = "MM/DD HH:mm",
	day = "MM/DD",
	month = "YYYY-MM",
	year = "YYYY",
}

-- UPlotAxisBuilder formatTime: the label format for a tick increment over a
-- visible range (both ms).
function M.timeFormat(incr: number, range: number): string
	local f = M.FORMATS
	if incr < SECOND then
		return f.millisecond
	elseif incr <= MINUTE then
		return f.second
	elseif range <= DAY then
		return f.minute
	elseif incr <= DAY then
		return f.hour
	elseif range < YEAR then
		return f.day
	elseif math.floor(incr / DAY + 0.5) == math.floor(YEAR / DAY + 0.5) then
		return f.year
	elseif incr <= YEAR then
		return f.month
	end
	return f.year
end

-- `ms` in one of the FORMATS, in a fixed offset (minutes east of UTC).
function M.formatTime(ms: number, format: string, offsetMin: number?): string
	local s = Range.formatMs(ms, offsetMin) -- "YYYY-MM-DD HH:MM:SS"
	local Y, Mo, D = string.sub(s, 1, 4), string.sub(s, 6, 7), string.sub(s, 9, 10)
	local hm = string.sub(s, 12, 16)
	if format == M.FORMATS.millisecond then
		return string.sub(s, 12, 19) .. string.format(".%03d", math.floor(ms) % 1000)
	elseif format == M.FORMATS.second then
		return string.sub(s, 12, 19)
	elseif format == M.FORMATS.minute then
		return hm
	elseif format == M.FORMATS.hour then
		return Mo .. "/" .. D .. " " .. hm
	elseif format == M.FORMATS.day then
		return Mo .. "/" .. D
	elseif format == M.FORMATS.month then
		return Y .. "-" .. Mo
	end
	return Y
end

export type TimeTicks = { incr: number, format: string, ticks: { number }, labels: { string } }

local function civil(ms: number, offsetMin: number): (number, number)
	local s = Range.formatMs(ms, offsetMin)
	return tonumber(string.sub(s, 1, 4)) :: number, tonumber(string.sub(s, 6, 7)) :: number
end

local function monthStart(y: number, m: number, offsetMin: number): number
	local ms = Range.parse(string.format("%04d-%02d-01", y, m), false, { now_ms = 0, offset_min = offsetMin })
	return ms :: number
end

local function calendarTicks(from: number, to: number, months: number, offsetMin: number): { number }
	local ticks: { number } = {}
	local y, m = civil(from, offsetMin)
	while true do
		local t = monthStart(y, m, offsetMin)
		if t > to then
			break
		end
		if t >= from and ((y * 12 + m - 1) % months) == 0 then
			table.insert(ticks, t)
		end
		m += 1
		if m > 12 then
			y, m = y + 1, 1
		end
	end
	return ticks
end

-- Ticks for from..to on an axis `plotPx` wide.
function M.timeTicks(from: number, to: number, plotPx: number, offsetMin: number?): TimeTicks
	local off = offsetMin or 0
	local range = math.max(to - from, 1)
	-- calculateSpace: the width of a label formatted for the densest
	-- increment the minimum spacing allows.
	local guess = range / math.max(plotPx / M.X_MIN_SPACE, 1)
	local sample = M.formatTime(math.max(math.abs(from), math.abs(to)), M.timeFormat(guess, range), off)
	local space = #sample * M.CHAR_PX + M.X_GAP
	local incr = TIME_INCRS[#TIME_INCRS]
	for _, candidate in TIME_INCRS do
		if candidate / range * plotPx >= space then
			incr = candidate
			break
		end
	end
	local ticks: { number }
	if incr >= 365 * DAY then
		ticks = calendarTicks(from, to, 12 * math.floor(incr / (365 * DAY) + 0.5), off)
	elseif incr >= 30 * DAY then
		ticks = calendarTicks(from, to, math.floor(incr / (30 * DAY) + 0.5), off)
	else
		ticks = {}
		local shift = off * MINUTE
		local t = math.ceil((from + shift) / incr) * incr - shift
		while t <= to do
			table.insert(ticks, t)
			t += incr
		end
	end
	local format = M.timeFormat(incr, range)
	local labels: { string } = table.create(#ticks)
	for i, t in ticks do
		labels[i] = M.formatTime(t, format, off)
	end
	return { incr = incr, format = format, ticks = ticks, labels = labels }
end

return M
