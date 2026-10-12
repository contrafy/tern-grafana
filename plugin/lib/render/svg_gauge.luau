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
-- Every color is a class (panels2.css): `tgg-s-<tone>` strokes,
-- `tgg-f-<tone>` fills, so a theme switch recolors without a new blob.
-- Grafana's conic color gradient becomes the threshold bands the gradient
-- passes through, each in its step's tone.

local M = {}

export type Style = "v1" | "gauge" | "circle"

-- A run of the scale (0..1 fractions of min..max) in one tone.
export type Band = { from: number, to: number, tone: string }

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
	-- Tones along the scale the filled run is painted in.
	bands: { Band },
	-- Tone of each segment by its start fraction (segmented bars).
	segment_tone: ((at: number) -> string)?,
	-- The outer threshold ring (showThresholdMarkers).
	ring: { Band }?,
	labels: { Label }?,
	-- endpointMarker "point".
	endpoint: boolean?,
	prefix: string?,
	text: string?,
	suffix: string?,
	-- Value text tone (v1 colors the value; v2 uses the text color).
	text_tone: string?,
	name: string?,
	value_size: number?,
	name_size: number?,
	-- Sparkline values scaled to 0..1 (nil entries are gaps).
	spark: { number? }?,
	spark_tone: string?,
}

-- RadialGauge constants.
local ARC_START = 250
local ARC_END = 110
local V1_START = 225
local V1_RANGE = 270
local LINE_HEIGHT = 1.21

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

local function clamp01(x: number): number
	return if x ~= x then 0 else math.clamp(x, 0, 1)
end

-- The colored runs of the filled part: the bands clipped to from..to.
function M.fillRuns(bands: { Band }, from: number, to: number): { Band }
	local out: { Band } = {}
	for _, b in bands do
		local a, z = math.max(b.from, from), math.min(b.to, to)
		if z > a then
			table.insert(out, { from = a, to = z, tone = b.tone })
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

function M.render(s: Spec): string
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
				'<path class="%s" fill="none" stroke-width="%s" stroke-linecap="%s" d="%s"/>',
				class,
				fmt(width),
				linecap,
				M.arcPath(d.cx, d.cy, piece[1], piece[2], r)
			)
		end
	end
	local from, to = clamp01(s.fill_from), clamp01(s.fill_to)
	local segments = s.segments or 1
	if segments > 1 then
		-- RadialBarSegmented: each segment is filled when its start lies in
		-- the filled run, in the color of its own start value.
		local n, between = M.segmentLayout(d, segments, s.segment_spacing or 0.3)
		local step = d.range / n
		for i = 0, n - 1 do
			local at = i / n
			local filled = at >= from and at < to
			local tone = if filled and s.segment_tone then s.segment_tone(at) else nil
			arc(
				if filled then "tgg-s-" .. (tone or "neutral") else "tgg-track",
				d.start + step * i + 0.01,
				step - between,
				d.radius,
				d.bar,
				"butt"
			)
		end
	else
		arc("tgg-track", d.start, d.range, d.radius, d.bar, cap)
		local runs = M.fillRuns(s.bands, from, to)
		for i, r in runs do
			-- Rounded caps only on the ends of the whole bar.
			local linecap = if s.rounded and (i == 1 or i == #runs) and #runs == 1 then "round" else "butt"
			arc("tgg-s-" .. r.tone, d.start + r.from * d.range, (r.to - r.from) * d.range, d.radius, d.bar, linecap)
		end
	end
	if s.ring then
		for _, b in s.ring do
			arc(
				"tgg-s-" .. b.tone,
				d.start + b.from * d.range,
				(b.to - b.from) * d.range,
				d.ring_radius,
				d.ring_width,
				"butt"
			)
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
		for _, l in s.labels do
			local a = rad(d.start + clamp01(l.at) * d.range)
			local r = d.labels_radius - d.labels_size * 0.6
			push(
				'<text class="tgg-label" x="%s" y="%s" font-size="%s" text-anchor="middle" dominant-baseline="middle">%s</text>',
				fmt(d.cx + r * math.cos(a)),
				fmt(d.cy + r * math.sin(a)),
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
		-- 0.6 em glyph estimate.
		local unit = math.max(vSize * 0.7, 6)
		local tone = if s.text_tone then "tgg-f-" .. s.text_tone else "tgg-text"
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
			return 0.6 * p.size * (utf8.len(p.text) or #p.text)
		end
		local total = 0
		for _, p in parts do
			total += width(p)
		end
		local x = d.cx - total / 2
		for _, p in parts do
			push(
				'<text class="%s" x="%s" y="%s" font-size="%s" text-anchor="start" dominant-baseline="middle">%s</text>',
				tone,
				fmt(x),
				fmt(valueY - offset),
				fmt(p.size),
				escape(p.text)
			)
			x += width(p)
		end
	end
	if showName then
		push(
			'<text class="%s" x="%s" y="%s" font-size="%s" text-anchor="middle" dominant-baseline="middle">%s</text>',
			if showValue then "tgg-name" else "tgg-text",
			fmt(d.cx),
			fmt(nameY - offset),
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
		local line: { string } = {}
		local first: number? = nil
		local last: number? = nil
		for i, v in spark do
			if v then
				local x = left + (i - 1) / (#spark - 1) * w
				local y = top + h - clamp01(v) * h
				table.insert(line, string.format("%s%s %s", if first == nil then "M" else "L", fmt(x), fmt(y)))
				first = first or x
				last = x
			end
		end
		if first and last and #line > 1 then
			local tone = s.spark_tone or "info"
			local path = table.concat(line)
			push(
				'<path class="tgg-f-%s" fill-opacity="0.2" d="%sL%s %sL%s %sZ"/>',
				tone,
				path,
				fmt(last),
				fmt(top + h),
				fmt(first),
				fmt(top + h)
			)
			push('<path class="tgg-s-%s" fill="none" stroke-width="1" d="%s"/>', tone, path)
		end
	end
	table.insert(out, "</svg>")
	return table.concat(out)
end

return M
