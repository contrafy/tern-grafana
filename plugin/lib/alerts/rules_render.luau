--!strict
-- The alerts block's rules view: one line per rule (status, health, name,
-- last evaluation), grouped under their source and rule group, and the open
-- rule's details (query, last error, labels, annotations).

local Env = require("../env")
local Normalize = require("./normalize")
local Rules = require("./rules")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type Rule = Normalize.Rule

local M = {}

-- The view id of rule row `i` (for the `reveal` effect).
function M.rowId(i: number): string
	return "main.rules.u" .. i
end

local STATUS_STYLE: { [string]: string } = {
	firing = "error",
	pending = "warning",
	inactive = "muted",
	paused = "muted",
	recording = "accent",
}

local STATUS_TONE: { [string]: string } = {
	firing = "error",
	pending = "warning",
	inactive = "muted",
	paused = "muted",
	recording = "info",
}

local function ago(ms: number): string
	local sec = math.max(0, math.floor(ms / 1000))
	if sec < 60 then
		return sec .. "s"
	elseif sec < 3600 then
		return (sec // 60) .. "m"
	elseif sec < 86400 then
		return (sec // 3600) .. "h"
	end
	return (sec // 86400) .. "d"
end

local function evalTime(s: number): string
	if s < 1 then
		return string.format("%.1fms", s * 1000)
	end
	return string.format("%.2fs", s)
end

local function button(text: string, act: string, key: string): Node
	return ui.el("button", { key = key, class = "tg-al-btn", text = text, actions = { click = act } })
end

local function pair(items: { { { SpanLike } } }, k: string, v: { SpanLike })
	local head: { SpanLike } = { k }
	table.insert(items, { head, v })
end

local function detail(r: Rule, env: Env.Env): Node
	local items: { { { SpanLike } } } = {}
	pair(items, "type", { r.type :: string })
	pair(items, "health", { ui.span(r.health, if Rules.unhealthy(r) then "error" else "muted") })
	if r.last_error then
		pair(items, "last error", { ui.span(r.last_error :: string, "error") })
	end
	if r.last_evaluation_ms then
		pair(items, "last evaluation", { ago(env.now_ms - (r.last_evaluation_ms :: number)) .. " ago" })
	end
	if r.evaluation_s then
		pair(items, "evaluation time", { evalTime(r.evaluation_s :: number) })
	end
	if r.interval_s then
		pair(items, "interval", { tostring(r.interval_s) .. "s" })
	end
	if r.duration_s and (r.duration_s :: number) > 0 then
		pair(items, "for", { tostring(r.duration_s) .. "s" })
	end
	pair(items, "group", { r.group .. (if r.file ~= "" then "  (" .. r.file .. ")" else "") })
	if r.uid then
		pair(items, "uid", { ui.span(r.uid :: string, "mono") })
	end
	if r.type == "alerting" then
		pair(items, "alerts", { tostring(#r.alerts) })
	end
	local children: { Node } = { ui.kv(items) }
	if r.query ~= "" then
		table.insert(children, ui.code(r.query, "promql", nil, { key = "q" }))
	end
	local labels: { { { SpanLike } } } = {}
	local names: { string } = {}
	for name in r.labels do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		if not Normalize.isInternal(name) then
			local k: { SpanLike } = { ui.span(name, "mono") }
			table.insert(labels, { k, { ui.span(r.labels[name], "mono") } })
		end
	end
	if #labels > 0 then
		table.insert(children, ui.rule({ "labels" }, { key = "rl" }))
		table.insert(children, ui.kv(labels))
	end
	local anns: { { { SpanLike } } } = {}
	names = {}
	for name in r.annotations do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		if not Normalize.isInternal(name) then
			pair(anns, name, { r.annotations[name] })
		end
	end
	if #anns > 0 then
		table.insert(children, ui.rule({ "annotations" }, { key = "ra" }))
		table.insert(children, ui.kv(anns))
	end
	local buttons: { Node } = {}
	if Rules.queryLink(r) then
		table.insert(buttons, button("Query (q)", "rule=query", "bq"))
	end
	if r.type == "alerting" then
		table.insert(buttons, button("Alerts (a)", "rule=alerts", "ba"))
	end
	if #buttons > 0 then
		table.insert(children, ui.row(buttons, { key = "acts" }))
	end
	return ui.col(children, { key = "detail", class = "tg-al-detail" })
end

local function row(s: any, i: number, r: Rule, env: Env.Env): Node
	local status = Rules.status(r)
	local bad = Rules.unhealthy(r)
	local spans: { SpanLike } = {
		ui.span(string.format("%-9s ", status), STATUS_STYLE[status] or "muted"),
		ui.span(string.format("%-6s ", r.health), if bad then "error" else "muted"),
		ui.span(r.name, "strong"),
	}
	if r.type == "alerting" and #r.alerts > 0 then
		table.insert(
			spans,
			ui.span(string.format("  %d alert%s", #r.alerts, if #r.alerts == 1 then "" else "s"), "muted")
		)
	end
	if r.last_evaluation_ms then
		table.insert(spans, ui.span("  " .. ago(env.now_ms - (r.last_evaluation_ms :: number)) .. " ago", "muted"))
	end
	if r.evaluation_s then
		table.insert(spans, ui.span("  " .. evalTime(r.evaluation_s :: number), "muted"))
	end
	local children: { Node } = { ui.text(spans) }
	if r.last_error then
		table.insert(children, ui.text({ ui.span(r.last_error :: string, "error") }, { key = "err" }))
	end
	if s.rule_detail == Rules.key(r) then
		table.insert(children, detail(r, env))
	end
	local class = "tg-al-row" .. (if bad then " tg-al-error" else "") .. (if i == s.rule_sel then " is-sel" else "")
	return ui.el("div", { key = "u" .. i, class = class, actions = { click = "rrow=" .. i } }, children)
end

-- Everything below the shared header and filter line. `s` is the alerts
-- block state (typed loosely to avoid a require cycle with ./state).
function M.body(s: any, env: Env.Env): { Node }
	local out: { Node } = {}
	if s.rules_problem then
		table.insert(out, ui.text({ ui.span(s.rules_problem, "error") }, { key = "rproblem" }))
		return out
	end
	local counts: { [string]: number } = {}
	local unhealthy = 0
	for _, r in s.rules do
		local st = Rules.status(r)
		counts[st] = (counts[st] or 0) + 1
		if Rules.unhealthy(r) then
			unhealthy += 1
		end
	end
	local summary: { Node } = {}
	for _, st in { "firing", "pending", "inactive", "paused", "recording" } do
		local n = counts[st] or 0
		if n > 0 then
			table.insert(
				summary,
				ui.badge(string.format("%d %s", n, st), STATUS_TONE[st] or "muted", { key = "k" .. st })
			)
		end
	end
	table.insert(
		summary,
		ui.badge(
			if s.problems_only
				then string.format("showing %d unhealthy (p shows all)", unhealthy)
				else string.format("%d unhealthy (p shows only these)", unhealthy),
			if unhealthy > 0 then "error" else "muted",
			{ key = "kbad", actions = { click = "problems" }, class = "tg-al-chip" }
		)
	)
	local when: { SpanLike } = {}
	if s.rules_loading then
		table.insert(when, ui.span("loading", "accent"))
	elseif s.rules_loaded_ms then
		table.insert(when, ui.span("updated " .. ago(env.now_ms - s.rules_loaded_ms) .. " ago", "muted"))
	end
	table.insert(summary, ui.text(when, { key = "when" }))
	table.insert(out, ui.row(summary, { key = "rsum", wrap = true }))
	for i, e in s.rules_errors do
		table.insert(out, ui.text({ ui.span(e, "error") }, { key = "re" .. i }))
	end
	if s.rules_loading and s.rules_loaded_ms == nil then
		table.insert(out, ui.muted("Loading rules...", { key = "rempty" }))
	elseif #s.rule_rows == 0 and s.rules_loaded_ms then
		table.insert(
			out,
			ui.muted(
				if #s.rules == 0
					then "No rules."
					else "No rule matches (esc clears the filter, p toggles unhealthy only).",
				{ key = "rempty" }
			)
		)
	end
	local rows: { Node } = {}
	local lastGroup: string? = nil
	for i, r in s.rule_rows do
		local g = r.source .. "\0" .. r.group
		if g ~= lastGroup then
			lastGroup = g
			table.insert(
				rows,
				ui.text({
					ui.span(if r.source == "grafana" then "Grafana  " else "Prometheus  ", "muted"),
					ui.span(r.group, "strong"),
					ui.span(if r.file ~= "" then "  " .. r.file else "", "muted"),
				}, { key = "h" .. i, class = "tg-al-rgroup" })
			)
		end
		table.insert(rows, row(s, i, r, env))
	end
	table.insert(out, ui.col(rows, { key = "rules" }))
	return out
end

return M
