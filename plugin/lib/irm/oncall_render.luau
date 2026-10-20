--!strict
-- The on-call block's view: open alert groups (state, integration, age,
-- alert count, the selected one's actions and detail) or schedules (who is
-- on call now and next), the silence-duration picker, and the confirmation
-- panel of a staged action, which sits on top so it is always in view.

local Actions = require("./actions")
local Common = require("./common")
local Effect = require("../effect")
local Env = require("../env")
local Irm = require("../source/irm")
local State = require("./oncall_state")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type State = State.State
type AlertGroup = Irm.AlertGroup

local M = {}

M.MESSAGE_LINES = 6
M.SUB_ALERTS = 5
M.LABELS = 4

local STATE_TONE: { [string]: string } = {
	firing = "error",
	acknowledged = "warning",
	silenced = "muted",
	resolved = "accent",
}

local ROW_TONE: { [string]: string } = {
	firing = "tg-al-error",
	acknowledged = "tg-al-warning",
	silenced = "tg-al-muted",
	resolved = "tg-al-info",
}

local function groupName(g: AlertGroup): string
	return if g.number then "#" .. tostring(g.number) else g.id
end

local function host(url: string?): string
	return if url then string.match(url :: string, "^%a+://([^/]+)") or url :: string else "OnCall"
end

local function header(s: State, env: Env.Env): Node
	local items = Common.contextChips(s.contexts, s.context)
	local nGroups = #s.groups
	table.insert(
		items,
		ui.badge(
			string.format("Alert groups %d", nGroups),
			if s.view == "groups" then "info" else "neutral",
			{ key = "vg", actions = { click = "view=groups" }, class = "tg-al-chip" }
		)
	)
	table.insert(
		items,
		ui.badge(
			"Schedules",
			if s.view == "schedules" then "info" else "neutral",
			{ key = "vs", actions = { click = "view=schedules" }, class = "tg-al-chip" }
		)
	)
	for _, st in { "firing", "acknowledged", "silenced" } do
		local n = s.counts[st]
		if n then
			table.insert(
				items,
				ui.badge(string.format("%d %s", n, st), if n > 0 then STATE_TONE[st] else "muted", { key = "n" .. st })
			)
		end
	end
	local you = State.you(s)
	if you then
		local text = if you.now
			then "you: on call" .. (if you.until_ms then " until " .. Common.clock(you.until_ms :: number, env) else "")
			elseif you.next_ms then "you: next on call from " .. Common.clock(you.next_ms :: number, env)
			else "you: not on call"
		table.insert(items, ui.badge(text, if you.now then "info" else "muted", { key = "you" }))
	end
	local when = Common.when(s.loading, s.loaded_ms, env)
	if s.version then
		table.insert(when, 1, ui.span("IRM " .. (s.version :: string) .. "  ", "muted"))
	end
	table.insert(items, ui.text(when, { key = "when" }))
	return ui.row(items, { key = "head", class = "tg-al-head", wrap = true })
end

local function confirmPanel(s: State, env: Env.Env): Node
	local p = s.confirm :: State.Pending
	local spec = Actions.SPECS[p.action]
	local g = p.group
	local items: { { { SpanLike } } } = {}
	local function pair(k: string, v: { SpanLike })
		local head: { SpanLike } = { k }
		table.insert(items, { head, v })
	end
	pair("alert group", { ui.span(groupName(g) .. "  ", "strong"), g.title })
	pair("state", {
		ui.span(g.state, STATE_TONE[g.state] or "muted"),
		ui.span(" -> ", "muted"),
		ui.span(spec.after, STATE_TONE[spec.after] or "muted"),
	})
	if p.delay_s then
		pair("silence", {
			ui.span("for " .. Common.age((p.delay_s :: number) * 1000), "strong"),
			ui.span("  until " .. Common.clock(env.now_ms + (p.delay_s :: number) * 1000, env), "muted"),
		})
	end
	local integration = if g.integration_id then s.integrations[g.integration_id :: string] else nil
	pair("integration", { integration or g.integration_id or "unknown" })
	pair("alerts", { tostring(g.alerts_count) })
	pair("server", { host(s.oncall_url) .. " (context " .. (s.context or "") .. ")" })
	local children: { Node } = { ui.kv(items) }
	if spec.warning then
		table.insert(children, ui.text({ ui.span(spec.warning :: string, "warning") }, { key = "cpwarn" }))
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
		{ ui.span(string.format("%s alert group %s?", spec.label, groupName(g)), "strong") },
		children,
		{ key = "confirm", tone = "warning", class = "tg-sil-panel" }
	)
end

local function pickPanel(s: State): Node
	local p = s.picking :: { group: AlertGroup, preset: number }
	local chips: { Node } = {}
	for i, preset in Actions.SILENCE_PRESETS do
		table.insert(
			chips,
			ui.badge(
				string.format("%d %s", i, preset.label),
				if i == p.preset then "info" else "neutral",
				{ key = "p" .. i, actions = { click = "preset=" .. i }, class = "tg-al-chip" }
			)
		)
	end
	return ui.card({ ui.span("Silence alert group " .. groupName(p.group) .. " for how long?", "strong") }, {
		ui.row(chips, { key = "chips", wrap = true }),
		ui.muted("left/right or 1-6 choose, enter reviews before anything is sent, esc cancels", { key = "ph" }),
	}, { key = "pick", class = "tg-sil-panel" })
end

local function labelSpans(labels: { [string]: string }): { SpanLike }
	local out: { SpanLike } = {}
	local keys: { string } = {}
	for k in labels do
		if k ~= "alertname" and string.sub(k, 1, 2) ~= "__" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	if labels.alertname then
		table.insert(out, ui.span(labels.alertname, "strong"))
	end
	for i, k in keys do
		if i > M.LABELS then
			table.insert(out, ui.span(string.format("  +%d", #keys - M.LABELS), "muted"))
			break
		end
		table.insert(out, ui.span(string.format("  %s=%s", k, labels[k]), "muted mono"))
	end
	return out
end

local function detailNodes(s: State, g: AlertGroup, env: Env.Env): { Node }
	local out: { Node } = {}
	if #g.labels > 0 then
		local spans: { SpanLike } = { ui.span("labels ", "muted") }
		for _, l in g.labels do
			table.insert(spans, ui.span(l.key .. "=" .. l.value .. "  ", "mono"))
		end
		table.insert(out, ui.text(spans, { key = "lbl" }))
	end
	local times: { SpanLike } = {}
	if g.created_ms then
		table.insert(times, ui.span("started " .. Common.clock(g.created_ms :: number, env) .. "  ", "muted"))
	end
	if g.acknowledged_ms then
		table.insert(times, ui.span("acknowledged " .. Common.clock(g.acknowledged_ms :: number, env) .. "  ", "muted"))
	end
	if g.silenced_ms then
		table.insert(times, ui.span("silenced " .. Common.clock(g.silenced_ms :: number, env) .. "  ", "muted"))
	end
	if g.resolved_ms then
		table.insert(times, ui.span("resolved " .. Common.clock(g.resolved_ms :: number, env), "muted"))
	end
	if #times > 0 then
		table.insert(out, ui.text(times, { key = "times" }))
	end
	local last = g.last
	if last then
		if last.message then
			local n = 0
			for line in string.gmatch(last.message :: string, "[^\n]+") do
				n += 1
				if n > M.MESSAGE_LINES then
					table.insert(out, ui.muted("...", { key = "msgmore" }))
					break
				end
				table.insert(out, ui.text({ ui.span(line) }, { key = "msg" .. n }))
			end
		end
		for i, a in last.alerts do
			if i > M.SUB_ALERTS then
				table.insert(
					out,
					ui.muted(string.format("... and %d more alerts", #last.alerts - M.SUB_ALERTS), { key = "submore" })
				)
				break
			end
			local spans: { SpanLike } = {
				ui.span(string.format("%-8s ", a.status or "?"), if a.status == "firing" then "error" else "muted"),
			}
			for _, sp in labelSpans(a.labels) do
				table.insert(spans, sp)
			end
			local children: { Node } = { ui.text(spans) }
			local summary = a.annotations.summary or a.annotations.description
			if summary then
				table.insert(children, ui.muted("  " .. summary))
			end
			if a.value then
				table.insert(children, ui.text({ ui.span("  value ", "muted"), ui.span(a.value :: string, "mono") }))
			end
			local runbook = a.annotations.runbook_url
			if runbook and string.match(runbook, "^https?://") then
				table.insert(children, ui.text({ { t = "  runbook", s = "accent", href = runbook } }))
			end
			table.insert(out, ui.col(children, { key = "sub" .. i, gap = "none" }))
		end
	end
	local d = s.detail
	if d and d.id == g.id then
		if d.loading then
			table.insert(out, ui.muted("loading alerts", { key = "dload" }))
		elseif d.error then
			table.insert(out, ui.text({ ui.span(d.error :: string, "error") }, { key = "derr" }))
		elseif d.alerts then
			local list = d.alerts :: { Irm.Alert }
			local spans: { SpanLike } = {
				ui.span(string.format("%d alerts", d.count or #list), "strong"),
				ui.span("  latest:", "muted"),
			}
			for i, a in list do
				if i > 5 then
					break
				end
				table.insert(
					spans,
					ui.span(
						string.format(
							"  %s %s",
							if a.created_ms then Common.clock(a.created_ms :: number, env) else "?",
							a.status or ""
						),
						"muted"
					)
				)
			end
			table.insert(out, ui.text(spans, { key = "dalerts" }))
		end
	end
	return out
end

local function groupRow(s: State, i: number, g: AlertGroup, env: Env.Env): Node
	local selected = i == s.sel
	local first: { SpanLike } = {
		ui.span(string.format("%-12s ", g.state), STATE_TONE[g.state] or "muted"),
		ui.span(groupName(g) .. " ", "muted"),
		ui.span(g.title, "strong"),
	}
	local integration = if g.integration_id then s.integrations[g.integration_id :: string] else nil
	local second: { SpanLike } = {
		ui.span(
			string.format(
				"%s  %s  %d alert%s",
				integration or "integration " .. (g.integration_id or "?"),
				if g.created_ms then "started " .. Common.age(env.now_ms - (g.created_ms :: number)) .. " ago" else "",
				g.alerts_count,
				if g.alerts_count == 1 then "" else "s"
			),
			"muted"
		),
	}
	if g.state == "acknowledged" and g.acknowledged_ms then
		table.insert(
			second,
			ui.span("  acknowledged " .. Common.age(env.now_ms - (g.acknowledged_ms :: number)) .. " ago", "muted")
		)
	end
	local children: { Node } = { ui.text(first), ui.text(second) }
	if selected then
		local buttons: { Node } = {}
		for _, spec in Actions.available(g.state) do
			table.insert(
				buttons,
				Common.button(
					string.format("%s (%s)", spec.label, spec.key),
					spec.action .. "=" .. i,
					"b" .. spec.action
				)
			)
		end
		if g.url then
			table.insert(buttons, Common.button("Open in Grafana (o)", "open=" .. i, "bopen"))
		end
		table.insert(children, ui.row(buttons, { key = "acts", wrap = true }))
		local d = s.detail
		if d and d.id == g.id then
			table.insert(
				children,
				ui.col(detailNodes(s, g, env), { key = "detail", class = "tg-al-detail", gap = "none" })
			)
		end
	end
	return ui.el("div", {
		key = "g" .. g.id,
		class = "tg-al-row " .. (ROW_TONE[g.state] or "") .. (if selected then " is-sel" else ""),
		actions = { click = "row=" .. i },
	}, children)
end

local function groupsPage(s: State, env: Env.Env): { Node }
	local out: { Node } = {}
	if s.groups_error then
		table.insert(
			out,
			ui.text({ ui.span(s.groups_error :: string, "error"), ui.span("  (r retries)", "muted") }, { key = "gerr" })
		)
	end
	if #s.groups == 0 and s.loaded_ms and s.groups_error == nil then
		table.insert(out, ui.muted("No open alert groups.", { key = "empty" }))
	end
	local shown = 0
	for _, st in { "firing", "acknowledged", "silenced" } do
		shown = #(s.by_state[st] or {})
		local total = s.counts[st] or 0
		if total > shown then
			table.insert(
				out,
				ui.muted(
					string.format("Showing the newest %d of %d %s alert groups.", shown, total, st),
					{ key = "more" .. st }
				)
			)
		end
	end
	local rows: { Node } = {}
	for i, g in s.groups do
		table.insert(rows, groupRow(s, i, g, env))
	end
	table.insert(out, ui.col(rows, { key = "list", gap = "none" }))
	return out
end

-- Who is on call, `irm.user` shown as "you (name)" and highlighted.
local function names(oc: Irm.OnCall?, me: string?, tone: string?): { SpanLike }
	if oc == nil then
		return { ui.span("...", "muted") }
	end
	local out: { SpanLike } = {}
	for i, u in (oc :: Irm.OnCall).users do
		if i > 1 then
			table.insert(out, ui.span(", ", tone))
		end
		if me and u.email == me then
			table.insert(out, ui.span("you (" .. u.name .. ")", "strong accent"))
		else
			table.insert(out, ui.span(u.name, tone))
		end
	end
	if #out == 0 then
		table.insert(out, ui.span("nobody", "muted"))
	end
	return out
end

local function line(head: string, body: { SpanLike }, tail: string): { SpanLike }
	local out: { SpanLike } = { ui.span(head, "muted") }
	for _, sp in body do
		table.insert(out, sp)
	end
	table.insert(out, ui.span(tail, "muted"))
	return out
end

local function shiftEdge(oc: Irm.OnCall?, field: "start_ms" | "end_ms"): number?
	if oc == nil then
		return nil
	end
	local best: number? = nil
	for _, sh in (oc :: Irm.OnCall).shifts do
		local v = (sh :: any)[field]
		if v and (best == nil or (if field == "start_ms" then v < best else v > best)) then
			best = v
		end
	end
	return best
end

local function schedulesPage(s: State, env: Env.Env): { Node }
	local out: { Node } = {}
	if s.schedules_error then
		table.insert(out, ui.text({ ui.span(s.schedules_error :: string, "error") }, { key = "serr" }))
	end
	local rows = s.schedules
	if rows == nil then
		table.insert(out, ui.muted(if s.oncall then "loading schedules" else "", { key = "sload" }))
		return out
	end
	if #(rows :: { State.ScheduleRow }) == 0 then
		table.insert(out, ui.muted("No schedules.", { key = "sempty" }))
	end
	local list: { Node } = {}
	for i, row in rows :: { State.ScheduleRow } do
		local nowEnd = shiftEdge(row.now, "end_ms")
		local nextStart = shiftEdge(row.next, "start_ms")
		local children: { Node } = {
			ui.text({ ui.span(row.schedule.name, "strong") }),
			ui.text(
				line(
					"now  ",
					names(row.now, s.me, "accent"),
					if nowEnd then "  until " .. Common.clock(nowEnd :: number, env) else ""
				)
			),
			ui.text(
				line(
					"next ",
					names(row.next, s.me, nil),
					if nextStart then "  from " .. Common.clock(nextStart :: number, env) else ""
				)
			),
		}
		if row.error then
			table.insert(children, ui.text({ ui.span(row.error :: string, "error") }))
		end
		table.insert(
			list,
			ui.el("div", {
				key = "s" .. row.schedule.id,
				class = "tg-al-row" .. (if i == s.schedule_sel then " is-sel" else ""),
				actions = { click = "srow=" .. i },
			}, children)
		)
	end
	table.insert(out, ui.col(list, { key = "list", gap = "none" }))
	return out
end

local function hints(s: State): string
	if s.confirm then
		return "y confirm and send  n/esc cancel (nothing is sent)"
	elseif s.picking then
		return "left/right or 1-6 duration  enter review  esc cancel"
	elseif s.view == "schedules" then
		return "j/k move  tab alert groups  c context  r refresh"
	end
	return "j/k move  enter detail  a ack  A unack  x resolve  X unresolve  s silence  o open  m resolved  tab schedules  c context  r refresh"
end

function M.view(s: State, env: Env.Env): Effect.View
	local children: { Node } = { header(s, env) }
	if s.problem then
		table.insert(children, ui.text({ ui.span(s.problem :: string, "error") }, { key = "problem" }))
	end
	if s.can_write == false and s.problem == nil then
		table.insert(children, ui.muted("Read-only: " .. Irm.NEEDS.alert_group_write .. ".", { key = "ro" }))
	end
	if s.note then
		local tone = if s.note_tone == "ok" then "accent" else s.note_tone or "muted"
		table.insert(children, ui.text({ ui.span(s.note :: string, tone) }, { key = "note" }))
	end
	if s.picking then
		table.insert(children, pickPanel(s))
	end
	if s.confirm then
		table.insert(children, confirmPanel(s, env))
	end
	if s.problem == nil then
		local body: { Node } = if s.view == "schedules" then schedulesPage(s, env) else groupsPage(s, env)
		for _, n in body do
			table.insert(children, n)
		end
	end
	local bar: { Node } = {
		Common.button(if s.show_resolved then "Hide resolved (m)" else "Show resolved (m)", "resolved", "bres"),
		Common.button("Refresh (r)", "reload", "brel"),
		ui.text({ ui.span(hints(s), "muted") }, { key = "keys" }),
	}
	return {
		main = ui.col(children, { role = "tern-grafana.oncall" }),
		dock = ui.row(bar, { key = "dock", wrap = true }),
	}
end

return M
