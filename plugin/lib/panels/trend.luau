--!strict
-- The trend panel (public/app/plugins/panel/trend: TrendPanel.tsx,
-- utils.ts prepSeries, panelcfg.cue): a time series panel whose x axis is
-- a number field, drawn by lib/render/svg_xy.
-- - one frame only (Grafana's "Only one frame is supported, consider adding
--   a join transformation"); x is options.xField (display or field name),
--   else the first number field, and must ascend;
-- - every other number field not hidden from the viz is a series with its
--   GraphFieldConfig (lib/panels/charts graphLine), palette colors indexed
--   over the plotted fields (x skipped), stacking normal|percent;
-- - fieldConfig unit, decimals, min, max, thresholdsStyle, axis placement,
--   label, soft bounds and grid; the x axis uses the x field's unit and
--   decimals over the data's exact range; legend with calcs.
-- Per-series stacking and per-series units are unsupported: svg_xy draws
-- one stack on one y axis (lib/panels/timeseries singleAxisUnsupported).

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local Series = require("../render/series")
local SvgKit = require("../render/svg_kit")
local SvgXY = require("../render/svg_xy")
local Timeseries = require("./timeseries")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

M.types = { "trend" }

M.WIDTH = 960
M.HEIGHT = 300

function M.supports(panel: any, env: Env): (boolean, string?)
	local why = Timeseries.singleAxisUnsupported(panel, env)
	if why then
		return false, why
	end
	return true, nil
end

export type Prepared = { x: Item, series: { Item } }

-- prepSeries: the x field and the plotted fields, or Grafana's warning.
function M.prepare(panel: any, frames: { Frame }, env: Env): (Prepared?, string?)
	if #frames > 1 then
		return nil, "Only one frame is supported, consider adding a join transformation"
	end
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "palette-classic" })
	local xName = Json.str(env, Json.path(env, panel, "options", "xField"))
	local x: Item? = nil
	if xName and xName ~= "" then
		x = Charts.findItem(items, xName)
		if x == nil then
			return nil, "Unable to find field: " .. xName
		end
	else
		for _, item in items do
			if item.field.type == "number" then
				x = item
				break
			end
		end
		if x == nil then
			return nil, "No numeric fields found for X axis"
		end
	end
	local xi = x :: Item
	if xi.field.type == "number" then
		local prev: number? = nil
		for _, v in xi.field.values do
			local n = Frame.finite(v)
			if n then
				if prev and n < (prev :: number) then
					return nil, "Values must be in ascending order"
				end
				prev = n
			end
		end
	end
	local series: { Item } = {}
	for _, item in items do
		if item ~= xi and item.field.type == "number" and not FieldConfig.hidden(item) then
			table.insert(series, item)
		end
	end
	return { x = xi, series = series }, nil
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	if not Common.hasData(frames) then
		return Common.noData(panel, env, opts.key), {}
	end
	local prep, warn = M.prepare(panel, frames, env)
	if prep == nil then
		return Charts.message(opts.key, warn or Common.noDataText(panel, env)), {}
	end
	local p = prep :: Prepared
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local xs: { number } = {}
	local keep: { number } = {}
	for r, v in p.x.field.values do
		local n = Frame.finite(v)
		if n then
			table.insert(xs, n)
			table.insert(keep, r)
		end
	end
	local function column(item: Item): { any }
		local out: { any } = table.create(#keep)
		for k, r in keep do
			local v = item.field.values[r]
			out[k] = if v == nil then Frame.NULL else v
		end
		return out
	end
	local base = FieldConfig.defaults(panel, env, { color_mode = "palette-classic" })
	local stackMode = Json.str(env, Json.path(env, base.custom.stacking, "mode"))
	local columns: { { any } } = table.create(#p.series)
	for k, item in p.series do
		columns[k] = column(item)
	end
	local tops: { { any } }, bottoms: { { number } }? = columns, nil
	if stackMode == "normal" or stackMode == "percent" then
		local t, b = Series.stack(columns, stackMode)
		tops, bottoms = t, b
	end
	local lines: { SvgXY.Line } = table.create(#p.series)
	local classes: { string } = table.create(#p.series)
	for k, item in p.series do
		classes[k] = Charts.seriesClass(item, k, opts)
		local line = Charts.graphLine(item, classes[k], xs, tops[k], W)
		if bottoms then
			line.bottoms = bottoms[k]
		end
		lines[k] = line
	end
	local first = if #p.series > 0 then p.series[1].config else base
	local side, label, softMin, softMax, grid = Charts.yAxis(first)
	local xSide, xLabel = Charts.yAxis(p.x.config)
	local thresholdMode = Json.str(env, Json.path(env, first.custom.thresholdsStyle, "mode"))
	local percent = stackMode == "percent"
	local result = SvgXY.render({
		width = W,
		height = H,
		x_unit = p.x.config.unit,
		x_decimals = p.x.config.decimals,
		x_min = p.x.config.min,
		x_max = p.x.config.max,
		x_axis = xSide ~= "hidden",
		x_label = xLabel,
		y_unit = if percent then "percentunit" else first.unit,
		y_decimals = first.decimals,
		y_min = if percent then 0 else first.min,
		y_max = if percent then 1 else first.max,
		y_soft_min = softMin,
		y_soft_max = softMax,
		y_side = side,
		y_label = label,
		grid = grid,
		thresholds = first.thresholds,
		threshold_style = SvgKit.thresholdStyle(thresholdMode),
		lines = lines,
	})
	local chart, assets =
		Charts.image(opts.key, result.svg, W, H, Charts.alt(panel, env, "Trend chart"), "tern-grafana.trend")
	local legend = Charts.legendOptions(panel, env)
	local legendNode: Node? = nil
	if legend.show then
		local rows: { Charts.Row } = {}
		for k, item in p.series do
			if not Charts.hiddenFromLegend(item) then
				table.insert(rows, Charts.calcRow(item, classes[k], legend.calcs, opts))
			end
		end
		legendNode = Charts.calcLegend(opts.key .. ".legend", rows, legend)
	end
	return Charts.compose(opts.key, chart, legendNode, legend.placement), assets
end

return M
