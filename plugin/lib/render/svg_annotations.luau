--!strict
-- Dashboard annotations over a time series chart, as Grafana 13's time
-- series panel draws them (public/app/plugins/panel/timeseries/plugins/
-- AnnotationsPlugin.tsx draw hook and markers, annotations/AnnotationMarker
-- styles, plugins/utils.ts getAnnoRegionBoxStyle / shouldRenderAnnotation*):
--
-- - over the plot, clipped to it: a dashed line (2 px, dash 5 5) at each
--   annotation's time, and for a region (an end time other than its start)
--   a second line at its end and a fill between them at the region opacity
--   (default 0.1). Lines and fills are drawn only when both
--   options.annotations.lines.width and regions.opacity allow them (they
--   default to on unless multiLane);
-- - under the plot, at the top of the x axis: a marker per annotation, an
--   upward triangle 10 px wide and 5 px tall for a point, a 5 px tall bar
--   over the region (at least 5 px wide) for a region; with multiLane each
--   annotation layer gets its own 7 px lane.
--
-- Colors are classes (lib/render/ts_gradient stopClass): Grafana's named
-- colors follow the theme; Grafana's default annotation color has its own
-- class (`tg-anno`), any other literal its nearest stop color.

local TsGradient = require("./ts_gradient")

local M = {}

export type Mark = {
	time_ms: number,
	-- Set only for a region (an end other than the start).
	end_ms: number?,
	-- Grafana color (name, hex, rgb/rgba).
	color: string,
	-- The annotation layer's lane (0-based), for multiLane.
	lane: number,
}

-- The marks and the panel's options.annotations (VizAnnotations).
export type Layer = {
	marks: { Mark },
	line_width: number?,
	region_opacity: number?,
	multi_lane: boolean?,
}

-- The plot box in viewBox px, its time range, and viewBox px per Grafana px.
export type Box = {
	t_from: number,
	t_to: number,
	left: number,
	right: number,
	top: number,
	bottom: number,
	scale: number,
}

-- Most marks drawn (Grafana's built-in layer asks for 100 per range).
M.CAP = 200
-- Upper bound of the bytes one mark adds to the document.
M.BYTES = 220
-- packages/grafana-ui DEFAULT_ANNOTATION_COLOR.
M.DEFAULT_COLOR = "rgba(0, 211, 255, 1)"
M.LANE_PX = 7
M.MARKER_PX = 5
M.REGION_MIN_PX = 5

local fmt = string.format

local DEFAULT_CLASSES: { [string]: boolean } = {
	["rgba(0, 211, 255, 1)"] = true,
	["rgba(0,211,255,1)"] = true,
	["#00d3ff"] = true,
	["#00d3ffff"] = true,
}

local classes: { [string]: string } = {}

function M.class(color: string): string
	local hit = classes[color]
	if hit then
		return hit
	end
	local c = if DEFAULT_CLASSES[string.lower(color)] then "tg-anno" else TsGradient.stopClass(color)
	classes[color] = c
	return c
end

local function num(v: any): number?
	return if type(v) == "number" and v == v then v else nil
end

-- The panel's options.annotations (nil or not a table: Grafana's defaults).
function M.layer(marks: { Mark }, options: any): Layer
	local o = if type(options) == "table" then options else {}
	local lines = if type(o.lines) == "table" then o.lines else {}
	local regions = if type(o.regions) == "table" then o.regions else {}
	return {
		marks = marks,
		line_width = num(lines.width),
		region_opacity = num(regions.opacity),
		multi_lane = if o.multiLane == true then true else nil,
	}
end

-- shouldRenderAnnotationLine / shouldRenderAnnotationRegion.
local function shown(v: number?, multiLane: boolean?): boolean
	if v ~= nil then
		return v > 0
	end
	return not multiLane
end

-- Appends the annotation shapes to `out`: fills and dashed lines (over the
-- series), then the markers under the plot.
function M.draw(out: { string }, layer: Layer, b: Box)
	local span = b.t_to - b.t_from
	local w = b.right - b.left
	if span <= 0 or w <= 0 or #layer.marks == 0 then
		return
	end
	local k = b.scale
	local function xOf(t: number): number
		return b.left + (t - b.t_from) / span * w
	end
	local function inPlot(x: number): boolean
		return x >= b.left and x <= b.right
	end
	-- AnnotationsPlugin draws lines (and fills) only when regions render too.
	local overlay = shown(layer.line_width, layer.multi_lane) and shown(layer.region_opacity, layer.multi_lane)
	local width = (layer.line_width or 2) * k
	local opacity = layer.region_opacity or 0.1
	local lineByClass: { [string]: { string } } = {}
	local lineOrder: { string } = {}
	local markers: { string } = {}
	local function line(class: string, x: number)
		if not inPlot(x) then
			return
		end
		local list = lineByClass[class]
		if list == nil then
			list = {}
			lineByClass[class] = list
			table.insert(lineOrder, class)
		end
		table.insert(list :: { string }, fmt("M%.1f %.1fV%.1f", x, b.top, b.bottom))
	end
	local m = M.MARKER_PX * k
	for i, a in layer.marks do
		if i > M.CAP then
			break
		end
		local class = M.class(a.color)
		local x0 = xOf(a.time_ms)
		local y = b.bottom + (if layer.multi_lane then a.lane * M.LANE_PX * k else 0)
		local stop = a.end_ms
		if stop then
			local x1 = xOf(stop)
			if overlay then
				local l, r = math.max(x0, b.left), math.min(x1, b.right)
				if r > l then
					table.insert(
						out,
						fmt(
							'<rect class="%s tg-area" x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill-opacity="%g"/>',
							class,
							l,
							b.top,
							r - l,
							b.bottom - b.top,
							opacity
						)
					)
				end
				line(class, x0)
				line(class, x1)
			end
			-- getAnnoRegionBoxStyle, in plot coordinates.
			if x0 < b.right and x1 > b.left then
				local l, r = math.max(b.left, x0), math.min(b.right, x1)
				local minW = M.REGION_MIN_PX * k
				if r - l < minW then
					l = math.max(b.left, l - (minW - (r - l)) / 2)
					r = l + minW
				end
				table.insert(
					markers,
					fmt(
						'<rect class="%s tg-area" x="%.1f" y="%.1f" width="%.1f" height="%.1f"/>',
						class,
						l,
						y,
						r - l,
						m
					)
				)
			end
		else
			if overlay then
				line(class, x0)
			end
			if inPlot(x0) then
				table.insert(
					markers,
					fmt('<path class="%s tg-area" d="M%.1f %.1fl%.1f %.1fh%.1fZ"/>', class, x0, y, m, m, -2 * m)
				)
			end
		end
	end
	local dash = fmt("%g %g", 5 * k, 5 * k)
	for _, class in lineOrder do
		table.insert(
			out,
			fmt(
				'<path class="%s tg-line" fill="none" stroke-width="%g" stroke-dasharray="%s" d="%s"/>',
				class,
				width,
				dash,
				table.concat(lineByClass[class])
			)
		)
	end
	table.move(markers, 1, #markers, #out + 1, out)
end

return M
