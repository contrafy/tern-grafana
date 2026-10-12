--!strict
-- The state-timeline and status-history panels
-- (public/app/plugins/panel/state-timeline/StateTimelinePanel.tsx,
-- status-history/StatusHistoryPanel.tsx, panelcfg.cue for both, and
-- public/app/core/components/TimelineChart/utils.ts, timeline.ts):
-- - every number, string and boolean field of a frame with a time field is
--   a lane named by its display name (prepareTimelineFields), sorted by
--   time; frames without a time field are left out ("Data does not have a
--   time field" when none has one);
-- - state timeline draws value changes (mergeValues, default on, merges
--   equal neighbors); with mergeValues and thresholds color mode, numbers
--   become their threshold step ("< 1", "1+": mergeThresholdValues), so
--   lanes merge by step and print the step label; status history draws
--   one column per sample (colWidth);
-- - colors and texts come from the field's display processor: value
--   mappings, then the color mode (default continuous-GrYlRd); nulls are
--   not drawn unless a null mapping exists;
-- - options rowHeight, showValue (auto|always|never), alignValue (state
--   timeline), perPage (lanes per page: the first page is drawn, the rest
--   counted in a note), custom.fillOpacity, custom.lineWidth,
--   custom.hideFrom.viz, custom.axisPlacement hidden;
-- - the legend (prepareTimelineLegendItems): threshold steps in
--   thresholds mode with more than one step, nothing for continuous
--   modes, else every distinct value text with a color.

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Json = require("./json")
local Mappings = require("./mappings")
local SvgTimeline = require("../render/svg_timeline")
local Thresholds = require("../units/thresholds")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Item = FieldConfig.Item
type Node = ui.Node

local M = {}

M.types = { "state-timeline", "status-history" }

M.WIDTH = 960
M.HEIGHT = 300

function M.supports(panel: any, env: Env): (boolean, string?)
	local why = FieldConfig.unsupported(panel, env)
	if why then
		return false, why
	end
	return true, nil
end

export type Lane = {
	item: Item,
	times: { number },
	values: { any },
}

-- prepareTimelineFields: lanes (time-sorted) and Grafana's warning when
-- nothing is graphable.
function M.lanes(panel: any, frames: { Frame }, env: Env): ({ Lane }, string?)
	local items = FieldConfig.resolve(panel, frames, env, { color_mode = "continuous-GrYlRd" })
	local out: { Lane } = {}
	local hasTime = false
	for _, item in items do
		local tf = Frame.timeField(item.frame)
		if tf == nil or type(tf.values[1]) ~= "number" then
			continue
		end
		hasTime = true
		local kind = item.field.type
		if kind ~= "number" and kind ~= "string" and kind ~= "boolean" then
			continue
		end
		if FieldConfig.hidden(item) then
			continue
		end
		local tv = (tf :: Frame.Field).values
		local order: { number } = {}
		for i, t in tv do
			if type(t) == "number" then
				table.insert(order, i)
			end
		end
		table.sort(order, function(a, b)
			return tv[a] < tv[b]
		end)
		local times: { number } = table.create(#order)
		local values: { any } = table.create(#order)
		for k, i in order do
			times[k] = tv[i]
			values[k] = item.field.values[i]
		end
		table.insert(out, { item = item, times = times, values = values })
	end
	if not hasTime then
		return out, "Data does not have a time field"
	elseif #out == 0 then
		return out, "No graphable fields"
	end
	return out, nil
end

-- getThresholdItems: one label per step ("< next" for the base step,
-- "value+" for the rest), formatted in the field unit (percent in
-- percentage mode).
function M.thresholdLabels(config: FieldConfig.Config): { string }
	local steps = config.thresholds.steps
	local unit = if config.thresholds.mode == "percentage" then "percent" else config.unit
	local out: { string } = table.create(#steps)
	for i, step in steps do
		local v = if type(step.value) == "number" then step.value else -math.huge
		local pre, suf = "", ""
		if v == -math.huge and i < #steps then
			v = if type(steps[i + 1].value) == "number" then steps[i + 1].value else -math.huge
			pre = "< "
		else
			suf = "+"
		end
		out[i] = pre .. Format.text(v, unit, config.decimals) .. suf
	end
	return out
end

local function isNull(v: any): boolean
	return v == nil or v == Frame.NULL or (type(v) == "number" and v ~= v)
end

-- Whether a null (or NaN) value has a special mapping (hasSpecialMappedValue).
local function mapsNull(item: Item, v: any): boolean
	if #item.config.mappings == 0 then
		return false
	end
	return Mappings.apply(item.config.mappings, if v == Frame.NULL then nil else v) ~= nil
end

-- The boxes of a lane and their legend entries (text -> class).
local function boxes(
	lane: Lane,
	merge: boolean,
	opts: Common.Options
): ({ SvgTimeline.Box }, { { text: string, class: string } })
	local item = lane.item
	local cfg = item.config
	local out: { SvgTimeline.Box } = {}
	local seen: { [string]: boolean } = {}
	local states: { { text: string, class: string } } = {}
	local byStep = merge
		and item.field.type == "number"
		and cfg.color_mode == "thresholds"
		and #cfg.thresholds.steps > 0
	local stepLabels = if byStep then M.thresholdLabels(cfg) else {}
	local lo, hi = item.range_min or 0, item.range_max or 100
	for i, v in lane.values do
		if isNull(v) and not mapsNull(item, v) then
			-- An explicit null ends the previous state.
			table.insert(out, { t = lane.times[i], class = "", text = nil, key = "\0null" })
			continue
		end
		local text: string, class: string
		if byStep then
			local probe = v :: number
			if cfg.thresholds.mode == "percentage" then
				probe = (probe - lo) / (hi - lo) * 100
			end
			local spec: Thresholds.Thresholds = { mode = "absolute", steps = cfg.thresholds.steps }
			local a = Thresholds.active(probe, spec, nil, nil, opts.theme)
			text = stepLabels[math.max(a.index, 1)] or ""
			class = Charts.toneClass(a.tone)
		else
			local d = FieldConfig.display(item, v, { theme = opts.theme, offset_min = opts.offset_min })
			text = FieldConfig.joined(d)
			class = Charts.displayClass(d)
		end
		table.insert(out, { t = lane.times[i], class = class, text = text, key = text .. "\0" .. class })
		if text ~= "" and not seen[text] then
			seen[text] = true
			table.insert(states, { text = text, class = class })
		end
	end
	return out, states
end

local function hideLegend(item: Item): boolean
	return Charts.hiddenFromLegend(item)
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	if not Common.hasData(frames) then
		return Common.noData(panel, env, opts.key), {}
	end
	local lanes, warn = M.lanes(panel, frames, env)
	if warn then
		return Charts.message(opts.key, warn), {}
	end
	local kind = Json.str(env, panel.type)
	local samples = kind == "status-history"
	local o = Json.obj(env, panel.options)
	local merge = not samples and Json.bool(env, o.mergeValues) ~= false
	local perPage = Json.num(env, o.perPage) or 20
	local total = #lanes
	local notes: { string } = {}
	if perPage >= 1 and total > perPage then
		local page: { Lane } = table.create(perPage)
		for i = 1, perPage do
			page[i] = lanes[i]
		end
		lanes = page
		table.insert(notes, string.format("Page 1 of %d (%d rows)", math.ceil(total / perPage), total))
	end
	local svgLanes: { SvgTimeline.Lane } = table.create(#lanes)
	local legendStates: { { text: string, class: string } } = {}
	local legendSeen: { [string]: boolean } = {}
	for i, lane in lanes do
		local b, states = boxes(lane, merge, opts)
		svgLanes[i] = { label = lane.item.name, boxes = b }
		if not hideLegend(lane.item) then
			for _, s in states do
				if not legendSeen[s.text] then
					legendSeen[s.text] = true
					table.insert(legendStates, s)
				end
			end
		end
	end
	local first = lanes[1].item
	local custom = first.config.custom
	local defaultsLine = if samples then 1 else 0
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local legend = Charts.legendOptions(panel, env)
	local legendRows: { Charts.Row } = {}
	if legend.show then
		local cfg = first.config
		if cfg.color_mode == "thresholds" and #cfg.thresholds.steps > 1 then
			local labels = M.thresholdLabels(cfg)
			for k, step in cfg.thresholds.steps do
				table.insert(
					legendRows,
					{ class = Charts.toneClass(Thresholds.tone(step.color)), name = labels[k], values = {} }
				)
			end
		elseif string.sub(cfg.color_mode, 1, 11) ~= "continuous-" then
			for _, s in legendStates do
				table.insert(legendRows, { class = s.class, name = s.text, values = {} })
			end
		end
	end
	local svgH = H
	if #legendRows > 0 then
		svgH = math.max(60, H - 24)
	end
	local from, to = Charts.range(opts)
	if from == nil or to == nil then
		local lo, hi = math.huge, -math.huge
		for _, l in lanes do
			if #l.times > 0 then
				lo = math.min(lo, l.times[1])
				hi = math.max(hi, l.times[#l.times])
			end
		end
		from, to = lo, hi
	end
	local svg = SvgTimeline.render({
		width = W,
		height = svgH,
		from_ms = from :: number,
		to_ms = to :: number,
		mode = if samples then "samples" else "changes",
		lanes = svgLanes,
		row_height = Json.num(env, o.rowHeight),
		col_width = Json.num(env, o.colWidth),
		merge = merge,
		show_value = (Json.str(env, o.showValue) or "auto") :: any,
		align_value = (Json.str(env, o.alignValue) or "left") :: any,
		fill_opacity = Json.num(env, custom.fillOpacity),
		line_width = Json.num(env, custom.lineWidth) or defaultsLine,
		offset_min = opts.offset_min,
		hide_y = Json.str(env, custom.axisPlacement) == "hidden",
	}).svg
	local chart, assets = Charts.image(
		opts.key,
		svg,
		W,
		svgH,
		Charts.alt(panel, env, if samples then "Status history" else "State timeline"),
		"tern-grafana." .. (kind or "state-timeline")
	)
	local legendNode: Node? = nil
	if #legendRows > 0 then
		legendNode = Charts.legend(opts.key .. ".legend", legendRows, {}, "list")
	end
	return Charts.compose(opts.key, chart, legendNode, legend.placement, notes), assets
end

return M
