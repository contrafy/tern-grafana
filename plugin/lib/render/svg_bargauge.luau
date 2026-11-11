--!strict
-- Bar gauges as an SVG document, for an `image` node. Layout ports
-- packages/grafana-ui/src/components/BarGauge/BarGauge.tsx and the panel's
-- VizRepeater (public/app/plugins/panel/bargauge/BarGaugePanel.tsx):
-- - one bar per value, stacked (horizontal) or side by side (vertical),
--   itemSpacing 2 px for lcd and 10 px otherwise, a horizontal bar's height
--   clamped to minVizHeight..maxVizHeight (more overflows downwards);
-- - calculateTitleDimensions: the name above (bars over 40 px, titleSize
--   or 45% of the bar's height up to 50 px), left of the bar, or below a
--   vertical bar; calculateBarAndValueDimensions: the value column at
--   least 20% of the width up to 150 px, wider for the widest value;
-- - getValueStyles: the value right-aligned (centered above a vertical
--   bar) at calculateFontSize of the widest value, in the value's color or
--   the text color (valueMode text);
-- - displayMode basic (the value's color at 35% with a 2 px edge in full),
--   gradient (the thresholds' colors along the bar, getBarGradient) and
--   lcd (12 px cells, lit up to the value in each cell's own color, unlit
--   at 18%); showUnfilled draws the empty track.
-- Colors are classes (lib/render/ts_gradient tg-gc<n> or tone pairs) with
-- shape roles tg-bar / tg-line; gradients are <linearGradient>s whose stops
-- carry the stop classes.

local Kit = require("./svg_kit")
local Stat = require("../panels/stat")

local M = {}

export type Stop = { at: number, class: string }

export type Bar = {
	title: string?,
	prefix: string,
	text: string,
	suffix: string,
	-- The value's fraction of min..max, 0..1.
	fill: number,
	-- The value's color class.
	class: string,
	-- Gradient mode: color stops along the full bar length (fractions).
	gradient: { Stop }?,
	-- Lcd mode: the color class of a cell by its start fraction.
	cell_class: ((at: number) -> string)?,
}

export type Mode = "basic" | "gradient" | "lcd"

export type Options = {
	width: number,
	height: number,
	vertical: boolean,
	mode: Mode,
	-- valueMode: color, text (text color) or hidden.
	value_mode: string,
	show_unfilled: boolean,
	-- namePlacement auto|top|left|hidden.
	name_placement: string,
	title_size: number?,
	value_size: number?,
	min_viz_height: number,
	max_viz_height: number,
	min_viz_width: number,
}

M.MIN_VALUE_HEIGHT = 18
M.MAX_VALUE_HEIGHT = 50
M.MAX_VALUE_WIDTH = 150
M.TITLE_LINE_HEIGHT = 1.5
M.VALUE_LEFT_PADDING = 10
M.LCD_CELL = 12
M.RADIUS = 2

local fmt = string.format

-- measureText: the advance widths of the SVG's font (.tgg, Tern's Geist),
-- which stand in for Grafana's Inter.
local function measure(s: string, size: number): number
	return Stat.textEm(s) * size
end

-- calculateFontSize (lineHeight 1 for values).
local function fontSize(s: string, width: number, height: number, lineHeight: number): number
	local byWidth = width / (measure(s, 14) + 2) * 14
	return math.max(1, math.min(height / lineHeight, byWidth))
end

function M.itemSpacing(mode: Mode): number
	return if mode == "lcd" then 2 else 10
end

type TitleDim = { size: number, placement: string, width: number, height: number }

local function titleDimensions(title: string?, w: number, h: number, o: Options): TitleDim
	if title == nil or title == "" then
		return { size = 0, width = 0, height = 0, placement = "above" }
	end
	if o.name_placement == "hidden" then
		return { size = 0, width = 0, height = 0, placement = "hidden" }
	end
	if o.vertical then
		local size = o.title_size or 14
		return { size = size, width = w, height = size * M.TITLE_LINE_HEIGHT, placement = "below" }
	end
	if (h > 40 and o.name_placement == "auto") or o.name_placement == "top" then
		if o.title_size then
			return {
				size = o.title_size :: number,
				width = 0,
				height = (o.title_size :: number) * M.TITLE_LINE_HEIGHT,
				placement = "above",
			}
		end
		local th = math.max(math.min(h * 0.45, M.MAX_VALUE_HEIGHT), 17)
		return { size = th / M.TITLE_LINE_HEIGHT, width = 0, height = th, placement = "above" }
	end
	local th = math.max(h * 0.6, M.MIN_VALUE_HEIGHT)
	local size = th / M.TITLE_LINE_HEIGHT
	return {
		size = o.title_size or size,
		width = math.min(measure(title :: string, size) + 15, w * 0.4),
		height = 0,
		placement = "left",
	}
end

local function joined(b: Bar): string
	return b.prefix .. b.text .. b.suffix
end

-- `s` cut with an ellipsis to fit `width` px at `size`.
local function fit(s: string, size: number, width: number): string
	if measure(s, size) <= width or utf8.len(s) == nil then
		return s
	end
	local budget = width - measure("…", size)
	local used = 0
	for pos, c in utf8.codes(s) do
		used += measure(utf8.char(c), size)
		if used > budget then
			return if pos == 1 then "" else string.sub(s, 1, pos - 1) .. "…"
		end
	end
	return s
end

-- The SVG and its size: the bars laid out over width x height (taller when
-- they overflow).
function M.render(bars: { Bar }, o: Options): (string, number, number)
	local n = math.max(#bars, 1)
	local W, H = math.max(o.width, 20), math.max(o.height, 20)
	local spacing = M.itemSpacing(o.mode)
	local itemW: number, itemH: number
	if o.vertical then
		itemW = math.max((W - spacing * (n - 1)) / n, o.min_viz_width)
		itemH = H
	else
		itemW = W
		itemH = math.min(math.max((H - spacing * (n - 1)) / n, o.min_viz_height), o.max_viz_height)
	end
	local totalW = if o.vertical then itemW * n + spacing * (n - 1) else W
	local totalH = if o.vertical then H else itemH * n + spacing * (n - 1)
	local overflow = not o.vertical and totalH > H + 0.5

	-- getDisplayValueAlignmentFactors: the longest title and value size
	-- every bar; the title by its drawn width, so no name is wider than
	-- the column it sets.
	local alignTitle: string? = nil
	local alignValue = ""
	for _, b in bars do
		if b.title and (alignTitle == nil or Stat.textEm(b.title :: string) > Stat.textEm(alignTitle :: string)) then
			alignTitle = b.title
		end
		if #joined(b) > #alignValue then
			alignValue = joined(b)
		end
	end
	if #bars == 1 then
		alignTitle, alignValue = bars[1].title, joined(bars[1])
	end

	local out: { string } = {
		fmt(
			'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" class="tgg">',
			math.ceil(totalW),
			math.ceil(totalH),
			math.ceil(totalW),
			math.ceil(totalH)
		),
	}
	local defs: { string } = {}
	local hidden = o.value_mode == "hidden"

	local function rect(class: string, x: number, y: number, w: number, h: number, opacity: number?)
		if w <= 0 or h <= 0 then
			return
		end
		table.insert(
			out,
			fmt(
				'<rect class="%s tg-bar" x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%d"%s/>',
				class,
				x,
				y,
				w,
				h,
				M.RADIUS,
				if opacity then fmt(' fill-opacity="%.2f"', opacity) else ""
			)
		)
	end
	local function text(class: string, x: number, y: number, s: string, size: number, anchor: string)
		table.insert(
			out,
			fmt(
				'<text class="%s" x="%.1f" y="%.1f" font-size="%.1f" text-anchor="%s" dominant-baseline="central">%s</text>',
				class,
				x,
				y,
				size,
				anchor,
				Kit.escape(s)
			)
		)
	end

	for i, b in bars do
		local x0 = if o.vertical then (i - 1) * (itemW + spacing) else 0
		local y0 = if o.vertical then 0 else (i - 1) * (itemH + spacing)
		local w, h = itemW, itemH
		local title = titleDimensions(if b.title then alignTitle else nil, w, h, o)
		local valueStr = joined(b)

		-- calculateBarAndValueDimensions.
		local measureSize = o.value_size or math.max(title.size, 12)
		local realValueWidth = measure(alignValue, measureSize) + M.VALUE_LEFT_PADDING * 2
		local valueW: number, valueH: number, barMaxW: number, barMaxH: number
		if o.vertical then
			valueH = if o.value_size
				then o.value_size :: number
				else math.min(math.max(h * 0.1, M.MIN_VALUE_HEIGHT), M.MAX_VALUE_HEIGHT)
			valueW = w
			if hidden then
				valueH, valueW = 0, 0
			end
			barMaxH = h - (title.height + valueH)
			barMaxW = w
		else
			if hidden then
				valueH, valueW = 0, 0
			else
				valueH = h - title.height
				valueW = math.max(math.min(w * 0.2, M.MAX_VALUE_WIDTH), realValueWidth)
			end
			barMaxH = h - title.height
			barMaxW = w - valueW - title.width
		end
		barMaxW, barMaxH = math.max(barMaxW, 1), math.max(barMaxH, 1)

		-- The name.
		if title.placement ~= "hidden" and title.size > 0 and b.title then
			local name = b.title :: string
			if title.placement == "above" then
				text("tgg-text", x0, y0 + title.height / 2, fit(name, title.size, w), title.size, "start")
			elseif title.placement == "below" then
				text("tgg-text", x0 + w / 2, y0 + h - title.height / 2, fit(name, title.size, w), title.size, "middle")
			else
				text(
					"tgg-text",
					x0 + title.width - 10,
					y0 + h / 2,
					fit(name, title.size, title.width - 10),
					title.size,
					"end"
				)
			end
		end

		-- The bar area: right of a left name, below a name above, below the
		-- value of a vertical bar.
		local bx = x0 + (if title.placement == "left" then title.width else 0)
		local by = y0 + (if o.vertical then valueH elseif title.placement == "above" then title.height else 0)
		local fill = math.clamp(b.fill, 0, 1)
		local valueClass = if o.value_mode == "text" then "tgg-text" else b.class .. " tg-bar"
		-- The horizontal value column's right edge: after the lcd cells, or
		-- the bar's end.
		local valueRight = x0 + w

		if o.mode == "lcd" then
			local maxSize = if o.vertical then barMaxH else barMaxW
			local count = math.max(1, math.floor(maxSize / M.LCD_CELL))
			local cell = math.max(1, math.floor((maxSize - spacing * count) / count))
			for c = 0, count - 1 do
				local at = c / count
				local class = if b.cell_class then (b.cell_class :: (number) -> string)(at) else b.class
				-- getCellColor: a cell is lit unless it starts past the value.
				local opacity = if at <= b.fill then 0.85 else 0.18
				if o.vertical then
					rect(class, bx, by + barMaxH - (c + 1) * (cell + spacing) + spacing, barMaxW, cell, opacity)
				else
					rect(class, bx + c * (cell + spacing), by, cell, barMaxH, opacity)
				end
			end
			valueRight = bx + count * (cell + spacing) + valueW
		else
			local maxLen = if o.vertical then barMaxH else barMaxW
			local len = math.max(fill * maxLen, 1)
			if o.show_unfilled then
				rect("tgb-empty", bx, by, barMaxW, barMaxH)
			end
			local bxs: number, bys: number, bw: number, bh: number
			if o.vertical then
				bxs, bys, bw, bh = bx, by + barMaxH - len, barMaxW, len
			else
				bxs, bys, bw, bh = bx, by, len, barMaxH
			end
			if o.mode == "basic" then
				rect(b.class, bxs, bys, bw, bh, 0.35)
				-- The 2 px edge at the value's end.
				if o.vertical then
					rect(b.class, bxs, bys, bw, math.min(2, bh))
				else
					rect(b.class, bxs + bw - math.min(2, bw), bys, math.min(2, bw), bh)
				end
			elseif b.gradient and #(b.gradient :: { Stop }) > 1 then
				-- getBarGradient: stops at offsets along the full bar length;
				-- the gradient spans the drawn bar.
				local id = fmt("tgb%d", i)
				local stops: { string } = {}
				for _, s in b.gradient :: { Stop } do
					local offset = math.clamp(s.at * maxLen / len, 0, 1)
					table.insert(stops, fmt('<stop offset="%.4f" class="%s"/>', offset, s.class))
				end
				table.insert(
					defs,
					fmt(
						'<linearGradient id="%s" x1="0" y1="%d" x2="%d" y2="0">%s</linearGradient>',
						id,
						if o.vertical then 1 else 0,
						if o.vertical then 0 else 1,
						table.concat(stops)
					)
				)
				table.insert(
					out,
					fmt(
						'<rect class="tg-bar" fill="url(#%s)" x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%d"/>',
						id,
						bxs,
						bys,
						bw,
						bh,
						M.RADIUS
					)
				)
			else
				rect(b.class, bxs, bys, bw, bh)
			end
		end

		-- The value.
		if not hidden then
			local size = o.value_size
			if o.vertical then
				size = size or fontSize(alignValue, valueW, valueH, 1)
				text(valueClass, x0 + w / 2, y0 + valueH / 2, valueStr, size :: number, "middle")
			else
				local pad = M.VALUE_LEFT_PADDING + (if overflow then 15 else 0)
				size = size or fontSize(alignValue, valueW - M.VALUE_LEFT_PADDING * 2, valueH, 1)
				text(valueClass, valueRight - pad, by + valueH / 2, valueStr, size :: number, "end")
			end
		end
	end
	if #defs > 0 then
		table.insert(out, 2, "<defs>" .. table.concat(defs) .. "</defs>")
	end
	table.insert(out, "</svg>")
	return table.concat(out), math.ceil(totalW), math.ceil(totalH)
end

return M
