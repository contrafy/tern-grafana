--!strict
-- A rendered chart as a view: an `image` node referencing the SVG by asset
-- key, the keyboard cursor as an overlay child (a flex spacer whose basis is
-- the cursor's fraction of the image width, then a 1-px `tg-cursor` line;
-- moving it changes no blob), and the legend under it.

local Assets = require("./assets")
local Layout = require("./layout")
local Legend = require("./legend")
local SvgTimeseries = require("./svg_timeseries")
local ui = require("../ui")

type Node = ui.Node

export type Options = {
	-- Node key and asset key (default "chart").
	key: string?,
	alt: string?,
	role: string?,
	cursor: number?,
	-- Default true.
	show_legend: boolean?,
	legend: Legend.Options?,
}

local M = {}

function M.overlay(layout: Layout.Layout, cursor: number): Node?
	if cursor < layout.t_from or cursor > layout.t_to then
		return nil
	end
	local spacer: Node =
		{ k = "el", p = { tag = "div", key = "sp", basis = Layout.fractionOfTime(layout, cursor), shrink = 0 } }
	local line: Node = { k = "el", p = { tag = "div", key = "ln", class = "tg-cursor" } }
	return { k = "row", p = { key = "cur", grow = 1 }, c = { spacer, line } }
end

function M.view(result: SvgTimeseries.Result, opts: Options?): (Node, Assets.Assets)
	local o: Options = opts or {}
	local key = o.key or "chart"
	local layout = result.layout
	local over = if o.cursor then M.overlay(layout, o.cursor) else nil
	local image: Node = {
		k = "image",
		p = {
			key = key,
			asset = key,
			w = layout.width,
			h = layout.height,
			alt = o.alt or "Time series chart",
			role = o.role or "tern-grafana.chart",
		},
		c = if over then { over } else nil,
	}
	local children: { Node } = { image }
	if o.show_legend ~= false then
		local lo: Legend.Options = if o.legend then table.clone(o.legend) else {}
		lo.cursor = o.cursor
		lo.key = lo.key or (key .. ".legend")
		table.insert(children, Legend.view(layout, lo))
	end
	local node: Node = { k = "col", p = { key = key .. ".view", gap = "xs" }, c = children }
	return node, { [key] = { mime = Assets.SVG, bytes = result.svg } }
end

return M
