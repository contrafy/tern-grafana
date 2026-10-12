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
local Charts = require("./charts")
local ColorScheme = require("../render/color_scheme")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Json = require("./json")
local Step = require("../time/step")
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

-- Layout of a bucket around its value: le (value is the upper bound), ge
-- (lower bound) or unknown (centered).
export type Layout = "le" | "ge" | "unknown"

-- One dense heatmap ready to draw.
export type Dense = {
	-- Column edges in x units, row edges in y units (ordinal: bucket index).
	cols: { { number } },
	rows: { { number } },
	x_time: boolean,
	x_unit: string?,
	-- "ordinal" (labels), "linear" or "log" (base y_log).
	y_kind: "ordinal" | "linear" | "log",
	y_log: number?,
	y_layout: Layout,
	-- Ordinal labels: the bucket names, and the label under the first
	-- bucket for le layouts.
	y_labels: { string }?,
	y_min_label: string?,
	y_unit: string?,
	y_decimals: number?,
	-- counts[(c - 1) * #rows + r].
	counts: { any },
	value_unit: string?,
	value_decimals: number?,
	-- Grafana's warning in place of the chart.
	warning: string?,
}

-- parseSampleValue: "+Inf"/"-Inf" and numbers; NaN otherwise.
function M.sampleValue(s: string?): number
	if s == nil then
		return 0 / 0
	end
	local lower = string.lower(s)
	if lower == "+inf" or lower == "inf" then
		return math.huge
	elseif lower == "-inf" then
		return -math.huge
	end
	if string.find(lower, "nan", 1, true) or string.find(lower, "inf", 1, true) then
		return 0 / 0
	end
	local n = tonumber((string.match(s, "^%s*([%+%-]?[%d%.eE%+%-]+)")))
	return if n then n else 0 / 0
end

local function numberField(frame: Frame): Field?
	for _, f in frame.fields do
		if f.type == "number" then
			return f
		end
	end
	return nil
end

local function nameOf(field: Field, frame: Frame, frames: { Frame }): string
	return FieldConfig.displayName(field, frame, frames)
end

-- Prometheus `format: heatmap` (transformV2): per refId, frames grouped by
-- their non-le labels, sorted by le, de-accumulated and merged into one
-- heatmap-rows frame each. Other frames pass through.
function M.promHeatmap(panel: any, frames: { Frame }, env: Env): { Frame }
	local heatRefs: { [string]: boolean } = {}
	for _, t in Json.list(env, panel.targets) do
		if Json.str(env, Json.path(env, t, "format")) == "heatmap" then
			heatRefs[Json.str(env, Json.path(env, t, "refId")) or "A"] = true
		end
	end
	if next(heatRefs) == nil then
		return frames
	end
	local out: { Frame } = {}
	local groups: { { key: string, frames: { Frame } } } = {}
	local groupAt: { [string]: number } = {}
	for _, f in frames do
		local kind = if f.meta then f.meta.type else nil
		if not heatRefs[f.refId or "A"] or kind == "heatmap-cells" or Frame.timeField(f) == nil then
			table.insert(out, f)
			continue
		end
		local nf = numberField(f)
		local parts: { string } = {}
		if nf and nf.labels then
			for _, k in Frame.labelKeys(nf.labels) do
				if k ~= "le" then
					table.insert(parts, nf.labels[k])
				end
			end
		end
		local key = (f.refId or "A") .. "\0" .. table.concat(parts, ",")
		local at = groupAt[key]
		if at == nil then
			table.insert(groups, { key = key, frames = {} })
			at = #groups
			groupAt[key] = at
		end
		table.insert(groups[at].frames, f)
	end
	for _, g in groups do
		local list = table.clone(g.frames)
		local function le(f: Frame): number
			local nf = numberField(f)
			local name: string? = nil
			if nf then
				name = (nf.config and nf.config.displayName) or (nf.labels and nf.labels.le) or nil
			end
			return M.sampleValue(name or f.name or (if nf then nf.name else nil))
		end
		table.sort(list, function(a, b)
			return le(a) < le(b)
		end)
		-- transformToHistogramOverTime.
		local counts: { { any } } = table.create(#list)
		for i, f in list do
			local nf = numberField(f)
			counts[i] = if nf then table.clone(nf.values) else {}
		end
		for i = #list, 2, -1 do
			local top, bottom = counts[i], counts[i - 1]
			for j, v in top do
				local b = bottom[j]
				local t = (if type(v) == "number" then v else 0) - (if type(b) == "number" then b else 0)
				top[j] = if t < 1e-9 then 0 else t
			end
		end
		local first = list[1]
		local tf = Frame.timeField(first) :: Field
		local fields: { Field } = { tf }
		for i, f in list do
			local nf = numberField(f)
			if nf then
				local name = (nf.config and nf.config.displayName) or (nf.labels and nf.labels.le) or nf.name
				table.insert(fields, Frame.field(name, "number", counts[i], nf.labels, nf.config))
			end
		end
		table.insert(out, {
			name = first.name,
			refId = first.refId,
			meta = { type = "heatmap-rows" },
			fields = fields,
		})
	end
	return out
end

-- Rows ------------------------------------------------------------------------

local function layoutOf(raw: string?, fallback: Layout): Layout
	if raw == "le" then
		return "le"
	elseif raw == "ge" then
		return "ge"
	elseif raw == "unknown" then
		return "unknown"
	end
	return fallback
end

local function edges(v: number, size: number, layout: Layout): { number }
	if layout == "le" then
		return { v - size, v }
	elseif layout == "ge" then
		return { v, v + size }
	end
	return { v - size / 2, v + size / 2 }
end

local function columns(xs: { number }, layout: Layout): { { number } }
	local size = if #xs >= 2 then xs[2] - xs[1] else 1
	if size == 0 then
		size = 1
	end
	local out: { { number } } = table.create(#xs)
	for i, x in xs do
		out[i] = edges(x, size, layout)
	end
	return out
end

-- calculateBucketFactor.
local function bucketFactor(values: { number }, default: number): number
	if #values >= 2 then
		local last, prev = values[#values], values[#values - 1]
		if prev ~= 0 then
			local f = last / prev
			if f == f and f ~= math.huge and f > 1 then
				return f
			end
		end
	end
	return default
end

-- The rows frame (heatmap-rows or joined bucket fields) as cells
-- (rowsToCellsHeatmap).
local function fromRows(frame: Frame, frames: { Frame }, options: any, env: Env): Dense
	local xField = frame.fields[1]
	local yFields: { Field } = {}
	for i, f in frame.fields do
		if i > 1 and f.type == "number" then
			table.insert(yFields, f)
		end
	end
	if #yFields == 0 then
		return { warning = "No numeric fields found for heatmap" } :: any
	end
	local rowsFrame = Json.obj(env, options.rowsFrame)
	local yAxis = Json.obj(env, options.yAxis)
	local scaleType = Json.str(env, Json.path(env, rowsFrame, "yBucketScale", "type"))
	local numeric = scaleType == "linear" or scaleType == "log"
	local firstLabels: { [string]: string } = yFields[1].labels or {}
	local fallback: Layout = if firstLabels.le ~= nil then "le" elseif firstLabels.ge ~= nil then "ge" else "unknown"
	local layout: Layout = layoutOf(Json.str(env, rowsFrame.layout), fallback)
	local labelKey: string? = if firstLabels.le ~= nil then "le" else Frame.labelKeys(firstLabels)[1]
	local xs: { number } = {}
	for _, v in xField.values do
		table.insert(xs, if type(v) == "number" then v else 0)
	end
	local nrows = #yFields
	local counts: { any } = table.create(#xs * nrows)
	for c = 1, #xs do
		for r, f in yFields do
			counts[(c - 1) * nrows + r] = f.values[c]
		end
	end
	local yUnit = Json.str(env, yAxis.unit)
	if yUnit == "" then
		yUnit = nil
	end
	local yDecimals = Json.num(env, yAxis.decimals)
	local valueCfg: Frame.FieldConfig = yFields[1].config or {}
	local dense: Dense = {
		cols = columns(xs, if xField.type == "time" then "le" else "unknown"),
		rows = {},
		x_time = xField.type == "time",
		y_kind = "ordinal",
		y_layout = layout,
		y_unit = yUnit,
		y_decimals = yDecimals,
		counts = counts,
		value_unit = valueCfg.unit,
		value_decimals = valueCfg.decimals,
	}
	if numeric then
		local bounds: { number } = table.create(nrows)
		for r, f in yFields do
			local lv = if labelKey and f.labels then f.labels[labelKey] else nil
			bounds[r] = M.sampleValue(lv or f.name)
		end
		local factor = bucketFactor(bounds, 1.5)
		for r = 1, nrows do
			local hi = if r < nrows then bounds[r + 1] else bounds[r] * factor
			dense.rows[r] = { bounds[r], hi }
		end
		dense.y_kind = if scaleType == "log" then "log" else "linear"
		dense.y_log = Json.num(env, Json.path(env, rowsFrame, "yBucketScale", "log")) or 2
		dense.y_layout = "ge"
		dense.y_unit = yUnit or valueCfg.unit
		return dense
	end
	local labels: { string } = table.create(nrows)
	for r, f in yFields do
		local name = nameOf(f, frame, frames)
		if yUnit or yDecimals ~= nil then
			local n = M.sampleValue(name)
			local plain = tonumber(name)
			if plain and n == n and n ~= math.huge and n ~= -math.huge then
				name = Format.text(n, yUnit or "short", yDecimals)
			end
		end
		labels[r] = name
		dense.rows[r] = edges(r - 1, 1, layout)
	end
	dense.y_labels = labels
	if labelKey == "le" then
		dense.y_min_label = if yUnit or yDecimals ~= nil then Format.text(0, yUnit or "short", yDecimals) else "0.0"
	end
	return dense
end

-- Dense heatmap-cells frames (isHeatmapCellsDense).
local function fromCells(frame: Frame, options: any, env: Env): Dense
	local xName: string?, yName: string? = nil, nil
	local xF: Field?, yF: Field?, valueF: Field? = nil, nil, nil
	for _, f in frame.fields do
		local n = f.name
		if n == "x" or n == "xMin" or n == "xMax" then
			xName, xF = n, f
		elseif n == "y" or n == "yMin" or n == "yMax" then
			if yName == nil then
				yName, yF = n, f
			end
		elseif f.type == "number" and valueF == nil then
			valueF = f
		end
	end
	if yF == nil then
		return { warning = "Missing Y field" } :: any
	elseif valueF == nil then
		return { warning = "Missing value field" } :: any
	end
	local xs = (xF or frame.fields[1]).values
	local ys = (yF :: Field).values
	local dlen = #xs
	local lastY = 1
	for i = dlen, 1, -1 do
		if ys[i] == ys[1] then
			lastY = i
			break
		end
	end
	local yBinQty = dlen - lastY + 1
	if yBinQty < 1 or dlen % yBinQty ~= 0 then
		return { warning = "Expected heatmap scanlines format" } :: any
	end
	local xBinQty = dlen // yBinQty
	local xLayout: Layout = if xName == "xMax" then "le" elseif xName == "xMin" then "ge" else "unknown"
	local yLayout: Layout = if yName == "yMax" then "le" elseif yName == "yMin" then "ge" else "unknown"
	local colXs: { number } = table.create(xBinQty)
	for c = 1, xBinQty do
		local v = xs[(c - 1) * yBinQty + 1]
		colXs[c] = if type(v) == "number" then v else 0
	end
	local rowYs: { number } = table.create(yBinQty)
	for r = 1, yBinQty do
		local v = ys[r]
		rowYs[r] = if type(v) == "number" then v else 0
	end
	local custom = if frame.meta then (frame.meta :: any).custom else nil
	local ordinal = if type(custom) == "table" and type(custom.yOrdinalDisplay) == "table"
		then custom.yOrdinalDisplay
		else nil
	local yAxis = Json.obj(env, options.yAxis)
	local yCfg: Frame.FieldConfig = (yF :: Field).config or {}
	local vCfg: Frame.FieldConfig = (valueF :: Field).config or {}
	local calcScale = Json.path(env, options, "calculation", "yBuckets", "scale")
	local log = if Json.str(env, Json.path(env, calcScale, "type")) == "log"
		then (Json.num(env, Json.path(env, calcScale, "log")) or 2)
		else nil
	local rows: { { number } } = table.create(yBinQty)
	local yIncr = if yBinQty >= 2 then rowYs[2] - rowYs[1] else 1
	for r, y in rowYs do
		if log then
			local nextY = if r < yBinQty then rowYs[r + 1] else y * (if r > 1 then y / rowYs[r - 1] else log)
			rows[r] = if yLayout == "le" then { y / (nextY / y), y } else { y, nextY }
		else
			rows[r] = edges(y, if yIncr ~= 0 then yIncr else 1, yLayout)
		end
	end
	return {
		cols = columns(colXs, xLayout),
		rows = rows,
		x_time = (xF or frame.fields[1]).type == "time",
		x_unit = if (xF or frame.fields[1]).config then ((xF or frame.fields[1]).config :: any).unit else nil,
		y_kind = if ordinal then "ordinal" elseif log then "log" else "linear",
		y_log = log,
		y_layout = yLayout,
		y_labels = ordinal,
		y_min_label = if type(custom) == "table" then custom.yMinDisplay else nil,
		y_unit = Json.str(env, yAxis.unit) or yCfg.unit,
		y_decimals = Json.num(env, yAxis.decimals) or yCfg.decimals,
		counts = (valueF :: Field).values,
		value_unit = vCfg.unit,
		value_decimals = vCfg.decimals,
	}
end

-- Calculation (calculateHeatmapFromData) ----------------------------------------

local function roundDecimals(v: number, dec: number): number
	local p = 10 ^ dec
	return math.floor(v * p * (1 + 2.220446049250313e-16) + 0.5) / p
end

local function guessDecimals(v: number): number
	local s = tostring(v)
	local frac = string.match(s, "%.(%d+)$")
	return if frac then #frac else 0
end

local ALL_MULTS = { 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5, 5.5, 6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5 }

local function genIncrs(base: number, minExp: number, maxExp: number): { number }
	local out: { number } = {}
	for exp = minExp, maxExp - 1 do
		local expa = math.abs(exp)
		local mag = roundDecimals(base ^ exp, expa)
		for _, m in ALL_MULTS do
			local incr = m * mag
			local dec = (if incr >= 0 and exp >= 0 then 0 else expa)
				+ (if exp >= guessDecimals(m) then 0 else guessDecimals(m))
			table.insert(out, roundDecimals(incr, dec))
		end
	end
	return out
end

local NICE_LINEAR: { number } = genIncrs(10, -16, 0)
for _, v in genIncrs(10, 0, 16) do
	if v % 1 == 0 then
		table.insert(NICE_LINEAR, v)
	end
end

local SEC, MIN, HOUR, DAY = 1000, 60000, 3600000, 86400000
local YEAR = 365 * DAY
-- stylua: ignore
local NICE_TIME: { number } = {
	1, 2, 4, 5, 10, 20, 25, 40, 50, 100, 200, 250, 400, 500,
	SEC, 2 * SEC, 4 * SEC, 5 * SEC, 10 * SEC, 15 * SEC, 20 * SEC, 30 * SEC,
	MIN, 2 * MIN, 4 * MIN, 5 * MIN, 10 * MIN, 15 * MIN, 20 * MIN, 30 * MIN,
	HOUR, 2 * HOUR, 4 * HOUR, 6 * HOUR, 8 * HOUR, 12 * HOUR, 18 * HOUR,
	DAY, 2 * DAY, 3 * DAY, 4 * DAY, 5 * DAY, 6 * DAY, 7 * DAY, 10 * DAY, 15 * DAY, 30 * DAY, 45 * DAY,
	60 * DAY, 90 * DAY, 180 * DAY,
	YEAR, 2 * YEAR, 3 * YEAR, 4 * YEAR, 5 * YEAR, 6 * YEAR, 7 * YEAR, 8 * YEAR, 9 * YEAR, 10 * YEAR,
}

-- The first increment above `approx`, one step down (findIndex - 1).
local function niceIncr(list: { number }, approx: number): number
	for i, v in list do
		if v > approx then
			return list[math.max(i - 1, 1)]
		end
	end
	return list[1]
end

-- convertDurationToMilliseconds.
local function durationMs(s: string?): number?
	if s == nil or s == "" then
		return nil
	end
	if string.match(s, "^%s*%d+%s*$") then
		return tonumber(s)
	end
	local d = Step.parseDuration(s)
	if d then
		return d
	end
	local ms = string.match(s, "(%d+)ms$")
	return if ms then tonumber(ms) else nil
end

function M.calculate(frames: { Frame }, options: any, env: Env, from_ms: number?, to_ms: number?): Dense
	local calc = Json.obj(env, options.calculation)
	local xb = Json.obj(env, calc.xBuckets)
	local yb = Json.obj(env, calc.yBuckets)
	local xs: { number }, ys: { number } = {}, {}
	local xField: Field?, yField: Field? = nil, nil
	for _, f in frames do
		local tf = Frame.timeField(f)
		if tf == nil then
			continue
		end
		xField = xField or tf
		for _, field in f.fields do
			if field ~= tf and field.type == "number" then
				yField = yField or field
				for i, x in tf.values do
					local y = field.values[i]
					if type(x) == "number" and type(y) == "number" and y == y then
						table.insert(xs, x)
						table.insert(ys, y)
					end
				end
			end
		end
	end
	if xField == nil or yField == nil or #xs == 0 then
		return { warning = "no heatmap fields found" } :: any
	end
	local xMode = Json.str(env, xb.mode) or "size"
	local yMode = Json.str(env, yb.mode) or "size"
	local yScaleType = Json.str(env, Json.path(env, yb, "scale", "type"))
	local yExp: number? = if yScaleType == "log" then (Json.num(env, Json.path(env, yb, "scale", "log")) or 2) else nil
	local xValue = Json.str(env, xb.value) or (if Json.num(env, xb.value) then tostring(xb.value) else nil)
	local yValue = Json.str(env, yb.value) or (if Json.num(env, yb.value) then tostring(yb.value) else nil)
	local xSize: number? = if xMode == "size" then durationMs(xValue) else tonumber(xValue or "")
	local ySize: number? = tonumber(yValue or "")
	local minX, maxX = from_ms or math.huge, to_ms or -math.huge
	local minY, maxY = math.huge, -math.huge
	for i = 1, #xs do
		if from_ms == nil or to_ms == nil then
			minX = math.min(minX, xs[i])
			maxX = math.max(maxX, xs[i])
		end
		if yExp == nil or ys[i] > 0 then
			minY = math.min(minY, ys[i])
			maxY = math.max(maxY, ys[i])
		end
	end
	local xIncr = xSize or 0
	local yIncr = ySize or 0
	if xIncr ~= xIncr or xIncr <= 0 or xIncr == math.huge then
		xMode = "count"
		xIncr = 20
	end
	if yIncr ~= yIncr or yIncr <= 0 or yIncr == math.huge then
		yMode = "count"
		yIncr = 10
	end
	if xMode == "count" then
		xIncr = niceIncr(NICE_TIME, (maxX - minX) / math.max(xIncr - 1, 1))
	end
	if yMode == "count" then
		yIncr = niceIncr(NICE_LINEAR, (maxY - minY) / math.max(yIncr - 1, 1))
	end
	local function binX(v: number): number
		return math.floor(v / xIncr) * xIncr
	end
	local binY = function(v: number): number
		return math.floor(v / yIncr) * yIncr
	end
	if yExp then
		yIncr = 1 / (ySize or 1)
		local base = yExp :: number
		binY = function(v: number): number
			return math.floor((math.log(v) / math.log(base)) / yIncr) * yIncr
		end
	end
	local minXBin, maxXBin = binX(minX), binX(maxX)
	local minYBin, maxYBin = binY(minY), binY(maxY)
	local xQty = math.floor((maxXBin - minXBin) / xIncr + 0.5) + 1
	local yQty = math.floor((maxYBin - minYBin) / yIncr + 0.5) + 1
	if xQty * yQty > 200000 then
		return { warning = "Too many heatmap buckets" } :: any
	end
	local counts: { any } = table.create(xQty * yQty, 0)
	for i = 1, #xs do
		if yExp and ys[i] <= 0 then
			continue
		end
		local xi = math.floor((binX(xs[i]) - minXBin) / xIncr + 0.5)
		local yi = math.floor((binY(ys[i]) - minYBin) / yIncr + 0.5)
		local ci = xi * yQty + yi + 1
		if ci >= 1 and ci <= #counts then
			counts[ci] += 1
		end
	end
	local cols: { { number } } = table.create(xQty)
	for c = 1, xQty do
		local x = minXBin + (c - 1) * xIncr
		cols[c] = { x, x + xIncr }
	end
	local rows: { { number } } = table.create(yQty)
	for r = 1, yQty do
		if yExp then
			local base = yExp :: number
			rows[r] = { base ^ (minYBin + (r - 1) * yIncr), base ^ (minYBin + r * yIncr) }
		else
			local y = minYBin + (r - 1) * yIncr
			rows[r] = { y, y + yIncr }
		end
	end
	local yCfg: Frame.FieldConfig = (yField :: Field).config or {}
	return {
		cols = cols,
		rows = rows,
		x_time = true,
		y_kind = if yExp then "log" else "linear",
		y_log = yExp,
		y_layout = "ge",
		y_unit = Json.str(env, Json.path(env, options, "yAxis", "unit")) or yCfg.unit,
		y_decimals = Json.num(env, Json.path(env, options, "yAxis", "decimals")) or yCfg.decimals,
		counts = counts,
		value_unit = "short",
	}
end

-- prepareHeatmapData ----------------------------------------------------------------

function M.dense(panel: any, frames: { Frame }, env: Env, from_ms: number?, to_ms: number?): Dense?
	local options = Json.obj(env, panel.options)
	local data: { Frame } = {}
	for _, f in frames do
		-- Exemplars are an annotation layer here, not buckets.
		if f.name ~= "exemplar" then
			table.insert(data, f)
		end
	end
	if #data == 0 then
		return nil
	end
	if Json.bool(env, options.calculate) == true then
		return M.calculate(data, options, env, from_ms, to_ms)
	end
	data = M.promHeatmap(panel, data, env)
	local rows: Frame? = nil
	for _, f in data do
		local kind = if f.meta then f.meta.type else nil
		if kind == "heatmap-cells" then
			return fromCells(f, options, env)
		elseif kind == "heatmap-rows" then
			rows = f
		end
	end
	if rows == nil then
		local withTime: { Frame } = {}
		for _, f in data do
			if Frame.timeField(f) then
				table.insert(withTime, f)
			end
		end
		if #withTime == 0 then
			return { warning = "No numeric fields found for heatmap" } :: any
		end
		if #withTime > 1 then
			local function nameNum(f: Frame): number
				local nf = numberField(f)
				return if nf then M.sampleValue(nameOf(nf, f, withTime)) else 0 / 0
			end
			local allNumeric = true
			for _, f in withTime do
				local n = nameNum(f)
				if n ~= n then
					allNumeric = false
				end
			end
			if allNumeric then
				withTime = table.clone(withTime)
				table.sort(withTime, function(a, b)
					return nameNum(a) < nameNum(b)
				end)
			end
			rows = Charts.joinByTime(withTime)
		else
			local f = withTime[1]
			local nums: { Field } = {}
			for _, field in f.fields do
				if field.type == "number" then
					table.insert(nums, field)
				end
			end
			local allNumeric = true
			for _, field in nums do
				local n = M.sampleValue(nameOf(field, f, withTime))
				if n ~= n then
					allNumeric = false
				end
			end
			if allNumeric then
				table.sort(nums, function(a, b)
					return M.sampleValue(nameOf(a, f, withTime)) < M.sampleValue(nameOf(b, f, withTime))
				end)
			end
			local fields: { Field } = { Frame.timeField(f) :: Field }
			for _, field in nums do
				table.insert(fields, field)
			end
			rows = { name = f.name, refId = f.refId, meta = f.meta, fields = fields }
		end
	end
	local r = rows :: Frame
	if #r.fields < 2 or #r.fields[1].values < 1 then
		return nil
	end
	return fromRows(r, data, options, env)
end

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
