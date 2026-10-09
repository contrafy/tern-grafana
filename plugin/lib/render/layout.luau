--!strict
-- Geometry of a rendered time-series chart, kept as plain data so a block can
-- hold it in state and place the cursor overlay (a fraction of the image
-- width) without rebuilding the SVG.

local Series = require("./series")

export type DrawnSeries = {
	name: string,
	-- Palette class, "tg-s1" .. "tg-s10".
	class: string,
	labels: { [string]: string },
	-- The drawn samples (after downsampling), raw values (not stacked);
	-- missing samples are Frame.NULL.
	times: { number },
	values: { any },
	-- Over the full-resolution series.
	calcs: Series.Calcs,
}

export type Layout = {
	width: number,
	height: number,
	plot_left: number,
	plot_right: number,
	plot_top: number,
	plot_bottom: number,
	t_from: number,
	t_to: number,
	y_min: number,
	y_max: number,
	unit: string?,
	decimals: number?,
	-- Sorted union of the drawn sample times (cursor stops).
	times: { number },
	series: { DrawnSeries },
	-- Series beyond the cap, not drawn.
	dropped: number,
}

local M = {}

function M.xOfTime(layout: Layout, t: number): number
	local span = layout.t_to - layout.t_from
	local f = if span > 0 then (t - layout.t_from) / span else 0.5
	return layout.plot_left + f * (layout.plot_right - layout.plot_left)
end

function M.yOfValue(layout: Layout, v: number): number
	local span = layout.y_max - layout.y_min
	local f = if span > 0 then (v - layout.y_min) / span else 0.5
	return layout.plot_bottom - f * (layout.plot_bottom - layout.plot_top)
end

-- Position of time `t` as a fraction of the whole image width (0..1).
function M.fractionOfTime(layout: Layout, t: number): number
	return math.clamp(M.xOfTime(layout, t) / layout.width, 0, 1)
end

-- Inverse of fractionOfTime, clamped to the plotted time range.
function M.timeAtFraction(layout: Layout, f: number): number
	local x = f * layout.width
	local w = layout.plot_right - layout.plot_left
	local p = if w > 0 then math.clamp((x - layout.plot_left) / w, 0, 1) else 0
	return layout.t_from + p * (layout.t_to - layout.t_from)
end

return M
