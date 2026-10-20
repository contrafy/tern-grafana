--!strict
-- The incidents block's view: open incidents (severity, status, how long
-- open), one incident's detail and timeline, the declare form, the status
-- and severity pickers, and the confirmation panel of a staged write, which
-- sits on top so it is always in view.

local Common = require("./common")
local Effect = require("../effect")
local Env = require("../env")
local Irm = require("../source/irm")
local State = require("./incidents_state")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type State = State.State
type Incident = Irm.Incident

local M = {}

M.TIMELINE = 30
M.BODY_LINES = 4

local HOOKS = "IRM runs this stack's incident hooks on this change: they may post to chat, notify or page people."

-- Severity labels are the org's own words; the usual ones get a tone.
function M.severityTone(label: string): string
	local l = string.lower(label)
	if string.find(l, "crit", 1, true) or l == "sev1" or l == "p1" then
		return "error"
	elseif string.find(l, "maj", 1, true) or string.find(l, "high", 1, true) or l == "sev2" or l == "p2" then
		return "warning"
	elseif l == "pending" or l == "" then
		return "muted"
	end
	return "accent"
end

local function openFor(x: Incident, env: Env.Env): string
	local from = x.start_ms or x.created_ms
	if from == nil then
		return ""
	end
	return "open " .. Common.age(env.now_ms - (from :: number))
end

local function header(s: State, env: Env.Env): Node
	local items = Common.contextChips(s.contexts, s.context)
	local bySev: { [string]: number } = {}
	local order: { string } = {}
	for _, x in s.incidents do
		if bySev[x.severity] == nil then
			table.insert(order, x.severity)
		end
		bySev[x.severity] = (bySev[x.severity] or 0) + 1
	end
	table.insert(
		items,
		ui.badge(
			string.format("%d open%s", #s.incidents, if s.more then "+" else ""),
			if #s.incidents > 0 then "warning" else "muted",
			{ key = "nopen" }
		)
	)
	for i, sev in order do
		table.insert(
			items,
			ui.badge(
				string.format("%d %s", bySev[sev], if sev == "" then "no severity" else sev),
				M.severityTone(sev),
				{ key = "sev" .. i }
			)
		)
	end
	table.insert(items, ui.text(Common.when(s.loading, s.loaded_ms, env), { key = "when" }))
	return ui.row(items, { key = "head", class = "tg-al-head", wrap = true })
end

local function statusName(s: State, slug: string): string
	for _, st in State.statuses(s) do
		if st.slug == slug then
			return st.name
		end
	end
	return slug
end

local function confirmPanel(s: State): Node
	local p = s.confirm :: State.Pending
	local items: { { { SpanLike } } } = {}
	local function pair(k: string, v: { SpanLike })
		local head: { SpanLike } = { k }
		table.insert(items, { head, v })
	end
	local title: string
	local warnings: { string } = {}
	if p.kind == "declare" then
		local d = p :: any
		title = "Declare this incident?"
		pair("title", { ui.span(d.title, "strong") })
		pair("severity", { ui.span(d.severity, M.severityTone(d.severity)) })
		pair("status", { "active (not a drill)" })
		table.insert(warnings, HOOKS)
	else
		local x = (p :: any).incident :: Incident
		pair("incident", { ui.span(x.id .. "  ", "muted"), ui.span(x.title, "strong") })
		if p.kind == "status" then
			local st = (p :: any).status :: Irm.Status
			title = "Change the status?"
			pair("status", { statusName(s, x.status), ui.span(" -> ", "muted"), ui.span(st.name, "strong") })
			table.insert(warnings, HOOKS)
		elseif p.kind == "severity" then
			local sev = (p :: any).severity :: string
			title = "Change the severity?"
			pair("severity", {
				ui.span(x.severity, M.severityTone(x.severity)),
				ui.span(" -> ", "muted"),
				ui.span(sev, M.severityTone(sev)),
			})
			table.insert(warnings, HOOKS)
		else
			title = "Add this note to the timeline?"
			pair("note", { (p :: any).body })
		end
	end
	pair("server", { (if s.grafana then s.grafana.endpoint.url else "") .. " (context " .. (s.context or "") .. ")" })
	local children: { Node } = { ui.kv(items) }
	for i, w in warnings do
		table.insert(children, ui.text({ ui.span(w, "warning") }, { key = "cpwarn" .. i }))
	end
	table.insert(children, ui.text({ ui.span(Common.notice(s.login), "muted") }, { key = "cpwho" }))
	table.insert(
		children,
		ui.row({
			Common.button("Confirm (y)", "confirm", "bconfirm", "tg-sil-confirm"),
			Common.button("Cancel (n)", "cancel", "bcancel"),
		}, { key = "cpb" })
	)
	return ui.card(
		{ ui.span(title, "strong") },
		children,
		{ key = "confirm", tone = "warning", class = "tg-sil-panel" }
	)
end

local function pickerPanel(s: State): Node
	local p = s.picker :: State.Picker
	local chips: { Node } = {}
	if p.kind == "status" then
		for i, st in State.statuses(s) do
			table.insert(
				chips,
				ui.badge(
					st.name,
					if i == p.index then "info" else "neutral",
					{ key = "o" .. i, actions = { click = "pick=" .. i }, class = "tg-al-chip" }
				)
			)
		end
	else
		for i, sev in State.severities(s) do
			table.insert(
				chips,
				ui.badge(
					sev,
					if i == p.index then "info" else "neutral",
					{ key = "o" .. i, actions = { click = "pick=" .. i }, class = "tg-al-chip" }
				)
			)
		end
	end
	local children: { Node } = { ui.row(chips, { key = "chips", wrap = true }) }
	if p.kind == "severity" and s.org_severities == nil then
		table.insert(
			children,
			ui.muted(
				"This IRM does not list its severities (GetOrgSeverities): these are IRM's defaults and the ones in use.",
				{ key = "pnote" }
			)
		)
	end
	table.insert(
		children,
		ui.muted("left/right choose, enter reviews before anything is sent, esc cancels", { key = "ph" })
	)
	return ui.card(
		{ ui.span(if p.kind == "status" then "New status" else "New severity", "strong") },
		children,
		{ key = "picker", class = "tg-sil-panel" }
	)
end

local function incidentRow(s: State, i: number, x: Incident, env: Env.Env): Node
	local selected = i == s.sel
	local children: { Node } = {
		ui.text({
			ui.span(string.format("%-9s ", if x.severity == "" then "-" else x.severity), M.severityTone(x.severity)),
			ui.span(string.format("%-9s ", statusName(s, x.status)), "accent"),
			ui.span(x.title, "strong"),
		}),
		ui.text({
			ui.span(
				string.format("%s  %s%s", x.id, openFor(x, env), if x.created_by then "  by " .. x.created_by else ""),
				"muted"
			),
		}),
	}
	if selected then
		children[#children + 1] = ui.row({
			Common.button("Detail (enter)", "row=" .. i, "bdet"),
			Common.button("Status (s)", "status", "bst"),
			Common.button("Severity (v)", "severity", "bsev"),
			Common.button("Open in Grafana (o)", "open", "bopen"),
		}, { key = "acts", wrap = true })
	end
	return ui.el("div", {
		key = "i" .. x.id,
		class = "tg-al-row tg-irm-" .. M.severityTone(x.severity) .. (if selected then " is-sel" else ""),
		actions = { click = "row=" .. i },
	}, children)
end

local function listPage(s: State, env: Env.Env): { Node }
	local out: { Node } = {}
	if s.list_error then
		table.insert(
			out,
			ui.text({ ui.span(s.list_error :: string, "error"), ui.span("  (r retries)", "muted") }, { key = "lerr" })
		)
	end
	if #s.incidents == 0 and s.loaded_ms and s.list_error == nil then
		table.insert(out, ui.muted("No open incidents.", { key = "empty" }))
	end
	local rows: { Node } = {}
	for i, x in s.incidents do
		table.insert(rows, incidentRow(s, i, x, env))
	end
	table.insert(out, ui.col(rows, { key = "list", gap = "none" }))
	return out
end

local function detailPage(s: State, env: Env.Env): { Node }
	local out: { Node } = {}
	local d = s.detail
	if d == nil then
		return out
	end
	if d.error then
		table.insert(out, ui.text({ ui.span(d.error :: string, "error") }, { key = "derr" }))
	end
	local x = d.incident
	if x == nil then
		table.insert(out, ui.muted(if d.loading then "loading the incident" else "", { key = "dload" }))
		return out
	end
	local items: { { { SpanLike } } } = {}
	local function pair(k: string, v: { SpanLike })
		local head: { SpanLike } = { k }
		table.insert(items, { head, v })
	end
	pair("status", { ui.span(statusName(s, x.status), "accent") })
	pair("severity", { ui.span(if x.severity == "" then "none" else x.severity, M.severityTone(x.severity)) })
	local from = x.start_ms or x.created_ms
	if from then
		pair("started", { Common.clock(from :: number, env), ui.span("  " .. openFor(x, env), "muted") })
	end
	if x.closed_ms then
		pair("closed", { Common.clock(x.closed_ms :: number, env) })
	end
	if x.created_by then
		pair("declared by", { x.created_by :: string })
	end
	for _, r in x.roles do
		pair(r.role, { r.name })
	end
	if x.drill then
		pair("drill", { "yes" })
	end
	pair("id", { ui.span(x.id, "mono") })
	local children: { Node } = { ui.kv(items) }
	if x.summary then
		table.insert(children, ui.text({ ui.span(x.summary :: string) }, { key = "sum" }))
	end
	table.insert(
		children,
		ui.row({
			Common.button("Status (s)", "status", "bst"),
			Common.button("Severity (v)", "severity", "bsev"),
			Common.button("Add note (a)", "addnote", "bnote"),
			Common.button("Open in Grafana (o)", "open", "bopen"),
			Common.button("Back (esc)", "back", "bback"),
		}, { key = "acts", wrap = true })
	)
	table.insert(out, ui.card({ ui.span(x.title, "strong") }, children, { key = "inc" }))
	table.insert(out, ui.rule({ "timeline" }, { key = "rt" }))
	if d.activity_error then
		table.insert(out, ui.text({ ui.span(d.activity_error :: string, "error") }, { key = "aerr" }))
	end
	local lines: { Node } = {}
	for i, a in (d.activity or {}) :: { Irm.Activity } do
		if i > M.TIMELINE then
			table.insert(
				lines,
				ui.muted(string.format("... and %d older items", #(d.activity :: { any }) - M.TIMELINE))
			)
			break
		end
		local head: { SpanLike } = {
			ui.span(if a.time_ms then Common.clock(a.time_ms :: number, env) .. "  " else "", "muted"),
			ui.span(a.kind, if a.kind == "userNote" then "accent" else "muted"),
		}
		if a.user then
			table.insert(head, ui.span("  " .. (a.user :: string), "muted"))
		end
		local item: { Node } = { ui.text(head) }
		local n = 0
		for line in string.gmatch(a.body, "[^\n]+") do
			n += 1
			if n > M.BODY_LINES then
				table.insert(item, ui.muted("  ..."))
				break
			end
			table.insert(item, ui.text({ ui.span("  " .. line) }))
		end
		table.insert(lines, ui.col(item, { key = "a" .. a.id, gap = "none" }))
	end
	if d.activity and #(d.activity :: { any }) == 0 then
		table.insert(lines, ui.muted("No timeline items."))
	end
	table.insert(out, ui.col(lines, { key = "timeline", gap = "none" }))
	return out
end

local function declarePage(s: State): { Node }
	local form = s.form :: State.Form
	local out: { Node } = {
		ui.text({ ui.span(HOOKS, "warning") }, { key = "dwarn" }),
	}
	local sevChips: { Node } = {}
	for i, sev in State.severities(s) do
		table.insert(
			sevChips,
			ui.badge(
				sev,
				if i == form.severity then "info" else "neutral",
				{ key = "s" .. i, actions = { click = "sev=" .. i }, class = "tg-al-chip" }
			)
		)
	end
	local rows: { { Node } } = {
		{
			ui.text({
				ui.span("title  ", "muted"),
				if form.title ~= "" then ui.span(form.title) else ui.span("required", "warning"),
			}),
		},
		{ ui.text({ ui.span("severity  ", "muted") }), ui.row(sevChips, { key = "chips", wrap = true }) },
		{ ui.text({ ui.span("Declare incident... (D)", "strong") }) },
	}
	local list: { Node } = {}
	for i, children in rows do
		table.insert(
			list,
			ui.el("div", {
				key = "f" .. i,
				class = "tg-al-row" .. (if i == form.row then " is-sel" else ""),
				actions = { click = "frow=" .. i },
			}, { ui.row(children, { wrap = true }) })
		)
	end
	table.insert(out, ui.col(list, { key = "form", gap = "none" }))
	if form.error then
		table.insert(out, ui.text({ ui.span(form.error :: string, "error") }, { key = "ferr" }))
	end
	return out
end

local function hints(s: State): string
	if s.confirm then
		return "y confirm and send  n/esc cancel (nothing is sent)"
	elseif s.editing then
		return "enter "
			.. (if (s.editing :: State.Editing).field == "note" then "review" else "apply")
			.. "  esc cancel  ctrl+u clear"
	elseif s.picker then
		return "left/right choose  enter review  esc cancel"
	elseif s.page == "declare" then
		return "j/k move  enter edit  left/right severity  D declare  esc back"
	elseif s.page == "detail" then
		return "s status  v severity  a add note  o open  r refresh  esc back"
	end
	return "j/k move  enter detail  n declare  s status  v severity  o open  c context  r refresh"
end

function M.view(s: State, env: Env.Env): Effect.View
	local children: { Node } = { header(s, env) }
	if s.problem then
		table.insert(children, ui.text({ ui.span(s.problem :: string, "error") }, { key = "problem" }))
	end
	if s.note then
		local tone = if s.note_tone == "ok" then "accent" else s.note_tone or "muted"
		table.insert(children, ui.text({ ui.span(s.note :: string, tone) }, { key = "note" }))
	end
	local e = s.editing
	if e then
		table.insert(children, {
			k = "input",
			p = {
				key = "edit",
				text = e.text,
				cursor = utf8.len(e.text) or #e.text,
				prompt = { { t = e.field .. ": ", s = "muted" } },
				placeholder = if e.field == "note" then "a note for the timeline" else "what is happening",
			},
		})
	end
	if s.picker then
		table.insert(children, pickerPanel(s))
	end
	if s.confirm then
		table.insert(children, confirmPanel(s))
	end
	if s.problem == nil then
		local body: { Node } = if s.page == "declare" and s.form
			then declarePage(s)
			elseif s.page == "detail" then detailPage(s, env)
			else listPage(s, env)
		for _, n in body do
			table.insert(children, n)
		end
	end
	local bar: { Node } = {}
	if s.page == "list" and s.grafana then
		table.insert(bar, Common.button("Declare incident (n)", "declare", "bdecl"))
	elseif s.page ~= "list" then
		table.insert(bar, Common.button("Back (esc)", "back", "bback"))
	end
	table.insert(bar, Common.button("Refresh (r)", "reload", "brel"))
	table.insert(bar, ui.text({ ui.span(hints(s), "muted") }, { key = "keys" }))
	return {
		main = ui.col(children, { role = "tern-grafana.incidents" }),
		dock = ui.row(bar, { key = "dock", wrap = true }),
	}
end

return M
