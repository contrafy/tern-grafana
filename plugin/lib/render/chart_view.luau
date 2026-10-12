--!strict
-- A rendered chart as a view: an `image` node referencing the SVG by asset
-- key, the keyboard cursor as an overlay child (a flex spacer whose basis is
-- the cursor's fraction of the image width, then a 1-px `tg-cursor` line;
-- moving it changes no blob), and the legend under it. A selected exemplar
-- (`x`) moves the cursor onto it, recolors the line and adds a read-out of
-- its value and labels under the legend.

local Assets = require("./assets")
local Format = require("../units/format")
local FrameProm = require("../frame/prom")
local Layout = require("./layout")
local Legend = require("./legend")
local Range = require("../time/range")
local SvgTimeseries = require("./svg_timeseries")
local ui = require("../ui")

type Node = ui.Node

export type Options = {
	-- Node key and asset key (default "chart").
	key: string?,
	alt: string?,
	role: string?,
	cursor: number?,
	-- Index into layout.exemplars of the selected exemplar.
	exemplar: number?,
	-- Label naming the trace id (config query.exemplar_trace_label).
	trace_label: string?,
	-- Default true.
	show_legend: boolean?,
	legend: Legend.Options?,
}

local M = {}

function M.overlay(layout: Layout.Layout, cursor: number, class: string?): Node?
	if cursor < layout.t_from or cursor > layout.t_to then
		return nil
	end
	local spacer: Node =
		{ k = "el", p = { tag = "div", key = "sp", basis = Layout.fractionOfTime(layout, cursor), shrink = 0 } }
	local line: Node = { k = "el", p = { tag = "div", key = "ln", class = class or "tg-cursor" } }
	return { k = "row", p = { key = "cur", grow = 1 }, c = { spacer, line } }
end

-- The selected exemplar, if `index` names a drawn one.
function M.selected(layout: Layout.Layout, index: number?): FrameProm.Exemplar?
	local list = layout.exemplars
	if index == nil or list == nil then
		return nil
	end
	return list[index]
end

local function sortedKeys(t: { [string]: string }): { string }
	local keys: { string } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- "Exemplar 12:03:04  0.24 s  traceID=..." and the other labels; with a
-- trace id the line says enter opens it.
function M.exemplarView(
	layout: Layout.Layout,
	e: FrameProm.Exemplar,
	key: string,
	offset_min: number?,
	traceLabel: string?
): Node
	local spans: { ui.SpanLike } = {
		ui.span("Exemplar ", "strong"),
		ui.span(Range.formatMs(e.time_ms, offset_min) .. "  ", "muted"),
		ui.span(Format.text(e.value, layout.unit, layout.decimals), "strong"),
	}
	local id, idLabel = FrameProm.traceId(e.labels, traceLabel)
	if id then
		table.insert(spans, ui.span("  " .. (idLabel :: string) .. "=" .. id, "accent"))
		table.insert(spans, ui.span("  enter opens the trace", "muted"))
	end
	local rest: { string } = {}
	for _, k in sortedKeys(e.labels) do
		if k ~= idLabel then
			table.insert(rest, k .. "=" .. e.labels[k])
		end
	end
	for _, k in sortedKeys(e.series) do
		if k ~= "__name__" then
			table.insert(rest, k .. "=" .. e.series[k])
		end
	end
	local children: { Node } = { ui.text(spans, { key = "head" }) }
	if #rest > 0 then
		table.insert(children, ui.muted(table.concat(rest, "  "), { key = "labels" }))
	end
	return ui.col(children, { key = key, gap = "xs", role = "tern-grafana.exemplar" })
end

function M.view(result: SvgTimeseries.Result, opts: Options?): (Node, Assets.Assets)
	local o: Options = opts or {}
	local key = o.key or "chart"
	local layout = result.layout
	local ex = M.selected(layout, o.exemplar)
	local cursor = if ex then ex.time_ms else o.cursor
	local over = if cursor then M.overlay(layout, cursor, if ex then "tg-cursor tg-exemplar-cursor" else nil) else nil
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
		lo.cursor = cursor
		lo.key = lo.key or (key .. ".legend")
		table.insert(children, Legend.view(layout, lo))
	end
	if ex then
		local offset = if o.legend then o.legend.offset_min else nil
		table.insert(children, M.exemplarView(layout, ex, key .. ".ex", offset, o.trace_label))
	end
	local node: Node = { k = "col", p = { key = key .. ".view", gap = "xs" }, c = children }
	return node, { [key] = { mime = Assets.SVG, bytes = result.svg } }
end

return M
