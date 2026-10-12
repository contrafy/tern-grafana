--!strict
-- The Logs block's view: a header (context, range, synced badge, tail, line
-- count, status, warnings), the LogQL input with its suggestions, the volume
-- bars with level chips, and the log lines as native text rows (newest
-- first, level tone on the left edge, then the labels that tell streams
-- apart, and a "trace" chip on lines that name a trace id). The selected
-- line's detail lists its stream labels, structured metadata and parsed
-- fields as chips: click (or `f`) filters for the value, the minus chip (or
-- `x`) filters it out. A metric LogQL query shows a chart instead.

local Assets = require("../render/assets")
local ChartView = require("../render/chart_view")
local Edit = require("../query/edit")
local Effect = require("../effect")
local Env = require("../env")
local FrameLoki = require("../frame/loki")
local LogsPanel = require("../panels/logs")
local LogQL = require("./logql")
local Range = require("../time/range")
local State = require("./state")
local Step = require("../time/step")
local ui = require("../ui")

type Node = ui.Node
type State = State.State
type Line = FrameLoki.Line

local M = {}

M.KEYS = table.freeze({
	{ "/  i", "Edit the query (Enter runs, Tab completes, Esc leaves the input)" },
	{ "j  k  up  down", "Select a line (g / G: first / last)" },
	{ "enter  space", "Open or close the line's detail" },
	{ "left  right", "Select a chip in the detail" },
	{ "f  x", "Filter for / filter out the selected chip" },
	{ "T", "Open the selected line's trace (lines with a trace chip)" },
	{ "M", "Metrics: the Query block with the line's correlation labels as a selector" },
	{ "S", "Sync the time range with other synced blocks on or off" },
	{ "t", "Tail on or off (polls every logs.tail_interval)" },
	{ "v", "Volume bars on or off" },
	{ "[  ]", "Shift the range back or forward by half its span" },
	{ "-  +", "Zoom out or in" },
	{ "1 .. 9", "Last 5m, 15m, 1h, 3h, 6h, 12h, 24h, 2d, 7d" },
	{ "r", "Run again" },
	{ "c", "Next context" },
	{ "y", "Copy the selected line (the query when none is selected)" },
	{ "o", "Open in Grafana Explore" },
	{ "?", "This help" },
	{ "q  esc", "Close (esc closes the detail first)" },
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

local LEVEL_TAGS: { [string]: string } = {
	critical = "CRIT ",
	error = "ERROR",
	warning = "WARN ",
	info = "INFO ",
	debug = "DEBUG",
	trace = "TRACE",
	unknown = "     ",
}

local KIND_TITLES: { [string]: string } = {
	label = "Labels",
	metadata = "Structured metadata",
	parsed = "Parsed fields",
}

local function plural(n: number, word: string): string
	return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
end

local function header(s: State): Node
	local children: { Node } = {
		ui.badge(s.context or "no context", "accent", { key = "ctx" }),
		ui.text({ ui.span(Range.describe(s.from, s.to), "strong") }, { key = "range" }),
	}
	if s.sync.on then
		table.insert(
			children,
			ui.badge("synced", "info", {
				key = "sync",
				actions = { click = "sync" },
				class = "tg-lg-chip",
				title = "Time range shared with other synced blocks (S)",
			})
		)
	end
	if s.tail then
		table.insert(
			children,
			ui.badge("tail " .. Step.formatDuration(s.options.tail_ms), "success", {
				key = "tail",
				actions = { click = "tail" },
				class = "tg-lg-chip",
			})
		)
	end
	local r = s.ran
	if r and not r.metric then
		local text = plural(#s.lines, "line")
		if #s.lines >= s.options.limit then
			text ..= " (limit)"
		end
		if s.tail and s.tail_added > 0 then
			text ..= string.format(", %d new", s.tail_added)
		end
		table.insert(children, ui.muted(text, { key = "count" }))
	end
	if s.status == "loading" or s.tail_inflight then
		table.insert(children, { k = "spinner", p = { key = "spin" } })
	end
	local warnings = #s.warnings + #s.notices
	if warnings > 0 then
		table.insert(children, ui.badge(plural(warnings, "warning"), "warning", { key = "warn" }))
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
			placeholder = if s.editing then '{app="api"} |= "error", Enter runs' else "Press / to write a LogQL query",
			prompt = { { t = "> ", s = "muted" } },
			aria = "LogQL query",
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
			empty = if sg.loading then { { t = "Loading suggestions...", s = "muted" } } else nil,
			max = { lines = 8 },
			role = "tern-grafana.logs-suggest",
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

local function failure(s: State): Node?
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
		role = "tern-grafana.logs-error",
	})
end

local function clock(ms: number): string
	local whole = math.floor(ms)
	return Range.formatMs(whole) .. string.format(".%03d", whole % 1000)
end

local function volume(s: State): Node?
	local r = s.ran
	if not s.show_volume or r == nil or r.metric then
		return nil
	end
	local v = s.volume
	local children: { Node } = {}
	if v and v.total > 0 then
		local series: { { [string]: any } } = table.create(#v.buckets)
		for i, b in v.buckets do
			local parts: { string } = {}
			for _, level in { "critical", "error", "warning", "info", "debug", "trace", "unknown" } do
				local n = b.levels[level :: LogsPanel.Level]
				if n then
					table.insert(parts, string.format("%s %d", level, n))
				end
			end
			series[i] = {
				value = if v.max > 0 then b.total / v.max else 0,
				title = string.format(
					"%s  %s%s",
					Range.formatMs(b.t_ms),
					plural(b.total, "line"),
					if #parts > 0 then " (" .. table.concat(parts, ", ") .. ")" else ""
				),
			}
		end
		table.insert(children, {
			k = "chart",
			p = {
				key = "bars",
				kind = "bars",
				size = "sm",
				token = "accent",
				series = series,
				summary = {
					{
						t = string.format(
							"%s per %s, max %d",
							plural(v.total, "line"),
							Step.formatInterval(v.step_ms),
							v.max
						),
						s = "muted",
					},
				},
			},
		})
	elseif s.volume_loading then
		table.insert(children, ui.muted("Loading volume...", { key = "vload" }))
	end
	local chips: { Node } = {}
	for _, chip in State.levelChips(s.lines) do
		local count = if v then v.totals[chip.level] else nil
		local text = string.format("%s %d", chip.value, count or chip.count)
		local active = LogQL.active(s.expr, chip.name, chip.value, false)
		table.insert(
			chips,
			ui.badge(text, if active then "accent" else LogsPanel.tone(chip.level), {
				key = "lv" .. chip.level,
				class = "tg-lg-chip",
				actions = { click = "lvl=" .. chip.level },
				title = string.format('Filter for %s="%s"', chip.name, chip.value),
			})
		)
	end
	if #chips > 0 then
		table.insert(children, ui.row(chips, { key = "levels", wrap = true, gap = "xs" }))
	end
	if #children == 0 then
		return nil
	end
	return ui.col(children, { key = "volume", gap = "xs", class = "tg-lg-volume" })
end

-- Stream labels whose value is not the same on every line (shown dim after
-- the line, so a long label set never hides the line itself).
local function varying(lines: { Line }): { string }
	local first = lines[1]
	if first == nil then
		return {}
	end
	local names: { [string]: boolean } = {}
	for _, l in lines do
		for k, v in l.labels do
			if first.labels[k] ~= v then
				names[k] = true
			end
		end
		for k in first.labels do
			if l.labels[k] == nil then
				names[k] = true
			end
		end
	end
	local out: { string } = {}
	for k in names do
		-- The level tag already shows these.
		if k ~= "detected_level" and k ~= "level" then
			table.insert(out, k)
		end
	end
	table.sort(out)
	return out
end

local function detail(s: State, line: Line): Node
	local children: { Node } = {
		ui.text({ ui.span(line.line) }, { key = "full", wrap = "word", class = "tg-lg-full" }),
	}
	local sections: { [string]: { Node } } = {}
	local order: { string } = {}
	for i, f in State.fields(line) do
		local list = sections[f.kind]
		if list == nil then
			list = {}
			sections[f.kind] = list
			table.insert(order, f.kind)
		end
		local selected = i == s.field_sel
		table.insert(
			list,
			ui.row({
				ui.badge(f.name .. "=" .. f.value, if selected then "accent" else "neutral", {
					key = "inc",
					class = "tg-lg-chip",
					actions = { click = "inc=" .. i },
					title = "Filter for this value (f)",
				}),
				ui.badge("-", "neutral", {
					key = "exc",
					class = "tg-lg-chip",
					actions = { click = "exc=" .. i },
					title = "Filter out this value (x)",
				}),
			}, { key = "f" .. i, gap = "none" })
		)
	end
	for _, kind in order do
		table.insert(children, ui.text({ ui.span(KIND_TITLES[kind], "muted") }, { key = "h" .. kind }))
		table.insert(children, ui.row(sections[kind], { key = kind, wrap = true, gap = "xs" }))
	end
	if #order == 0 then
		table.insert(children, ui.muted("No labels", { key = "none" }))
	end
	table.insert(
		children,
		ui.muted(clock(line.time_ms) .. "  ts " .. line.ts_ns .. "  f/x filter, left/right select", { key = "meta" })
	)
	return ui.col(children, { key = "detail", gap = "xs", class = "tg-lg-detail" })
end

local function lines(s: State): Node
	if #s.lines == 0 then
		local text = if s.status == "loading" then "Running..." else "No log lines in this range."
		return ui.muted(text, { key = "lines" })
	end
	local show = varying(s.lines)
	local rows: { Node } = table.create(#s.lines)
	for i, l in s.lines do
		local spans: { ui.SpanLike } = {
			ui.span(clock(l.time_ms) .. " ", "muted"),
			ui.span(LEVEL_TAGS[l.level] .. " ", LogsPanel.tone(l.level)),
		}
		table.insert(spans, ui.span(l.line))
		if #show > 0 then
			local parts: { string } = {}
			for _, k in show do
				local v = l.labels[k]
				if v then
					table.insert(parts, k .. "=" .. v)
				end
			end
			if #parts > 0 then
				table.insert(spans, ui.span("  " .. table.concat(parts, " "), "dim"))
			end
		end
		local open = s.detail == l.id
		local class = "tg-lg-row tg-lg-" .. LogsPanel.tone(l.level) .. (if s.sel == i then " is-sel" else "")
		local children: { Node }
		if State.traceIdOf(s, l) then
			children = {
				ui.row({
					ui.text(spans, { key = "t", truncate = "end", grow = 1, basis = 0 }),
					ui.badge("trace", "accent", {
						key = "tr",
						class = "tg-lg-chip",
						shrink = 0,
						actions = { click = "trace=" .. l.id },
						title = "Open this line's trace (T)",
					}),
				}, { key = "tl", gap = "xs", align = "center" }),
			}
		else
			children = { ui.text(spans, { key = "t", truncate = "end" }) }
		end
		if open then
			table.insert(children, detail(s, l))
		end
		rows[i] = ui.el("div", { key = "r" .. l.id, class = class, actions = { click = "row=" .. l.id } }, children)
	end
	return ui.col(rows, { key = "lines", gap = "none", role = "tern-grafana.logs-lines" })
end

local function body(s: State): (Node, Assets.Assets?)
	local f = failure(s)
	if f then
		return f, nil
	end
	local r = s.ran
	if r == nil then
		local text = if s.status == "loading" then "Running..." else "Write a LogQL query and press Enter."
		return ui.muted(text, { key = "empty" }), nil
	end
	if r.metric then
		local chart = s.chart
		if chart == nil then
			return ui.muted("No data", { key = "empty" }), nil
		end
		return ChartView.view(chart, { key = "chart", alt = "LogQL metric chart" })
	end
	return lines(s), nil
end

local function help(): Node
	local items: { { { ui.SpanLike } } } = {}
	for _, k in M.KEYS do
		table.insert(items, { { ui.span(k[1], "key") }, { ui.span(k[2]) } })
	end
	return ui.col({
		ui.text({ ui.span("Tern Grafana logs keys", "strong"), ui.span("   esc or ? closes", "muted") }, {
			key = "title",
		}),
		ui.kv(items),
	}, { role = "tern-grafana.logs-help" })
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
	local vol = volume(s)
	if vol then
		table.insert(children, vol)
	end
	local result, assets = body(s)
	table.insert(children, result)
	return {
		main = ui.col(children, { role = "tern-grafana.logs" }),
		layer = if s.overlay == "help" then help() else nil,
	},
		assets
end

return M
