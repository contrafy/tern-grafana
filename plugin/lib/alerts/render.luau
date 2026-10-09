--!strict
-- The alerts inbox view: header (context, counts, filter), groups with their
-- alerts, the open alert's detail, and a key-hint dock.

local Effect = require("../effect")
local Env = require("../env")
local Normalize = require("./normalize")
local Sources = require("./sources")
local State = require("./state")
local Summary = require("./summary")
local RulesRender = require("./rules_render")
local SilenceApi = require("../silences/api")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type Alert = Normalize.Alert
type State = State.State

local M = {}

local STATE_TONE: { [string]: string } = {
	firing = "error",
	pending = "warning",
	silenced = "muted",
	inhibited = "muted",
	resolved = "ok",
}

local SPAN_STYLE: { [string]: string } = {
	error = "error",
	warning = "warning",
	info = "accent",
	muted = "muted",
	ok = "muted",
}

-- "42s", "5m", "3h", "2d".
function M.age(ms: number): string
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

local function severityTone(a: Alert): string
	if a.state == "silenced" or a.state == "inhibited" then
		return "muted"
	end
	return Summary.tone(a.severity)
end

local function chip(text: string, action: string, key: string, tone: string?): Node
	return ui.badge(text, tone or "neutral", { key = key, actions = { click = action }, class = "tg-al-chip" })
end

local function header(s: State, env: Env.Env): Node
	local counts: { [string]: number } = {}
	for _, a in s.alerts do
		counts[a.state] = (counts[a.state] or 0) + 1
	end
	local items: { Node } = {}
	for i, name in s.contexts do
		table.insert(items, chip(name, "ctx=" .. name, "c" .. i, if name == s.context then "info" else "neutral"))
	end
	for _, st in { "firing", "pending", "silenced", "inhibited" } do
		local n = counts[st] or 0
		if n > 0 or st == "firing" then
			table.insert(
				items,
				ui.badge(string.format("%d %s", n, st), if n > 0 then STATE_TONE[st] else "muted", { key = "n" .. st })
			)
		end
	end
	local when: { SpanLike } = {}
	if s.loading then
		table.insert(when, ui.span("loading", "accent"))
	elseif s.loaded_ms then
		table.insert(when, ui.span("updated " .. M.age(env.now_ms - (s.loaded_ms :: number)) .. " ago", "muted"))
	end
	table.insert(items, ui.text(when, { key = "when" }))
	return ui.row(items, { key = "head", class = "tg-al-head", wrap = true })
end

local function filterLine(s: State): Node
	if s.editing ~= nil then
		return {
			k = "input",
			p = {
				key = "filter",
				text = s.editing,
				cursor = utf8.len(s.editing :: string) or #(s.editing :: string),
				placeholder = 'alertname=~"Disk.*" severity!=info text',
				prompt = { { t = "/ ", s = "muted" } },
			},
		}
	end
	local spans: { SpanLike } = {}
	if s.filter_text ~= "" then
		table.insert(spans, ui.span("filter ", "muted"))
		table.insert(spans, ui.span(s.filter_text, "mono"))
		if s.view == "rules" then
			table.insert(spans, ui.span(string.format("  %d of %d rules", #s.rule_rows, #s.rules), "muted"))
		else
			table.insert(spans, ui.span(string.format("  %d of %d", s.shown, #s.alerts), "muted"))
		end
	else
		table.insert(spans, ui.span("/ filters by text or label matchers (a=b a!=b a=~re a!~re)", "muted"))
	end
	if s.filter_error then
		table.insert(spans, ui.span("  " .. (s.filter_error :: string), "error"))
	end
	if not s.show_muted and s.view == "inbox" then
		local muted = 0
		for _, a in s.alerts do
			if a.state == "silenced" or a.state == "inhibited" then
				muted += 1
			end
		end
		if muted > 0 then
			table.insert(spans, ui.span(string.format("  %d silenced or inhibited hidden (m shows)", muted), "muted"))
		end
	end
	return ui.text(spans, { key = "filter", actions = { click = "filter" } })
end

local function labelSpans(a: Alert, skip: { [string]: boolean }): { SpanLike }
	local names: { string } = {}
	for name in a.labels do
		if not skip[name] and not Normalize.isInternal(name) and name ~= "severity" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	local out: { SpanLike } = {}
	for _, name in names do
		table.insert(out, ui.span("  " .. name .. "=", "muted"))
		table.insert(out, ui.span(a.labels[name], "mono"))
	end
	return out
end

local function link(text: string, target: string?, act: string, key: string): Node?
	if target == nil then
		return nil
	end
	return ui.el("button", { key = key, class = "tg-al-btn", text = text, actions = { click = "open=" .. act } })
end

local function detail(s: State, a: Alert, env: Env.Env): Node
	local items: { { { SpanLike } } } = {}
	local function pair(k: string, v: { SpanLike })
		local head: { SpanLike } = { k }
		table.insert(items, { head, v })
	end
	pair("state", { ui.span(a.state, SPAN_STYLE[STATE_TONE[a.state]] or "muted") })
	pair("severity", { a.severity })
	pair("since", { M.age(env.now_ms - a.starts_at_ms) .. " ago" })
	pair("source", { a.source .. " (" .. a.context .. ")" })
	if a.value then
		pair("value", { ui.span(a.value :: string, "mono") })
	end
	if #a.silenced_by > 0 then
		pair("silenced by", { ui.span(table.concat(a.silenced_by, ", "), "mono") })
	end
	if #a.inhibited_by > 0 then
		pair("inhibited by", { ui.span(table.concat(a.inhibited_by, ", "), "mono") })
	end
	if #a.receivers > 0 then
		pair("receivers", { table.concat(a.receivers, ", ") })
	end
	local labelItems: { { { SpanLike } } } = {}
	local names: { string } = {}
	for name in a.labels do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		if not Normalize.isInternal(name) then
			table.insert(labelItems, { { ui.span(name, "mono") }, { ui.span(a.labels[name], "mono") } })
		end
	end
	local annItems: { { { SpanLike } } } = {}
	local anns: { string } = {}
	for name in a.annotations do
		table.insert(anns, name)
	end
	table.sort(anns)
	for _, name in anns do
		if not Normalize.isInternal(name) then
			table.insert(annItems, { { name }, { a.annotations[name] } })
		end
	end
	local buttons: { Node } = {}
	local targets: { { label: string, target: string?, act: string } } = {
		{ label = "Runbook (o)", target = Sources.runbookTarget(a), act = "runbook" },
		{ label = "Dashboard (d)", target = Sources.dashboardTarget(a), act = "dashboard" },
		{ label = "Source (g)", target = Sources.generatorTarget(a), act = "generator" },
		{
			label = "Silence (s)",
			target = if s.plan and SilenceApi.target(s.plan) then "silence" else nil,
			act = "silence",
		},
	}
	for _, b in targets do
		local n = link(b.label, b.target, b.act, "b" .. b.act)
		if n then
			table.insert(buttons, n)
		end
	end
	table.insert(
		buttons,
		ui.el(
			"button",
			{ key = "bcopy", class = "tg-al-btn", text = "Copy matchers (y)", actions = { click = "copy" } }
		)
	)
	local children: { Node } = { ui.kv(items) }
	if #labelItems > 0 then
		table.insert(children, ui.rule({ "labels" }, { key = "rl" }))
		table.insert(children, ui.kv(labelItems))
	end
	if #annItems > 0 then
		table.insert(children, ui.rule({ "annotations" }, { key = "ra" }))
		table.insert(children, ui.kv(annItems))
	end
	table.insert(children, ui.row(buttons, { key = "links", wrap = true }))
	return ui.col(children, { key = "detail", class = "tg-al-detail" })
end

local function alertRow(s: State, i: number, a: Alert, skip: { [string]: boolean }, env: Env.Env): Node
	local tone = severityTone(a)
	local spans: { SpanLike } = {
		ui.span(string.format("%-9s", a.state), SPAN_STYLE[STATE_TONE[a.state]] or "muted"),
		ui.span(string.format("%-8s ", a.severity), SPAN_STYLE[tone] or "muted"),
		ui.span(a.summary, "strong"),
	}
	for _, sp in labelSpans(a, skip) do
		table.insert(spans, sp)
	end
	table.insert(spans, ui.span("  " .. M.age(env.now_ms - a.starts_at_ms), "muted"))
	local class = "tg-al-row tg-al-" .. tone .. (if i == s.sel then " is-sel" else "")
	local children: { Node } = { ui.text(spans) }
	if s.detail == a.fingerprint then
		table.insert(children, detail(s, a, env))
	end
	return ui.el("div", { key = "r" .. a.fingerprint, class = class, actions = { click = "row=" .. i } }, children)
end

local function groups(s: State, env: Env.Env): Node
	local out: { Node } = {}
	local rowIndex: { [any]: number } = {}
	local groupRow: { [number]: number } = {}
	for i, r in s.rows do
		if r.kind == "group" then
			groupRow[r.group] = i
		else
			rowIndex[(r :: any).alert] = i
		end
	end
	for gi, g in s.groups do
		local head: { SpanLike } = {}
		local skip: { [string]: boolean } = {}
		for j, l in g.labels do
			skip[l.name] = true
			if j > 1 then
				table.insert(head, ui.span("  ", "muted"))
			end
			table.insert(head, ui.span(l.name .. "=", "muted"))
			table.insert(head, ui.span(l.value, "strong"))
		end
		if #g.labels == 0 then
			table.insert(head, ui.span("(no group labels)", "muted"))
		end
		local parts: { string } = {}
		for _, st in { "firing", "pending", "silenced", "inhibited" } do
			local n = g.counts[st :: Normalize.State]
			if n then
				table.insert(parts, string.format("%d %s", n, st))
			end
		end
		table.insert(head, ui.span("   " .. table.concat(parts, ", "), "muted"))
		local rows: { Node } = {}
		for _, a in g.alerts do
			local i = rowIndex[a]
			if i then
				table.insert(rows, alertRow(s, i, a, skip, env))
			end
		end
		table.insert(
			out,
			ui.card(head, rows, {
				key = "g" .. gi,
				collapsible = true,
				collapsed = s.collapsed[g.key] == true,
				selected = groupRow[gi] == s.sel,
				tone = if g.worst ~= "none" then Summary.tone(g.worst) else nil,
				inset = true,
			})
		)
	end
	return ui.col(out, { key = "groups" })
end

local function emptyNote(s: State): Node?
	if s.loading and s.loaded_ms == nil then
		return ui.muted("Loading alerts...", { key = "empty" })
	end
	if #s.rows > 0 or s.loaded_ms == nil then
		return nil
	end
	if #s.alerts == 0 then
		return ui.text({ ui.span("Nothing is firing or pending.", "muted") }, { key = "empty" })
	end
	return ui.muted("Nothing matches the filter. Esc clears it.", { key = "empty" })
end

local function viewTabs(s: State): { Node }
	return {
		chip("Inbox", "view=inbox", "vinbox", if s.view == "inbox" then "info" else "neutral"),
		chip("Rules", "view=rules", "vrules", if s.view == "rules" then "info" else "neutral"),
	}
end

function M.view(s: State, env: Env.Env): Effect.View
	local children: { Node } = { ui.row(viewTabs(s), { key = "tabs" }), header(s, env) }
	if s.view == "rules" then
		table.insert(children, filterLine(s))
		if s.note then
			table.insert(children, ui.text({ ui.span(s.note :: string, "warning") }, { key = "note" }))
		end
		for _, n in RulesRender.body(s, env) do
			table.insert(children, n)
		end
		return {
			main = ui.col(children, { role = "tern-grafana.alerts" }),
			dock = ui.col({
				ui.text({
					ui.span(
						"j/k move  enter details  q query  a alerts  p problems only  / filter  v inbox  c context  r refresh",
						"muted"
					),
				}, { key = "keys" }),
			}, { key = "dock" }),
		}
	end
	if s.problem then
		table.insert(children, ui.text({ ui.span(s.problem :: string, "error") }, { key = "problem" }))
		return { main = ui.col(children, { role = "tern-grafana.alerts" }) }
	end
	table.insert(children, filterLine(s))
	if s.error then
		table.insert(
			children,
			ui.text({
				ui.span(s.error :: string, "error"),
				ui.span(
					if #s.alerts > 0 then "  (showing the last good answer; r retries)" else "  (r retries)",
					"muted"
				),
			}, { key = "error" })
		)
	end
	for i, w in s.warnings do
		table.insert(children, ui.text({ ui.span("pending alerts unavailable: " .. w, "warning") }, { key = "w" .. i }))
	end
	if s.note then
		table.insert(children, ui.text({ ui.span(s.note :: string, "warning") }, { key = "note" }))
	end
	local empty = emptyNote(s)
	if empty then
		table.insert(children, empty)
	end
	table.insert(children, groups(s, env))
	local hints = ui.text({
		ui.span(
			"j/k move  enter open  / filter  m muted  c context  r refresh  o runbook  d dashboard  g source  s silence  y copy  v rules",
			"muted"
		),
	}, { key = "keys" })
	return {
		main = ui.col(children, { role = "tern-grafana.alerts" }),
		dock = ui.col({ hints }, { key = "dock" }),
	}
end

return M
