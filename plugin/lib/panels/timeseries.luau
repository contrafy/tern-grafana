--!strict
-- The time series panel (public/app/plugins/panel/timeseries: panelcfg.cue,
-- packages/grafana-schema common GraphFieldConfig) mapped onto
-- lib/render/svg_timeseries:
-- - fieldConfig.defaults unit, decimals, min, max, thresholds;
-- - custom.drawStyle line|bars|points, fillOpacity, spanNulls (true
--   connects; false or a gap threshold keeps gaps), stacking.mode
--   none|normal|percent, thresholdsStyle.mode (off, line, dashed, area,
--   line+area, dashed+area; "series" colors by value, drawn as off);
-- - overrides (lib/panels/fieldconfig) for display names, colors and
--   hidden series (custom.hideFrom.viz);
-- - series colors: palette-classic keeps the chart palette; fixed and
--   by-value modes (thresholds, continuous) paint the whole series in the
--   tone of its `seriesBy` value (getFieldSeriesColor);
-- - options.legend: showLegend, displayMode list|table|hidden, calcs (any
--   lib/panels/reduce reducer, formatted with the series' own config).
-- Per-series stacking and per-series units (a second y axis) are reported
-- as unsupported: one SVG has one stack and one axis.

local Assets = require("../render/assets")
local ChartView = require("../render/chart_view")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Grid = require("../render/grid")
local Json = require("./json")
local Reduce = require("./reduce")
local SvgTimeseries = require("../render/svg_timeseries")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

local M = {}

M.WIDTH = 960
M.HEIGHT = 300

local function legendCalcs(panel: any, env: Env): { string }
	local out: { string } = {}
	for _, c in Json.list(env, Json.path(env, panel, "options", "legend", "calcs")) do
		if type(c) == "string" then
			table.insert(out, c)
		end
	end
	return out
end

function M.unsupported(panel: any, env: Env): string?
	local defaultsUnit = Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "unit"))
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		for _, p in Json.list(env, Json.path(env, o, "properties")) do
			local id = Json.str(env, Json.path(env, p, "id"))
			local value = Json.path(env, p, "value")
			if id == "custom.stacking" then
				return "per-series stacking (custom.stacking override) is not supported"
			elseif id == "unit" and Json.str(env, value) ~= defaultsUnit then
				return "a per-series unit override (second y axis) is not supported"
			end
		end
	end
	for _, c in legendCalcs(panel, env) do
		if not Reduce.supports(c) then
			return string.format("legend reducer %s is not supported", c)
		end
	end
	return nil
end

local THRESHOLD_STYLES: { [string]: SvgTimeseries.ThresholdStyle } = {
	line = "line",
	dashed = "line",
	area = "area",
	["line+area"] = "line+area",
	["dashed+area"] = "line+area",
}

-- `s` with every plain occurrence of `from` replaced by `to`.
local function replacePlain(s: string, from: string, to: string): string
	local out: { string } = {}
	local i = 1
	while true do
		local a, b = string.find(s, from, i, true)
		if a == nil or b == nil then
			break
		end
		table.insert(out, string.sub(s, i, a - 1))
		table.insert(out, to)
		i = b + 1
	end
	table.insert(out, string.sub(s, i))
	return table.concat(out)
end

type Drawn = { item: FieldConfig.Item, class: string }

local function swatch(class: string): Node
	return { k = "el", p = { tag = "span", class = "tg-swatch " .. class } }
end

local function legendView(
	key: string,
	drawn: { Drawn },
	calcs: { string },
	mode: string,
	dropped: number,
	opts: Common.Options
): Node
	local rows: { { class: string, name: string, values: { string } } } = {}
	for i, d in drawn do
		local item = d.item
		local results = Reduce.calcs(item.field.values, calcs, item.field.type, item.config.null_mode)
		local values: { string } = {}
		for k, c in calcs do
			local v = results[c]
			values[k] = if v == nil
				then "-"
				else FieldConfig.joined(
					FieldConfig.display(item, v, { theme = opts.theme, offset_min = opts.offset_min })
				)
		end
		rows[i] = { class = d.class, name = item.name, values = values }
	end
	local children: { Node } = {}
	if mode == "table" then
		local columns: { Grid.Column } = { { head = "Name" } }
		for _, c in calcs do
			table.insert(columns, { head = Reduce.name(c), numeric = true })
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
		table.insert(children, Grid.grid(key .. ".t", columns, gridRows, "tern-grafana.legend"))
	else
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
		table.insert(children, {
			k = "row",
			p = { key = key .. ".l", gap = "md", wrap = true, role = "tern-grafana.legend" },
			c = entries,
		})
	end
	if dropped > 0 then
		table.insert(
			children,
			ui.muted(string.format("%d more series not shown (chart limit %d)", dropped, #drawn), { key = "dropped" })
		)
	end
	return { k = "col", p = { key = key, gap = "xs" }, c = children }
end

-- The SVG render options a panel maps to (exposed for specs and the
-- dashboard's PNG-vs-native decisions).
function M.renderOptions(panel: any, env: Env, opts: Common.Options): SvgTimeseries.Options
	local cfg = FieldConfig.defaults(panel, env, { color_mode = "palette-classic" })
	local custom = cfg.custom
	local draw: SvgTimeseries.Draw = "line"
	if custom.drawStyle == "bars" then
		draw = "bars"
	elseif custom.drawStyle == "points" then
		draw = "points"
	end
	local stackMode = Json.str(env, Json.path(env, custom.stacking, "mode"))
	local thresholdMode = Json.str(env, Json.path(env, custom.thresholdsStyle, "mode")) or "off"
	local style: SvgTimeseries.ThresholdStyle? = THRESHOLD_STYLES[thresholdMode]
	local thresholdStyle: SvgTimeseries.ThresholdStyle = style or "off"
	local fill = Json.num(env, custom.fillOpacity)
	return {
		width = opts.width or M.WIDTH,
		height = opts.height or M.HEIGHT,
		unit = cfg.unit,
		decimals = cfg.decimals,
		min = cfg.min,
		max = cfg.max,
		thresholds = if style then cfg.thresholds else nil,
		threshold_style = thresholdStyle,
		stack = if stackMode == "normal" or stackMode == "percent" then stackMode else "none",
		draw = draw,
		fill_opacity = fill or 0,
		null_mode = if custom.spanNulls == true then "connect" else "gap",
		from_ms = opts.from_ms,
		to_ms = opts.to_ms,
		offset_min = opts.offset_min,
	}
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets)
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "palette-classic" })
	local render = M.renderOptions(panel, env, opts)
	-- Frames with their time field and the visible number fields, baked.
	local baked: { Frame } = {}
	local visible: { FieldConfig.Item } = {}
	local byFrame: { [Frame]: Frame } = {}
	for _, item in items do
		local tf = Frame.timeField(item.frame)
		if tf == nil or item.field.type ~= "number" or FieldConfig.hidden(item) then
			continue
		end
		local out = byFrame[item.frame]
		if out == nil then
			out = { name = item.frame.name, refId = item.frame.refId, meta = item.frame.meta, fields = { tf } }
			byFrame[item.frame] = out
			table.insert(baked, out :: Frame)
		end
		table.insert((out :: Frame).fields, FieldConfig.bake(item))
		table.insert(visible, item)
	end
	if #visible > 0 then
		local first = visible[1].config
		render.unit = render.unit or first.unit
		if render.decimals == nil then
			render.decimals = first.decimals
		end
	end
	local result = SvgTimeseries.render(baked, render)
	local drawn: { Drawn } = {}
	for i, s in result.layout.series do
		local item = visible[i]
		local color = FieldConfig.seriesColor(item, { theme = opts.theme })
		if color.class == nil then
			local extra = "tgp-fx " .. Common.toneClass(color.tone)
			result.svg =
				replacePlain(result.svg, 'class="' .. s.class .. " ", 'class="' .. s.class .. " " .. extra .. " ")
			s.class = s.class .. " " .. extra
		end
		drawn[i] = { item = item, class = s.class }
	end
	local legendOpts = Json.obj(env, Json.path(env, panel, "options", "legend"))
	local mode = Json.str(env, legendOpts.displayMode) or "list"
	local showLegend = Json.bool(env, legendOpts.showLegend) ~= false and mode ~= "hidden"
	local title = Json.str(env, Json.path(env, panel, "title"))
	local chart, assets = ChartView.view(result, {
		key = opts.key,
		alt = if title and title ~= "" then title else "Time series chart",
		cursor = opts.cursor,
		show_legend = showLegend and opts.cursor ~= nil,
		legend = { mode = if mode == "table" then "table" else "list", offset_min = opts.offset_min },
	})
	if not showLegend or opts.cursor ~= nil then
		return chart, assets
	end
	local legend = legendView(opts.key .. ".legend", drawn, legendCalcs(panel, env), mode, result.dropped, opts)
	return { k = "col", p = { key = opts.key .. ".panel", gap = "xs" }, c = { chart, legend } }, assets
end

return M
