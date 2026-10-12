--!strict
-- The XY chart panel (public/app/plugins/panel/xychart, the v2 options of
-- Grafana 11.3+: utils.ts prepSeries, scatter.ts prepConfig/prepData,
-- panelcfg.cue) drawn by lib/render/svg_xy:
-- - options.mapping auto|manual and options.series: per series config the
--   frame (byIndex), x, y, color and size field matchers (lib/panels/
--   fieldconfig matchers; x and y default to number fields); in auto mode
--   every other number field of each frame is a y series (skipping the
--   color and size fields), in manual mode one series per config;
-- - names: series name.fixed, else the y display name with the words
--   common to every series name trimmed (autoNameSeries);
-- - show points|lines|points+lines, pointSize.fixed (5), lineWidth (2),
--   lineStyle, fillOpacity (50, the marker fill), pointShape circle|square;
-- - a size field scales marker area between pointSize.min (5) and max
--   (100) over the size values of every series; a color field colors each
--   point by its own color scheme over the color values' range; otherwise
--   palette colors in series order or the y field's fixed color;
-- - axis labels: custom.axisLabel, else the x (y) display name when one
--   series or all share it.

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local SvgXY = require("../render/svg_xy")
local Tbl = require("../tbl")
local Thresholds = require("../units/thresholds")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

M.types = { "xychart" }

M.WIDTH = 960
M.HEIGHT = 300

function M.supports(panel: any, env: Env): (boolean, string?)
	local options = Json.obj(env, Json.path(env, panel, "options"))
	if options.mapping == nil and (options.seriesMapping ~= nil or options.dims ~= nil) then
		return false, "the XY chart options from before Grafana 11.3 (seriesMapping, dims) are not supported"
	end
	local why = Charts.unsupportedLegend(panel, env)
	if why then
		return false, why
	end
	return true, nil
end

export type XYSeries = {
	name: string,
	x: Item,
	y: Item,
	color: Item?,
	size: Item?,
	size_min: number,
	size_max: number,
	size_fixed: number,
	show_points: boolean,
	show_line: boolean,
	line_width: number,
	dash: string?,
	fill: number,
	square: boolean,
	-- Whole-series color class (no color field).
	class: string,
}

local function num(v: any): number?
	return if type(v) == "number" and v == v then v else nil
end

-- findCommonPrefixSuffixLengths over word lists.
local function commonAffixes(names: { { string } }): (number, number)
	local prefix, suffix = math.huge, math.huge
	local shortest = names[1]
	for i = 2, #names do
		if #names[i] < #shortest then
			shortest = names[i]
		end
	end
	for i = 2, #names do
		local segs = names[i]
		if segs ~= shortest then
			local pre = 0
			for j = 1, #shortest do
				if segs[j] == shortest[j] then
					pre += 1
				else
					break
				end
			end
			prefix = math.min(prefix, pre)
			local suf = 0
			for j = #shortest, 1, -1 do
				-- Same index on both sides, as Grafana compares them.
				if segs[j] == shortest[j] then
					suf += 1
				else
					break
				end
			end
			suffix = math.min(suffix, suf)
		end
	end
	return prefix, suffix
end

local function words(s: string): { string }
	local out: { string } = {}
	for w in string.gmatch(s, "%S+") do
		table.insert(out, w)
	end
	return out
end

-- autoNameSeries: strip the words every name shares at either end.
local function autoName(series: { XYSeries })
	if #series < 2 then
		return
	end
	local names: { { string } } = table.create(#series)
	for i, s in series do
		names[i] = words(s.name)
	end
	local prefix, suffix = commonAffixes(names)
	if prefix == math.huge and suffix == math.huge then
		return
	end
	for i, s in series do
		local w = names[i]
		local stop = #w - (if suffix == math.huge then 0 else suffix)
		local start = (if prefix == math.huge then 0 else prefix) + 1
		local kept: { string } = {}
		for j = start, stop do
			table.insert(kept, w[j])
		end
		s.name = table.concat(kept, " ")
	end
end

-- prepSeries.
function M.series(panel: any, frames: { Frame }, env: Env): { XYSeries }
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local mapping = if Json.str(env, options.mapping) == "manual" then "manual" else "auto"
	local configs: { any } = Json.list(env, options.series)
	if #configs == 0 then
		configs = { {} }
	end
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "palette-classic" })
	local byFrame: { [Frame]: { Item } } = {}
	for _, item in items do
		local list = byFrame[item.frame]
		if list == nil then
			list = {}
			byFrame[item.frame] = list
		end
		table.insert(list :: { Item }, item)
	end
	local numberMatcher = { id = "byType", options = "number" }
	local out: { XYSeries } = {}
	for _, raw in configs do
		local cfg = Json.obj(env, raw)
		local frameMatcher = Json.obj(env, Json.path(env, cfg, "frame", "matcher"))
		local xm = Json.path(env, cfg, "x", "matcher")
		local ym = Json.path(env, cfg, "y", "matcher")
		if
			mapping == "manual"
			and (Json.tbl(env, Json.path(env, cfg, "frame", "matcher")) == nil or xm == nil or ym == nil)
		then
			continue
		end
		local xMatch = FieldConfig.matcherFor(env, xm or numberMatcher)
		local yMatch = FieldConfig.matcherFor(env, ym or numberMatcher)
		local cm = Json.path(env, cfg, "color", "matcher")
		local sm = Json.path(env, cfg, "size", "matcher")
		local colorMatch = if cm then FieldConfig.matcherFor(env, cm) else nil
		local sizeMatch = if sm then FieldConfig.matcherFor(env, sm) else nil
		local fixedName = Json.str(env, Json.path(env, cfg, "name", "fixed"))
		local frameIndex: number? = nil
		if Json.str(env, frameMatcher.id) == "byIndex" then
			frameIndex = Json.num(env, frameMatcher.options)
		end
		for fi, frame in frames do
			if frameIndex ~= nil and fi - 1 ~= frameIndex then
				continue
			end
			if Json.tbl(env, Json.path(env, cfg, "frame")) and frameIndex == nil then
				-- Only byIndex frame matchers exist (getFrameMatcher2).
				continue
			end
			local fitems: { Item } = byFrame[frame] or {}
			local numTime: { Item } = {}
			for _, item in fitems do
				if item.field.type == "number" or item.field.type == "time" then
					table.insert(numTime, item)
				end
			end
			local x: Item? = nil
			for _, item in numTime do
				if xMatch and xMatch(item.field, frame, frames) then
					x = item
					break
				end
			end
			if x == nil then
				continue
			end
			local color: Item?, size: Item? = nil, nil
			for _, item in numTime do
				if item.field.type == "number" then
					if color == nil and colorMatch and colorMatch(item.field, frame, frames) then
						color = item
					end
					if size == nil and sizeMatch and sizeMatch(item.field, frame, frames) then
						size = item
					end
				end
			end
			local added = 0
			for _, item in numTime do
				if item.field.type ~= "number" or item == x then
					continue
				end
				if mapping == "auto" and (item == color or item == size) then
					continue
				end
				if mapping == "manual" and added > 0 then
					continue
				end
				if not (yMatch and yMatch(item.field, frame, frames)) then
					continue
				end
				local hideFrom = item.config.custom.hideFrom
				if type(hideFrom) == "table" and hideFrom.viz == true then
					continue
				end
				local c = item.config.custom
				local show = if type(c.show) == "string" then c.show else "points"
				local pointSize = if type(c.pointSize) == "table" then c.pointSize else {}
				local sizeCfg = if size then (size :: Item).config.custom.pointSize else nil
				local dash: string? = nil
				local style = c.lineStyle
				if type(style) == "table" and (style.fill == "dash" or style.fill == "dot") then
					dash = if style.fill == "dot" then "0 10" else "10 10"
				end
				table.insert(out, {
					name = fixedName or item.name,
					x = x :: Item,
					y = item,
					color = color,
					size = size,
					size_min = num(if type(sizeCfg) == "table" then sizeCfg.min else nil) or 5,
					size_max = num(if type(sizeCfg) == "table" then sizeCfg.max else nil) or 100,
					size_fixed = num(pointSize.fixed) or 5,
					show_points = show ~= "lines",
					show_line = show ~= "points",
					line_width = num(c.lineWidth) or 2,
					dash = dash,
					fill = (num(c.fillOpacity) or 50) / 100,
					square = c.pointShape == "square",
					class = "",
				})
				added += 1
			end
		end
	end
	-- Fallback colors by series order: palette, or the y field's fixed color.
	local paletteIdx = 0
	for _, s in out do
		local mode = s.y.config.color_mode
		if mode == "palette-classic" or mode == "palette-classic-by-name" then
			paletteIdx += 1
			s.class = FieldConfig.paletteClass(paletteIdx)
		else
			s.class = Charts.toneClass(Thresholds.tone(s.y.config.fixed_color))
		end
	end
	autoName(out)
	return out
end

local function axisLabel(custom: { [string]: any }, names: { string }, single: string?): string?
	local own = custom.axisLabel
	if type(own) == "string" and own ~= "" then
		return own
	end
	if #names == 0 then
		return nil
	end
	if single then
		return single
	end
	for i = 2, #names do
		if names[i] ~= names[1] then
			return nil
		end
	end
	return if names[1] ~= "" then names[1] else nil
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	if not Common.hasData(frames) then
		return Common.noData(panel, env, opts.key), {}
	end
	local list = M.series(panel, frames, env)
	if #list == 0 then
		return Charts.message(opts.key, "No data"), {}
	end
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	-- Global size and color ranges (getGlobalRanges).
	local sLo, sHi, cLo, cHi = math.huge, -math.huge, math.huge, -math.huge
	for _, s in list do
		if s.size then
			for _, v in (s.size :: Item).field.values do
				local n = Frame.finite(v)
				if n then
					sLo, sHi = math.min(sLo, n), math.max(sHi, n)
				end
			end
		end
		if s.color then
			for _, v in (s.color :: Item).field.values do
				local n = Frame.finite(v)
				if n then
					cLo, cHi = math.min(cLo, n), math.max(cHi, n)
				end
			end
		end
	end
	local scatters: { SvgXY.Scatter } = {}
	local lines: { SvgXY.Line } = {}
	for _, s in list do
		local xs: { number } = {}
		local ys: { any } = {}
		local rows: { number } = {}
		for r, xv in s.x.field.values do
			local xn = Frame.finite(xv)
			if xn then
				table.insert(xs, xn)
				local yv = s.y.field.values[r]
				table.insert(ys, if yv == nil then Frame.NULL else yv)
				table.insert(rows, r)
			end
		end
		if s.show_line then
			table.insert(lines, {
				class = s.class,
				xs = xs,
				ys = ys,
				width = s.line_width,
				dash = s.dash,
			})
		end
		if s.show_points then
			local sc: SvgXY.Scatter = {
				class = s.class,
				xs = xs,
				ys = ys,
				size = s.size_fixed,
				square = s.square,
				opacity = s.fill,
			}
			if s.size then
				local sizeItem = s.size :: Item
				local minPx, maxPx = s.size_min ^ 2, s.size_max ^ 2
				local span = sHi - sLo
				local sizes: { number } = table.create(#rows)
				for k, r in rows do
					local v = Frame.finite(sizeItem.field.values[r])
					local pct = if v and span > 0 then (v - sLo) / span else 0
					sizes[k] = math.sqrt(minPx + pct * (maxPx - minPx))
				end
				sc.sizes = sizes
			end
			if s.color then
				local colorItem = Tbl.copy(s.color :: Item)
				colorItem.range_min, colorItem.range_max = cLo, cHi
				local classes: { string } = table.create(#rows)
				for k, r in rows do
					local d = FieldConfig.display(colorItem, colorItem.field.values[r], { theme = opts.theme })
					classes[k] = Charts.displayClass(d)
				end
				sc.classes = classes
			end
			table.insert(scatters, sc)
		end
	end
	local first = list[1]
	local xNames: { string } = {}
	local yNames: { string } = {}
	for _, s in list do
		table.insert(xNames, s.x.name)
		table.insert(yNames, s.y.name)
	end
	local ySide, _, softMin, softMax, grid = Charts.yAxis(first.y.config)
	local xSide, _, xSoftMin, xSoftMax = Charts.yAxis(first.x.config)
	local result = SvgXY.render({
		width = W,
		height = H,
		x_time = first.x.field.type == "time",
		offset_min = opts.offset_min,
		x_unit = first.x.config.unit,
		x_decimals = first.x.config.decimals,
		x_min = first.x.config.min or xSoftMin,
		x_max = first.x.config.max or xSoftMax,
		x_padded = true,
		x_axis = xSide ~= "hidden",
		x_label = axisLabel(first.x.config.custom, xNames, if #list == 1 then first.x.name else nil),
		y_unit = first.y.config.unit,
		y_decimals = first.y.config.decimals,
		y_min = first.y.config.min,
		y_max = first.y.config.max,
		y_soft_min = softMin,
		y_soft_max = softMax,
		y_side = ySide,
		y_label = axisLabel(first.y.config.custom, yNames, if #list == 1 then first.y.name else nil),
		grid = grid,
		lines = lines,
		scatters = scatters,
	})
	local chart, assets =
		Charts.image(opts.key, result.svg, W, H, Charts.alt(panel, env, "XY chart"), "tern-grafana.xychart")
	local legend = Charts.legendOptions(panel, env)
	local legendNode: Node? = nil
	if legend.show then
		local rows: { Charts.Row } = {}
		for _, s in list do
			if not Charts.hiddenFromLegend(s.y) then
				local row = Charts.calcRow(s.y, s.class, legend.calcs, opts)
				row.name = s.name
				table.insert(rows, row)
			end
		end
		legendNode = Charts.calcLegend(opts.key .. ".legend", rows, legend)
	end
	return Charts.compose(opts.key, chart, legendNode, legend.placement), assets
end

return M
