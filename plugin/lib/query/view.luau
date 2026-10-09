--!strict
-- The Query block's view: a header (context, range, step, refresh, status,
-- warnings), the PromQL input with its suggestion list, and the result (the
-- chart with its cursor overlay and legend, the instant table, or an error
-- card). The help sheet and the history picker live in the layer region.

local Assets = require("../render/assets")
local ChartView = require("../render/chart_view")
local Edit = require("./edit")
local Effect = require("../effect")
local Env = require("../env")
local Range = require("../time/range")
local State = require("./state")
local Step = require("../time/step")
local Table = require("../render/table")
local ui = require("../ui")

type Node = ui.Node
type State = State.State

local M = {}

-- { keys, what } for the help sheet; the docs (docs/query.md) list the same.
M.KEYS = table.freeze({
	{ "/  i", "Edit the query (Enter runs, Tab completes, Esc leaves the input)" },
	{ "g  t", "Graph (range query) or table (instant query at the range end)" },
	{ "left  right", "Move the chart cursor one sample (shift: 10)" },
	{ "[  ]", "Shift the range back or forward by half its span" },
	{ "-  +", "Zoom out or in" },
	{ "1 .. 9", "Last 5m, 15m, 1h, 3h, 6h, 12h, 24h, 2d, 7d" },
	{ "r", "Run again" },
	{ "a", "Auto-refresh on or off" },
	{ "c", "Next context" },
	{ "h", "Query history" },
	{ "y", "Copy the query" },
	{ "o", "Open in Grafana Explore" },
	{ "?", "This help" },
	{ "q  esc", "Close" },
})

local FAILURE_TITLES: { [string]: string } = {
	auth = "Authentication failed",
	network = "Network error",
	timeout = "Timed out",
	http = "HTTP error",
	parse = "Unreadable response",
	query = "Query error",
	unsupported = "Unsupported",
	config = "Not configured",
	render = "Chart failed",
}

local function header(s: State): Node
	local children: { Node } = {
		ui.badge(s.context or "no context", "accent", { key = "ctx" }),
		ui.text({ ui.span(Range.describe(s.from, s.to), "strong") }, { key = "range" }),
	}
	local r = s.inflight or s.ran
	if r then
		table.insert(
			children,
			ui.muted(
				if r.kind == "range" then "step " .. Step.formatInterval(r.step_ms) else "instant",
				{ key = "step" }
			)
		)
	end
	table.insert(children, ui.badge(s.mode, "info", { key = "mode" }))
	if s.refresh_ms then
		table.insert(children, ui.badge("auto " .. Step.formatDuration(s.refresh_ms), "info", { key = "auto" }))
	end
	if s.status == "loading" then
		table.insert(children, { k = "spinner", p = { key = "spin" } })
	end
	local warnings = #s.warnings + #s.notices
	if warnings > 0 then
		table.insert(
			children,
			ui.badge(string.format("%d warning%s", warnings, if warnings == 1 then "" else "s"), "warning", {
				key = "warn",
			})
		)
	end
	return ui.row(children, { key = "head", align = "center", wrap = true })
end

local function input(s: State): Node
	return {
		k = "input",
		p = {
			key = "q",
			text = s.expr,
			cursor = Edit.utf16(s.expr, s.cursor),
			placeholder = if s.editing then "PromQL, Enter runs" else "Press / to write a PromQL query",
			prompt = { { t = "> ", s = "muted" } },
			aria = "PromQL query",
		},
	}
end

local function suggestions(s: State): Node?
	local sg = s.suggest
	if sg == nil or not s.editing then
		return nil
	end
	local items: { Node } = table.create(#sg.items)
	for i, item in sg.items do
		items[i] = {
			k = "item",
			p = {
				key = "s" .. i,
				label = { { t = item.label } },
				detail = if item.detail then { { t = item.detail, s = "muted" } } else nil,
			},
		}
	end
	return {
		k = "list",
		p = {
			key = "sugg",
			selected = if sg.selected then "main.sugg.s" .. sg.selected else nil,
			filter = sg.ctx.prefix,
			empty = if sg.loading then { { t = "Loading suggestions...", s = "muted" } } else nil,
			max = { lines = 8 },
			role = "tern-grafana.query-suggest",
		},
		c = items,
	}
end

local function warnings(s: State): Node?
	local lines: { Node } = {}
	for i, w in s.notices do
		table.insert(lines, ui.text({ ui.span(w, "warning") }, { key = "n" .. i }))
	end
	for i, w in s.warnings do
		table.insert(lines, ui.text({ ui.span(w, "warning") }, { key = "w" .. i }))
	end
	if #lines == 0 then
		return nil
	end
	return ui.col(lines, { key = "warnings", gap = "xs" })
end

function M.failure(s: State): Node?
	local f = s.failure
	if f == nil then
		return nil
	end
	local title = FAILURE_TITLES[f.kind] or "Query failed"
	if f.status and f.status > 0 then
		title ..= " (HTTP " .. tostring(f.status) .. ")"
	end
	return ui.card({ ui.span(title, "error") }, { ui.text({ f.message }, { key = "msg" }) }, {
		key = "error",
		tone = "error",
		role = "tern-grafana.query-error",
	})
end

local function body(s: State): (Node, Assets.Assets?)
	local f = M.failure(s)
	if f then
		return f, nil
	end
	if s.frames == nil then
		local text = if s.status == "loading" then "Running..." else "Write a query and press Enter."
		return ui.muted(text, { key = "empty" }), nil
	end
	local ran = s.ran
	if ran and ran.kind == "range" then
		local chart = s.chart
		if chart == nil then
			return ui.muted("No data", { key = "empty" }), nil
		end
		return ChartView.view(chart, { key = "chart", cursor = s.cursor_t, alt = "PromQL result chart" })
	end
	return Table.view(s.frames :: any, { key = "table" }), nil
end

local function help(): Node
	local items: { { { ui.SpanLike } } } = {}
	for _, k in M.KEYS do
		table.insert(items, { { ui.span(k[1], "key") }, { ui.span(k[2]) } })
	end
	return ui.col({
		ui.text({ ui.span("Tern Grafana query keys", "strong"), ui.span("   esc or ? closes", "muted") }, {
			key = "title",
		}),
		ui.kv(items),
	}, { role = "tern-grafana.query-help" })
end

local function historyPicker(s: State): Node
	local h = s.history :: State.HistoryPicker
	local visible = State.historyVisible(h)
	local items: { Node } = table.create(#visible)
	for i, expr in visible do
		items[i] = { k = "item", p = { key = "h" .. i, label = { { t = expr } } } }
	end
	-- A region root is not drawn: no key, so item ids stay layer.hist.h<i>.
	return ui.col({
		ui.text({
			ui.span("Query history: " .. (s.context or ""), "strong"),
			ui.span("   type to filter, enter runs, esc closes", "muted"),
		}, { key = "title" }),
		ui.text({ ui.span("> ", "muted"), ui.span(h.filter) }, { key = "filter" }),
		{
			k = "list",
			p = {
				key = "hist",
				selected = "layer.hist.h" .. h.selected,
				filter = h.filter,
				empty = { { t = "No match", s = "muted" } },
				max = { lines = 12 },
			},
			c = items,
		},
	}, { role = "tern-grafana.query-history" })
end

function M.view(s: State, _env: Env.Env): (Effect.View, Assets.Assets?)
	local children: { Node } = { header(s), input(s) }
	local sugg = suggestions(s)
	if sugg then
		table.insert(children, sugg)
	end
	local warn = warnings(s)
	if warn then
		table.insert(children, warn)
	end
	local result, assets = body(s)
	table.insert(children, result)
	local layer: Node? = nil
	if s.overlay == "help" then
		layer = help()
	elseif s.overlay == "history" and s.history then
		layer = historyPicker(s)
	end
	return {
		main = ui.col(children, { role = "tern-grafana.query" }),
		layer = layer,
	}, assets
end

return M
