--!strict
-- The heatmap panel (public/app/plugins/panel/heatmap: HeatmapPanel.tsx,
-- fields.ts prepareHeatmapData, utils.ts prepConfig/heatmapPathsDense/
-- boundedMinMax/valuesToFills, palettes.ts; public/app/features/
-- transformers/calculateHeatmap/heatmap.ts rowsToCellsHeatmap and
-- calculateHeatmapFromData; packages/grafana-prometheus/src/
-- result_transformer.ts for `format: heatmap` targets):
-- - Prometheus heatmap targets: the frontend's transform first (series
--   grouped per query and non-`le` labels, sorted by `le`, de-accumulated,
--   merged into one heatmap-rows frame);
-- - heatmap-rows (or any frames with a field per bucket, sorted when every
--   name is numeric and outer joined on time): ordinal y buckets labeled
--   by their names (formatted in yAxis.unit/decimals; `le` buckets start
--   at a "0" label), or numeric buckets with rowsFrame.yBucketScale
--   linear/log; rowsFrame.layout le/ge/unknown/auto;
-- - dense heatmap-cells frames (x|xMin|xMax, y|yMin|yMax, a count field);
-- - options.calculate: buckets computed from raw series (xBuckets and
--   yBuckets size or count, y log scale with a split);
-- - colors: options.color scheme (every d3 scheme Grafana lists) or
--   opacity of one color, steps, reverse, linear/exponential scale,
--   min/max; filterValues hides cells (default <= 1e-9); cellGap; yAxis
--   placement, reverse, min/max (numeric), unit, decimals; the color scale
--   legend (legend.show) with the value display (cellValues unit/decimals).

local Assets = require("../render/assets")
local HeatmapData = require("./heatmap_data")
local Charts = require("./charts")
local ColorScheme = require("../render/color_scheme")
local Common = require("./common")
local Env = require("../env")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Json = require("./json")
local SvgHeatmap = require("../render/svg_heatmap")
local Thresholds = require("../units/thresholds")
local Axis = require("../render/axis")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field
type Node = ui.Node

local M = {}

M.types = { "heatmap" }

M.WIDTH = 960
M.HEIGHT = 300

function M.supports(panel: any, env: Env): (boolean, string?)
	local o = Json.obj(env, panel.options)
	local calc = Json.obj(env, o.calculation)
	local yScale = Json.str(env, Json.path(env, calc, "yBuckets", "scale", "type"))
	if
		Json.bool(env, o.calculate) == true
		and Json.str(env, Json.path(env, calc, "xBuckets", "scale", "type")) == "log"
	then
		return false, "heatmap X axis only supports linear buckets"
	end
	local rowsScale = Json.str(env, Json.path(env, o, "rowsFrame", "yBucketScale", "type"))
	if yScale == "symlog" or rowsScale == "symlog" then
		return false, "heatmap symlog y scale is not drawn natively"
	end
	return true, nil
end

-- Data preparation lives in heatmap_data; the panel's API keeps it.
export type Layout = HeatmapData.Layout
export type Dense = HeatmapData.Dense
M.sampleValue = HeatmapData.sampleValue
M.promHeatmap = HeatmapData.promHeatmap
M.calculate = HeatmapData.calculate
M.dense = HeatmapData.dense

-- boundedMinMax over the counts, skipping filtered values.
function M.bounds(counts: { any }, min: number?, max: number?, hideLE: number, hideGE: number): (number, number)
	local lo, hi = min, max
	if lo == nil then
		local v = math.huge
		for _, c in counts do
			if type(c) == "number" and c > hideLE and c < hideGE then
				v = math.min(v, c)
			end
		end
		lo = v
	end
	if hi == nil then
		local v = -math.huge
		for _, c in counts do
			if type(c) == "number" and c > hideLE and c < hideGE then
				v = math.max(v, c)
			end
		end
		hi = v
	end
	return lo :: number, hi :: number
end

-- valuesToFills (1-based palette index).
function M.fill(v: number, n: number, lo: number, hi: number): number
	local range = hi - lo
	if range == 0 or range ~= range then
		range = 1
	end
	if v < lo then
		return 1
	elseif v > hi then
		return n
	end
	return math.min(n - 1, math.floor(n * (v - lo) / range)) + 1
end

local function hexOf(color: string): string?
	local h = string.match(color, "^#(%x%x%x%x%x%x)")
	if h then
		return "#" .. string.lower(h)
	end
	local short = string.match(color, "^#(%x%x%x)$")
	if short then
		local r, g, b = string.sub(short, 1, 1), string.sub(short, 2, 2), string.sub(short, 3, 3)
		return string.lower("#" .. r .. r .. g .. g .. b .. b)
	end
	local args = string.match(color, "^rgba?%(([^%)]*)%)$")
	if args then
		local parts: { number } = {}
		for piece in string.gmatch(args, "[^,%s/]+") do
			table.insert(parts, tonumber(piece) or 0)
		end
		if #parts >= 3 then
			return string.format("#%02x%02x%02x", parts[1], parts[2], parts[3])
		end
	end
	return nil
end

-- The palette for the panel's color options.
function M.palette(panel: any, env: Env, theme: Thresholds.Theme?): { string }
	local c = Json.obj(env, Json.path(env, panel, "options", "color"))
	local mode = Json.str(env, c.mode) or "scheme"
	local fill = Thresholds.color(Json.str(env, c.fill) or "dark-orange", theme)
	return ColorScheme.palette({
		mode = mode,
		scheme = Json.str(env, c.scheme) or "Oranges",
		fill = hexOf(fill) or "#fa6400",
		scale = Json.str(env, c.scale) or "exponential",
		exponent = Json.num(env, c.exponent) or 0.5,
		steps = Json.num(env, c.steps) or 64,
		reverse = Json.bool(env, c.reverse) == true,
	}, theme ~= "light")
end

-- The y axis ticks in scale units: ordinal bucket labels on the bucket
-- splits (thinned like Grafana's to fit), powers of the base on a log
-- scale, nice steps otherwise.
local function yTicks(d: Dense, plotH: number, lo: number, hi: number): { SvgHeatmap.Tick }
	local out: { SvgHeatmap.Tick } = {}
	if d.y_kind == "ordinal" then
		local labels = d.y_labels or {}
		local splits: { number } = {}
		for i = 0, #labels - 1 do
			table.insert(splits, i)
		end
		if d.y_layout == "le" then
			table.insert(splits, 1, -1)
		elseif d.y_layout == "ge" then
			table.insert(splits, #labels)
		end
		if plotH < 60 then
			splits = { splits[1], splits[#splits] }
		else
			while #splits > 3 and (plotH - 15) / #splits < 10 do
				local kept: { number } = {}
				for i, v in splits do
					if (i - 1) % 2 == 0 then
						table.insert(kept, v)
					end
				end
				splits = kept
			end
		end
		for _, s in splits do
			local label = if s < 0 then d.y_min_label or "" else labels[s + 1] or ""
			table.insert(out, { v = s, label = label })
		end
		return out
	end
	if d.y_kind == "log" then
		local base = d.y_log or 2
		for e = math.floor(lo), math.ceil(hi) do
			table.insert(out, { v = e, label = Format.text(base ^ e, d.y_unit, d.y_decimals) })
		end
		return out
	end
	local s = Axis.niceScale(lo, hi, plotH, lo, hi)
	for i, v in s.ticks do
		out[i] = { v = v, label = Format.text(v, d.y_unit, d.y_decimals) }
	end
	return out
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	if not Common.hasData(frames) then
		return Common.noData(panel, env, opts.key), {}
	end
	local from, to = Charts.range(opts)
	local maybe = M.dense(panel, frames, env, from, to)
	if maybe == nil then
		return Common.noData(panel, env, opts.key), {}
	end
	local d = maybe :: Dense
	if d.warning then
		return Charts.message(opts.key, d.warning :: string), {}
	end
	local options = Json.obj(env, panel.options)
	local colorOpts = Json.obj(env, options.color)
	local filter = Json.tbl(env, options.filterValues)
	local hideLE = -math.huge
	local hideGE = math.huge
	if filter == nil then
		hideLE = 1e-9
	else
		hideLE = Json.num(env, filter.le) or -math.huge
		hideGE = Json.num(env, filter.ge) or math.huge
	end
	local lo, hi = M.bounds(d.counts, Json.num(env, colorOpts.min), Json.num(env, colorOpts.max), hideLE, hideGE)
	local palette = M.palette(panel, env, opts.theme)
	local fills: { number } = table.create(#d.counts)
	for i, v in d.counts do
		fills[i] = if type(v) == "number" and v > hideLE and v < hideGE then M.fill(v, #palette, lo, hi) else 0
	end
	-- Scales.
	local function toScale(v: number): number
		if d.y_kind == "log" then
			return math.log(v) / math.log(d.y_log or 2)
		end
		return v
	end
	local rows: { { number } } = table.create(#d.rows)
	local ylo, yhi = math.huge, -math.huge
	for r, e in d.rows do
		local a, b = toScale(e[1]), toScale(e[2])
		rows[r] = { a, b }
		ylo = math.min(ylo, a, b)
		yhi = math.max(yhi, a, b)
	end
	local yAxis = Json.obj(env, options.yAxis)
	if d.y_kind ~= "ordinal" then
		local mn, mx = Json.num(env, yAxis.min), Json.num(env, yAxis.max)
		if mn and (d.y_kind ~= "log" or mn > 0) then
			ylo = toScale(mn)
		end
		if mx and (d.y_kind ~= "log" or mx > 0) then
			yhi = toScale(mx)
		end
	end
	local xlo, xhi = from, to
	if not d.x_time or xlo == nil or xhi == nil then
		xlo, xhi = math.huge, -math.huge
		for _, e in d.cols do
			xlo = math.min(xlo :: number, e[1])
			xhi = math.max(xhi :: number, e[2])
		end
	end
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local showLegend = Json.bool(env, Json.path(env, options, "legend", "show")) ~= false
	local cellValues = Json.obj(env, options.cellValues)
	local vUnit = Json.str(env, cellValues.unit) or d.value_unit
	if vUnit == "" then
		vUnit = d.value_unit
	end
	local vDec = Json.num(env, cellValues.decimals) or d.value_decimals
	local plotH = H - 32 - (if showLegend then 30 else 0)
	local placement = Json.str(env, yAxis.axisPlacement)
	local svg = SvgHeatmap.render({
		width = W,
		height = H,
		x_min = xlo :: number,
		x_max = xhi :: number,
		x_time = d.x_time,
		x_unit = d.x_unit,
		offset_min = opts.offset_min,
		cols = d.cols,
		rows = rows,
		y_min = ylo,
		y_max = yhi,
		y_ticks = yTicks(d, plotH, ylo, yhi),
		y_side = if placement == "hidden" then "hidden" elseif placement == "right" then "right" else "left",
		y_reverse = Json.bool(env, yAxis.reverse) == true,
		fills = fills,
		palette = palette,
		gap = Json.num(env, options.cellGap) or 1,
		scale = if showLegend and lo <= hi
			then { min = Format.text(lo, vUnit, vDec), max = Format.text(hi, vUnit, vDec) }
			else nil,
	}).svg
	local chart, assets = Charts.image(opts.key, svg, W, H, Charts.alt(panel, env, "Heatmap"), "tern-grafana.heatmap")
	return Charts.compose(opts.key, chart, nil, "bottom"), assets
end

return M
