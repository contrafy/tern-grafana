--!strict
-- The histogram panel (public/app/plugins/panel/histogram: HistogramPanel,
-- Histogram.tsx; packages/grafana-data/src/transformations/transformers/
-- histogram.ts getHistogramFields, buildHistogram, joinHistograms):
-- - pre-bucketed data (one frame, or only heatmap frames): xMin/xMax (or
--   BucketMin/BucketMax, one guessed from the other) with count fields,
--   heatmap-cells (yMin/yMax/count) and heatmap-rows (one count field per
--   `le` bucket, drawn as ordinal buckets); several such frames join on
--   xMax with missing counts as 0;
-- - otherwise buckets computed from every number field's raw values:
--   options.bucketSize (auto: the first of Grafana's bucket sizes larger
--   than range / bucketCount, default 30, and no smaller than the closest
--   two values), bucketOffset, combine (one "Count" series); nulls become
--   the field's noValue when it is a number, else are dropped;
-- - bars span each bucket, stacked per custom.stacking (normal, percent),
--   in palette or fixed colors with custom.fillOpacity and lineWidth; the
--   x axis takes the source unit (and the bucket size's decimals), the
--   count axis is plain; fieldConfig min/max bound the x axis as in
--   Grafana; legend calcs read the raw values.

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local Reduce = require("./reduce")
local Series = require("../render/series")
local SvgBars = require("../render/svg_bars")
local SvgXY = require("../render/svg_xy")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

M.types = { "histogram" }

M.WIDTH = 960
M.HEIGHT = 300
M.DEFAULT_BUCKET_COUNT = 30

-- histogramBucketSizes.
-- stylua: ignore
M.BUCKET_SIZES = {
	1e-9, 2e-9, 2.5e-9, 4e-9, 5e-9,
	1e-8, 2e-8, 2.5e-8, 4e-8, 5e-8,
	1e-7, 2e-7, 2.5e-7, 4e-7, 5e-7,
	1e-6, 2e-6, 2.5e-6, 4e-6, 5e-6,
	1e-5, 2e-5, 2.5e-5, 4e-5, 5e-5,
	1e-4, 2e-4, 2.5e-4, 4e-4, 5e-4,
	1e-3, 2e-3, 2.5e-3, 4e-3, 5e-3,
	1e-2, 2e-2, 2.5e-2, 4e-2, 5e-2,
	1e-1, 2e-1, 2.5e-1, 4e-1, 5e-1,
	1, 2, 4, 5,
	1e+1, 2e+1, 2.5e+1, 4e+1, 5e+1,
	1e+2, 2e+2, 2.5e+2, 4e+2, 5e+2,
	1e+3, 2e+3, 2.5e+3, 4e+3, 5e+3,
	1e+4, 2e+4, 2.5e+4, 4e+4, 5e+4,
	1e+5, 2e+5, 2.5e+5, 4e+5, 5e+5,
	1e+6, 2e+6, 2.5e+6, 4e+6, 5e+6,
	1e+7, 2e+7, 2.5e+7, 4e+7, 5e+7,
	1e+8, 2e+8, 2.5e+8, 4e+8, 5e+8,
	1e+9, 2e+9, 2.5e+9, 4e+9, 5e+9,
}

function M.supports(panel: any, env: Env): (boolean, string?)
	local why = Charts.unsupportedLegend(panel, env)
	if why then
		return false, why
	end
	return true, nil
end

export type Count = {
	name: string,
	values: { number },
	-- The source field (config, color, legend calcs); nil for combined.
	item: Item?,
}

export type Histogram = {
	x_min: { any },
	x_max: { any },
	counts: { Count },
	-- Ordinal buckets (heatmap-rows): x_max holds the bucket labels.
	ordinal: boolean,
	bucket_size: number?,
	x_unit: string?,
	x_decimals: number?,
}

-- roundDecimals (packages/grafana-data/src/utils/numbers.ts).
local function roundDecimals(v: number, dec: number): number
	if v == math.floor(v) then
		return v
	end
	local p = 10 ^ dec
	local n = v * p * (1 + 2.220446049250313e-16)
	return math.floor(n + 0.5) / p
end

local function itemsOf(items: { Item }, frame: Frame): { Item }
	local out: { Item } = {}
	for _, item in items do
		if item.frame == frame then
			table.insert(out, item)
		end
	end
	return out
end

local function numbers(values: { any }): { number }
	local out: { number } = table.create(#values)
	for i, v in values do
		out[i] = if type(v) == "number" then v else 0
	end
	return out
end

-- getHistogramFields.
local function explicitFields(frame: Frame, items: { Item }): Histogram?
	local kind = if frame.meta then frame.meta.type else nil
	if kind == "heatmap-cells" then
		local yMin: Item?, yMax: Item?, count: Item? = nil, nil, nil
		for _, item in items do
			local n = item.field.name
			if n == "yMin" then
				yMin = item
			elseif n == "yMax" then
				yMax = item
			elseif n == "count" then
				count = item
			end
		end
		if yMin == nil or yMax == nil or count == nil then
			return nil
		end
		-- Unique bucket bounds with counts summed over time.
		local byMax: { [number]: number } = {}
		local minOf: { [number]: number } = {}
		local maxes: { number } = {}
		for r, mx in (yMax :: Item).field.values do
			if type(mx) == "number" then
				if byMax[mx] == nil then
					byMax[mx] = 0
					table.insert(maxes, mx)
					local mn = (yMin :: Item).field.values[r]
					minOf[mx] = if type(mn) == "number" then mn else mx
				end
				local c = (count :: Item).field.values[r]
				byMax[mx] += if type(c) == "number" then c else 0
			end
		end
		table.sort(maxes)
		local xMin: { any }, xMax: { any }, counts: { number } = {}, {}, {}
		for i, mx in maxes do
			xMin[i], xMax[i], counts[i] = minOf[mx], mx, byMax[mx]
		end
		return {
			x_min = xMin,
			x_max = xMax,
			counts = { { name = (count :: Item).name, values = counts, item = count } },
			ordinal = false,
			x_unit = (yMax :: Item).config.unit,
			x_decimals = (yMax :: Item).config.decimals,
		}
	elseif kind == "heatmap-rows" then
		local mins: { any }, maxs: { any }, counts: { number } = {}, {}, {}
		local minVal = "0"
		local first: Item? = nil
		for _, item in items do
			if item.field.type == "number" then
				first = first or item
				local sum = 0
				for _, v in item.field.values do
					if type(v) == "number" then
						sum += v
					end
				end
				table.insert(counts, sum)
				table.insert(mins, minVal)
				minVal = item.field.name
				table.insert(maxs, minVal)
			end
		end
		if first == nil then
			return nil
		end
		return {
			x_min = mins,
			x_max = maxs,
			counts = { { name = "count", values = counts, item = first } },
			ordinal = true,
		}
	end
	local xMin: Item?, xMax: Item? = nil, nil
	local counts: { Count } = {}
	for _, item in items do
		local n = item.field.name
		if n == "xMin" or n == "BucketMin" then
			xMin = item
		elseif n == "xMax" or n == "BucketMax" then
			xMax = item
		elseif item.field.type == "number" then
			table.insert(counts, { name = item.name, values = numbers(item.field.values), item = item })
		end
	end
	local minV: { any }? = if xMin then (xMin :: Item).field.values else nil
	local maxV: { any }? = if xMax then (xMax :: Item).field.values else nil
	local function shifted(vals: { any }, by: number): { any }
		local out: { any } = table.create(#vals)
		for i, v in vals do
			out[i] = if type(v) == "number" then v + by else v
		end
		return out
	end
	if maxV == nil and minV and #(minV :: { any }) > 1 then
		local v = minV :: { any }
		maxV = shifted(v, roundDecimals((v[2] :: number) - (v[1] :: number), 6))
	elseif minV == nil and maxV and #(maxV :: { any }) > 1 then
		local v = maxV :: { any }
		minV = shifted(v, -roundDecimals((v[2] :: number) - (v[1] :: number), 6))
	end
	if minV == nil or maxV == nil or #counts == 0 then
		return nil
	end
	local unitItem = (xMin or xMax) :: Item
	return {
		x_min = minV :: { any },
		x_max = maxV :: { any },
		counts = counts,
		ordinal = false,
		x_unit = unitItem.config.unit,
		x_decimals = unitItem.config.decimals,
	}
end

-- joinHistograms: outer join on xMax, missing counts 0.
local function joinHistograms(list: { Histogram }): Histogram
	if #list == 1 then
		return list[1]
	end
	local keys: { any } = {}
	local seen: { [any]: boolean } = {}
	local minOf: { [any]: any } = {}
	for _, h in list do
		for i, mx in h.x_max do
			if not seen[mx] then
				seen[mx] = true
				table.insert(keys, mx)
				minOf[mx] = h.x_min[i]
			end
		end
	end
	if not list[1].ordinal then
		table.sort(keys, function(a, b)
			return (tonumber(a) or 0) < (tonumber(b) or 0)
		end)
	end
	local counts: { Count } = {}
	for _, h in list do
		local at: { [any]: number } = {}
		for i, mx in h.x_max do
			at[mx] = i
		end
		for _, c in h.counts do
			local values: { number } = table.create(#keys)
			for k, mx in keys do
				local i = at[mx]
				values[k] = if i then c.values[i] or 0 else 0
			end
			table.insert(counts, { name = c.name, values = values, item = c.item })
		end
	end
	local xMin: { any } = table.create(#keys)
	for k, mx in keys do
		xMin[k] = minOf[mx]
	end
	return {
		x_min = xMin,
		x_max = keys,
		counts = counts,
		ordinal = list[1].ordinal,
		x_unit = list[1].x_unit,
		x_decimals = list[1].x_decimals,
	}
end

local function numOption(env: Env, v: any): number?
	local n = Json.num(env, v)
	if n == nil or n ~= n then
		return nil
	end
	return n
end

-- buildHistogram.
function M.buildHistogram(panel: any, items: { Item }, env: Env): Histogram?
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local bucketCount = numOption(env, options.bucketCount) or M.DEFAULT_BUCKET_COUNT
	local bucketSize = numOption(env, options.bucketSize)
	local bucketOffset = numOption(env, options.bucketOffset) or 0
	local fields: { { item: Item, values: { number } } } = {}
	for _, item in items do
		if item.field.type ~= "number" or FieldConfig.hidden(item) then
			continue
		end
		local noValue = tonumber(item.config.no_value or "")
		local vals: { number } = {}
		for _, v in item.field.values do
			if type(v) == "number" and v == v then
				table.insert(vals, v)
			elseif noValue then
				table.insert(vals, noValue)
			end
		end
		table.insert(fields, { item = item, values = vals })
	end
	if #fields == 0 then
		return nil
	end
	if bucketSize == nil or bucketSize <= 0 then
		local all: { number } = {}
		for _, f in fields do
			for _, v in f.values do
				table.insert(all, v)
			end
		end
		table.sort(all)
		local smallest = math.huge
		if #all == 1 then
			smallest = 1
		else
			for i = 2, #all do
				local d = all[i] - all[i - 1]
				if d ~= 0 then
					smallest = math.min(smallest, d)
				end
			end
		end
		local range = if #all > 0 then all[#all] - all[1] else 0
		local target = range / bucketCount
		bucketSize = nil
		for _, s in M.BUCKET_SIZES do
			if target < s and s >= smallest then
				bucketSize = s
				break
			end
		end
		-- Every value equal (no delta): Grafana finds no size; one unit
		-- buckets keep the single bar drawable.
		bucketSize = bucketSize or 1
	end
	local size = bucketSize :: number
	local function bucket(v: number): number
		return roundDecimals(math.floor((v - bucketOffset) / size) * size + bucketOffset, 9)
	end
	-- Per field counts per bucket, then aligned on the union of buckets.
	local keys: { number } = {}
	local seen: { [number]: boolean } = {}
	local perField: { { [number]: number } } = {}
	for i, f in fields do
		local hist: { [number]: number } = {}
		for _, v in f.values do
			local b = bucket(v)
			hist[b] = (hist[b] or 0) + 1
			if not seen[b] then
				seen[b] = true
				table.insert(keys, b)
			end
		end
		perField[i] = hist
	end
	table.sort(keys)
	local xMax: { any } = table.create(#keys)
	for i, k in keys do
		xMax[i] = k + size
	end
	local counts: { Count } = {}
	for i, f in fields do
		local values: { number } = table.create(#keys)
		for k, b in keys do
			values[k] = perField[i][b] or 0
		end
		table.insert(counts, { name = f.item.name, values = values, item = f.item })
	end
	if Json.bool(env, options.combine) == true then
		local sum: { number } = table.create(#keys, 0)
		for _, c in counts do
			for k, v in c.values do
				sum[k] += v
			end
		end
		counts = { { name = "Count", values = sum, item = nil } }
	end
	local sizeText = tostring(size)
	local frac = string.match(sizeText, "%.(%d+)$")
	local decimals = if frac then #frac else 0
	local unit: string?, xDecimals: number? = nil, nil
	for _, f in fields do
		if f.item.config.unit then
			unit = f.item.config.unit
			xDecimals = f.item.config.decimals
			break
		end
	end
	if decimals ~= 0 then
		xDecimals = decimals
	end
	local xMin: { any } = table.create(#keys)
	for i, k in keys do
		xMin[i] = k
	end
	return {
		x_min = xMin,
		x_max = xMax,
		counts = counts,
		ordinal = false,
		bucket_size = size,
		x_unit = unit,
		x_decimals = xDecimals,
	}
end

-- The histogram a panel draws (HistogramPanel), or nil.
function M.histogram(panel: any, frames: { Frame }, env: Env): (Histogram?, { Item })
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "palette-classic" })
	if #frames == 0 then
		return nil, items
	end
	local allHeatmap = true
	for _, f in frames do
		local kind = if f.meta then f.meta.type else nil
		if kind ~= "heatmap-cells" and kind ~= "heatmap-rows" then
			allHeatmap = false
		end
	end
	if #frames == 1 or allHeatmap then
		local list: { Histogram } = {}
		for _, f in frames do
			local h = explicitFields(f, itemsOf(items, f))
			if h then
				table.insert(list, h)
			end
		end
		if #list > 0 then
			return joinHistograms(list), items
		end
	end
	return M.buildHistogram(panel, items, env), items
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	if not Common.hasData(frames) then
		return Common.noData(panel, env, opts.key), {}
	end
	local hist = M.histogram(panel, frames, env)
	if hist == nil or #hist.counts == 0 then
		return Charts.message(opts.key, "No histogram found in response"), {}
	end
	local h = hist :: Histogram
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local base = FieldConfig.defaults(panel, env, { color_mode = "palette-classic" })
	local custom = base.custom
	local fill = (Json.num(env, custom.fillOpacity) or 80) / 100
	local lineWidth = Json.num(env, custom.lineWidth) or 1
	local stackMode = Json.str(env, Json.path(env, custom.stacking, "mode"))
	local classes: { string } = table.create(#h.counts)
	for k, c in h.counts do
		classes[k] = if c.item then Charts.seriesClass(c.item :: Item, k, opts) else FieldConfig.paletteClass(k)
	end
	local svg: string
	if h.ordinal then
		local cats: { string } = table.create(#h.x_max)
		for i, v in h.x_max do
			cats[i] = tostring(v)
		end
		local series: { SvgBars.Series } = table.create(#h.counts)
		for k, c in h.counts do
			series[k] = { class = classes[k], values = c.values }
		end
		svg = SvgBars.render({
			width = W,
			height = H,
			categories = cats,
			series = series,
			stacking = if stackMode == "normal" or stackMode == "percent" then stackMode else "none",
			group_width = 1,
			bar_width = 1,
			fill_opacity = fill,
			line_width = lineWidth,
			show_value = "never",
		}).svg
	else
		local columns: { { any } } = table.create(#h.counts)
		for k, c in h.counts do
			columns[k] = c.values
		end
		local tops: { { any } }, bottoms: { { number } }? = columns, nil
		if stackMode == "normal" or stackMode == "percent" then
			local t, b = Series.stack(columns, stackMode)
			tops, bottoms = t, b
		end
		local layers: { SvgXY.Rects } = {}
		for k = 1, #h.counts do
			local rects: { SvgXY.Rect } = {}
			for i, top in tops[k] do
				local x0, x1 = h.x_min[i], h.x_max[i]
				local y1 = Frame.finite(top)
				if type(x0) == "number" and type(x1) == "number" and y1 then
					local y0 = if bottoms then bottoms[k][i] else 0
					if y1 ~= y0 then
						table.insert(rects, { x0 = x0, x1 = x1, y0 = y0, y1 = y1 :: number })
					end
				end
			end
			table.insert(layers, { class = classes[k], rects = rects, opacity = fill })
			if lineWidth > 0 then
				table.insert(layers, { class = classes[k], rects = rects, outline = lineWidth })
			end
		end
		local xlo: number?, xhi: number? = nil, nil
		for i = 1, #h.x_min do
			local a, b = h.x_min[i], h.x_max[i]
			if type(a) == "number" then
				xlo = if xlo == nil then a else math.min(xlo :: number, a)
			end
			if type(b) == "number" then
				xhi = if xhi == nil then b else math.max(xhi :: number, b)
			end
		end
		local countUnit: string? = nil
		local first = h.counts[1].item
		if first and first.config.unit == "short" then
			countUnit = "short"
		end
		svg = SvgXY.render({
			width = W,
			height = H,
			x_unit = h.x_unit,
			x_decimals = h.x_decimals,
			x_min = base.min or xlo,
			x_max = base.max or xhi,
			y_unit = if stackMode == "percent" then "percentunit" else countUnit,
			y_zero = true,
			y_min = if stackMode == "percent" then 0 else nil,
			y_max = if stackMode == "percent" then 1 else nil,
			rects = layers,
			grid = Json.bool(env, custom.axisGridShow) ~= false,
		}).svg
	end
	local chart, assets =
		Charts.image(opts.key, svg, W, H, Charts.alt(panel, env, "Histogram"), "tern-grafana.histogram")
	local legend = Charts.legendOptions(panel, env)
	local legendNode: Node? = nil
	if legend.show then
		local rows: { Charts.Row } = {}
		for k, c in h.counts do
			local item = c.item
			if item and Charts.hiddenFromLegend(item) then
				continue
			end
			if item and not h.ordinal then
				local row = Charts.calcRow(item :: Item, classes[k], legend.calcs, opts)
				row.name = c.name
				table.insert(rows, row)
			else
				local values: { string } = {}
				local results = Reduce.calcs(c.values, legend.calcs, "number")
				for i, calc in legend.calcs do
					local v = results[calc]
					values[i] = if type(v) == "number" then tostring(v) else "-"
				end
				table.insert(rows, { class = classes[k], name = c.name, values = values })
			end
		end
		legendNode = Charts.calcLegend(opts.key .. ".legend", rows, legend)
	end
	return Charts.compose(opts.key, chart, legendNode, legend.placement), assets
end

return M
