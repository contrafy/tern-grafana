--!strict
-- The flame graph panel (public/app/plugins/panel/flamegraph, the
-- @grafana/flamegraph package: FlameGraph/dataTransform.ts
-- nestedSetToLevels, rendering.ts, colors.ts, TopTable, constants.ts):
-- - the data is a nested set frame: `level`, `value`, `self` and `label`
--   fields in depth-first order (a row's parent is the nearest earlier row
--   one level up; siblings follow each other); a value field unit formats
--   values;
-- - the icicle: the root on top, package based colors, "label (value)"
--   in bars wide enough, the levels that fit the panel;
-- - the metadata line "<total> | <total short> samples (<unit title>)";
-- - panels at least 800 px wide also show the top table (symbol, self,
--   total; self descending) beside the graph, as Grafana's "Both" view.
-- A frame without those fields is Grafana's "Data does not look like a
-- flame graph" (no level/value/label).

local Assets = require("../render/assets")
local Charts = require("./charts")
local Common = require("./common")
local Env = require("../env")
local Format = require("../units/format")
local Frame = require("../frame/types")
local Grid = require("../render/grid")
local SvgFlame = require("../render/svg_flame")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Field = Frame.Field
type Node = ui.Node

local M = {}

M.types = { "flamegraph" }

M.WIDTH = 960
M.HEIGHT = 300
-- MIN_WIDTH_TO_SHOW_BOTH_TOPTABLE_AND_FLAMEGRAPH.
M.MIN_WIDTH_BOTH = 800

function M.supports(_: any, _: Env): (boolean, string?)
	return true, nil
end

export type Item = {
	index: number,
	level: number,
	start: number,
	value: number,
	self: number,
	label: string,
	parent: Item?,
	children: { Item },
}

export type Profile = {
	items: { Item },
	levels: number,
	total: number,
	unit: string?,
}

local function field(frame: Frame, name: string): Field?
	for _, f in frame.fields do
		if f.name == name then
			return f
		end
	end
	return nil
end

local function num(v: any): number
	return if type(v) == "number" and v == v then v else 0
end

-- nestedSetToLevels over the first frame with level, value and label.
function M.profile(frames: { Frame }): Profile?
	for _, frame in frames do
		local level, value, label = field(frame, "level"), field(frame, "value"), field(frame, "label")
		if level == nil or value == nil or label == nil then
			continue
		end
		local selfF = field(frame, "self")
		local items: { Item } = {}
		local byLevel: { [number]: { Item } } = {}
		local offset = 0
		local parent: Item? = nil
		local maxLevel = -1
		for i = 1, #(value :: Field).values do
			local lv = num((level :: Field).values[i])
			local prev = if i > 1 then num((level :: Field).values[i - 1]) else nil
			local list = byLevel[lv]
			if list == nil then
				list = {}
				byLevel[lv] = list
			end
			if prev ~= nil and prev >= lv then
				local last = list[#list]
				if last then
					offset = last.start + last.value
					parent = last.parent
				end
			end
			local raw = (label :: Field).values[i]
			local item: Item = {
				index = i,
				level = lv,
				start = offset,
				value = num((value :: Field).values[i]),
				self = if selfF then num(selfF.values[i]) else 0,
				label = if type(raw) == "string"
					then raw
					elseif raw == nil or raw == Frame.NULL then ""
					else tostring(raw),
				parent = parent,
				children = {},
			}
			if parent then
				table.insert((parent :: Item).children, item)
			end
			parent = item
			table.insert(list, item)
			table.insert(items, item)
			maxLevel = math.max(maxLevel, lv)
		end
		if #items == 0 then
			return nil
		end
		local cfg = (value :: Field).config
		return {
			items = items,
			levels = maxLevel + 1,
			total = items[1].value,
			unit = if cfg then cfg.unit else nil,
		}
	end
	return nil
end

export type Symbol = { label: string, self: number, total: number }

-- The top table: per label the self sum and the total of its outermost
-- occurrences (a recursive call is not counted twice), self descending.
function M.symbols(p: Profile): { Symbol }
	local by: { [string]: Symbol } = {}
	local out: { Symbol } = {}
	for _, item in p.items do
		local s = by[item.label]
		if s == nil then
			s = { label = item.label, self = 0, total = 0 }
			by[item.label] = s
			table.insert(out, s)
		end
		s.self += item.self
		local nested = false
		local a = item.parent
		while a do
			if a.label == item.label then
				nested = true
				break
			end
			a = a.parent
		end
		if not nested then
			s.total += item.value
		end
	end
	table.sort(out, function(a, b)
		if a.self ~= b.self then
			return a.self > b.self
		end
		return a.label < b.label
	end)
	return out
end

local UNIT_TITLES: { [string]: string } = {
	short = "Count",
	none = "Count",
	ns = "Nanoseconds",
	bytes = "Bytes",
	decbytes = "Bytes",
}

function M.metadata(p: Profile): string
	local unit = p.unit
	local value = Format.text(p.total, unit, nil)
	local title = UNIT_TITLES[unit or "short"] or (unit :: string)
	return string.format("%s | %s samples (%s)", value, Format.text(p.total, "short", nil), title)
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	if not Common.hasData(frames) then
		return Common.noData(panel, env, opts.key), {}
	end
	local maybe = M.profile(frames)
	if maybe == nil then
		return Charts.message(opts.key, "Data does not look like a flame graph"), {}
	end
	local p = maybe :: Profile
	local W, H = Charts.size(opts, M.WIDTH, M.HEIGHT)
	local both = W >= M.MIN_WIDTH_BOTH
	local graphW = if both then math.floor(W / 2) - 8 else W
	local light = opts.theme == "light"
	local bars: { SvgFlame.Bar } = table.create(#p.items)
	for i, item in p.items do
		bars[i] = {
			level = item.level,
			start = item.start,
			value = item.value,
			label = item.label,
			value_text = "(" .. Format.text(item.value, p.unit, nil) .. ")",
			color = SvgFlame.packageColor(item.label, light),
		}
	end
	local maxLevels = math.max(1, math.floor((H - 28) / SvgFlame.PIXELS_PER_LEVEL))
	local svg =
		SvgFlame.render({ width = graphW, total = p.total, levels = p.levels, bars = bars, max_levels = maxLevels })
	local shown = math.min(p.levels, maxLevels)
	local chart, assets = Charts.image(
		opts.key,
		svg,
		graphW,
		shown * SvgFlame.PIXELS_PER_LEVEL,
		Charts.alt(panel, env, "Flame graph"),
		"tern-grafana.flamegraph"
	)
	local graph: Node = {
		k = "col",
		p = { key = opts.key .. ".graph", gap = "xs", grow = 1, basis = 0 },
		c = { ui.muted(M.metadata(p), { key = "meta" }), chart },
	}
	if not both then
		return { k = "col", p = { key = opts.key .. ".panel", gap = "xs" }, c = { graph } }, assets
	end
	local rows: { Grid.Row } = {}
	for i, s in M.symbols(p) do
		rows[i] = {
			key = "s" .. i,
			cells = {
				Grid.text(s.label),
				Grid.text(Format.text(s.self, p.unit, nil)),
				Grid.text(Format.text(s.total, p.unit, nil)),
			},
		}
	end
	local tableNode = Grid.grid(opts.key .. ".top", {
		{ head = "Symbol" },
		{ head = "Self", numeric = true },
		{ head = "Total", numeric = true },
	}, rows, "tern-grafana.flamegraph-top")
	local left: Node = { k = "col", p = { key = opts.key .. ".table", grow = 1, basis = 0 }, c = { tableNode } }
	return {
		k = "row",
		p = { key = opts.key .. ".panel", gap = "sm", align = "start" },
		c = { left, graph },
	},
		assets
end

return M
