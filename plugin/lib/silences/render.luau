--!strict
-- The silence block's view: the list (state, matchers, timing, what each
-- silence mutes now), the new-silence form with a live preview of the alerts
-- it would cover, and the confirmation panel of a staged write, which sits on
-- top so it is always in view.

local Api = require("./api")
local Duration = require("./duration")
local Effect = require("../effect")
local Env = require("../env")
local Matchers = require("./matchers")
local Normalize = require("../alerts/normalize")
local State = require("./state")
local Summary = require("../alerts/summary")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type State = State.State
type Silence = Api.Silence
type Alert = Normalize.Alert

local M = {}

-- How many affected alerts the preview lists by name.
M.PREVIEW_ALERTS = 8

local STATE_STYLE: { [string]: string } = {
	active = "warning",
	pending = "accent",
	expired = "muted",
	firing = "error",
	silenced = "muted",
	inhibited = "muted",
}

local SEVERITY_STYLE: { [string]: string } = { error = "error", warning = "warning", info = "accent", muted = "muted" }

local function age(ms: number): string
	return Duration.format(math.abs(ms) / 1000)
end

local function timing(x: Silence, now: number): string
	if x.state == "active" then
		return "ends in " .. age(x.ends_ms - now)
	elseif x.state == "pending" then
		return "starts in " .. age(x.starts_ms - now)
	end
	return "ended " .. age(now - x.ends_ms) .. " ago"
end

local function button(text: string, act: string, key: string, class: string?): Node
	return ui.el("button", {
		key = key,
		class = "tg-al-btn" .. (if class then " " .. class else ""),
		text = text,
		actions = { click = act },
	})
end

local function header(s: State, env: Env.Env): Node
	local items: { Node } = {}
	for i, name in s.contexts do
		table.insert(
			items,
			ui.badge(
				name,
				if name == s.context then "info" else "neutral",
				{ key = "c" .. i, actions = { click = "ctx=" .. name }, class = "tg-al-chip" }
			)
		)
	end
	local counts: { [string]: number } = {}
	for _, x in s.silences do
		counts[x.state] = (counts[x.state] or 0) + 1
	end
	for _, st in { "active", "pending", "expired" } do
		local n = counts[st] or 0
		if n > 0 or st == "active" then
			table.insert(
				items,
				ui.badge(
					string.format("%d %s", n, st),
					if n > 0 and st == "active" then "warning" else "muted",
					{ key = "n" .. st }
				)
			)
		end
	end
	local when: { SpanLike } = {}
	if s.target then
		table.insert(when, ui.span((s.target :: Api.Target).label .. "  ", "muted"))
	end
	if s.loading then
		table.insert(when, ui.span("loading", "accent"))
	elseif s.loaded_ms then
		table.insert(when, ui.span("updated " .. age(env.now_ms - (s.loaded_ms :: number)) .. " ago", "muted"))
	end
	table.insert(items, ui.text(when, { key = "when" }))
	return ui.row(items, { key = "head", class = "tg-al-head", wrap = true })
end

local function matcherSpans(list: { Matchers.Matcher }): { SpanLike }
	local out: { SpanLike } = {}
	for i, m in list do
		if i > 1 then
			table.insert(out, ui.span(", ", "muted"))
		end
		table.insert(out, ui.span(Matchers.format(m), "mono"))
	end
	if #list == 0 then
		table.insert(out, ui.span("(no matchers)", "muted"))
	end
	return out
end

local function alertLine(a: Alert, key: string): Node
	return ui.text({
		ui.span(string.format("%-9s ", a.state), STATE_STYLE[a.state] or "muted"),
		ui.span(string.format("%-8s ", a.severity), SEVERITY_STYLE[Summary.tone(a.severity)] or "muted"),
		ui.span(a.labels.alertname or "", "strong"),
		ui.span("  " .. a.summary, "muted"),
	}, { key = key })
end

local function affectedNodes(s: State, matchers: { Matchers.Matcher }, prefix: string): { Node }
	local out: { Node } = {}
	local list, err = Matchers.affected(matchers, s.alerts)
	if list == nil then
		table.insert(out, ui.text({ ui.span(tostring(err), "error") }, { key = prefix .. "err" }))
		return out
	end
	local head = if #list == 1 then "1 current alert matches" else string.format("%d current alerts match", #list)
	local spans: { SpanLike } = { ui.span(head, if #list > 0 then "strong" else "warning") }
	if #list == 0 then
		table.insert(spans, ui.span("  (the silence still applies to future alerts)", "muted"))
	end
	if s.alerts_error then
		table.insert(spans, ui.span("  alerts could not be read: " .. (s.alerts_error :: string), "error"))
	end
	table.insert(out, ui.text(spans, { key = prefix .. "n" }))
	for i, a in list do
		if i > M.PREVIEW_ALERTS then
			table.insert(
				out,
				ui.muted(string.format("... and %d more", #list - M.PREVIEW_ALERTS), { key = prefix .. "more" })
			)
			break
		end
		table.insert(out, alertLine(a, prefix .. "a" .. i))
	end
	return out
end

local function pair(items: { { { SpanLike } } }, k: string, v: { SpanLike })
	local head: { SpanLike } = { k }
	table.insert(items, { head, v })
end

local function confirmPanel(s: State, env: Env.Env): Node
	local p = s.confirm :: State.Pending
	local items: { { { SpanLike } } } = {}
	local title: string
	local extra: { Node } = {}
	if p.kind == "create" then
		local d = (p :: any).draft :: Api.Draft
		title = "Create this silence?"
		pair(items, "matchers", matcherSpans(d.matchers))
		pair(items, "starts", { "now" })
		pair(items, "ends", {
			ui.span("in " .. Duration.format(d.duration_s), "strong"),
			ui.span("  " .. Duration.iso(env.now_ms + d.duration_s * 1000), "muted"),
		})
		pair(items, "comment", { d.comment })
		pair(items, "created by", { d.created_by })
		extra = affectedNodes(s, d.matchers, "cp")
	else
		local x = (p :: any).silence :: Silence
		title = "Expire this silence?"
		pair(items, "id", { ui.span(x.id, "mono") })
		pair(items, "matchers", matcherSpans(x.matchers))
		pair(items, "state", { x.state .. ", " .. timing(x, env.now_ms) })
		pair(items, "comment", { x.comment })
		local n = State.silencing(s, x.id)
		table.insert(
			extra,
			ui.text({
				ui.span(
					string.format("It mutes %d alert%s now; they notify again.", n, if n == 1 then "" else "s"),
					"strong"
				),
			}, { key = "cpmutes" })
		)
	end
	if s.target then
		pair(items, "server", { (s.target :: Api.Target).label })
	end
	local children: { Node } = { ui.kv(items) }
	for _, n in extra do
		table.insert(children, n)
	end
	table.insert(
		children,
		ui.row({
			button("Confirm (y)", "confirm", "bconfirm", "tg-sil-confirm"),
			button("Cancel (n)", "cancel", "bcancel"),
		}, { key = "cpb" })
	)
	return ui.card(
		{ ui.span(title, "strong") },
		children,
		{ key = "confirm", tone = "warning", class = "tg-sil-panel" }
	)
end

local function silenceRow(s: State, i: number, x: Silence, env: Env.Env): Node
	local spans: { SpanLike } = {
		ui.span(string.format("%-8s ", x.state), STATE_STYLE[x.state] or "muted"),
	}
	for _, sp in matcherSpans(x.matchers) do
		table.insert(spans, sp)
	end
	table.insert(spans, ui.span("  " .. timing(x, env.now_ms), "muted"))
	local second: { SpanLike } = {}
	if x.state ~= "expired" then
		local n = State.silencing(s, x.id)
		table.insert(
			second,
			ui.span(
				string.format("mutes %d alert%s  ", n, if n == 1 then "" else "s"),
				if n > 0 then "strong" else "muted"
			)
		)
	end
	table.insert(second, ui.span(x.created_by, "muted"))
	if x.comment ~= "" then
		table.insert(second, ui.span(": " .. x.comment, "muted"))
	end
	local children: { Node } = { ui.text(spans), ui.text(second) }
	if i == s.sel then
		local buttons: { Node } = {}
		if x.state ~= "expired" then
			table.insert(buttons, button("Expire (x)", "expire=" .. i, "bx"))
		end
		table.insert(buttons, button("Recreate (e)", "recreate=" .. i, "be"))
		table.insert(children, ui.text({ ui.span("id " .. x.id, "muted mono") }, { key = "id" }))
		table.insert(children, ui.row(buttons, { key = "acts" }))
	end
	return ui.el("div", {
		key = "s" .. x.id,
		class = "tg-al-row tg-sil-" .. x.state .. (if i == s.sel then " is-sel" else ""),
		actions = { click = "row=" .. i },
	}, children)
end

local function listPage(s: State, env: Env.Env): { Node }
	local out: { Node } = {}
	if s.silences_error then
		table.insert(
			out,
			ui.text(
				{ ui.span(s.silences_error :: string, "error"), ui.span("  (r retries)", "muted") },
				{ key = "serr" }
			)
		)
	end
	local visible = State.visible(s)
	if #visible == 0 and s.loaded_ms then
		table.insert(
			out,
			ui.muted(
				if #s.silences > 0 then "No active or pending silences (m shows expired ones)." else "No silences.",
				{ key = "empty" }
			)
		)
	end
	local rows: { Node } = {}
	for i, x in visible do
		table.insert(rows, silenceRow(s, i, x, env))
	end
	table.insert(out, ui.col(rows, { key = "list" }))
	return out
end

local function rowLabel(s: State, row: State.FormRow, env: Env.Env): ({ SpanLike }, Node?)
	local form = s.form :: State.Form
	if row.field == "matcher" then
		local m = form.matchers[row.index :: number]
		return { ui.span("matcher  ", "muted"), ui.span(Matchers.format(m), "mono") },
			button("x", "rm=" .. tostring(row.index), "rm" .. tostring(row.index))
	elseif row.field == "add" then
		return { ui.span("+ add matcher (a)", "accent") }, nil
	elseif row.field == "duration" then
		local chips: { Node } = {}
		for i, p in Duration.PRESETS do
			table.insert(
				chips,
				ui.badge(
					p.label,
					if form.preset == i then "info" else "neutral",
					{ key = "d" .. i, actions = { click = "dur=" .. i }, class = "tg-al-chip" }
				)
			)
		end
		table.insert(
			chips,
			ui.badge(
				if form.custom ~= "" then "custom " .. form.custom else "custom",
				if form.preset == Duration.CUSTOM then "info" else "neutral",
				{ key = "dc", actions = { click = "dur=" .. Duration.CUSTOM }, class = "tg-al-chip" }
			)
		)
		local seconds = State.durationOf(form)
		local spans: { SpanLike } = { ui.span("duration ", "muted") }
		if seconds then
			table.insert(spans, ui.span("until " .. Duration.iso(env.now_ms + seconds * 1000), "muted"))
		end
		return spans, ui.row(chips, { key = "chips" })
	elseif row.field == "comment" then
		return {
			ui.span("comment  ", "muted"),
			if form.comment ~= "" then ui.span(form.comment) else ui.span("required: why is this silenced?", "warning"),
		},
			nil
	elseif row.field == "created_by" then
		return {
			ui.span("created by  ", "muted"),
			if form.created_by ~= "" then ui.span(form.created_by) else ui.span("required", "warning"),
		},
			nil
	end
	return { ui.span("Create silence... (S)", "strong") }, nil
end

local function formPage(s: State, env: Env.Env): { Node }
	local form = s.form :: State.Form
	local out: { Node } = {}
	local e = s.editing
	if e then
		table.insert(out, {
			k = "input",
			p = {
				key = "edit",
				text = e.text,
				cursor = utf8.len(e.text) or #e.text,
				prompt = { { t = (if e.field == "created_by" then "created by" else e.field) .. ": ", s = "muted" } },
				placeholder = if e.field == "matcher"
					then 'name="value", name!="value", name=~"regex" or name!~"regex"'
					elseif e.field == "duration" then "90m, 3h, 1d12h"
					else "",
			},
		})
		if e.error then
			table.insert(out, ui.text({ ui.span(e.error :: string, "error") }, { key = "eerr" }))
		end
	end
	local rows: { Node } = {}
	for i, row in State.formRows(form) do
		local spans, trailing = rowLabel(s, row, env)
		local children: { Node } = { ui.text(spans) }
		if trailing then
			table.insert(children, trailing)
		end
		table.insert(
			rows,
			ui.el("div", {
				key = "f" .. i,
				class = "tg-al-row tg-sil-field" .. (if i == form.sel then " is-sel" else ""),
				actions = { click = "frow=" .. i },
			}, { ui.row(children, { wrap = true }) })
		)
	end
	table.insert(out, ui.col(rows, { key = "form" }))
	if form.error then
		table.insert(out, ui.text({ ui.span(form.error :: string, "error") }, { key = "ferr" }))
	end
	table.insert(out, ui.rule({ "preview" }, { key = "rp" }))
	for _, n in affectedNodes(s, form.matchers, "pv") do
		table.insert(out, n)
	end
	return out
end

local function hints(s: State): string
	if s.confirm then
		return "y confirm and send  n/esc cancel (nothing is sent)"
	elseif s.editing then
		return "enter apply  esc cancel  ctrl+u clear"
	elseif s.page == "form" then
		return "j/k move  enter edit  left/right duration  a add matcher  x remove matcher  S create  esc back"
	end
	return "j/k move  x expire  n new  e recreate  m expired  c context  r refresh"
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
	if s.confirm then
		table.insert(children, confirmPanel(s, env))
	end
	if s.problem == nil then
		local body: { Node } = if s.page == "form" and s.form then formPage(s, env) else listPage(s, env)
		for _, n in body do
			table.insert(children, n)
		end
	end
	local bar: { Node } = {}
	if s.page == "list" and s.target then
		table.insert(bar, button("New silence (n)", "new", "bnew"))
		table.insert(bar, button(if s.show_expired then "Hide expired (m)" else "Show expired (m)", "expired", "bexp"))
	elseif s.page == "form" then
		table.insert(bar, button("Back to list (esc)", "back", "bback"))
	end
	table.insert(bar, ui.text({ ui.span(hints(s), "muted") }, { key = "keys" }))
	return {
		main = ui.col(children, { role = "tern-grafana.silence" }),
		dock = ui.row(bar, { key = "dock", wrap = true }),
	}
end

return M
