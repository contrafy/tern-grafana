--!strict
-- Pie and donut SVGs as Grafana's pie chart draws them
-- (public/app/plugins/panel/piechart/PieChart.tsx): slices clockwise from
-- 12 o'clock in the given order, a 16 px margin, a donut ring max(r/3, 20)
-- thick, 0.005 rad padding between slices, each slice in its color's
-- radial gradient (getGradientColorFrom at the inner radius to
-- getGradientColorTo at the outer one, per theme: Tern's SVG has no
-- radialGradient, so RINGS concentric bands sample it, the dark and light
-- theme's bands each shown only in their theme, filled with the exact
-- sampled colors), and labels (name, value, percent lines) at the middle of
-- the ring on slices of at least 0.3 rad.
-- The SVG is as wide as the panel gives it, the pie centered, so labels
-- running past the pie stay visible as in Grafana (overflow: visible).
-- A slice without a color is flat in its classes (palette tg-s<n>, exact
-- tg-gc<n> or tone classes).

local Kit = require("./svg_kit")
local TsGradient = require("./ts_gradient")

local M = {}

export type Slice = {
	value: number,
	-- Color classes (tg-s3, tg-gc12 tg-hex, or "tgp-fx tgp-error").
	class: string,
	-- The slice's color (name or hex) for its gradient; nil draws it flat.
	color: string?,
	-- Label lines drawn on the slice (empty: none).
	labels: { string },
}

export type Options = {
	-- Pie side, px.
	size: number,
	-- Canvas width, px (at least `size`; default `size`).
	width: number?,
	donut: boolean?,
	-- Name is among the labels: Grafana sizes label text smaller then.
	name_label: boolean?,
}

M.RINGS = 8

M.MARGIN = 16
M.PAD = 0.005
M.MIN_LABEL_ANGLE = 0.3

local fmt = string.format
local TAU = 2 * math.pi

export type Layout = { cx: number, cy: number, outer: number, inner: number }

-- getPieLayout.
function M.layout(size: number, donut: boolean): Layout
	local outer = math.max(1, (size - M.MARGIN * 2) / 2)
	local thickness = if donut then math.max(outer / 3, 20) else outer
	return { cx = size / 2, cy = size / 2, outer = outer, inner = math.max(0, outer - thickness) }
end

local function point(l: Layout, r: number, a: number): (number, number)
	return l.cx + r * math.sin(a), l.cy - r * math.cos(a)
end

local function arcPath(l: Layout, a0: number, a1: number): string
	local span = a1 - a0
	local ro, ri = l.outer, l.inner
	if span >= TAU - 1e-9 then
		-- A full ring: two half arcs per circle.
		local top = fmt(
			"M%.1f %.1fA%.1f %.1f 0 1 1 %.1f %.1fA%.1f %.1f 0 1 1 %.1f %.1fZ",
			l.cx,
			l.cy - ro,
			ro,
			ro,
			l.cx,
			l.cy + ro,
			ro,
			ro,
			l.cx,
			l.cy - ro
		)
		if ri <= 0 then
			return top
		end
		return top
			.. fmt(
				"M%.1f %.1fA%.1f %.1f 0 1 0 %.1f %.1fA%.1f %.1f 0 1 0 %.1f %.1fZ",
				l.cx,
				l.cy - ri,
				ri,
				ri,
				l.cx,
				l.cy + ri,
				ri,
				ri,
				l.cx,
				l.cy - ri
			)
	end
	local large = if span > math.pi then 1 else 0
	local x0, y0 = point(l, ro, a0)
	local x1, y1 = point(l, ro, a1)
	local d = fmt("M%.1f %.1fA%.1f %.1f 0 %d 1 %.1f %.1f", x0, y0, ro, ro, large, x1, y1)
	if ri > 0 then
		local x2, y2 = point(l, ri, a1)
		local x3, y3 = point(l, ri, a0)
		d ..= fmt("L%.1f %.1fA%.1f %.1f 0 %d 0 %.1f %.1fZ", x2, y2, ri, ri, large, x3, y3)
	else
		d ..= fmt("L%.1f %.1fZ", l.cx, l.cy)
	end
	return d
end

-- The SVG for `slices` (non-positive values take no room, as in d3's pie).
function M.render(slices: { Slice }, opts: Options): string
	local size = math.max(40, opts.size)
	local width = math.max(size, opts.width or size)
	local l = M.layout(size, opts.donut == true)
	l.cx += (width - size) / 2
	local out: { string } = { Kit.open(width, size) }
	local total = 0
	local count = 0
	for _, s in slices do
		if s.value > 0 and s.value == s.value then
			total += s.value
			count += 1
		end
	end
	if total <= 0 then
		Kit.noData(out, l.cx, l.cy)
		return Kit.finish(out, "svg_pie")
	end
	-- Each color's gradient bands per theme.
	local rings: { [string]: { dark: { string }, light: { string } } } = {}
	for _, s in slices do
		local color = s.color
		if color and rings[color] == nil then
			rings[color] = {
				dark = TsGradient.pieRings(color, "dark", M.RINGS),
				light = TsGradient.pieRings(color, "light", M.RINGS),
			}
		end
	end
	local pad = if count > 1 then M.PAD else 0
	local fontSize = if opts.name_label
		then math.clamp(l.outer / 150 * 14, 12, 30)
		else math.clamp(l.outer / 100 * 14, 12, 36)
	local labelRadius = if l.inner == 0 then l.outer / 6 else l.inner
	local labels: { string } = {}
	local a = 0
	for _, s in slices do
		if not (s.value > 0 and s.value == s.value) then
			continue
		end
		local span = s.value / total * TAU
		local a0, a1 = a, a + span
		a = a1
		local p0, p1 = a0 + pad / 2, a1 - pad / 2
		if p1 <= p0 then
			p0, p1 = a0, a1
		end
		local bands = if s.color then rings[s.color :: string] else nil
		if bands then
			-- Outermost band first, each next one inside it, so the bands
			-- overlap without seams.
			for _, theme in { "dark", "light" } do
				local fills = if theme == "dark" then bands.dark else bands.light
				for i = M.RINGS, 1, -1 do
					local ring: Layout =
						{ cx = l.cx, cy = l.cy, inner = l.inner, outer = l.inner + (l.outer - l.inner) * i / M.RINGS }
					table.insert(
						out,
						fmt('<path class="tg-bar tgv-%s" fill="%s" d="%s"/>', theme, fills[i], arcPath(ring, p0, p1))
					)
				end
			end
		else
			table.insert(out, fmt('<path class="%s tg-bar" d="%s"/>', s.class, arcPath(l, p0, p1)))
		end
		if #s.labels > 0 and span >= M.MIN_LABEL_ANGLE then
			local mid = (a0 + a1) / 2
			local lx, ly = point(l, (l.outer + labelRadius) / 2, mid)
			for i, line in s.labels do
				table.insert(
					labels,
					Kit.text(lx, ly + fontSize * (0.33 + 1.2 * i), line, {
						size = fontSize,
						class = "tg-label tgc-text",
						attrs = 'font-weight="500"',
					})
				)
			end
		end
	end
	for _, t in labels do
		table.insert(out, t)
	end
	return Kit.finish(out, "svg_pie")
end

return M
