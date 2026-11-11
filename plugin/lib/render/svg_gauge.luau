--!strict
-- A radial gauge as an SVG document, for an `image` node. Geometry ports
-- Grafana's gauges:
-- - "gauge" and "circle" (Grafana 12 newGauge, packages/grafana-ui/src/
--   components/RadialGauge: utils.ts calculateDimensions, drawRadialArcPath,
--   getOptimalSegmentCount; RadialBar, RadialBarSegmented, ThresholdsBar,
--   RadialScaleLabels, RadialArcPathEndpointMarks, RadialText): a 220 degree
--   arc (ARC_START 250, ARC_END 110) or a full circle;
-- - "v1" (packages/grafana-ui/src/components/Gauge/Gauge.tsx, the flot
--   gauge): a 270 degree arc whose width is min(size / 5.5, 40), with the
--   threshold markers as an outer ring a fifth of that wide.
-- Every color is a class: an exact color class (lib/render/ts_gradient
-- tg-gc<n>, or a tone pair "tgp-fx tgp-<tone>") drawn with the shape role
-- tg-line (strokes) or tg-bar (fills), so a theme switch recolors without
-- a new blob. effects.gradient (RadialArcPath: a CSS conic-gradient masked
-- by the bar, the threshold ring and each segment) becomes sub-arcs of at
-- most CONIC_STEP degrees, each stroked with a linear gradient between the
-- two stops around it laid along its chord (Tern's SVG has no conic
-- gradient), so the colors at the sub-arcs' ends are the conic gradient's.

local Hash = require("../hash")
local SvgPaths = require("./svg_paths")
local Stat = require("../panels/stat")

local M = {}

export type Style = "v1" | "gauge" | "circle"

-- A run of the scale (0..1 fractions of min..max) in one color class.
export type Band = { from: number, to: number, class: string }

-- A conic gradient stop: a color class at a fraction of the scale (may lie
-- outside 0..1).
export type Stop = { at: number, class: string }

export type Label = { at: number, text: string }

export type Spec = {
	width: number,
	height: number,
	style: Style,
	-- RadialGauge barWidthFactor (v2 only).
	bar_width_factor: number?,
	rounded: boolean?,
	-- effects.barGlow: Grafana only reserves a margin for the glow.
	glow: boolean?,
	segments: number?,
	segment_spacing: number?,
	-- The filled run of the bar (fractions): min or the neutral value to
	-- the value.
	fill_from: number,
	fill_to: number,
	-- Colors along the scale the filled run is painted in.
	bands: { Band },
	-- effects.gradient: the conic gradient's stops, sorted (it paints the
	-- filled run, the filled segments and the ring instead of their classes).
	gradient: { Stop }?,
	-- Color class of each segment by its start fraction (segmented bars).
	segment_class: ((at: number) -> string)?,
	-- The outer threshold ring (showThresholdMarkers).
	ring: { Band }?,
	labels: { Label }?,
	-- endpointMarker "point".
	endpoint: boolean?,
	prefix: string?,
	text: string?,
	suffix: string?,
	-- Value text color class (v1 colors the value; v2 uses the text color).
	text_class: string?,
	name: string?,
	value_size: number?,
	name_size: number?,
	-- Sparkline values scaled to 0..1 (nil entries are gaps).
	spark: { number? }?,
	spark_class: string?,
	-- 1-based sparkline sample the reducer picked (Sparkline showHighlights,
	-- Grafana 12.4 and later): drawn as a point.
	spark_highlight: number?,
}

-- RadialGauge constants.
local ARC_START = 250
local ARC_END = 110
local V1_START = 225
local V1_RANGE = 270
local LINE_HEIGHT = 1.21
-- The widest sub-arc one linear gradient stands in for the conic one, in
-- degrees.
local CONIC_STEP = 10
-- Degrees a gradient sub-arc overlaps the next one.
local SEAM_OVERLAP = 0.5

local function rad(deg: number): number
	return (deg - 90) * math.pi / 180
end

local function fmt(n: number): string
	local s = string.format("%.2f", n)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	return if s == "-0" then "0" else s
end

local function escape(text: string): string
	return (string.gsub(text, '[&<>"]', { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- drawRadialArcPath around (cx, cy): `sweep` degrees clockwise from `start`
-- (degrees clockwise from twelve o'clock).
function M.arcPath(cx: number, cy: number, start: number, sweep: number, r: number): string
	if sweep >= 360 then
		sweep = 359.99
	end
	local a, b = rad(start), rad(start + sweep)
	return string.format(
		"M%s %sA%s %s 0 %d 1 %s %s",
		fmt(cx + r * math.cos(a)),
		fmt(cy + r * math.sin(a)),
		fmt(r),
		fmt(r),
		if sweep > 180 then 1 else 0,
		fmt(cx + r * math.cos(b)),
		fmt(cy + r * math.sin(b))
	)
end

-- calculateFontSize with measureText approximated at 0.6 em per glyph.
local function fontSize(text: string, width: number, height: number, max: number?): number
	local measured = 14 * 0.6 * math.max(1, utf8.len(text) or #text)
	local byWidth = width / (measured + 2) * 14
	local size = math.min(height / LINE_HEIGHT, byWidth)
	return if max then math.min(size, max) else size
end

export type Dimensions = {
	cx: number,
	cy: number,
	-- Bar centerline radius and width.
	radius: number,
	bar: number,
	ring_radius: number,
	ring_width: number,
	labels_radius: number,
	labels_size: number,
	bottom: number,
	start: number,
	range: number,
}

-- RadialGauge calculateDimensions (barIndex 0).
local function v2Dimensions(s: Spec): Dimensions
	local w, h = s.width, s.height
	local circle = s.style == "circle"
	local endAngle = if circle then 360 else ARC_END
	local yMax = if endAngle > 180 then 180 else endAngle
	local margin = if s.glow then 0.02 * math.min(w, h) else 0
	local maxW = w / 2 - margin
	local ratio = math.sin(rad(yMax))
	local maxH = (h - margin * 2) / (1 + ratio)
	local maxRadius = math.min(maxW, maxH)
	local limitedByH = maxH == maxRadius
	local outer = maxRadius
	local bar = math.max((s.bar_width_factor or 0.5) * (maxRadius / 3), 2)
	local endcap = if yMax < 180 and s.rounded then bar * 0.5 else 0
	local radiusAdj = endcap * 0.5
	outer -= radiusAdj
	maxH -= radiusAdj
	maxW -= radiusAdj
	local labelsSize, labelsRadius = 0, 0
	if s.labels then
		labelsRadius = outer
		labelsSize = math.max(0.12 * outer ^ 0.92, 10)
		local used = labelsSize * 1.2 + labelsSize / 3
		outer -= used
		maxW -= used
		maxH -= used
		if limitedByH and endAngle < 180 then
			local amount = outer * 0.07
			labelsRadius -= amount
			maxH -= amount
			maxW -= amount
			outer -= amount
		end
	end
	local ringWidth = if s.ring then math.clamp(0.2 * bar ^ 0.92, 4, 12) else 0
	local ringSpacing = math.clamp(ringWidth / 2, 2, 12)
	local ringRadius = 0
	if ringWidth > 0 then
		ringRadius = outer - ringWidth / 2
		maxW -= ringWidth + ringSpacing
		maxH -= ringWidth + ringSpacing
		outer = math.min(maxW, maxH)
	end
	local below = maxRadius * ratio
	local rest = h - below - margin * 2 - maxRadius
	local cy = maxRadius + margin + rest / 2 - (endcap - radiusAdj)
	return {
		cx = w / 2,
		cy = cy,
		radius = outer - bar / 2,
		bar = bar,
		ring_radius = ringRadius,
		ring_width = ringWidth,
		labels_radius = labelsRadius,
		labels_size = labelsSize,
		bottom = cy + below,
		start = if circle then 0 else ARC_START,
		range = if circle then 360 else (360 % ARC_START) + ARC_END,
	}
end

-- Gauge.tsx: gauge width min(dimension / 5.5, 40) (thinner with threshold
-- labels), markers a fifth of it outside the bar, labels outside those.
local function v1Dimensions(s: Spec): Dimensions
	local dimension = math.min(s.width, s.height)
	local bar = math.min(dimension / 5.5, 40) / (if s.labels then 1.5 else 1)
	local ringWidth = if s.ring then bar / 5 else 0
	local labelsSize = if s.labels then math.max(bar * 1.7 / 2.5, 12) else 0
	-- A 270 degree arc spans r * (1 + sin 45) vertically.
	local outer = math.min(s.width / 2, s.height / (1 + math.sqrt(0.5)))
		- 5
		- (if s.labels then labelsSize * 1.6 else 0)
	outer = math.max(outer, bar)
	local ringRadius = outer - ringWidth / 2
	local radius = outer - ringWidth - (if ringWidth > 0 then 1 else 0) - bar / 2
	local cy = (s.height - outer * (1 + math.sqrt(0.5))) / 2 + outer
	return {
		cx = s.width / 2,
		cy = cy,
		radius = radius,
		bar = bar,
		ring_radius = ringRadius,
		ring_width = ringWidth,
		labels_radius = outer + labelsSize * 0.9,
		labels_size = labelsSize,
		bottom = cy + outer * math.sqrt(0.5),
		start = V1_START,
		range = V1_RANGE,
	}
end

function M.dimensions(s: Spec): Dimensions
	return if s.style == "v1" then v1Dimensions(s) else v2Dimensions(s)
end

-- `x` within 0..1, NaN as 0.
local function clamp01(x: number): number
	return if x ~= x then 0 else math.clamp(x, 0, 1)
end
M.clamp01 = clamp01

-- The colored runs of the filled part: the bands clipped to from..to.
function M.fillRuns(bands: { Band }, from: number, to: number): { Band }
	local out: { Band } = {}
	for _, b in bands do
		local a, z = math.max(b.from, from), math.min(b.to, to)
		if z > a then
			table.insert(out, { from = a, to = z, class = b.class })
		end
	end
	return out
end

-- getOptimalSegmentCount and getAngleBetweenSegments.
function M.segmentLayout(d: Dimensions, count: number, spacing: number): (number, number)
	local between = spacing * math.max(d.range / 1.5 / count, 2)
	local inner = d.radius - d.bar / 2
	local circumference = math.pi * inner * 2 * (d.range / 360)
	local n = math.min(math.floor(circumference / (between + 3)), count)
	return math.max(n, 1), between
end

export type Box = { x0: number, y0: number, x1: number, y1: number }

local function grow(b: Box, x: number, y: number)
	b.x0, b.y0 = math.min(b.x0, x), math.min(b.y0, y)
	b.x1, b.y1 = math.max(b.x1, x), math.max(b.y1, y)
end

-- The lowest and highest label positions on the scale.
local function labelEnds(labels: { Label }): (number, number)
	local lo, hi = math.huge, -math.huge
	for _, l in labels do
		lo, hi = math.min(lo, l.at), math.max(hi, l.at)
	end
	return lo, hi
end

-- A label's angle in degrees (RadialScaleLabels getStartOffset): on a full
-- circle the lowest label moves clockwise and the highest back by 0.65 of
-- its width, so min and max at twelve o'clock stand side by side; on an arc
-- an end label that would cross the arc's end moves half its width inside.
-- The labels follow a path a line of text inside their radius.
local function labelAngle(s: Spec, d: Dimensions, l: Label, lo: number, hi: number): number
	local at = clamp01(l.at)
	local length = d.range / 360 * 2 * math.pi * (d.labels_radius - d.labels_size * 1.2)
	if s.style == "v1" or length <= 0 then
		return d.start + at * d.range
	end
	local offset = at * length
	local width = Stat.textEm(l.text) * d.labels_size
	if d.range >= 360 then
		if l.at == lo then
			offset += width * 0.65
		elseif l.at == hi then
			offset -= width * 0.65
		end
	else
		if l.at == lo and offset - width / 2 < 0 then
			offset += width / 2
		end
		if l.at == hi and offset + width / 2 > length then
			offset -= width / 2
		end
	end
	return d.start + offset / length * d.range
end

-- The box around what the arc part draws: the bar (its rounded caps), the
-- threshold ring and labels over the arc's sweep, and the center the text
-- sits on. Grafana draws a gauge at min(width, height) of its panel; a
-- viewBox this tight lets the image scale to whatever the pane allows.
function M.arcBounds(s: Spec, d: Dimensions): Box
	local outer = d.radius + d.bar / 2 + (if s.rounded then d.bar / 2 else 0)
	if s.ring then
		outer = math.max(outer, d.ring_radius + d.ring_width / 2)
	end
	local b: Box = { x0 = d.cx, y0 = d.cy, x1 = d.cx, y1 = d.cy }
	local steps = math.max(1, math.ceil(d.range / 5))
	for i = 0, steps do
		local a = rad(d.start + d.range * i / steps)
		grow(b, d.cx + outer * math.cos(a), d.cy + outer * math.sin(a))
	end
	local labels: { Label } = s.labels or {}
	local lo, hi = labelEnds(labels)
	for _, l in labels do
		local a = rad(labelAngle(s, d, l, lo, hi))
		local r = d.labels_radius - d.labels_size * 0.6
		local x, y = d.cx + r * math.cos(a), d.cy + r * math.sin(a)
		local half = 0.3 * d.labels_size * (utf8.len(l.text) or #l.text)
		grow(b, x - half, y - d.labels_size * 0.6)
		grow(b, x + half, y + d.labels_size * 0.6)
	end
	return b
end

-- The SVG and its size in px (the tight viewBox's).
function M.render(s: Spec): (string, number, number)
	local d = M.dimensions(s)
	local out: { string } = {}
	local function push(fmtString: string, ...: any)
		table.insert(out, string.format(fmtString, ...))
	end
	push(
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" class="tgg">',
		s.width,
		s.height,
		s.width,
		s.height
	)
	local cap = if s.rounded then "round" else "butt"
	local function arc(class: string, from: number, sweep: number, r: number, width: number, linecap: string)
		if sweep <= 0 then
			return
		end
		-- A full circle as two halves: an arc whose ends meet draws nothing.
		local pieces: { { number } } = if sweep >= 359
			then { { from, sweep / 2 }, { from + sweep / 2, sweep / 2 } }
			else { { from, sweep } }
		for _, piece in pieces do
			push(
				'<path class="%s tg-line" fill="none" stroke-width="%s" stroke-linecap="%s" d="%s"/>',
				class,
				fmt(width),
				linecap,
				M.arcPath(d.cx, d.cy, piece[1], piece[2], r)
			)
		end
	end
	-- The conic gradient over the scale run from..to at radius r: one piece
	-- per run between two stops (past the first or last stop, its color),
	-- split into sub-arcs of at most CONIC_STEP degrees. Rounded, the run's
	-- two ends are round: the last sub-arc goes first, so the ones before
	-- it cover its round start, and the second covers the first's round end.
	local defined: { [string]: boolean } = {}
	local function conic(stops: { Stop }, from: number, to: number, r: number, width: number, rounded: boolean)
		type Sub = { a: number, b: number, p: Stop, q: Stop }
		local subs: { Sub } = {}
		local function add(a: number, b: number, p: Stop, q: Stop)
			if b <= a then
				return
			end
			local n = if p.class == q.class then 1 else math.ceil((b - a) * d.range / CONIC_STEP)
			for j = 1, n do
				table.insert(subs, { a = a + (b - a) * (j - 1) / n, b = a + (b - a) * j / n, p = p, q = q })
			end
		end
		local first, last = stops[1], stops[#stops]
		add(from, math.min(to, first.at), first, first)
		for i = 1, #stops - 1 do
			add(math.max(from, stops[i].at), math.min(to, stops[i + 1].at), stops[i], stops[i + 1])
		end
		add(math.max(from, last.at), to, last, last)
		local function draw(k: number)
			local sub = subs[k]
			local linecap = if rounded and (k == 1 or k == #subs) then "round" else "butt"
			local start, sweep = d.start + sub.a * d.range, (sub.b - sub.a) * d.range
			-- Each sub-arc but the run's last reaches a little into the next,
			-- drawn over it: abutting antialiased edges leave a light seam.
			local overlap = if k < #subs then math.min(SEAM_OVERLAP, sweep) else 0
			if sub.p.class == sub.q.class then
				arc(sub.q.class, start, sweep + overlap, r, width, linecap)
				return
			end
			-- The gradient line runs from where the conic gradient is p to
			-- where it is q, along the sub-arc's chord.
			local span = sub.q.at - sub.p.at
			local u0, u1 = (sub.a - sub.p.at) / span, (sub.b - sub.p.at) / span
			local a0, a1 = rad(start), rad(start + sweep)
			local x0, y0 = d.cx + r * math.cos(a0), d.cy + r * math.sin(a0)
			local dx, dy = d.cx + r * math.cos(a1) - x0, d.cy + r * math.sin(a1) - y0
			local back, ahead = u0 / (u1 - u0), (1 - u0) / (u1 - u0)
			local def = string.format(
				' gradientUnits="userSpaceOnUse" x1="%s" y1="%s" x2="%s" y2="%s"><stop offset="0" class="%s"/><stop offset="1" class="%s"/>',
				fmt(x0 - dx * back),
				fmt(y0 - dy * back),
				fmt(x0 + dx * ahead),
				fmt(y0 + dy * ahead),
				sub.p.class,
				sub.q.class
			)
			local id = "tgq" .. Hash.fnv1a32hex(def)
			if not defined[id] then
				defined[id] = true
				push('<defs><linearGradient id="%s"%s</linearGradient></defs>', id, def)
			end
			push(
				'<path class="tg-line" stroke="url(#%s)" fill="none" stroke-width="%s" stroke-linecap="%s" d="%s"/>',
				id,
				fmt(width),
				linecap,
				M.arcPath(d.cx, d.cy, start, sweep + overlap, r)
			)
		end
		if #subs > 1 then
			draw(#subs)
		end
		for k = 1, math.max(#subs - 1, 1) do
			if subs[k] then
				draw(k)
			end
		end
	end
	local gradient = if s.gradient and #(s.gradient :: { Stop }) > 0 then s.gradient :: { Stop } else nil
	local from, to = clamp01(s.fill_from), clamp01(s.fill_to)
	local segments = s.segments or 1
	if segments > 1 then
		-- RadialBarSegmented: each segment is filled when its start lies in
		-- the filled run, in the color of its own start value (the gradient
		-- under it with effects.gradient).
		local n, between = M.segmentLayout(d, segments, s.segment_spacing or 0.3)
		local step = d.range / n
		for i = 0, n - 1 do
			local at = i / n
			local filled = at >= from and at < to
			local a, sweep = step * i + 0.01, step - between
			if filled and gradient then
				conic(gradient, a / d.range, (a + sweep) / d.range, d.radius, d.bar, false)
			else
				local class = if filled and s.segment_class then s.segment_class(at) else nil
				arc(
					if filled then class or "tgp-fx tgp-neutral" else "tgg-track",
					d.start + a,
					sweep,
					d.radius,
					d.bar,
					"butt"
				)
			end
		end
	else
		arc("tgg-track", d.start, d.range, d.radius, d.bar, cap)
		if gradient then
			conic(gradient, from, to, d.radius, d.bar, s.rounded == true)
		else
			local runs = M.fillRuns(s.bands, from, to)
			for i, r in runs do
				-- Rounded caps only on the ends of the whole bar.
				local linecap = if s.rounded and (i == 1 or i == #runs) and #runs == 1 then "round" else "butt"
				arc(r.class, d.start + r.from * d.range, (r.to - r.from) * d.range, d.radius, d.bar, linecap)
			end
		end
	end
	if s.ring then
		local ring = s.ring :: { Band }
		if gradient and #ring > 0 then
			conic(gradient, ring[1].from, ring[#ring].to, d.ring_radius, d.ring_width, false)
		else
			for _, b in ring do
				arc(b.class, d.start + b.from * d.range, (b.to - b.from) * d.range, d.ring_radius, d.ring_width, "butt")
			end
		end
	end
	if s.endpoint and segments <= 1 and to > from then
		-- RadialArcPathEndpointMarks "point": dots at both ends of the run
		-- (the start one only past 10 degrees).
		local r = math.min(d.bar / 2 * 0.4, 8)
		local sweep = (to - from) * d.range
		local ends = { d.start + to * d.range }
		if sweep > 10 then
			table.insert(ends, d.start + from * d.range)
		end
		for _, a in ends do
			push(
				'<circle class="tgg-dot" cx="%s" cy="%s" r="%s" opacity="0.5"/>',
				fmt(d.cx + d.radius * math.cos(rad(a))),
				fmt(d.cy + d.radius * math.sin(rad(a))),
				fmt(r)
			)
		end
	end
	if s.labels and #s.labels > 0 then
		local lo, hi = labelEnds(s.labels)
		for _, l in s.labels do
			local a = rad(labelAngle(s, d, l, lo, hi))
			local r = d.labels_radius - d.labels_size * 0.6
			push(
				'<text class="tgg-label" x="%s" y="%s" font-size="%s" text-anchor="middle">%s</text>',
				fmt(d.cx + r * math.cos(a)),
				fmt(d.cy + r * math.sin(a) + d.labels_size * 0.36),
				fmt(d.labels_size),
				escape(l.text)
			)
		end
	end
	-- RadialText.
	local maxWidth = d.radius * 2 - d.bar - d.radius / 7
	local showValue = s.text ~= nil
	local showName = s.name ~= nil
	local maxValueH = 0.82 * math.max(d.radius, 1) ^ 0.86
	local maxNameH = if showValue then 0.45 * math.max(d.radius, 1) ^ 0.86 else d.radius / 4
	local valueText = (s.prefix or "") .. (s.text or "") .. (s.suffix or "")
	local vSize = math.max(s.value_size or fontSize(valueText, maxWidth, maxValueH), 1)
	local nSize = math.max(s.name_size or fontSize(s.name or "", maxWidth, maxNameH), 10)
	local vH, nH = vSize * LINE_HEIGHT, nSize * LINE_HEIGHT
	local valueY = if showName then d.cy - nH * 0.3 else d.cy
	local nameY = if showValue then valueY + vH * 0.7 else d.cy
	local offset = 0
	if s.style == "gauge" then
		offset += (vH + nH) / 4
	end
	if s.spark then
		offset += 8
	end
	if s.style == "v1" then
		-- The flot gauge centers its value in the arc.
		offset = 0
	end
	if showValue then
		-- Prefix and suffix at 70% size beside the value. Tern's SVG sanitizer
		-- drops <tspan>, so each part is its own <text>, laid out with the
		-- advance widths of the SVG's font (.tgg, Geist).
		local unit = math.max(vSize * 0.7, 6)
		local tone = if s.text_class then s.text_class .. " tg-bar" else "tgg-text"
		type Part = { text: string, size: number }
		local parts: { Part } = {}
		if s.prefix and s.prefix ~= "" then
			table.insert(parts, { text = s.prefix :: string, size = unit })
		end
		table.insert(parts, { text = s.text or "", size = vSize })
		if s.suffix and s.suffix ~= "" then
			table.insert(parts, { text = s.suffix :: string, size = unit })
		end
		local function width(p: Part): number
			return Stat.textEm(p.text) * p.size
		end
		local total = 0
		for _, p in parts do
			total += width(p)
		end
		local x = d.cx - total / 2
		-- Tern's SVG ignores dominant-baseline: the value's baseline centers
		-- its cap height on the line, and the unit parts share it.
		local baseline = valueY - offset + vSize * 0.36
		for _, p in parts do
			push(
				'<text class="%s" x="%s" y="%s" font-size="%s" text-anchor="start">%s</text>',
				tone,
				fmt(x),
				fmt(baseline),
				fmt(p.size),
				escape(p.text)
			)
			x += width(p)
		end
	end
	if showName then
		push(
			'<text class="%s" x="%s" y="%s" font-size="%s" text-anchor="middle">%s</text>',
			if showValue then "tgg-name" else "tgg-text",
			fmt(d.cx),
			fmt(nameY - offset + nSize * 0.36),
			fmt(nSize),
			escape(s.name :: string)
		)
	end
	local spark = s.spark
	if spark and #spark > 1 then
		-- RadialSparkline: radius / 4 tall, radius * 1.4 (circle 1.6) - bar
		-- wide, above the arc's bottom (circle: below the center).
		local w = d.radius * (if s.style == "circle" then 1.6 else 1.4) - d.bar
		local h = d.radius / 4
		local top = if s.style == "circle"
			then d.cy + d.radius / (if showName and showValue then 3.3 else 4)
			else d.bottom - h - 8
		local left = d.cx - w / 2
		local hi = s.spark_highlight
		if hi then
			-- Sparkline with showHighlights: the plot keeps HIGHLIGHT_IDX_POINT_SIZE / 2
			-- (3 px) of padding on every side for the point.
			left, top, w, h = left + 3, top + 3, math.max(w - 6, 1), math.max(h - 6, 1)
		end
		local pts: { number } = {}
		for i, v in spark do
			if v then
				table.insert(pts, left + (i - 1) / (#spark - 1) * w)
				table.insert(pts, top + h - clamp01(v) * h)
			end
		end
		if #pts >= 4 then
			local first, last = pts[1], pts[#pts - 1]
			local class = s.spark_class or "tgp-fx tgp-info"
			-- RadialSparkline: lineInterpolation smooth (the time series' monotone
			-- cubic, which never overshoots a sample).
			local segs = SvgPaths.smoothSegs(pts)
			local parts: { string } = { "M" .. fmt(segs[1]) .. " " .. fmt(segs[2]) }
			for o = 3, #segs, 6 do
				table.insert(
					parts,
					string.format(
						"C%s %s %s %s %s %s",
						fmt(segs[o]),
						fmt(segs[o + 1]),
						fmt(segs[o + 2]),
						fmt(segs[o + 3]),
						fmt(segs[o + 4]),
						fmt(segs[o + 5])
					)
				)
			end
			local path = table.concat(parts)
			-- RadialSparkline: gradientMode opacity at fillOpacity 40, the fill
			-- fading from 40% at the plot's top to none at its bottom (a mask,
			-- the color stays the class's).
			local area = string.format("%sL%s %sL%s %sZ", path, fmt(last), fmt(top + h), fmt(first), fmt(top + h))
			local mask = "tgs" .. Hash.fnv1a32hex(area)
			push(
				'<defs><linearGradient id="%s-g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="white"/><stop offset="1" stop-color="white" stop-opacity="0"/></linearGradient><mask id="%s"><rect x="%s" y="%s" width="%s" height="%s" fill="url(#%s-g)"/></mask></defs>',
				mask,
				mask,
				fmt(left),
				fmt(top),
				fmt(w),
				fmt(h),
				mask
			)
			push('<path class="%s tg-area" fill-opacity="0.4" mask="url(#%s)" d="%s"/>', class, mask, area)
			push('<path class="%s tg-line" fill="none" stroke-width="1" d="%s"/>', class, path)
		end
		local hv = if hi then spark[hi] else nil
		if hi and hv then
			-- The calc's sample (getSparklineHighlight) as a 6 px point in the
			-- line's color.
			push(
				'<circle class="%s" cx="%s" cy="%s" r="3"/>',
				s.spark_class or "tgp-fx tgp-info",
				fmt(left + (hi - 1) / (#spark - 1) * w),
				fmt(top + h - clamp01(hv) * h)
			)
		end
	end
	-- Tight viewBox (2 px margin) inside the design box: text and
	-- sparkline join the arc's box.
	local b = M.arcBounds(s, d)
	if showValue then
		local half = 0.3 * vSize * (utf8.len(valueText) or #valueText)
		grow(b, d.cx - half, valueY - offset - vH / 2)
		grow(b, d.cx + half, valueY - offset + vH / 2)
	end
	if showName then
		local name = s.name :: string
		local half = 0.3 * nSize * (utf8.len(name) or #name)
		grow(b, d.cx - half, nameY - offset - nH / 2)
		grow(b, d.cx + half, nameY - offset + nH / 2)
	end
	if spark and #spark > 1 then
		local sw = d.radius * (if s.style == "circle" then 1.6 else 1.4) - d.bar
		grow(b, d.cx - sw / 2, d.bottom)
		grow(b, d.cx + sw / 2, d.bottom)
	end
	local x0, y0 = math.max(0, math.floor(b.x0 - 2)), math.max(0, math.floor(b.y0 - 2))
	local x1, y1 = math.min(s.width, math.ceil(b.x1 + 2)), math.min(s.height, math.ceil(b.y1 + 2))
	local w, h = math.max(1, x1 - x0), math.max(1, y1 - y0)
	out[1] = string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="%d %d %d %d" width="%d" height="%d" class="tgg">',
		x0,
		y0,
		w,
		h,
		w,
		h
	)
	table.insert(out, "</svg>")
	return table.concat(out), w, h
end

return M
