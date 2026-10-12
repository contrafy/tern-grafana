--!strict
-- Dense heatmap cells as SVG (public/app/plugins/panel/heatmap/utils.ts
-- heatmapPathsDense, prepConfig axes; ColorScale legend):
-- - a column per x bucket and a row per y bucket, both given as value
--   edges; a cell is the bucket minus `gap` px on its low-x and high-y
--   sides (Grafana rounds cells to whole pixels), filled with its palette
--   color, hidden cells left out;
-- - one path per palette color; when the cells would pass the byte budget,
--   neighbors of one color in a row merge (the gaps between them go) and,
--   past that, columns fold by their highest color;
-- - the time (or value) axis under the plot, the y axis labels given by
--   the panel (ordinal bucket labels or value ticks), and the color scale
--   (the palette as a bar with the min and max values) under the axis.
-- Colors are Grafana's palette hex values as literal attributes (they are
-- fixed colors in Grafana too); no <title>, under the 256 KiB cap.

local Axis = require("./axis")
local Kit = require("./svg_kit")

local M = {}

local fmt = string.format

-- Bytes per cell rect in a path ("M123 45h6v7h-6z" and change).
local CELL_BYTES = 22

export type Tick = { v: number, label: string }

export type Options = {
	width: number,
	height: number,
	-- x range shown, in x units (epoch ms when x_time).
	x_min: number,
	x_max: number,
	x_time: boolean,
	x_unit: string?,
	offset_min: number?,
	-- Bucket edges: cols[c] = {lo, hi} in x units, rows[r] = {lo, hi} in y
	-- scale units.
	cols: { { number } },
	rows: { { number } },
	y_min: number,
	y_max: number,
	y_ticks: { Tick },
	y_side: ("left" | "right" | "hidden")?,
	y_reverse: boolean?,
	-- fills[(c - 1) * #rows + r]: palette index (1-based), 0 for hidden.
	fills: { number },
	palette: { string },
	gap: number?,
	-- Color scale under the plot: the bar with min and max labels.
	scale: { min: string, max: string }?,
}

export type Result = { svg: string, plot: { left: number, right: number, top: number, bottom: number } }

function M.render(opts: Options): Result
	local W, H = math.max(80, opts.width), math.max(60, opts.height)
	local side = opts.y_side or "left"
	local labelW = 0
	for _, t in opts.y_ticks do
		labelW = math.max(labelW, Kit.textWidth(t.label))
	end
	local axisW = if side == "hidden" then 4 else math.ceil(labelW + 12)
	local left = if side == "left" then axisW else 4
	local right = if side == "right" then W - axisW else W - 8
	local top = 8
	local scaleH = if opts.scale then 30 else 0
	local bottom = H - 24 - scaleH
	local xspan = opts.x_max - opts.x_min
	if xspan <= 0 then
		xspan = 1
	end
	local yspan = opts.y_max - opts.y_min
	if yspan <= 0 then
		yspan = 1
	end
	local function xOf(x: number): number
		return left + (x - opts.x_min) / xspan * (right - left)
	end
	local function yOf(y: number): number
		local f = (y - opts.y_min) / yspan
		if opts.y_reverse then
			f = 1 - f
		end
		return bottom - f * (bottom - top)
	end
	local out: { string } = { Kit.open(W, H) }

	-- x ticks and grid.
	local xTicks: { number }, xLabels: { string }
	if opts.x_time then
		local tt = Axis.timeTicks(opts.x_min, opts.x_max, right - left, opts.offset_min)
		xTicks, xLabels = tt.ticks, tt.labels
	else
		local s, labels = Kit.hScale(opts.x_min, opts.x_max, right - left, opts.x_min, opts.x_max, opts.x_unit, nil)
		xTicks, xLabels = s.ticks, labels
	end
	local grid: { string } = {}
	for _, x in xTicks do
		if x >= opts.x_min and x <= opts.x_max then
			table.insert(grid, fmt("M%.1f %.1fV%.1f", xOf(x), top, bottom))
		end
	end
	for _, t in opts.y_ticks do
		if t.v >= opts.y_min and t.v <= opts.y_max then
			table.insert(grid, fmt("M%.1f %.1fH%.1f", left, yOf(t.v), right))
		end
	end
	if #grid > 0 then
		table.insert(out, '<path class="tg-grid" fill="none" stroke-width="1" d="' .. table.concat(grid) .. '"/>')
	end

	-- Cells.
	local nrows, ncols = #opts.rows, #opts.cols
	local gap = math.floor((opts.gap or 1) + 0.5)
	local colPx: { { number } } = table.create(ncols)
	for c, e in opts.cols do
		local a = math.floor(xOf(e[1]) + 0.5)
		local b = math.floor(xOf(e[2]) + 0.5)
		if a > b then
			a, b = b, a
		end
		colPx[c] = { a, b }
	end
	local rowPx: { { number } } = table.create(nrows)
	for r, e in opts.rows do
		local a = math.floor(yOf(e[2]) + 0.5)
		local b = math.floor(yOf(e[1]) + 0.5)
		if a > b then
			a, b = b, a
		end
		rowPx[r] = { a, b }
	end
	local shown = 0
	for _, f in opts.fills do
		if f > 0 then
			shown += 1
		end
	end
	local budget = Kit.TARGET - 8192
	local merge = shown * CELL_BYTES > budget
	-- Past what merging can save, fold `fold` columns into one.
	local fold = 1
	if merge then
		local runs = 0
		for r = 1, nrows do
			local prev = 0
			for c = 1, ncols do
				local f = opts.fills[(c - 1) * nrows + r]
				if f > 0 and f ~= prev then
					runs += 1
				end
				prev = f
			end
		end
		if runs * CELL_BYTES > budget then
			fold = math.ceil(runs * CELL_BYTES / budget)
		end
	end
	local paths: { [number]: { string } } = {}
	local function put(f: number, x0: number, x1: number, r: number)
		local rp = rowPx[r]
		local w = math.max(1, x1 - x0)
		local h = math.max(1, rp[2] - rp[1] - gap)
		local cx0, cx1 = math.max(x0, left), math.min(x0 + w, right)
		if cx1 <= cx0 then
			return
		end
		local p = paths[f]
		if p == nil then
			p = {}
			paths[f] = p
		end
		table.insert(p, fmt("M%d %dh%dv%dh%dz", cx0, rp[1], cx1 - cx0, h, cx0 - cx1))
	end
	for r = 1, nrows do
		local c = 1
		while c <= ncols do
			local last = math.min(ncols, c + fold - 1)
			local f = 0
			for k = c, last do
				f = math.max(f, opts.fills[(k - 1) * nrows + r])
			end
			local x0 = colPx[c][1] + gap
			local x1 = colPx[last][2]
			local nextC = last + 1
			if merge and f > 0 then
				while nextC <= ncols do
					local stop = math.min(ncols, nextC + fold - 1)
					local g = 0
					for k = nextC, stop do
						g = math.max(g, opts.fills[(k - 1) * nrows + r])
					end
					if g ~= f then
						break
					end
					x1 = colPx[stop][2]
					nextC = stop + 1
				end
			end
			if f > 0 then
				put(f, x0, x1, r)
			end
			c = nextC
		end
	end
	for f = 1, #opts.palette do
		local p = paths[f]
		if p then
			table.insert(out, fmt('<path fill="%s" d="%s"/>', opts.palette[f], table.concat(p)))
		end
	end

	-- Axes labels.
	table.insert(
		out,
		fmt('<path class="tg-axis" fill="none" stroke-width="1" d="M%.1f %.1fH%.1f"/>', left, bottom, right)
	)
	for i, x in xTicks do
		if x >= opts.x_min and x <= opts.x_max then
			table.insert(out, Kit.text(xOf(x), bottom + 16, xLabels[i]))
		end
	end
	if side ~= "hidden" then
		for _, t in opts.y_ticks do
			if t.v >= opts.y_min and t.v <= opts.y_max then
				local tx = if side == "left" then left - 6 else right + 6
				table.insert(
					out,
					Kit.text(tx, yOf(t.v), t.label, {
						anchor = if side == "left" then "end" else "start",
						attrs = 'dominant-baseline="central"',
					})
				)
			end
		end
	end

	-- Color scale.
	local sc = opts.scale
	if sc then
		local barW = math.min(300, math.max(60, (W - 16) * 0.3))
		local y = bottom + 30
		local n = #opts.palette
		local step = barW / n
		local bars: { string } = {}
		for i, color in opts.palette do
			table.insert(
				bars,
				fmt(
					'<rect x="%.1f" y="%d" width="%.2f" height="6" fill="%s"/>',
					8 + (i - 1) * step,
					y,
					step + 0.3,
					color
				)
			)
		end
		table.insert(out, table.concat(bars))
		table.insert(out, Kit.text(8, y + 18, sc.min, { anchor = "start", size = 10 }))
		table.insert(out, Kit.text(8 + barW, y + 18, sc.max, { anchor = "end", size = 10 }))
	end
	return { svg = Kit.finish(out, "heatmap"), plot = { left = left, right = right, top = top, bottom = bottom } }
end

return M
