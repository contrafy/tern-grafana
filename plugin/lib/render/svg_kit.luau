--!strict
-- Shared pieces of the native chart SVGs (lib/render/svg_pie, svg_bars,
-- svg_xy): the document frame, text, value scales and their tick labels,
-- and threshold shapes. Same rules as lib/render/svg_timeseries: colors are
-- classes only (Tern resolves no var() in attributes and drops `style`), no
-- <title>, and a document stays under Tern's 256 KiB image cap.

local Axis = require("./axis")
local Format = require("../units/format")
local Thresholds = require("../units/thresholds")
local Tbl = require("../tbl")

local M = {}

M.CAP = 262144
-- Aim below the cap: estimates are rough and the next refresh may grow.
M.TARGET = 240 * 1024
M.CHAR_PX = Axis.CHAR_PX
M.FONT = 12
-- Gap between two x tick labels, px (uPlot's axis gap as in lib/render/axis).
M.X_GAP = Axis.X_GAP

-- Beyond this, tick labels use automatic decimals.
local MAX_TICK_DECIMALS = 4

local fmt = string.format

function M.escape(s: string): string
	return (string.gsub(s, '[&<>"]', { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

function M.open(w: number, h: number): string
	local W, H = math.floor(w + 0.5), math.floor(h + 0.5)
	return fmt(
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" class="tg-chart">',
		W,
		H,
		W,
		H
	)
end

M.CLOSE = "</svg>"

-- Estimated width of `s` at `size` px (7 px per character at 12 px).
function M.textWidth(s: string, size: number?): number
	return (utf8.len(s) or #s) * M.CHAR_PX * (size or M.FONT) / M.FONT
end

-- `s` cut to `n` characters plus "..." (Grafana shortenValue).
function M.shorten(s: string, n: number?): string
	if n == nil or n <= 0 or n == math.huge then
		return s
	end
	local len = utf8.len(s) or #s
	if len <= n then
		return s
	end
	local stop = utf8.offset(s, n + 1)
	return string.sub(s, 1, (stop or (#s + 1)) - 1) .. "..."
end

export type TextOptions = {
	anchor: ("start" | "middle" | "end")?,
	size: number?,
	class: string?,
	-- Degrees, around (x, y).
	rotate: number?,
	-- Extra attributes, verbatim (dominant-baseline, font-weight).
	attrs: string?,
}

function M.text(x: number, y: number, s: string, o: TextOptions?): string
	local opts: TextOptions = o or {}
	local rot = opts.rotate
	local transform = if rot and rot ~= 0 then fmt(' transform="rotate(%d %.1f %.1f)"', rot, x, y) else ""
	return fmt(
		'<text class="%s" x="%.1f" y="%.1f" font-size="%d" text-anchor="%s"%s%s>%s</text>',
		opts.class or "tg-label",
		x,
		y,
		math.floor((opts.size or M.FONT) + 0.5),
		opts.anchor or "middle",
		transform,
		if opts.attrs then " " .. opts.attrs else "",
		M.escape(s)
	)
end

-- Scales ------------------------------------------------------------------------

export type Scale = Axis.Scale

-- A value scale whose ticks are at least `space` px apart on an axis `px`
-- long; hardMin/hardMax are kept exactly, free ends round to whole steps.
function M.scale(lo: number, hi: number, px: number, space: number, hardMin: number?, hardMax: number?): Scale
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
	local step = Axis.niceStep(b - a, math.max(1, math.floor(px / math.max(space, 1))))
	local function clean(v: number): number
		local n = tonumber(fmt("%.12g", v)) :: number
		return if n == 0 then 0 else n
	end
	local lo2 = if hardMin then a else clean(math.floor(a / step + 1e-9) * step)
	local hi2 = if hardMax then b else clean(math.ceil(b / step - 1e-9) * step)
	local ticks: { number } = {}
	for i = math.ceil(lo2 / step - 1e-9), math.floor(hi2 / step + 1e-9) do
		table.insert(ticks, clean(i * step))
	end
	return { min = lo2, max = hi2, step = step, ticks = ticks }
end

-- A vertical value axis (Grafana's y spacing: 30 px, 15 px on short plots).
function M.vScale(lo: number, hi: number, px: number, hardMin: number?, hardMax: number?): Scale
	return Axis.niceScale(lo, hi, px, hardMin, hardMax)
end

-- uPlot's rangeNum for an auto-ranged numeric scale (pad 0.1, soft 0 in
-- mode 3, as Grafana's UPlotScaleBuilder configures it): the data range
-- widened by 10% at both ends, rounded out to a tenth of its magnitude, and
-- kept on its side of 0 when the data do not cross it.
function M.padRange(lo: number, hi: number): (number, number)
	local delta = hi - lo
	local nonZero = if delta ~= 0 then delta elseif hi ~= 0 then math.abs(hi) else 1000
	local base = 10 ^ math.floor(math.log10(nonZero))
	local padding = nonZero * (if delta == 0 then (if lo == 0 then 0.1 else 1) else 0.1)
	local incr = base / 10
	local function clean(v: number): number
		local n = tonumber(fmt("%.9g", v)) :: number
		return if n == 0 then 0 else n
	end
	local a = clean(math.floor((lo - padding) / incr + 1e-9) * incr)
	local b = clean(math.ceil((hi + padding) / incr - 1e-9) * incr)
	if lo >= 0 and a < 0 then
		a = 0
	end
	if hi <= 0 and b > 0 then
		b = 0
	end
	return a, b
end

-- A vertical value axis over uPlot's padded range: free ends padded
-- (padRange), ticks at nice steps inside it.
function M.vScalePadded(lo: number, hi: number, px: number, hardMin: number?, hardMax: number?): Scale
	local a, b = M.padRange(lo, hi)
	local s = Axis.niceScale(hardMin or a, hardMax or b, px, hardMin or a, hardMax or b)
	return s
end

-- Tick labels sharing one decimals count: the fewest that print every tick
-- exactly in its unit (lib/render/svg_timeseries yLabels).
function M.tickLabels(ticks: { number }, unit: string?, decimals: number?): { string }
	local function render(d: number?): { string }
		local out: { string } = table.create(#ticks)
		for i, v in ticks do
			out[i] = Format.text(v, unit, d)
		end
		return out
	end
	if decimals ~= nil then
		return render(decimals)
	end
	local function trimmed(s: string): string
		if string.find(s, ".", 1, true) then
			s = string.gsub(string.gsub(s, "0+$", ""), "%.$", "")
		end
		return s
	end
	local common = 0
	for _, v in ticks do
		local exact = trimmed(Format.format(v, unit, 10).text)
		local d = 0
		while d <= MAX_TICK_DECIMALS and trimmed(Format.format(v, unit, d).text) ~= exact do
			d += 1
		end
		if d > MAX_TICK_DECIMALS then
			return render(nil)
		end
		common = math.max(common, d)
	end
	local labels = render(common)
	for i = 2, #labels do
		if labels[i] == labels[i - 1] then
			return render(nil)
		end
	end
	return labels
end

-- A horizontal value axis: spacing from the widest label plus a gap,
-- settled in two passes (the labels depend on the step).
function M.hScale(
	lo: number,
	hi: number,
	px: number,
	hardMin: number?,
	hardMax: number?,
	unit: string?,
	decimals: number?
): (Scale, { string })
	local scale = M.scale(lo, hi, px, 60, hardMin, hardMax)
	local labels = M.tickLabels(scale.ticks, unit, decimals)
	for _ = 1, 2 do
		local widest = 0
		for _, l in labels do
			widest = math.max(widest, M.textWidth(l))
		end
		local space = widest + M.X_GAP
		local next = M.scale(lo, hi, px, space, hardMin, hardMax)
		if next.step == scale.step then
			break
		end
		scale = next
		labels = M.tickLabels(scale.ticks, unit, decimals)
	end
	return scale, labels
end

-- Thresholds ---------------------------------------------------------------------

export type ThresholdStyle = "off" | "line" | "area" | "line+area"

-- GraphThresholdsStyleMode -> what is drawn ("series" colors the series
-- instead, drawn as off here as in lib/panels/timeseries).
function M.thresholdStyle(mode: string?): ThresholdStyle
	if mode == "line" or mode == "dashed" then
		return "line"
	elseif mode == "area" then
		return "area"
	elseif mode == "line+area" or mode == "dashed+area" then
		return "line+area"
	end
	return "off"
end

export type ValueAxis = {
	-- The value range shown and its px mapping.
	min: number,
	max: number,
	toPx: (number) -> number,
	-- The plot rect across the value axis (left..right for a vertical value
	-- axis, top..bottom for a horizontal one).
	from: number,
	to: number,
	-- True when the value axis runs left to right (horizontal bars).
	horizontal: boolean?,
}

-- Threshold areas and lines (GraphThresholdsStyleConfig) on a value axis.
function M.thresholds(out: { string }, axis: ValueAxis, spec: Thresholds.Thresholds?, style: ThresholdStyle)
	if style == "off" or spec == nil or #spec.steps == 0 then
		return
	end
	local percent = spec.mode == "percentage"
	local steps = Tbl.copy(spec.steps)
	local function at(step: Thresholds.Step): number
		local v = step.value
		if type(v) ~= "number" then
			return -math.huge
		end
		return if percent then axis.min + (axis.max - axis.min) * v / 100 else v
	end
	table.sort(steps, function(a, b)
		return at(a) < at(b)
	end)
	local function rect(lo: number, hi: number): (number, number, number, number)
		local a, b = axis.toPx(lo), axis.toPx(hi)
		if axis.horizontal then
			return math.min(a, b), axis.from, math.abs(b - a), axis.to - axis.from
		end
		return axis.from, math.min(a, b), axis.to - axis.from, math.abs(b - a)
	end
	if style == "area" or style == "line+area" then
		for k, step in steps do
			local lo = math.max(at(step), axis.min)
			local hi = if k < #steps then math.min(at(steps[k + 1]), axis.max) else axis.max
			if hi > lo then
				local x, y, w, h = rect(lo, hi)
				table.insert(
					out,
					fmt(
						'<rect class="tg-tharea tg-th-%s" x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill-opacity="0.12"/>',
						Thresholds.tone(step.color),
						x,
						y,
						w,
						h
					)
				)
			end
		end
	end
	if style == "line" or style == "line+area" then
		for _, step in steps do
			local v = at(step)
			if v > axis.min and v <= axis.max then
				local p = axis.toPx(v)
				local d = if axis.horizontal
					then fmt("M%.1f %.1fV%.1f", p, axis.from, axis.to)
					else fmt("M%.1f %.1fH%.1f", axis.from, p, axis.to)
				table.insert(
					out,
					fmt(
						'<path class="tg-th tg-th-%s" d="%s" fill="none" stroke-width="1" stroke-dasharray="10 10"/>',
						Thresholds.tone(step.color),
						d
					)
				)
			end
		end
	end
end

-- "No data" in the middle of a plot.
function M.noData(out: { string }, x: number, y: number)
	table.insert(out, M.text(x, y, "No data", { size = 14 }))
end

-- The finished document; asserts the cap so an oversized chart fails loudly
-- in specs rather than as a blank image in Tern.
function M.finish(out: { string }, who: string): string
	table.insert(out, M.CLOSE)
	local svg = table.concat(out)
	assert(#svg <= M.CAP, who .. ": chart exceeds the 256 KiB SVG cap")
	return svg
end

return M
