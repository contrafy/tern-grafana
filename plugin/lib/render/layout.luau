--!strict
-- Geometry of a rendered time-series chart, kept as plain data so a block can
-- hold it in state and place the cursor overlay (a fraction of the image
-- width) without rebuilding the SVG.

local Axis = require("./axis")
local FrameProm = require("../frame/prom")
local Series = require("./series")

export type DrawnSeries = {
	name: string,
	-- Palette class, "tg-s1" .. "tg-s10".
	class: string,
	labels: { [string]: string },
	-- The drawn sample times (after downsampling) and the series' own values
	-- there (not stacked, not transformed); missing samples are Frame.NULL.
	times: { number },
	values: { any },
	-- Over the full-resolution series.
	calcs: Series.Calcs,
	-- Index into layout.axes of the scale the series is drawn on (default 1).
	axis: number?,
	-- The series' own unit and decimals for read-outs (default: the layout's).
	unit: string?,
	decimals: number?,
	-- Grafana custom.hideFrom.legend / .tooltip.
	hide_legend: boolean?,
	hide_tooltip: boolean?,
}

-- One y scale (Grafana's scale key: unit, bounds, placement, distribution,
-- label) and where its axis is drawn.
export type YAxis = {
	key: string,
	side: "left" | "right" | "hidden",
	min: number,
	max: number,
	distr: Axis.Distr?,
	log: number?,
	linear_threshold: number?,
	-- Tick label format (percentunit on a percent stack).
	unit: string?,
	decimals: number?,
	label: string?,
	-- Horizontal band of the tick labels (and axis label), viewBox px.
	x0: number,
	x1: number,
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
	-- The first scale's range and format (exemplars use it).
	y_min: number,
	y_max: number,
	unit: string?,
	decimals: number?,
	-- Every y scale; nil means one linear scale y_min..y_max.
	axes: { YAxis }?,
	-- Sorted union of the drawn sample times (cursor stops).
	times: { number },
	series: { DrawnSeries },
	-- Series beyond the cap, not drawn.
	dropped: number,
	-- Exemplar markers drawn, sorted by time (at most svg_timeseries
	-- EXEMPLAR_CAP); nil when none were given.
	exemplars: { FrameProm.Exemplar }?,
	-- Exemplars in range left out by the cap.
	exemplars_dropped: number?,
}

local M = {}

function M.xOfTime(layout: Layout, t: number): number
	local span = layout.t_to - layout.t_from
	local f = if span > 0 then (t - layout.t_from) / span else 0.5
	return layout.plot_left + f * (layout.plot_right - layout.plot_left)
end

-- The y of value `v` on scale `axis` (default the first); a value a log
-- scale cannot place sits at the bottom.
function M.yOfValue(layout: Layout, v: number, axis: number?): number
	local a = if layout.axes then layout.axes[axis or 1] else nil
	local f: number?
	if a then
		f = Axis.position(a, v)
	else
		local span = layout.y_max - layout.y_min
		f = if span > 0 then (v - layout.y_min) / span else 0.5
	end
	return layout.plot_bottom - (f or 0) * (layout.plot_bottom - layout.plot_top)
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
