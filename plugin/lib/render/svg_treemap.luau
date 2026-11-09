--!strict
-- Treemap SVGs as marcusolsson-treemap-panel 2.1.1 draws them
-- (TreemapPanel.tsx, TreemapTile.tsx): one rounded rect per tile in the
-- layout's order, a leaf filled with its color class and a group with the
-- text color at 5% opacity, and the tile's label 10 px in and 20 px down
-- (Grafana's typography base, 14 px, weight 500) in the panel background
-- color on a leaf and the text color on a group. Tiles of no area draw
-- nothing (the browser draws nothing for them either).

local Kit = require("./svg_kit")

local M = {}

export type Tile = {
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	-- Color classes of a leaf (tg-s3, "tgp-fx tgp-info"); nil for a group.
	class: string?,
	-- Drawn label, nil when it does not fit.
	label: string?,
}

-- theme.typography.size.base, theme.border.radius.sm.
M.FONT = 14
M.RADIUS = 6
M.LABEL_X = 10
M.LABEL_Y = 20

local fmt = string.format

function M.render(tiles: { Tile }, width: number, height: number): string
	local out: { string } = { Kit.open(width, height) }
	for _, t in tiles do
		local w, h = t.x1 - t.x0, t.y1 - t.y0
		if w <= 0 or h <= 0 then
			continue
		end
		local class = if t.class then t.class .. " tg-bar" else "tgp-tm-group"
		table.insert(
			out,
			fmt(
				'<rect class="%s" x="%g" y="%g" width="%g" height="%g" rx="%d" ry="%d"/>',
				class,
				t.x0,
				t.y0,
				w,
				h,
				M.RADIUS,
				M.RADIUS
			)
		)
		local label = t.label
		if label then
			table.insert(
				out,
				Kit.text(t.x0 + M.LABEL_X, t.y0 + M.LABEL_Y, label, {
					anchor = "start",
					size = M.FONT,
					class = if t.class then "tg-label tgp-tm-on-leaf" else "tg-label tgc-text",
					attrs = 'font-weight="500"',
				})
			)
		end
	end
	return Kit.finish(out, "svg_treemap")
end

return M
