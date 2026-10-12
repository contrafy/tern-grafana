--!strict
-- Canvas panel elements as SVG (public/app/features/canvas/elements:
-- rectangle, ellipse, triangle, text, metric-value; connections): boxes
-- placed in panel pixels with their background, border (width, color,
-- radius) and rotation, a text line aligned left/center/right and
-- top/middle/bottom inside the box, and straight connection lines with
-- an arrow head. Colors are the dashboard's fixed colors (or a field's
-- display color) as literal attributes, as Grafana paints them; no
-- <title>.

local Kit = require("./svg_kit")

local M = {}

local fmt = string.format

export type Shape = {
	kind: "rect" | "ellipse" | "triangle" | "none",
	x: number,
	y: number,
	w: number,
	h: number,
	rotation: number?,
	fill: string?,
	stroke: string?,
	stroke_width: number?,
	radius: number?,
	text: string?,
	text_color: string?,
	text_size: number?,
	align: string?,
	valign: string?,
}

export type Line = {
	x1: number,
	y1: number,
	x2: number,
	y2: number,
	color: string,
	width: number,
	arrow: boolean,
}

export type Options = {
	width: number,
	height: number,
	shapes: { Shape },
	lines: { Line },
}

local function paint(color: string?): string
	if color == nil or color == "" or color == "transparent" then
		return "none"
	end
	local lower = string.lower(color :: string)
	if string.match(lower, "^rgba%(%s*%d+%s*,%s*%d+%s*,%s*%d+%s*,%s*0%s*%)$") then
		return "none"
	end
	return Kit.escape(color :: string)
end

function M.render(opts: Options): string
	local W, H = math.max(20, opts.width), math.max(20, opts.height)
	local out: { string } = { Kit.open(W, H) }
	for _, s in opts.shapes do
		local rot = s.rotation or 0
		local cx, cy = s.x + s.w / 2, s.y + s.h / 2
		local g = rot ~= 0
		if g then
			table.insert(out, fmt('<g transform="rotate(%.1f %.1f %.1f)">', rot, cx, cy))
		end
		local sw = s.stroke_width or 0
		local stroke = if sw > 0 then paint(s.stroke) else "none"
		local strokeAttr = if stroke ~= "none" then fmt(' stroke="%s" stroke-width="%.1f"', stroke, sw) else ""
		local fill = paint(s.fill)
		if s.kind == "rect" then
			local r = s.radius or 0
			-- CSS borders sit inside the box.
			table.insert(
				out,
				fmt(
					'<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f"%s fill="%s"%s/>',
					s.x + sw / 2,
					s.y + sw / 2,
					math.max(0, s.w - sw),
					math.max(0, s.h - sw),
					if r > 0 then fmt(' rx="%.1f"', r) else "",
					fill,
					strokeAttr
				)
			)
		elseif s.kind == "ellipse" then
			table.insert(
				out,
				fmt(
					'<ellipse cx="%.1f" cy="%.1f" rx="%.1f" ry="%.1f" fill="%s"%s/>',
					cx,
					cy,
					math.max(0, (s.w - sw) / 2),
					math.max(0, (s.h - sw) / 2),
					fill,
					strokeAttr
				)
			)
		elseif s.kind == "triangle" then
			table.insert(
				out,
				fmt(
					'<path d="M%.1f %.1fL%.1f %.1fL%.1f %.1fZ" fill="%s"%s/>',
					cx,
					s.y,
					s.x + s.w,
					s.y + s.h,
					s.x,
					s.y + s.h,
					fill,
					strokeAttr
				)
			)
		end
		if s.text and s.text ~= "" then
			local size = s.text_size or 14
			local align = s.align or "center"
			local valign = s.valign or "middle"
			local tx = if align == "left" then s.x + sw + 2 elseif align == "right" then s.x + s.w - sw - 2 else cx
			local ty = if valign == "top"
				then s.y + sw + size * 0.6
				elseif valign == "bottom" then s.y + s.h - sw - size * 0.4
				else cy
			table.insert(
				out,
				Kit.text(tx, ty, s.text :: string, {
					anchor = if align == "left" then "start" elseif align == "right" then "end" else "middle",
					size = size,
					class = "tgv-text",
					attrs = fmt('dominant-baseline="central" fill="%s"', paint(s.text_color or "#000000")),
				})
			)
		end
		if g then
			table.insert(out, "</g>")
		end
	end
	for _, l in opts.lines do
		local dx, dy = l.x2 - l.x1, l.y2 - l.y1
		local len = math.sqrt(dx * dx + dy * dy)
		if len <= 0 then
			continue
		end
		local ux, uy = dx / len, dy / len
		local head = if l.arrow then 6 + l.width * 2 else 0
		local ex, ey = l.x2 - ux * head, l.y2 - uy * head
		local color = paint(l.color)
		table.insert(
			out,
			fmt(
				'<path d="M%.1f %.1fL%.1f %.1f" fill="none" stroke="%s" stroke-width="%.1f"/>',
				l.x1,
				l.y1,
				ex,
				ey,
				color,
				l.width
			)
		)
		if l.arrow then
			local px, py = -uy * head * 0.5, ux * head * 0.5
			table.insert(
				out,
				fmt(
					'<path d="M%.1f %.1fL%.1f %.1fL%.1f %.1fZ" fill="%s"/>',
					l.x2,
					l.y2,
					ex + px,
					ey + py,
					ex - px,
					ey - py,
					color
				)
			)
		end
	end
	return Kit.finish(out, "canvas")
end

return M
