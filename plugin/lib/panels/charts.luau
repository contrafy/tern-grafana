--!strict
-- Shared pieces of the chart panels (piechart, barchart, histogram, trend,
-- xychart, candlestick): panel size and range from the view options, series
-- color classes, Grafana's VizLegend (options.legend: showLegend,
-- displayMode list|table|hidden, placement bottom|right, calcs, and
-- custom.hideFrom.legend), the chart image node, and the time join the bar
-- chart and candlestick apply to multi-frame data (outerJoinDataFrames).

local Assets = require("../render/assets")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Grid = require("../render/grid")
local Json = require("./json")
local Reduce = require("./reduce")
local SvgXY = require("../render/svg_xy")
local Tbl = require("../tbl")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

-- The panel's design size in px: its gridPos size, else the view's.
function M.size(opts: Common.Options, w: number, h: number): (number, number)
	local s = opts.size
	if s then
		return s.w, s.h
	end
	return opts.width or w, opts.height or h
end

-- The panel's query range (after its time overrides), if known.
function M.range(opts: Common.Options): (number?, number?)
	local t = opts.time
	if t then
		return t.from_ms, t.to_ms
	end
	return opts.from_ms, opts.to_ms
end

-- SVG/swatch classes for a tone (panels.css tgp-fx pairs).
function M.toneClass(tone: string): string
	return "tgp-fx " .. Common.toneClass(tone :: any)
end

-- Classes for one displayed value: its palette class or its tone.
function M.displayClass(d: FieldConfig.Display): string
	return d.class or M.toneClass(d.tone)
end

-- Classes for a whole series (getFieldSeriesColor). Palette modes take the
-- k-th palette color: Grafana re-indexes the plotted fields
-- (setClassicPaletteIdxs), skipping x and hidden fields.
function M.seriesClass(item: Item, k: number, opts: Common.Options): string
	local mode = item.config.color_mode
	if mode == "palette-classic" or mode == "palette-classic-by-name" then
		return FieldConfig.paletteClass(k)
	end
	local c = FieldConfig.seriesColor(item, { theme = opts.theme })
	return c.class or M.toneClass(c.tone)
end

-- Whether Grafana colors each value of the field on its own (by-value
-- modes: thresholds and continuous schemes).
function M.byValue(item: Item): boolean
	local mode = item.config.color_mode
	return mode == "thresholds" or string.sub(mode, 1, 11) == "continuous-"
end

-- Legend ------------------------------------------------------------------------

export type Legend = {
	show: boolean,
	mode: "list" | "table",
	placement: "bottom" | "right",
	calcs: { string },
}

function M.legendOptions(panel: any, env: Env): Legend
	local raw = Json.tbl(env, Json.path(env, panel, "options", "legend"))
	local l = Json.obj(env, raw)
	local mode = Json.str(env, l.displayMode) or "list"
	local calcs: { string } = {}
	for _, c in Json.list(env, l.calcs) do
		if type(c) == "string" then
			table.insert(calcs, c)
		end
	end
	return {
		show = Json.bool(env, l.showLegend) ~= false and mode ~= "hidden",
		mode = if mode == "table" then "table" else "list",
		placement = if Json.str(env, l.placement) == "right" then "right" else "bottom",
		calcs = calcs,
	}
end

-- A legend reducer Tern cannot compute, as a reason.
function M.unsupportedLegend(panel: any, env: Env): string?
	for _, c in M.legendOptions(panel, env).calcs do
		if not Reduce.supports(c) then
			return string.format("legend reducer %s is not supported", c)
		end
	end
	return nil
end

export type Row = { class: string, name: string, values: { string } }

function M.hiddenFromLegend(item: Item): boolean
	local hideFrom = item.config.custom.hideFrom
	return type(hideFrom) == "table" and hideFrom.legend == true
end

-- A legend row per item with the legend's calcs over `values` (default the
-- field's own), formatted with the item's config.
function M.calcRow(item: Item, class: string, calcs: { string }, opts: Common.Options, values: { any }?): Row
	local vals = values or item.field.values
	local results = Reduce.calcs(vals, calcs, item.field.type, item.config.null_mode)
	local out: { string } = table.create(#calcs)
	for k, c in calcs do
		local v = results[c]
		out[k] = if v == nil
			then "-"
			else FieldConfig.joined(
				FieldConfig.display(item, v, { theme = opts.theme, offset_min = opts.offset_min })
			)
	end
	return { class = class, name = item.name, values = out }
end

-- The legend of calc rows: one column (or value) per reducer, named as
-- Grafana names them.
function M.calcLegend(key: string, rows: { Row }, legend: Legend): Node
	local heads: { string } = table.create(#legend.calcs)
	for i, c in legend.calcs do
		heads[i] = Reduce.name(c)
	end
	return M.legend(key, rows, heads, legend.mode)
end

local function swatch(class: string): Node
	return { k = "el", p = { tag = "span", class = "tg-swatch " .. class } }
end

-- VizLegend: a wrapping list (name, then the values in bold) or a table
-- with a column per value heading.
function M.legend(key: string, rows: { Row }, heads: { string }, mode: "list" | "table"): Node
	if mode == "table" then
		local columns: { Grid.Column } = { { head = "Name" } }
		for _, h in heads do
			table.insert(columns, { head = h, numeric = true })
		end
		local gridRows: { Grid.Row } = table.create(#rows)
		for i, r in rows do
			local cells: { Node } = {
				{ k = "row", p = { gap = "xs", align = "center" }, c = { swatch(r.class), Grid.text(r.name) } },
			}
			for _, v in r.values do
				table.insert(cells, Grid.text(v))
			end
			gridRows[i] = { key = "s" .. i, cells = cells }
		end
		return Grid.grid(key, columns, gridRows, "tern-grafana.legend")
	end
	local entries: { Node } = table.create(#rows)
	for i, r in rows do
		local spans: { ui.SpanLike } = { r.name }
		if #r.values > 0 then
			table.insert(spans, ui.span(" " .. table.concat(r.values, " "), "strong"))
		end
		entries[i] = {
			k = "row",
			p = { key = "s" .. i, gap = "xs", align = "center" },
			c = { swatch(r.class), ui.text(spans) },
		}
	end
	return { k = "row", p = { key = key, gap = "md", wrap = true, role = "tern-grafana.legend" }, c = entries }
end

-- Chart node -------------------------------------------------------------------

-- The SVG as an `image` node and its asset (keyed by `key`).
function M.image(key: string, svg: string, w: number, h: number, alt: string, role: string): (Node, Assets.Assets)
	local node: Node = {
		k = "image",
		p = { key = key, asset = key, w = math.floor(w + 0.5), h = math.floor(h + 0.5), alt = alt, role = role },
	}
	return node, { [key] = { mime = Assets.SVG, bytes = svg } }
end

-- The chart with its legend under it or to its right, and notes after.
function M.compose(key: string, chart: Node, legend: Node?, placement: "bottom" | "right", notes: { string }?): Node
	local body: Node = chart
	if legend then
		if placement == "right" then
			body = { k = "row", p = { key = key .. ".body", gap = "sm", align = "center" }, c = { chart, legend } }
		else
			body = { k = "col", p = { key = key .. ".body", gap = "xs" }, c = { chart, legend } }
		end
	end
	if notes == nil or #notes == 0 then
		if body == chart then
			return { k = "col", p = { key = key .. ".panel", gap = "xs" }, c = { chart } }
		end
		return body
	end
	local children: { Node } = { body }
	for i, n in notes :: { string } do
		table.insert(children, ui.muted(n, { key = "note" .. i }))
	end
	return { k = "col", p = { key = key .. ".panel", gap = "xs" }, c = children }
end

-- The panel title as the image's alt text.
function M.alt(panel: any, env: Env, fallback: string): string
	local title = Json.str(env, Json.path(env, panel, "title"))
	return if title and title ~= "" then title else fallback
end

-- A Grafana panel warning shown in place of the chart (PanelDataErrorView
-- with a message).
function M.message(key: string, text: string): Node
	return ui.muted(text, { key = key })
end

-- Data -------------------------------------------------------------------------

-- outerJoinDataFrames on each frame's first time field: one frame with the
-- union of times (ascending) and every other field, NULL where a frame has
-- no row at that time. Field display names are computed over the input
-- frames and kept (keepDisplayNames), so "A Value" stays apart from
-- "B Value". Frames without a time field are left out.
function M.joinByTime(frames: { Frame }): Frame
	local seen: { [number]: boolean } = {}
	local times: { number } = {}
	for _, f in frames do
		local tf = Frame.timeField(f)
		if tf then
			for _, t in tf.values do
				if type(t) == "number" and not seen[t] then
					seen[t] = true
					table.insert(times, t)
				end
			end
		end
	end
	table.sort(times)
	local index: { [number]: number } = {}
	for i, t in times do
		index[t] = i
	end
	local fields: { Frame.Field } = { Frame.field("Time", "time", times) }
	for _, f in frames do
		local tf = Frame.timeField(f)
		if tf == nil then
			continue
		end
		for _, field in f.fields do
			if field == tf then
				continue
			end
			local values: { any } = table.create(#times, Frame.NULL)
			for r, t in tf.values do
				local at = if type(t) == "number" then index[t] else nil
				if at then
					values[at] = field.values[r]
				end
			end
			local config: Frame.FieldConfig = if field.config then Tbl.copy(field.config) else {}
			config.displayName = FieldConfig.displayName(field, f, frames)
			table.insert(fields, Frame.field(field.name, field.type, values, field.labels, config))
		end
	end
	return { fields = fields, refId = frames[1] and frames[1].refId }
end

-- The frame sorted by its first time field (maybeSortFrame), unchanged when
-- already ascending.
function M.sortByTime(frame: Frame): Frame
	local tf = Frame.timeField(frame)
	if tf == nil then
		return frame
	end
	local tv = tf.values
	local sorted = true
	for i = 2, #tv do
		if type(tv[i]) == "number" and type(tv[i - 1]) == "number" and tv[i] < tv[i - 1] then
			sorted = false
			break
		end
	end
	if sorted then
		return frame
	end
	local order: { number } = table.create(#tv)
	for i = 1, #tv do
		order[i] = i
	end
	table.sort(order, function(a, b)
		local ta, tb = tv[a], tv[b]
		ta = if type(ta) == "number" then ta else math.huge
		tb = if type(tb) == "number" then tb else math.huge
		if ta == tb then
			return a < b
		end
		return ta < tb
	end)
	local fields: { Frame.Field } = table.create(#frame.fields)
	for i, field in frame.fields do
		local values: { any } = table.create(#order)
		for k, r in order do
			values[k] = field.values[r]
		end
		fields[i] = Frame.field(field.name, field.type, values, field.labels, field.config)
	end
	return { name = frame.name, refId = frame.refId, meta = frame.meta, fields = fields }
end

-- The field named `name` (display name or field name; findField).
function M.findItem(items: { Item }, name: string?): Item?
	if name == nil or name == "" then
		return nil
	end
	for _, item in items do
		if item.name == name then
			return item
		end
	end
	for _, item in items do
		if item.field.name == name then
			return item
		end
	end
	return nil
end

-- Graph field config ------------------------------------------------------------

local function num(v: any): number?
	return if type(v) == "number" and v == v then v else nil
end

-- GraphFieldConfig (packages/grafana-schema common.gen.ts) of one series as
-- a lib/render/svg_xy line: drawStyle line|bars|points, lineWidth (1),
-- fillOpacity (0), spanNulls (true joins gaps), showPoints auto|always|never
-- with pointSize (5), lineStyle dash|dot. Auto points follow uPlot: shown
-- when samples are at least twice its default point diameter apart
-- (points.space), never on bars.
function M.graphLine(item: Item, class: string, xs: { number }, ys: { any }, plotW: number): SvgXY.Line
	local c = item.config.custom
	local draw = if type(c.drawStyle) == "string" then c.drawStyle else "line"
	local width = num(c.lineWidth) or 1
	local fill = (num(c.fillOpacity) or 0) / 100
	local pointSize = num(c.pointSize) or 5
	local showPoints = if type(c.showPoints) == "string" then c.showPoints else "auto"
	local points: number? = nil
	if draw == "points" or showPoints == "always" then
		points = pointSize
	elseif showPoints == "auto" and draw == "line" and #xs > 1 then
		local space = 2 * (3 + 2 * math.max(1, width))
		if plotW / (#xs - 1) >= space then
			points = pointSize
		end
	end
	local dash: string? = nil
	local style = c.lineStyle
	if type(style) == "table" and (style.fill == "dash" or style.fill == "dot") then
		local parts: { string } = {}
		if type(style.dash) == "table" then
			for _, d in style.dash do
				if type(d) == "number" then
					table.insert(parts, tostring(d))
				end
			end
		end
		if #parts == 0 then
			parts = if style.fill == "dot" then { "0", "10" } else { "10", "10" }
		end
		dash = table.concat(parts, " ")
	end
	return {
		class = class,
		xs = xs,
		ys = ys,
		width = if draw == "points" then 0 else width,
		dash = dash,
		fill_opacity = fill,
		points = points,
		connect = c.spanNulls == true,
		bars = draw == "bars",
	}
end

-- The y axis options of a series' field config (AxisConfig): placement
-- (hidden, right), label, soft bounds, grid.
function M.yAxis(cfg: FieldConfig.Config): (string, string?, number?, number?, boolean)
	local c = cfg.custom
	local placement = if c.axisPlacement == "hidden" or c.axisPlacement == "right" then c.axisPlacement else "left"
	local label = if type(c.axisLabel) == "string" and c.axisLabel ~= "" then c.axisLabel else nil
	return placement, label, num(c.axisSoftMin), num(c.axisSoftMax), c.axisGridShow ~= false
end

return M
