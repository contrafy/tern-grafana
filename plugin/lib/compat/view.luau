--!strict
-- The compat block's view (lib/compat/state): header with the context and
-- Grafana's renderer, scan progress, the causes by count, then every
-- dashboard with its panels' rungs. Classes reuse plugin/ops.css (`tg-op-`).

local Analyze = require("./analyze")
local Effect = require("../effect")
local Env = require("../env")
local Markdown = require("./markdown")
local State = require("./state")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type State = State.State

local M = {}

local MODE_STYLE = { native = "success", png = "warning", browser = "error" }

local HINTS = "up/down select  enter open (dashboard, or the panel's Panel block)  d dashboard  / filter  "
	.. "n native panels  m copy as Markdown  r rescan  c context"

local function chip(text: string, action: string, key: string, tone: string?): Node
	return ui.badge(text, tone or "neutral", { key = key, actions = { click = action }, class = "tg-op-chip" })
end

local function button(text: string, action: string, key: string): Node
	return ui.el("button", { key = key, class = "tg-op-btn", text = text, actions = { click = action } })
end

local function pct(n: number, total: number): string
	return if total == 0 then "0%" else string.format("%d%%", math.floor(n * 100 / total + 0.5))
end

local function header(s: State): Node
	local items: { Node } = {}
	for i, name in s.contexts do
		table.insert(items, chip(name, "ctx=" .. name, "c" .. i, if name == s.context then "info" else "neutral"))
	end
	local spans: { SpanLike } = {}
	local settings = s.settings
	if settings then
		table.insert(spans, ui.span("Grafana " .. (settings.version or "(unknown version)"), "strong"))
		table.insert(
			spans,
			ui.span(
				if settings.renderer
					then "  image renderer available: non-native panels get a Grafana PNG"
					else "  no image renderer: non-native panels open in the browser",
				"muted"
			)
		)
	end
	table.insert(items, ui.text(spans, { key = "server" }))
	table.insert(items, button("Rescan", "scan", "scan"))
	-- Not "copy": a click action named "copy" copies the node's own text in Tern.
	table.insert(items, button("Copy as Markdown", "markdown", "copy"))
	return ui.row(items, { key = "head", class = "tg-op-head", wrap = true })
end

local function progress(s: State): Node?
	if s.phase == "scanning" then
		local text = if s.search_done
			then string.format("Scanning dashboards: %d of %d done, %d loading", s.finished, #s.hits, s.inflight)
			else string.format("Listing dashboards: %d found so far", #s.hits)
		return ui.text({ ui.span(text, "accent") }, { key = "progress" })
	elseif s.phase == "done" then
		local secs = if s.started_ms and s.finished_ms
			then math.floor(((s.finished_ms :: number) - (s.started_ms :: number)) / 1000 + 0.5)
			else nil
		local text = string.format("Scanned %d dashboards", #s.hits)
		if secs then
			text ..= string.format(" in %d s", secs)
		end
		return ui.text({ ui.span(text, "muted") }, { key = "progress" })
	elseif s.phase == "error" then
		return ui.text({ ui.span(s.error or "the scan failed", "error"), ui.span("  (r retries)", "muted") }, {
			key = "progress",
		})
	elseif s.problem == nil then
		return ui.muted("Press r to scan every dashboard of this context.", { key = "progress" })
	end
	return nil
end

local function totals(sum: Analyze.Summary): Node
	return ui.text({
		ui.span(string.format("%d panels in %d dashboards: ", sum.panels, sum.dashboards), "strong"),
		ui.span(string.format("native %d (%s)", sum.native, pct(sum.native, sum.panels)), "success"),
		ui.span(string.format("  Grafana PNG %d (%s)", sum.png, pct(sum.png, sum.panels)), "warning"),
		ui.span(string.format("  browser %d (%s)", sum.browser, pct(sum.browser, sum.panels)), "error"),
		ui.span(
			if sum.failed > 0 then string.format("  %d dashboards could not be loaded", sum.failed) else "",
			"error"
		),
	}, { key = "totals" })
end

local function reasons(sum: Analyze.Summary): Node
	if #sum.reasons == 0 then
		return ui.muted(if sum.panels == 0 then "No panels yet." else "Every panel is native.", { key = "reasons" })
	end
	local lines: { Node } = table.create(#sum.reasons)
	for i, r in sum.reasons do
		lines[i] = ui.text({
			ui.span(string.format("%d panels", r.panels), "strong"),
			ui.span(string.format(" in %d dashboards  ", r.dashboards), "muted"),
			ui.span(Markdown.modeText(r.mode), MODE_STYLE[r.mode]),
			ui.span("  " .. r.reason),
			ui.span("  " .. Analyze.typesText(r.types), "muted"),
		}, { key = "g" .. i })
	end
	return ui.section({ "Not native, by reason" }, lines, { key = "reasons" })
end

local function filterLine(s: State): Node
	if s.editing ~= nil then
		return {
			k = "input",
			p = {
				key = "filter",
				text = s.editing,
				cursor = utf8.len(s.editing :: string) or #(s.editing :: string),
				placeholder = "dashboard, panel, type, rung or reason",
				prompt = { { t = "/ ", s = "muted" } },
			},
		}
	end
	local spans: { SpanLike } = {}
	if s.filter_text ~= "" then
		table.insert(spans, ui.span("filter ", "muted"))
		table.insert(spans, ui.span(s.filter_text, "mono"))
		table.insert(spans, ui.span(string.format("  %d rows", s.matched), "muted"))
	else
		table.insert(spans, ui.span("/ filter: dashboard, panel, type, rung or reason", "muted"))
	end
	table.insert(
		spans,
		ui.span(if s.show_native then "   n hides native panels" else "   n shows native panels too", "muted")
	)
	return ui.text(spans, { key = "filter", actions = { click = "filter" } })
end

local function dashRow(r: Analyze.DashResult): Node
	local spans: { SpanLike } = { ui.span(r.title, "strong") }
	if r.folder and r.folder ~= "" then
		table.insert(spans, ui.span("  " .. (r.folder :: string), "muted"))
	end
	if r.error then
		table.insert(spans, ui.span("  " .. (r.error :: string), "error"))
	else
		table.insert(spans, ui.span(string.format("  native %d", r.native), "success"))
		if r.png > 0 then
			table.insert(spans, ui.span(string.format("  png %d", r.png), "warning"))
		end
		if r.browser > 0 then
			table.insert(spans, ui.span(string.format("  browser %d", r.browser), "error"))
		end
	end
	return ui.text(spans)
end

local function panelRow(p: Analyze.PanelResult): Node
	local spans: { SpanLike } = {
		ui.span("    " .. Markdown.modeText(p.mode) .. "  ", MODE_STYLE[p.mode]),
		ui.span(if p.title == "" then "(untitled)" else p.title),
		ui.span("  " .. p.type, "mono"),
	}
	if p.blocker then
		table.insert(spans, ui.span("  " .. (p.blocker :: string), "muted"))
	end
	local where = Markdown.placement(p)
	if where ~= "" then
		table.insert(spans, ui.span("  (" .. where .. ")", "muted"))
	end
	return ui.text(spans)
end

local function list(s: State): Node
	local children: { Node } = table.create(#s.rows)
	for i, row in s.rows do
		local r = s.results[row.dash]
		local body = if row.kind == "panel" then panelRow(r.panels[(row :: any).panel]) else dashRow(r)
		local class = "tg-op-row" .. (if i == s.sel then " is-sel" else "")
		children[i] = ui.el("div", { key = "r" .. i, class = class, actions = { click = "row=" .. i } }, { body })
	end
	if #children == 0 then
		table.insert(
			children,
			ui.muted(if s.filter_text ~= "" then "Nothing matches the filter." else "No dashboards yet.")
		)
	end
	return ui.col(children, { key = "list", gap = "none" })
end

function M.view(s: State, _env: Env.Env): Effect.View
	local children: { Node } = { header(s) }
	if s.problem then
		table.insert(children, ui.text({ ui.span(s.problem :: string, "error") }, { key = "problem" }))
		return { main = ui.col(children, { role = "tern-grafana.compat" }) }
	end
	local p = progress(s)
	if p then
		table.insert(children, p)
	end
	if s.capped then
		table.insert(
			children,
			ui.text({
				ui.span(
					string.format(
						"Capped at %d dashboards (config compat.max_dashboards); the search found at least %d.",
						s.max,
						s.found
					),
					"warning"
				),
			}, { key = "capped" })
		)
	end
	if s.note then
		table.insert(children, ui.muted(s.note :: string, { key = "note" }))
	end
	local sum = Analyze.summarize(State.ordered(s))
	table.insert(children, totals(sum))
	table.insert(children, reasons(sum))
	table.insert(children, filterLine(s))
	table.insert(children, list(s))
	if s.matched > #s.rows then
		table.insert(
			children,
			ui.muted(
				string.format(
					"Showing %d of %d rows: filter to narrow, or copy the whole report with m.",
					#s.rows,
					s.matched
				),
				{ key = "more" }
			)
		)
	end
	return {
		main = ui.col(children, { role = "tern-grafana.compat" }),
		dock = ui.col({ ui.muted(HINTS, { key = "keys" }) }, { key = "dock" }),
	}
end

return M
