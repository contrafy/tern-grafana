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

-- `distr` nil reads as linear. Log scales place values by log_base(v),
-- symlog by asinh(v / linear_threshold) (uPlot distr 3 and 4).
export type Distr = "linear" | "log" | "symlog"
export type Range = { min: number, max: number, distr: Distr?, log: number?, linear_threshold: number? }
export type Scale = {
	min: number,
	max: number,
	step: number,
	ticks: { number },
	distr: Distr?,
	log: number?,
	linear_threshold: number?,
}

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

-- One end of a uPlot range config: padding as a fraction of the data span,
-- the hard limit, the soft value and its mode (0 off, 1 always, 2 only when
-- the padded end stays inside it, 3 only when it would go past it).
export type RangePart = { pad: number, hard: number, soft: number?, mode: number }

local function fixFloat(v: number): number
	local n = tonumber(string.format("%.14g", v)) :: number
	return if n == 0 then 0 else n
end

-- uPlot 1.6.32 (Grafana 11 and 12) src/utils.js _rangeNum: the data range
-- widened by `pad` of its span at both ends, rounded out to a tenth of the
-- span's magnitude, then snapped to the soft values and clamped to the
-- hard limits. A flat 0 widens to 0..100.
function M.rangeNum(lo: number, hi: number, cmin: RangePart, cmax: RangePart): (number, number)
	local padMin, padMax = cmin.pad, cmax.pad
	local hardMin, hardMax = cmin.hard, cmax.hard
	local softMin = if cmin.soft == nil then math.huge else cmin.soft :: number
	local softMax = if cmax.soft == nil then -math.huge else cmax.soft :: number
	local softMinMode, softMaxMode = cmin.mode, cmax.mode
	local delta = hi - lo
	local scalarMax = math.max(math.abs(lo), math.abs(hi))
	local magDelta = math.abs(math.log10(scalarMax) - math.log10(delta))
	if delta < 1e-24 or magDelta > 10 then
		delta = 0
		if lo == 0 or hi == 0 then
			delta = 1e-24
			if softMinMode == 2 and softMin ~= math.huge then
				padMin = 0
			end
			if softMaxMode == 2 and softMax ~= -math.huge then
				padMax = 0
			end
		end
	end
	local nonZeroDelta = if delta ~= 0 then delta elseif scalarMax ~= 0 then scalarMax else 1e3
	local base = 10 ^ math.floor(math.log10(nonZeroDelta))
	local incr = base / 10

	local pMin = nonZeroDelta * (if delta == 0 then (if lo == 0 then 0.1 else 1) else padMin)
	local newMin = fixFloat(math.floor(fixFloat((lo - pMin) / incr)) * incr)
	local sMin = if lo >= softMin
			and (
				softMinMode == 1
				or (softMinMode == 3 and newMin <= softMin)
				or (softMinMode == 2 and newMin >= softMin)
			)
		then softMin
		else math.huge
	local minLim = math.max(hardMin, if newMin < sMin and lo >= sMin then sMin else math.min(sMin, newMin))

	local pMax = nonZeroDelta * (if delta == 0 then (if hi == 0 then 0.1 else 1) else padMax)
	local newMax = fixFloat(math.ceil(fixFloat((hi + pMax) / incr)) * incr)
	local sMax = if hi <= softMax
			and (
				softMaxMode == 1
				or (softMaxMode == 3 and newMax >= softMax)
				or (softMaxMode == 2 and newMax <= softMax)
			)
		then softMax
		else -math.huge
	local maxLim = math.min(hardMax, if newMax > sMax and hi <= sMax then sMax else math.max(sMax, newMax))

	if minLim == maxLim and minLim == 0 then
		maxLim = 100
	end
	return minLim, maxLim
end

export type LinearRange = {
	hard_min: number?,
	hard_max: number?,
	soft_min: number?,
	soft_max: number?,
	centered_zero: boolean?,
	percent: boolean?,
	decimals: number?,
}

-- A linear scale's range as Grafana configures uPlot
-- (packages/grafana-ui/src/components/uPlot/config/UPlotScaleBuilder.ts):
-- pad 0.1 at both ends, soft 0 in mode 3 unless a soft bound is set (then
-- mode 1), percent stacks soft 0..1, centered zero first, hard bounds kept
-- exactly, whole numbers with decimals 0, and 0..100 when nothing is left.
-- `lo`/`hi` nil (no data) read as 0.
function M.linearRange(lo: number?, hi: number?, r: LinearRange): (number, number)
	local softMin, softMax = r.soft_min, r.soft_max
	local hardMin, hardMax = r.hard_min, r.hard_max
	if r.percent then
		if hardMin == nil and softMin == nil then
			softMin = 0
		end
		if hardMax == nil and softMax == nil then
			softMax = 1
		end
	end
	local dataMin, dataMax = lo or 0, hi or 0
	if r.centered_zero then
		local m = math.max(math.abs(dataMin), math.abs(dataMax))
		if m == 0 then
			m = 80
		end
		dataMin, dataMax = -m, m
	end
	local hardMinOnly = softMin == nil and hardMin ~= nil
	local hardMaxOnly = softMax == nil and hardMax ~= nil
	local a, b = M.rangeNum(
		if hardMinOnly then hardMin :: number else dataMin,
		if hardMaxOnly then hardMax :: number else dataMax,
		{ pad = 0.1, hard = hardMin or -math.huge, soft = softMin or 0, mode = if softMin == nil then 3 else 1 },
		{ pad = 0.1, hard = hardMax or math.huge, soft = softMax or 0, mode = if softMax == nil then 3 else 1 }
	)
	if r.decimals == 0 then
		a, b = math.floor(a + 1e-9), math.ceil(b - 1e-9)
	end
	if hardMinOnly then
		a = hardMin :: number
	end
	if hardMaxOnly then
		b = hardMax :: number
	end
	if a == b and a ~= 0 then
		if a < 0 then
			a, b = a * 2, 0
		else
			a, b = 0, b * 2
		end
	end
	if a >= b then
		a, b = 0, 100
	end
	return a, b
end

-- uPlot axis splits on a fixed range: the smallest nice increment (1, 2,
-- 2.5, 5 x 10^n) whose ticks are at least the y spacing apart, at its
-- multiples inside min..max.
function M.rangeScale(min: number, max: number, plotPx: number): Scale
	local space = if plotPx <= 150 then M.Y_SPACE_SMALL else M.Y_SPACE
	local step = M.niceStep(max - min, plotPx / space)
	local ticks: { number } = {}
	for i = math.ceil(min / step - 1e-9), math.floor(max / step + 1e-9) do
		table.insert(ticks, clean(i * step))
	end
	return { min = min, max = max, step = step, ticks = ticks }
end

-- UPlotScaleBuilder: a log base is 2 or 10, anything else falls back to 10.
function M.logBase(base: number?): number
	return if base == 2 then 2 else 10
end

local function asinh(x: number): number
	local a = math.abs(x)
	local r = math.log(a + math.sqrt(a * a + 1))
	return if x < 0 then -r else r
end

-- Where `v` sits on a scale, 0 at min and 1 at max (outside for values out
-- of range); nil for a value a log scale cannot place (<= 0).
function M.position(r: Range, v: number): number?
	local d = r.distr or "linear"
	local a, b, x
	if d == "log" then
		if v <= 0 or r.min <= 0 then
			return nil
		end
		a, b, x = math.log(r.min), math.log(r.max), math.log(v)
	elseif d == "symlog" then
		local lt = r.linear_threshold or 1
		a, b, x = asinh(r.min / lt), asinh(r.max / lt), asinh(v / lt)
	else
		a, b, x = r.min, r.max, v
	end
	if b <= a then
		return 0.5
	end
	return (x - a) / (b - a)
end

local function ySpace(plotPx: number): number
	return if plotPx <= 150 then M.Y_SPACE_SMALL else M.Y_SPACE
end

-- A log scale over positive data lo..hi (uPlot rangeLog with whole
-- magnitudes: bounds at powers of `base`; hard bounds snap outward to
-- powers as UPlotScaleBuilder does). Ticks at powers of the base no closer
-- than the axis spacing, with 2x and 5x between decades of base 10 when
-- they fit.
function M.logScale(lo: number?, hi: number?, plotPx: number, base: number, hardMin: number?, hardMax: number?): Scale
	local lb = math.log(base)
	local function exp(v: number): number
		return math.log(v) / lb
	end
	local a = if hardMin and hardMin > 0 then hardMin else lo or 1
	local b = if hardMax and hardMax > 0 then hardMax else hi or base
	if a > b then
		a, b = b, a
	end
	if a == b then
		a, b = a / base, b * base
	end
	local e0 = math.floor(exp(a) + 1e-9)
	local e1 = math.ceil(exp(b) - 1e-9)
	if e1 <= e0 then
		e1 = e0 + 1
	end
	local space = ySpace(plotPx)
	local perMag = plotPx / (e1 - e0)
	local every = math.max(1, math.ceil(space / perMag - 1e-9))
	local minor = base == 10 and every == 1 and perMag * math.log10(2) >= space
	local ticks: { number } = {}
	for k = e0, e1, every do
		local p = base ^ k
		table.insert(ticks, clean(p))
		if minor and k < e1 then
			table.insert(ticks, clean(2 * p))
			table.insert(ticks, clean(5 * p))
		end
	end
	return { min = clean(base ^ e0), max = clean(base ^ e1), step = base, ticks = ticks, distr = "log", log = base }
end

-- A symlog (asinh) scale over lo..hi: free ends grow outward to signed
-- powers of `base` (uPlot rangeAsinh, 0 stays 0); ticks at 0 and the signed
-- powers from the linear threshold up, thinned to the axis spacing outward
-- from 0.
function M.symlogScale(
	lo: number,
	hi: number,
	plotPx: number,
	base: number,
	linearThreshold: number,
	hardMin: number?,
	hardMax: number?
): Scale
	local lb = math.log(base)
	local function grow(v: number, up: boolean): number
		if v == 0 then
			return 0
		end
		local e = math.log(math.abs(v)) / lb
		local k = if (v > 0) == up then math.ceil(e - 1e-9) else math.floor(e + 1e-9)
		return clean((if v < 0 then -1 else 1) * base ^ k)
	end
	local a, b = hardMin or lo, hardMax or hi
	if a > b then
		a, b = b, a
	end
	local min = hardMin or grow(a, false)
	local max = hardMax or grow(b, true)
	if min >= max then
		if max > 0 then
			min = 0
		elseif min < 0 then
			max = 0
		else
			max = base
		end
	end
	local s: Scale = {
		min = min,
		max = max,
		step = base,
		ticks = {},
		distr = "symlog",
		log = base,
		linear_threshold = linearThreshold,
	}
	local k0 = math.floor(math.log(linearThreshold) / lb + 1e-9)
	local k1 = math.ceil(math.log(math.max(math.abs(min), math.abs(max), linearThreshold)) / lb - 1e-9)
	local pos: { number }, neg: { number } = {}, {}
	for k = k0, k1 do
		local p = clean(base ^ k)
		local tol = 1e-9 * math.max(math.abs(min), math.abs(max))
		if p <= max + tol and p >= min - tol then
			table.insert(pos, p)
		end
		if -p >= min - tol and -p <= max + tol then
			table.insert(neg, -p)
		end
	end
	local minGap = ySpace(plotPx) / plotPx
	local function thin(list: { number }, from: number?): { number }
		local out: { number } = {}
		local last = if from then M.position(s, from) else nil
		for _, v in list do
			local p = M.position(s, v) :: number
			if last == nil or math.abs(p - last) >= minGap then
				table.insert(out, v)
				last = p
			end
		end
		return out
	end
	local zero = min <= 0 and max >= 0
	local up = thin(pos, if zero then 0 else nil)
	local down = thin(neg, if zero then 0 else nil)
	for i = #down, 1, -1 do
		table.insert(s.ticks, down[i])
	end
	if zero then
		table.insert(s.ticks, 0)
	end
	for _, v in up do
		table.insert(s.ticks, v)
	end
	return s
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
