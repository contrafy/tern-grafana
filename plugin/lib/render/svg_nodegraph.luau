--!strict
-- A node graph as SVG (public/app/plugins/panel/nodeGraph: Node.tsx,
-- Edge.tsx, EdgeArrowMarker.tsx, layout.ts):
-- - nodes are 40 px radius circles with their main and secondary stat in
--   the middle and the title and subtitle under them; the rim is arc
--   sections (a field's share of the circle, in its color) when the node
--   has arc fields with colors, else the plain rim; highlighted nodes get
--   the highlight rim;
-- - edges are lines from rim to rim with an arrow head at the target,
--   thickness and dash from their fields;
-- - the layout fills the panel: the graph is scaled down (never up) to
--   fit and centered, as Grafana's zoom to fit does.
-- Theme colors are classes (tgn-*: panels2.css); arc colors are Grafana's
-- fixed colors as literal attributes; no <title>.

local Kit = require("./svg_kit")

local M = {}

local fmt = string.format

M.RADIUS = 40

export type Arc = { value: number, color: string }

export type Node = {
	id: string,
	x: number,
	y: number,
	radius: number?,
	main: string?,
	secondary: string?,
	title: string?,
	subtitle: string?,
	arcs: { Arc },
	highlighted: boolean?,
}

export type Edge = {
	source: string,
	target: string,
	thickness: number?,
	dash: string?,
	highlighted: boolean?,
}

export type Options = {
	width: number,
	height: number,
	nodes: { Node },
	edges: { Edge },
}

local function arcPath(cx: number, cy: number, r: number, a0: number, a1: number): string
	-- Angles in turns from 12 o'clock, clockwise.
	local function at(a: number): (number, number)
		local rad = a * 2 * math.pi - math.pi / 2
		return cx + r * math.cos(rad), cy + r * math.sin(rad)
	end
	local x0, y0 = at(a0)
	local x1, y1 = at(a1)
	local large = if a1 - a0 > 0.5 then 1 else 0
	return fmt("M%.1f %.1fA%.1f %.1f 0 %d 1 %.1f %.1f", x0, y0, r, r, large, x1, y1)
end

function M.render(opts: Options): string
	local W, H = math.max(80, opts.width), math.max(60, opts.height)
	local out: { string } = { Kit.open(W, H) }
	if #opts.nodes == 0 then
		Kit.noData(out, W / 2, H / 2)
		return Kit.finish(out, "nodegraph")
	end
	-- Bounding box with the labels under the nodes.
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	local byId: { [string]: Node } = {}
	for _, n in opts.nodes do
		local r = n.radius or M.RADIUS
		byId[n.id] = n
		x0 = math.min(x0, n.x - r - 30)
		x1 = math.max(x1, n.x + r + 30)
		y0 = math.min(y0, n.y - r - 4)
		y1 = math.max(y1, n.y + r + 36)
	end
	local scale = math.min(1, (W - 16) / (x1 - x0), (H - 16) / (y1 - y0))
	local tx = W / 2 - (x0 + x1) / 2 * scale
	local ty = H / 2 - (y0 + y1) / 2 * scale
	table.insert(out, fmt('<g transform="translate(%.1f %.1f) scale(%.4f)">', tx, ty, scale))
	-- Edges under nodes.
	for _, e in opts.edges do
		local s, t = byId[e.source], byId[e.target]
		if s == nil or t == nil or s == t then
			continue
		end
		local dx, dy = t.x - s.x, t.y - s.y
		local len = math.sqrt(dx * dx + dy * dy)
		if len <= 0 then
			continue
		end
		local ux, uy = dx / len, dy / len
		local rs, rt = (s.radius or M.RADIUS) + 2, (t.radius or M.RADIUS) + 2
		local width = e.thickness or 1
		local head = 8 + width
		local ax, ay = s.x + ux * rs, s.y + uy * rs
		local bx, by = t.x - ux * rt, t.y - uy * rt
		local lx, ly = bx - ux * head, by - uy * head
		local cls = if e.highlighted then "tgn-edge tgn-hi" else "tgn-edge"
		table.insert(
			out,
			fmt(
				'<path class="%s" fill="none" stroke-width="%.1f"%s d="M%.1f %.1fL%.1f %.1f"/>',
				cls,
				width,
				if e.dash then fmt(' stroke-dasharray="%s"', Kit.escape(e.dash :: string)) else "",
				ax,
				ay,
				lx,
				ly
			)
		)
		local px, py = -uy * head * 0.45, ux * head * 0.45
		table.insert(
			out,
			fmt(
				'<path class="%s" d="M%.1f %.1fL%.1f %.1fL%.1f %.1fZ"/>',
				if e.highlighted then "tgn-arrow tgn-hi" else "tgn-arrow",
				bx,
				by,
				lx + px,
				ly + py,
				lx - px,
				ly - py
			)
		)
	end
	for _, n in opts.nodes do
		local r = n.radius or M.RADIUS
		table.insert(out, fmt('<circle class="tgn-node" cx="%.1f" cy="%.1f" r="%.1f"/>', n.x, n.y, r))
		local total = 0
		for _, a in n.arcs do
			total += math.max(0, a.value)
		end
		if total > 0 then
			local at = 0
			for _, a in n.arcs do
				local frac = math.max(0, a.value) / math.max(total, 1)
				if frac >= 1 then
					table.insert(
						out,
						fmt(
							'<circle cx="%.1f" cy="%.1f" r="%.1f" fill="none" stroke="%s" stroke-width="2"/>',
							n.x,
							n.y,
							r,
							a.color
						)
					)
				elseif frac > 0 then
					table.insert(
						out,
						fmt(
							'<path fill="none" stroke="%s" stroke-width="2" d="%s"/>',
							a.color,
							arcPath(n.x, n.y, r, at, at + frac)
						)
					)
				end
				at += frac
			end
		else
			table.insert(
				out,
				fmt(
					'<circle class="%s" cx="%.1f" cy="%.1f" r="%.1f" fill="none" stroke-width="2"/>',
					if n.highlighted then "tgn-ring tgn-hi" else "tgn-ring",
					n.x,
					n.y,
					r
				)
			)
		end
		local lines: { string } = {}
		if n.main and n.main ~= "" then
			table.insert(lines, n.main :: string)
		end
		if n.secondary and n.secondary ~= "" then
			table.insert(lines, n.secondary :: string)
		end
		for i, l in lines do
			local y = n.y + (i - (#lines + 1) / 2) * 15
			table.insert(
				out,
				Kit.text(n.x, y, l, { size = 10, class = "tgc-text", attrs = 'dominant-baseline="central"' })
			)
		end
		local ly = n.y + r + 15
		if n.title and n.title ~= "" then
			table.insert(out, Kit.text(n.x, ly, n.title :: string, { size = 10, class = "tgc-text" }))
			ly += 15
		end
		if n.subtitle and n.subtitle ~= "" then
			table.insert(out, Kit.text(n.x, ly, n.subtitle :: string, { size = 10 }))
		end
	end
	table.insert(out, "</g>")
	return Kit.finish(out, "nodegraph")
end

return M
