--!strict
-- State timeline and status history lanes as SVG
-- (public/app/core/components/TimelineChart/timeline.ts getConfig):
-- - one lane per series, lanes spread over the plot by uPlot's distribute
--   (space-between) with `row_height` of the height for the lanes;
-- - "changes" mode: a box from each drawn value to the next value (the
--   next one that differs when merging), the last one to the plot edge;
-- - "samples" mode: one box per value, `col_width` of the distance between
--   the first two samples, centered on the sample; the x range grows by
--   half a column at the ends when the data reaches them;
-- - values print inside their boxes (showValue auto: only boxes wide
--   enough for two characters; text cut to what fits), aligned left,
--   center or right in changes mode and centered in samples mode;
-- - the time axis under the plot (samples mode: ticks on samples, every
--   ceil(tick increment / sample increment)-th one).
-- Box colors are classes (fill-opacity from fillOpacity, the outline at
-- full color with lineWidth); no <title>, under the 256 KiB cap.

local Axis = require("./axis")
local Kit = require("./svg_kit")

local M = {}

local fmt = string.format

-- pxPerChar for 12 px text: the average glyph width rounded up plus 2.5
-- (timeline.ts init); Inter at 12 px averages under 6 px, and Grafana's
-- render fits "dow" in a 26 px column.
M.PX_PER_CHAR = 8.5
M.BOX_BUDGET = 6000
local TEXT_PADDING = 2
local Y_GAP = 16

export type Box = {
	-- Time (ms) the value starts at.
	t: number,
	-- Color classes of the box; "" for a null, which draws nothing and
	-- ends the state before it.
	class: string,
	-- Text to print (nil: nothing).
	text: string?,
	-- Merge key: equal keys extend one box when merging.
	key: string,
}

export type Lane = {
	label: string,
	boxes: { Box },
}

export type Options = {
	width: number,
	height: number,
	from_ms: number,
	to_ms: number,
	mode: "changes" | "samples",
	lanes: { Lane },
	row_height: number?,
	col_width: number?,
	merge: boolean?,
	show_value: ("auto" | "always" | "never")?,
	align_value: ("left" | "center" | "right")?,
	fill_opacity: number?,
	line_width: number?,
	offset_min: number?,
	-- Lane label axis hidden (axisPlacement hidden).
	hide_y: boolean?,
	-- Time axis hidden.
	hide_x: boolean?,
}

-- uPlot distribute with SPACE_BETWEEN: lane i's offset and size (0..1).
function M.lane(count: number, factor: number, i: number): (number, number)
	local space = 1 - factor
	local gap = if count > 1 then space / (count - 1) else 0
	local wid = math.floor(factor / count * 1e6 + 0.5) / 1e6
	return (i - 1) * (wid + gap), wid
end

-- The x range (samples mode pads half a column where the data reaches the
-- range ends).
function M.xRange(opts: Options): (number, number)
	local lo, hi = opts.from_ms, opts.to_ms
	if opts.mode ~= "samples" then
		return lo, hi
	end
	local first: { Box }? = nil
	for _, l in opts.lanes do
		if #l.boxes >= 2 then
			first = l.boxes
			break
		end
	end
	if first == nil then
		return lo, hi
	end
	local b = first :: { Box }
	local pad = (b[2].t - b[1].t) / 2
	if lo <= b[1].t then
		lo = b[1].t - pad
	end
	if hi >= b[#b].t then
		hi = b[#b].t + pad
	end
	return lo, hi
end

local function cut(s: string, n: number): string
	local len = utf8.len(s) or #s
	if len <= n then
		return s
	end
	local stop = utf8.offset(s, n + 1)
	return string.sub(s, 1, (stop or (#s + 1)) - 1)
end

export type Result = { svg: string, plot: { left: number, right: number, top: number, bottom: number } }

function M.render(opts: Options): Result
	local W, H = math.max(80, opts.width), math.max(40, opts.height)
	local lanes = opts.lanes
	local n = #lanes
	local labelW = 0
	if not opts.hide_y then
		for _, l in lanes do
			labelW = math.max(labelW, Kit.textWidth(l.label))
		end
	end
	local left = if opts.hide_y then 0 else math.ceil(labelW + Y_GAP)
	local right = W - 4
	local top = 4
	local bottom = H - (if opts.hide_x then 4 else 24)
	local xlo, xhi = M.xRange(opts)
	local span = math.max(xhi - xlo, 1)
	local function xOf(t: number): number
		return left + (t - xlo) / span * (right - left)
	end
	local plotH = bottom - top
	local rowH = opts.row_height or 0.9
	local stroke = math.floor((opts.line_width or 0) + 0.5)
	local fill = (opts.fill_opacity or 70) / 100
	local show = opts.show_value or "auto"
	local align = opts.align_value or "left"
	-- Byte budget: past BOX_BUDGET boxes, neighbors of one color merge
	-- (their boundary is invisible without an outline) and values stay
	-- unprinted.
	local total = 0
	for _, l in lanes do
		total += #l.boxes
	end
	local coalesce = opts.mode ~= "samples" and total > M.BOX_BUDGET
	if coalesce then
		show = "never"
	end
	local out: { string } = { Kit.open(W, H) }

	-- Time axis (and its grid).
	local ticks: { number }, labels: { string } = {}, {}
	if not opts.hide_x then
		local tt = Axis.timeTicks(xlo, xhi, right - left, opts.offset_min)
		ticks, labels = tt.ticks, tt.labels
		if opts.mode == "samples" then
			local samples: { Box }? = nil
			for _, l in lanes do
				if #l.boxes >= 2 then
					samples = l.boxes
					break
				end
			end
			if samples then
				local s = samples :: { Box }
				local incr = s[2].t - s[1].t
				local skip = math.max(1, math.ceil(tt.incr / math.max(incr, 1)))
				local fmtStr = Axis.timeFormat(tt.incr, xhi - xlo)
				ticks, labels = {}, {}
				for i = 1, #s, skip do
					local v = s[i].t
					if v >= xlo and v <= xhi then
						table.insert(ticks, v)
						table.insert(labels, Axis.formatTime(v, fmtStr, opts.offset_min))
					end
				end
			end
		end
		local grid: { string } = {}
		for _, t in ticks do
			if t >= xlo and t <= xhi then
				table.insert(grid, fmt("M%.1f %.1fV%.1f", xOf(t), top, bottom))
			end
		end
		if #grid > 0 then
			table.insert(out, '<path class="tg-grid" fill="none" stroke-width="1" d="' .. table.concat(grid) .. '"/>')
		end
	end

	-- Boxes, one path per class (fills, then outlines).
	local fills: { [string]: { string } } = {}
	local strokes: { [string]: { string } } = {}
	local order: { string } = {}
	local texts: { string } = {}
	local function put(class: string, x: number, y: number, w: number, h: number)
		w = math.max(1, w)
		local f = fills[class]
		if f == nil then
			f = {}
			fills[class] = f
			strokes[class] = {}
			table.insert(order, class)
		end
		table.insert(f, fmt("M%d %dh%dv%dh%dz", x, y, w, h, -w))
		if stroke > 0 then
			table.insert(
				strokes[class],
				fmt("M%.1f %.1fh%.1fv%.1fh%.1fz", x + stroke / 2, y + stroke / 2, w - stroke, h - stroke, -(w - stroke))
			)
		end
	end
	local function label(text: string?, x: number, w: number, yMid: number, anchor: "start" | "middle" | "end")
		if text == nil or show == "never" then
			return
		end
		local shownW = if x < left then w - (left - x) else w
		local maxChars = math.floor(shownW / M.PX_PER_CHAR)
		if show == "auto" and maxChars < 2 then
			return
		end
		local tx: number
		if anchor == "start" then
			tx = math.max(x, left) + stroke + TEXT_PADDING
		elseif anchor == "end" then
			tx = x + w - stroke - TEXT_PADDING
		else
			tx = x + w / 2
		end
		local s = cut(text :: string, math.max(maxChars, 0))
		if s ~= "" then
			table.insert(
				texts,
				Kit.text(tx, yMid, s, { anchor = anchor, class = "tgc-text", attrs = 'dominant-baseline="central"' })
			)
		end
	end
	for li, lane in lanes do
		local off, dim = M.lane(n, rowH, li)
		local y0 = math.floor(top + off * plotH + 0.5)
		local h = math.floor(dim * plotH + 0.5)
		local yMid = math.floor(top + (off + dim / 2) * plotH + 0.5)
		local boxes = lane.boxes
		if not opts.hide_y then
			table.insert(
				out,
				Kit.text(left - 8, yMid, lane.label, { anchor = "end", attrs = 'dominant-baseline="central"' })
			)
		end
		if opts.mode == "samples" then
			if #boxes == 0 then
				continue
			end
			local colWid = if #boxes >= 2 then xOf(boxes[2].t) - xOf(boxes[1].t) else (right - left)
			local gapWid = colWid * (1 - (opts.col_width or 0.9))
			local barWid = math.floor(colWid - gapWid - stroke + 0.5)
			for _, b in boxes do
				local x = math.floor(xOf(b.t) - barWid / 2 + 0.5)
				-- Clip to the plot (uPlot clips the canvas to the plot box).
				local cx0, cx1 = math.max(x, left), math.min(x + barWid, right)
				if b.class == "" or cx1 <= cx0 then
					continue
				end
				put(b.class, cx0, y0, cx1 - cx0, h)
				label(b.text, x, barWid, yMid, "middle")
			end
		else
			local i = 1
			while i <= #boxes do
				local b = boxes[i]
				local nextI = i + 1
				if opts.merge or coalesce then
					while
						nextI <= #boxes
						and ((opts.merge and boxes[nextI].key == b.key) or (coalesce and boxes[nextI].class == b.class))
					do
						nextI += 1
					end
				end
				local x0 = math.floor(xOf(b.t) + 0.5)
				local x1 = if nextI > #boxes then right + stroke else math.floor(xOf(boxes[nextI].t) + 0.5)
				-- Clip to the plot.
				local cx0, cx1 = math.max(x0, left), math.min(x1, right + stroke)
				if b.class ~= "" and cx1 > cx0 then
					put(b.class, cx0, y0, cx1 - cx0, h)
					label(
						b.text,
						x0,
						x1 - x0,
						yMid,
						if align == "center" then "middle" elseif align == "right" then "end" else "start"
					)
				end
				i = nextI
			end
		end
	end
	for _, class in order do
		table.insert(
			out,
			fmt('<path class="%s tg-bar" fill-opacity="%.2f" d="%s"/>', class, fill, table.concat(fills[class]))
		)
		if stroke > 0 then
			table.insert(
				out,
				fmt('<path class="%s tg-line" stroke-width="%d" d="%s"/>', class, stroke, table.concat(strokes[class]))
			)
		end
	end
	for _, t in texts do
		table.insert(out, t)
	end
	if not opts.hide_x then
		for i, t in ticks do
			if t >= xlo and t <= xhi then
				table.insert(out, Kit.text(xOf(t), bottom + 16, labels[i]))
			end
		end
	end
	return { svg = Kit.finish(out, "timeline"), plot = { left = left, right = right, top = top, bottom = bottom } }
end

return M
