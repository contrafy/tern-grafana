--!strict
-- Categorical bar chart SVGs as Grafana's bar chart draws them
-- (public/app/plugins/panel/barchart/bars.ts, utils.ts):
-- - one slot per category along the category axis; a group takes
--   `group_width` of its slot and its bars share `bar_width` of the group
--   (uPlot distribute, space-between); a stacked category is one bar the
--   width of its group;
-- - stacking normal (positives up, negatives down) or percent (each
--   category's values over the sum of their magnitudes, axis 0..100%);
-- - value labels at each bar's end, one font size for all (the largest
--   that fits every label: 65% of a bar's width or thickness, 8..30 px);
--   `auto` drops labels that would overlap one already drawn, `never` none;
-- - category labels rotated by `label_rotation` degrees, cut to `label_max`
--   characters, thinned so they do not overlap (label_spacing px apart;
--   negative spacing thins from the end);
-- - threshold lines and areas on the value axis.
-- Colors are classes: a series class, or a class per bar (color by value,
-- colorByField). Categories beyond what fits the size cap are dropped and
-- counted in `dropped`.

local Kit = require("./svg_kit")
local Thresholds = require("../units/thresholds")

local M = {}

export type Series = {
	-- Color classes for the whole series ("tg-s2", "tgp-fx tgp-error").
	class: string,
	values: { any },
	-- Per-bar color classes overriding `class` (nil entries keep it).
	classes: { string? }?,
}

export type Stacking = "none" | "normal" | "percent"

export type Options = {
	width: number,
	height: number,
	-- Bars run left to right, categories down the y axis.
	horizontal: boolean?,
	categories: { string },
	series: { Series },
	stacking: Stacking?,
	group_width: number?,
	bar_width: number?,
	-- 0..1 bar fill; the outline (line_width px) is drawn at full color.
	fill_opacity: number?,
	line_width: number?,
	show_value: ("auto" | "always" | "never")?,
	-- Fixed value label size (options.text.valueSize), px.
	value_size: number?,
	-- Value label text for a series' value (percent stacking passes the
	-- fraction of the category total).
	format: ((series: number, value: number) -> string)?,
	unit: string?,
	decimals: number?,
	min: number?,
	max: number?,
	thresholds: Thresholds.Thresholds?,
	threshold_style: Kit.ThresholdStyle?,
	label_rotation: number?,
	label_max: number?,
	label_spacing: number?,
	-- false hides the value axis labels (axisPlacement hidden).
	value_axis: boolean?,
	-- false hides grid lines (axisGridShow).
	grid: boolean?,
}

export type Result = { svg: string, dropped: number, bars: number }

M.MIN_FONT = 8
M.MAX_FONT = 30
local FONT_RATIO = 0.65
-- Bytes per bar: fill path segment, outline segment, value label.
local BYTES_BAR = 34
local BYTES_LABEL = 110
local FIXED_BYTES = 8 * 1024

local fmt = string.format
local finite = function(v: any): number?
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		return v
	end
	return nil
end

type Bar = { cat: number, series: number, lo: number, hi: number, raw: number, class: string }

-- Stacked or side by side bar extents in value units.
local function extents(opts: Options, ncat: number): ({ Bar }, number, number)
	local stacking = opts.stacking or "none"
	local bars: { Bar } = {}
	local lo, hi = 0, 0
	for c = 1, ncat do
		local pos, neg = 0, 0
		local total = 0
		if stacking == "percent" then
			for _, s in opts.series do
				local v = finite(s.values[c])
				if v then
					total += math.abs(v)
				end
			end
		end
		for si, s in opts.series do
			local v = finite(s.values[c])
			if v == nil then
				continue
			end
			local class = s.class
			if s.classes and s.classes[c] then
				class = s.classes[c] :: string
			end
			local val = v
			if stacking == "percent" then
				val = if total > 0 then v / total else 0
			end
			local a, b: number
			if stacking == "none" then
				a, b = 0, val
			elseif val >= 0 then
				a, b = pos, pos + val
				pos = b
			else
				a, b = neg, neg + val
				neg = b
			end
			lo = math.min(lo, a, b)
			hi = math.max(hi, a, b)
			table.insert(
				bars,
				{ cat = c, series = si, lo = math.min(a, b), hi = math.max(a, b), raw = v, class = class }
			)
		end
	end
	return bars, lo, hi
end

function M.render(opts: Options): Result
	local W, H = math.max(80, opts.width), math.max(60, opts.height)
	local horizontal = opts.horizontal == true
	local stacking = opts.stacking or "none"
	local nseries = #opts.series
	-- Categories that fit the byte budget.
	local perCat = math.max(1, nseries) * (BYTES_BAR + BYTES_LABEL)
	local maxCat = math.max(1, math.floor((Kit.TARGET - FIXED_BYTES) / perCat))
	local ncat = math.min(#opts.categories, maxCat)
	local dropped = #opts.categories - ncat
	local bars, lo, hi = extents(opts, ncat)
	local unit = if stacking == "percent" then "percentunit" else opts.unit
	local hardMin, hardMax = opts.min, opts.max
	if stacking == "percent" then
		hardMin = if lo < 0 then -1 else 0
		hardMax = 1
	end

	local out: { string } = { Kit.open(W, H) }
	local rotation = opts.label_rotation or 0
	local cats: { string } = table.create(ncat)
	local widest = 0
	for i = 1, ncat do
		cats[i] = Kit.shorten(opts.categories[i], opts.label_max)
		widest = math.max(widest, Kit.textWidth(cats[i]))
	end
	local showAxis = opts.value_axis ~= false

	-- Plot rect and value scale.
	local top, right = 8, W - 12
	local left, bottom: number
	local scale: Kit.Scale
	local tickLabels: { string }
	if horizontal then
		left = math.min(W * 0.4, widest + 12)
		bottom = H - (if showAxis then 24 else 8)
		local labels: { string }
		scale, labels = Kit.hScale(lo, hi, right - left, hardMin, hardMax, unit, opts.decimals)
		tickLabels = labels
	else
		local rad = math.rad(math.abs(rotation))
		local labelH = if rotation == 0 then 24 else math.min(H * 0.5, widest * math.sin(rad) + 16)
		bottom = H - labelH
		scale = Kit.vScale(lo, hi, bottom - top, hardMin, hardMax)
		tickLabels = Kit.tickLabels(scale.ticks, unit, opts.decimals)
		local labelW = 0
		for _, l in tickLabels do
			labelW = math.max(labelW, Kit.textWidth(l))
		end
		left = if showAxis then math.max(36, labelW + 12) else 8
	end
	local vmin, vmax = scale.min, scale.max
	local span = if vmax > vmin then vmax - vmin else 1
	local valPx: (number) -> number
	if horizontal then
		valPx = function(v: number): number
			return left + (math.clamp(v, vmin, vmax) - vmin) / span * (right - left)
		end
	else
		valPx = function(v: number): number
			return bottom - (math.clamp(v, vmin, vmax) - vmin) / span * (bottom - top)
		end
	end
	local catLen = if horizontal then bottom - top else right - left
	local slot = catLen / math.max(1, ncat)
	local function slotStart(c: number): number
		return (if horizontal then top else left) + (c - 1) * slot
	end

	-- Grid and value axis labels.
	if opts.grid ~= false then
		local grid: { string } = {}
		for _, v in scale.ticks do
			if v >= vmin and v <= vmax then
				local p = valPx(v)
				table.insert(
					grid,
					if horizontal
						then fmt("M%.1f %.1fV%.1f", p, top, bottom)
						else fmt("M%.1f %.1fH%.1f", left, p, right)
				)
			end
		end
		if #grid > 0 then
			table.insert(out, '<path class="tg-grid" fill="none" stroke-width="1" d="' .. table.concat(grid) .. '"/>')
		end
	end
	Kit.thresholds(out, {
		min = vmin,
		max = vmax,
		toPx = valPx,
		from = if horizontal then top else left,
		to = if horizontal then bottom else right,
		horizontal = horizontal,
	}, opts.thresholds, opts.threshold_style or "off")

	-- Bar geometry.
	local groupW = slot * math.clamp(opts.group_width or 0.7, 0, 1)
	local barFrac = math.clamp(opts.bar_width or 0.97, 0, 1)
	local function across(c: number, si: number): (number, number)
		local g0 = slotStart(c) + (slot - groupW) / 2
		if stacking ~= "none" or nseries <= 1 then
			local w = if stacking ~= "none" then groupW else groupW * barFrac
			return g0 + (groupW - w) / 2, w
		end
		local w = groupW * barFrac / nseries
		local gap = groupW * (1 - barFrac) / (nseries - 1)
		return g0 + (si - 1) * (w + gap), w
	end

	local byClass: { [string]: { string } } = {}
	local classOrder: { string } = {}
	local thickness = math.huge
	for _, b in bars do
		local a0, w = across(b.cat, b.series)
		thickness = math.min(thickness, w)
		local p0, p1 = valPx(b.lo), valPx(b.hi)
		local d: string
		if horizontal then
			d = fmt("M%.1f %.1fh%.1fv%.1fh%.1fZ", math.min(p0, p1), a0, math.abs(p1 - p0), w, -math.abs(p1 - p0))
		else
			d = fmt("M%.1f %.1fh%.1fv%.1fh%.1fZ", a0, math.min(p0, p1), w, math.abs(p1 - p0), -w)
		end
		local list = byClass[b.class]
		if list == nil then
			list = {}
			byClass[b.class] = list
			table.insert(classOrder, b.class)
		end
		table.insert(list :: { string }, d)
	end
	local fill = math.clamp(opts.fill_opacity or 0.8, 0, 1)
	local lineW = opts.line_width or 1
	for _, class in classOrder do
		local d = table.concat(byClass[class])
		table.insert(out, fmt('<path class="%s tg-bar" fill-opacity="%.2f" d="%s"/>', class, fill, d))
		if lineW > 0 and fill < 1 then
			table.insert(
				out,
				fmt('<path class="%s tg-line" stroke-width="%s" d="%s"/>', class, tostring(math.min(lineW, 10)), d)
			)
		end
	end
	table.insert(
		out,
		if horizontal
			then fmt('<path class="tg-axis" fill="none" stroke-width="1" d="M%.1f %.1fV%.1f"/>', valPx(0), top, bottom)
			else fmt(
				'<path class="tg-axis" fill="none" stroke-width="1" d="M%.1f %.1fH%.1f"/>',
				left,
				valPx(0),
				right
			)
	)

	-- Value labels.
	local show = opts.show_value or "auto"
	local format = opts.format
	if show ~= "never" and format and #bars > 0 then
		local texts: { string } = table.create(#bars)
		local size = opts.value_size
		for i, b in bars do
			local v = b.raw
			if stacking == "percent" then
				v = b.hi - b.lo
				if b.raw < 0 then
					v = -v
				end
			end
			texts[i] = format(b.series, v)
		end
		if size == nil then
			local fit = M.MAX_FONT
			for _, t in texts do
				local w14 = Kit.textWidth(t, 14) + 2
				if horizontal then
					fit = math.min(fit, thickness * FONT_RATIO)
				else
					fit = math.min(fit, thickness * FONT_RATIO / w14 * 14)
				end
			end
			size = math.floor(fit + 0.5)
		end
		local fs = size :: number
		if fs >= M.MIN_FONT then
			local placed: { { number } } = {}
			local function overlaps(x0: number, y0: number, x1: number, y1: number): boolean
				for _, r in placed do
					if x0 < r[3] and x1 > r[1] and y0 < r[4] and y1 > r[2] then
						return true
					end
				end
				return false
			end
			for i, b in bars do
				local a0, w = across(b.cat, b.series)
				local t = texts[i]
				local tw = Kit.textWidth(t, fs)
				local neg = b.raw < 0
				local x, y: number
				local anchor: "start" | "middle" | "end"
				local bx0, by0, bx1, by1: number
				if horizontal then
					local offset = math.min(10, math.floor(0.15 * w + 0.5))
					local edge = valPx(if neg then b.lo else b.hi)
					x = if neg then edge - offset else edge + offset
					y = a0 + w / 2 + fs * 0.35
					anchor = if neg then "end" else "start"
					bx0 = if neg then x - tw else x
					bx1 = bx0 + tw
					by0, by1 = y - fs * 0.8, y + fs * 0.2
				else
					local offset = math.min(5, math.floor(0.1 * w + 0.5))
					local edge = valPx(if neg then b.lo else b.hi)
					x = a0 + w / 2
					y = if neg then edge + offset + fs * 0.8 else edge - offset
					y = math.max(y, fs * 0.8)
					anchor = "middle"
					bx0, bx1 = x - tw / 2, x + tw / 2
					by0, by1 = y - fs * 0.8, y + fs * 0.2
				end
				if show == "auto" and overlaps(bx0, by0, bx1, by1) then
					continue
				end
				table.insert(placed, { bx0, by0, bx1, by1 })
				table.insert(out, Kit.text(x, y, t, { anchor = anchor, size = fs, class = "tg-label tgc-text" }))
			end
		end
	end

	-- Axis labels.
	if showAxis then
		for i, v in scale.ticks do
			if v >= vmin and v <= vmax then
				local p = valPx(v)
				if horizontal then
					table.insert(out, Kit.text(p, H - 6, tickLabels[i]))
				else
					table.insert(out, Kit.text(left - 6, p + 4, tickLabels[i], { anchor = "end" }))
				end
			end
		end
	end
	local gap = Kit.X_GAP + (opts.label_spacing and math.abs(opts.label_spacing) or 0)
	local order: { number } = table.create(ncat)
	for i = 1, ncat do
		order[i] = i
	end
	if (opts.label_spacing or 0) < 0 then
		for i = 1, ncat do
			order[i] = ncat - i + 1
		end
	end
	local lastEdge: number? = nil
	for _, c in order do
		local center = slotStart(c) + slot / 2
		local label = cats[c]
		if horizontal then
			-- One line per slot: skip when slots are shorter than the text.
			if lastEdge == nil or math.abs(center - lastEdge) >= Kit.FONT + 2 then
				table.insert(out, Kit.text(left - 6, center + 4, label, { anchor = "end" }))
				lastEdge = center
			end
		else
			local extent = if rotation == 0 then Kit.textWidth(label) else Kit.FONT * 1.2
			local half = extent / 2
			local x0 = center - half
			local ok = lastEdge == nil
				or (
					if (opts.label_spacing or 0) < 0
						then center + half + gap <= (lastEdge :: number)
						else x0 >= (lastEdge :: number) + gap
				)
			if ok then
				if rotation == 0 then
					table.insert(out, Kit.text(center, bottom + 16, label))
				else
					table.insert(
						out,
						Kit.text(center, bottom + 12, label, {
							anchor = if rotation > 0 then "end" else "start",
							rotate = -rotation,
						})
					)
				end
				lastEdge = if (opts.label_spacing or 0) < 0 then x0 else center + half
			end
		end
	end
	if #bars == 0 then
		Kit.noData(out, (left + right) / 2, (top + bottom) / 2)
	end
	return { svg = Kit.finish(out, "svg_bars"), dropped = dropped, bars = #bars }
end

return M
