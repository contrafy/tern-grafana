--!strict
-- Gauge and bar gauge panels (public/app/plugins/panel/gauge,
-- public/app/plugins/panel/bargauge; packages/grafana-ui/src/components/
-- Gauge, BarGauge) as Tern `meter` nodes. Each field display value
-- (lib/panels/values) becomes one meter whose fill is the value's percent
-- of the field range (min/max, else the data's) in its threshold tone:
-- - gauge: a ring; showThresholdMarkers puts a tick at every threshold step
--   inside the range; showThresholdLabels lists the step values;
-- - bar gauge: a bar per value. displayMode basic and gradient fill in the
--   value's tone (a gradient ends in that color); lcd is Tern's block grid
--   with each threshold band's cells in the band's tone; valueMode
--   color|text|hidden and namePlacement hidden decide the label and title.
-- Tern meters take only two threshold levels, so tones are explicit.

local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local Thresholds = require("../units/thresholds")
local Values = require("./values")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node

export type Mark = { at: number, tone: string, title: string }
export type Part = { value: number, token: string }

export type Meter = {
	title: string?,
	label: string?,
	value: number,
	tone: string,
	marks: { Mark }?,
	parts: { Part }?,
	-- Formatted threshold step values (gauge showThresholdLabels).
	threshold_labels: { string }?,
	-- The label's color: the value's tone, or none (bar gauge valueMode text).
	label_tone: string?,
}

local M = {}

-- A threshold step's position on the field's 0..1 scale.
local function stepAt(item: FieldConfig.Item, value: number): number?
	local t = item.config.thresholds
	if t.mode == "percentage" then
		return value / 100
	end
	local lo, hi = item.range_min or 0, item.range_max or 100
	if hi <= lo then
		return nil
	end
	return (value - lo) / (hi - lo)
end

local function steps(item: FieldConfig.Item): { { at: number, value: number, name: string } }
	local out = {}
	for _, s in item.config.thresholds.steps do
		if type(s.value) == "number" then
			local at = stepAt(item, s.value)
			if at and at > 0 and at < 1 then
				table.insert(out, { at = at, value = s.value, name = s.color })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.at < b.at
	end)
	return out
end

local function clamp01(x: number): number
	return if x ~= x then 0 else math.clamp(x, 0, 1)
end

-- LCD cells from 0 up to `fill`, each run in its threshold band's tone; the
-- run holding the value takes the value's own tone, so a value sitting
-- exactly on a step reads in that step's color as in Grafana.
local function bandParts(item: FieldConfig.Item, fill: number, valueTone: Thresholds.Tone): { Part }
	local parts: { Part } = {}
	local name = Thresholds.active(nil, item.config.thresholds).name
	local from = 0
	for _, e in steps(item) do
		if e.at >= fill then
			break
		end
		if e.at > from then
			table.insert(parts, { value = e.at - from, token = Common.token(Thresholds.tone(name)) })
		end
		from = e.at
		name = e.name
	end
	if fill > from then
		table.insert(parts, { value = fill - from, token = "" })
	end
	if #parts > 0 then
		parts[#parts].token = Common.token(valueTone)
	end
	for _, p in parts do
		if p.token == "" then
			p.token = "muted"
		end
	end
	return parts
end

function M.meters(panel: any, frames: { Frame }, env: Env, opts: Common.Options, bar: boolean): { Meter }
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "thresholds" })
	local values = Values.values(panel, items, env, { theme = opts.theme, offset_min = opts.offset_min })
	local options = Json.obj(env, Json.path(env, panel, "options"))
	local displayMode = Json.str(env, options.displayMode) or "gradient"
	local valueMode = Json.str(env, options.valueMode) or "color"
	local namePlacement = Json.str(env, options.namePlacement) or "auto"
	local showMarkers = Json.bool(env, options.showThresholdMarkers) ~= false
	local showLabels = Json.bool(env, options.showThresholdLabels) == true
	local out: { Meter } = {}
	for _, v in values do
		local d = v.display
		local fill = clamp01(d.percent)
		local meter: Meter = {
			title = if bar and namePlacement == "hidden" then nil else v.title,
			label = FieldConfig.joined(d),
			value = fill,
			tone = d.tone,
			label_tone = if bar and valueMode == "text" then nil else d.tone,
		}
		if bar and valueMode == "hidden" then
			meter.label = nil
		end
		local item = v.item
		if item and item.config.color_mode == "thresholds" then
			if bar and displayMode == "lcd" then
				meter.parts = bandParts(item, fill, d.tone)
			elseif not bar and showMarkers then
				local marks: { Mark } = {}
				for _, e in steps(item) do
					table.insert(marks, {
						at = e.at,
						tone = Thresholds.tone(e.name) :: string,
						title = FieldConfig.joined(FieldConfig.display(item, e.value, { theme = opts.theme })),
					})
				end
				meter.marks = marks
			end
			if not bar and showLabels then
				local labels: { string } = {}
				for _, s in item.config.thresholds.steps do
					if type(s.value) == "number" then
						table.insert(
							labels,
							FieldConfig.joined(FieldConfig.display(item, s.value, { theme = opts.theme }))
						)
					end
				end
				meter.threshold_labels = labels
			end
		end
		table.insert(out, meter)
	end
	return out
end

local function meterNode(m: Meter, key: string, style: string, size: string): Node
	local p: { [string]: any } = { key = "m", style = style, size = size, value = m.value, grow = 1 }
	if m.label then
		local token = Common.token((m.label_tone or "neutral") :: any)
		p.label = { ui.span(m.label :: string, if token ~= "" then "strong " .. token else "strong") }
	end
	if m.parts then
		p.parts = m.parts
	else
		-- `neutral` would yield to the accent default; Grafana's fallback is gray.
		p.tone = if m.tone == "neutral" then "muted" else m.tone
	end
	if m.marks then
		p.marks = m.marks
	end
	local children: { Node } = {}
	if m.title then
		table.insert(children, ui.text({ ui.span(m.title :: string, "muted") }, { key = "t", truncate = "end" }))
	end
	table.insert(children, { k = "meter", p = p })
	if m.threshold_labels and #(m.threshold_labels :: { string }) > 0 then
		table.insert(children, ui.muted(table.concat(m.threshold_labels :: { string }, " · "), { key = "th" }))
	end
	return { k = "col", p = { key = key, gap = "xs", grow = 1 }, c = children }
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options, bar: boolean): Node
	local meters = M.meters(panel, frames, env, opts, bar)
	local nodes: { Node } = table.create(#meters)
	local displayMode = Json.str(env, Json.path(env, panel, "options", "displayMode")) or "gradient"
	local style = if not bar then "ring" elseif displayMode == "lcd" then "blocks" else "bar"
	for i, m in meters do
		nodes[i] = meterNode(m, "g" .. i, style, if bar then "md" else "lg")
	end
	local role = if bar then "tern-grafana.bargauge" else "tern-grafana.gauge"
	local orientation = Json.str(env, Json.path(env, panel, "options", "orientation")) or "auto"
	if bar and orientation ~= "vertical" then
		-- Horizontal bar gauges stack their bars (Grafana's default reading).
		return ui.col(nodes, { key = opts.key, gap = "sm", role = role })
	end
	return ui.row(nodes, { key = opts.key, gap = "md", wrap = true, role = role })
end

return M
