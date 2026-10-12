--!strict
-- The pie chart panel (public/app/plugins/panel/piechart: PieChartPanel.tsx,
-- PieChart.tsx, utils.ts, module.tsx) drawn by lib/render/svg_pie:
-- - values from getFieldDisplayValues with options.reduceOptions
--   (lib/panels/values: calcs, all values, fields, limit); slices skip
--   NaN values and fields hidden from the viz;
-- - pieType pie|donut; sort desc (default)|asc|none orders both the slices
--   and the legend, NaN last;
-- - displayLabels name, value (formatted with unit/decimals/mappings) and
--   percent (of the total, field decimals, default 0) on slices of at least
--   0.3 rad;
-- - colors: palette-classic by default; with all values each row takes the
--   next palette color (setIndexForPaletteColor) unless a byName override
--   sets that row's color (lookupRowColorFromOverride); fixed colors as
--   tones;
-- - legend: showLegend, displayMode list|table|hidden, placement
--   bottom|right, values value/percent (defaults: list with percent when
--   the panel has no legend options), custom.hideFrom.legend.
-- No values to show reads as the field defaults' noValue, else "No data".

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Json = require("./json")
local SvgPie = require("../render/svg_pie")
local Thresholds = require("../units/thresholds")
local Values = require("./values")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

local M = {}

M.types = { "piechart" }

M.WIDTH = 480
M.HEIGHT = 300

function M.supports(panel: any, env: Env): (boolean, string?)
	local why = Values.unsupported(panel, env)
	if why then
		return false, why
	end
	return true, nil
end

export type Entry = {
	name: string,
	-- nil when the value is not a number (no slice).
	value: number?,
	text: string,
	class: string,
	decimals: number?,
	hide_legend: boolean,
}

-- The color a byName override gives a row (lookupRowColorFromOverride).
local function rowOverrideColor(panel: any, env: Env, name: string): string?
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		local matcher = Json.obj(env, Json.path(env, o, "matcher"))
		if Json.str(env, matcher.id) == "byName" and Json.str(env, matcher.options) == name then
			for _, p in Json.list(env, Json.path(env, o, "properties")) do
				if Json.str(env, Json.path(env, p, "id")) == "color" then
					local fixed = Json.str(env, Json.path(env, p, "value", "fixedColor"))
					if fixed then
						return fixed
					end
				end
			end
		end
	end
	return nil
end

-- The pie's entries in slice (and legend) order.
function M.entries(panel: any, frames: { Frame }, env: Env, opts: Common.Options): { Entry }
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "palette-classic" })
	local values = Values.values(panel, items, env, { theme = opts.theme, offset_min = opts.offset_min })
	local allRows = Json.bool(env, Json.path(env, panel, "options", "reduceOptions", "values")) == true
	local out: { Entry } = {}
	for k, v in values do
		local item = v.item
		-- The no-values placeholder: hasFrames is false, no pie.
		if item == nil or v.placeholder then
			continue
		end
		local d = v.display
		local class = Charts.displayClass(d)
		if allRows then
			local override = rowOverrideColor(panel, env, v.title)
			local mode = item.config.color_mode
			if override then
				class = Charts.toneClass(Thresholds.tone(override))
			elseif mode == "palette-classic" or mode == "palette-classic-by-name" then
				class = FieldConfig.paletteClass(k)
			end
		end
		table.insert(out, {
			name = v.title,
			value = d.numeric,
			text = FieldConfig.joined(d),
			class = class,
			decimals = item.config.decimals,
			hide_legend = Charts.hiddenFromLegend(item),
		})
	end
	local sort = Json.str(env, Json.path(env, panel, "options", "sort")) or "desc"
	if sort == "desc" or sort == "asc" then
		local index: { [Entry]: number } = {}
		for i, e in out do
			index[e] = i
		end
		table.sort(out, function(a, b)
			if a.value == nil or b.value == nil then
				if a.value == nil and b.value == nil then
					return index[a] < index[b]
				end
				return b.value == nil
			end
			if a.value == b.value then
				return index[a] < index[b]
			end
			if sort == "desc" then
				return (a.value :: number) > (b.value :: number)
			end
			return (a.value :: number) < (b.value :: number)
		end)
	end
	return out
end

local function percentText(e: Entry, total: number): string
	if e.value == nil or total == 0 then
		return "-"
	end
	return Format.toFixed((e.value :: number) / total * 100, e.decimals or 0) .. "%"
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local entries = M.entries(panel, frames, env, opts)
	if #entries == 0 then
		return Common.noData(panel, env, opts.key), {}
	end
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local labels: { [string]: boolean } = {}
	for _, l in Json.list(env, options.displayLabels) do
		if type(l) == "string" then
			labels[l] = true
		end
	end
	local total = 0
	for _, e in entries do
		if e.value then
			total += e.value :: number
		end
	end
	local slices: { SvgPie.Slice } = {}
	for _, e in entries do
		if e.value == nil then
			continue
		end
		local lines: { string } = {}
		if labels.name then
			table.insert(lines, e.name)
		end
		if labels.value then
			table.insert(lines, e.text)
		end
		if labels.percent then
			table.insert(lines, percentText(e, total))
		end
		table.insert(slices, { value = e.value :: number, class = e.class, labels = lines })
	end

	-- Legend (defaults when the panel has none: list, bottom, percent).
	local hasLegend = Json.tbl(env, options.legend) ~= nil
	local legend = Charts.legendOptions(panel, env)
	local shown: { string } = {}
	if hasLegend then
		local want: { [string]: boolean } = {}
		for _, v in Json.list(env, Json.path(env, options.legend, "values")) do
			if type(v) == "string" then
				want[v] = true
			end
		end
		if want.value then
			table.insert(shown, "value")
		end
		if want.percent then
			table.insert(shown, "percent")
		end
	else
		shown = { "percent" }
	end
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local legendNode: Node? = nil
	local side = math.min(W, H)
	if legend.show then
		local rows: { Charts.Row } = {}
		local widest = 0
		for _, e in entries do
			if e.hide_legend then
				continue
			end
			local values: { string } = {}
			for _, s in shown do
				table.insert(values, if s == "value" then e.text else percentText(e, total))
			end
			table.insert(rows, { class = e.class, name = e.name, values = values })
			widest = math.max(widest, utf8.len(e.name) or #e.name)
		end
		local heads: { string } = {}
		for _, s in shown do
			table.insert(heads, if s == "value" then "Value" else "Percent")
		end
		legendNode = Charts.legend(opts.key .. ".legend", rows, heads, legend.mode)
		-- Room the legend takes from the pie (VizLayout).
		if legend.placement == "right" then
			-- VizLayout gives a right legend its natural width; keep at least
			-- half the panel for the pie.
			side = math.min(H, math.max(W * 0.5, W - (widest + 12 * #shown + 4) * 7))
		elseif legend.mode == "table" then
			side = math.min(W, H - (#rows + 1) * 22)
		else
			side = math.min(W, H - 24)
		end
	end
	side = math.max(120, side)
	local svg = SvgPie.render(slices, {
		size = side,
		donut = Json.str(env, options.pieType) == "donut",
		name_label = labels.name == true,
	})
	local chart, assets =
		Charts.image(opts.key, svg, side, side, Charts.alt(panel, env, "Pie chart"), "tern-grafana.piechart")
	return Charts.compose(opts.key, chart, legendNode, legend.placement), assets
end

return M
