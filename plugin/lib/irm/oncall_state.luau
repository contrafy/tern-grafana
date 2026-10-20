--!strict
-- The `oncall` block: a context's Grafana OnCall, through IRM. Two views:
-- open alert groups (firing, acknowledged, silenced; resolved ones on
-- request) with their detail, and schedules with who is on call now and
-- next.
--
-- Writes (acknowledge, unacknowledge, resolve, unresolve, silence) are
-- never automatic: a key or button only stages the action (`confirm`), the
-- view spells out what will change and that IRM records it under the
-- service account, and the request is sent only when the user confirms that
-- exact staged action with `y` or the Confirm button. A failed write is
-- reported and never retried. When Grafana's permission list shows the
-- service account cannot act on alert groups, nothing is staged and the
-- view says which permission is missing.

local Actions = require("./actions")
local Effect = require("../effect")
local Env = require("../env")
local Irm = require("../source/irm")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Settings = require("./settings")
local Target = require("./target")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Route = Route.Route
type Response = TransportTypes.Response
type AlertGroup = Irm.AlertGroup
type GroupState = Irm.GroupState
type GroupAction = Irm.GroupAction

-- One log line per write decision: whitelisted fields only (never titles,
-- labels or alert content).
export type AuditEffect = {
	kind: "irm_audit",
	block: "oncall",
	action: string,
	outcome: "sent" | "ok" | "failed" | "cancelled",
	context: string,
	target: string,
	duration_s: number?,
	status: number?,
}
export type Effect = Effect.Effect | AuditEffect

export type ScheduleRow = { schedule: Irm.Schedule, now: Irm.OnCall?, next: Irm.OnCall?, error: string? }

export type Pending = { action: GroupAction, group: AlertGroup, delay_s: number? }

export type Detail = { id: string, alerts: { Irm.Alert }?, count: number?, error: string?, loading: boolean }

export type State = {
	contexts: { string },
	context: string?,
	grafana: Route?,
	oncall: Route?,
	oncall_url: string?,
	version: string?,
	problem: string?,
	gen: number,
	waiting: { [string]: boolean },
	loading: boolean,
	view: "groups" | "schedules",
	by_state: { [string]: { AlertGroup } },
	counts: { [string]: number },
	groups: { AlertGroup },
	groups_error: string?,
	show_resolved: boolean,
	integrations: { [string]: string },
	schedules: { ScheduleRow }?,
	schedules_error: string?,
	schedules_ms: number?,
	login: string?,
	-- `irm.user`: the user's own email, lower-cased (the token is a service
	-- account, so IRM has no "you" of its own).
	me: string?,
	-- From Grafana's permission list; nil when unknown.
	can_write: boolean?,
	loaded_ms: number?,
	sel: number,
	sel_id: string?,
	schedule_sel: number,
	detail: Detail?,
	-- A linked alert group whose detail opens once the groups land.
	want_detail: string?,
	-- Choosing a silence duration before staging.
	picking: { group: AlertGroup, preset: number }?,
	confirm: Pending?,
	writing: Pending?,
	write_tag: string?,
	write_seq: number,
	note: string?,
	note_tone: string?,
}

local M = {}

M.REFRESH_MS = 60 * 1000
-- Who is on call changes slowly; schedules reload at most this often.
M.SCHEDULES_REFRESH_MS = 5 * 60 * 1000
M.PAGE = 25
M.RESOLVED_PAGE = 10
M.MAX_SCHEDULES = 12
M.DETAIL_ALERTS = 10

local OPEN_STATES: { GroupState } = { "firing", "acknowledged", "silenced" }
local RANK: { [string]: number } = { firing = 1, acknowledged = 2, silenced = 3, resolved = 4 }

local function setNote(s: State, text: string?, tone: string?)
	s.note, s.note_tone = text, tone
end

function M.selected(s: State): AlertGroup?
	return s.groups[s.sel]
end

export type You = { now: boolean, until_ms: number?, next_ms: number?, schedules: { string } }

local function shiftEdge(oc: Irm.OnCall, ids: { [string]: boolean }, field: "start_ms" | "end_ms"): number?
	local best: number? = nil
	for _, sh in oc.shifts do
		local mine = false
		for _, id in sh.users do
			mine = mine or ids[id] == true
		end
		local v = (sh :: any)[field]
		if mine and v and (best == nil or (if field == "start_ms" then v < best else v > best)) then
			best = v
		end
	end
	return best
end

-- Whether `irm.user` is on call now (until when, in which schedules) or
-- next (from when), from the schedules read; nil when `irm.user` is not set
-- or no schedule's on-call users have been read yet.
function M.you(s: State): You?
	if s.me == nil or s.schedules == nil then
		return nil
	end
	local out: You = { now = false, until_ms = nil, next_ms = nil, schedules = {} }
	local read = false
	for _, row in s.schedules :: { ScheduleRow } do
		for _, which in { "now", "next" } do
			local oc: Irm.OnCall? = (row :: any)[which]
			if oc then
				read = true
				local ids: { [string]: boolean } = {}
				for _, u in (oc :: Irm.OnCall).users do
					if u.email == s.me then
						ids[u.id] = true
					end
				end
				if next(ids) then
					if which == "now" then
						out.now = true
						table.insert(out.schedules, row.schedule.name)
						local e = shiftEdge(oc :: Irm.OnCall, ids, "end_ms")
						if e and (out.until_ms == nil or e > (out.until_ms :: number)) then
							out.until_ms = e
						end
					else
						local b = shiftEdge(oc :: Irm.OnCall, ids, "start_ms")
						if b and (out.next_ms == nil or b < (out.next_ms :: number)) then
							out.next_ms = b
						end
					end
				end
			end
		end
	end
	return if read then out else nil
end

local function request(s: State, effects: { Effect }, name: string, route: Route, req: TransportTypes.Request)
	s.waiting[name] = true
	s.loading = true
	table.insert(effects, { kind = "http", tag = string.format("%d:%s", s.gen, name), route = route, request = req })
end

local function merge(s: State)
	local list: { AlertGroup } = {}
	local states: { string } = { "firing", "acknowledged", "silenced" }
	if s.show_resolved then
		table.insert(states, "resolved")
	end
	for _, st in states do
		for _, g in (s.by_state[st] or {}) :: { AlertGroup } do
			table.insert(list, g)
		end
	end
	table.sort(list, function(a, b)
		if a.state ~= b.state then
			return RANK[a.state] < RANK[b.state]
		end
		return (a.created_ms or 0) > (b.created_ms or 0)
	end)
	s.groups = list
	local found = false
	if s.sel_id then
		for i, g in list do
			if g.id == s.sel_id then
				s.sel = i
				found = true
				break
			end
		end
	end
	if not found then
		s.sel = math.clamp(s.sel, 1, math.max(1, #list))
	end
	local g = list[s.sel]
	s.sel_id = if g then g.id else nil
end

local function readGroups(s: State, env: Env, effects: { Effect })
	local route = s.oncall :: Route
	for _, st in OPEN_STATES do
		request(s, effects, "g:" .. st, route, Irm.groupsRequest(st, M.PAGE))
	end
	if s.show_resolved then
		request(s, effects, "g:resolved", route, Irm.groupsRequest("resolved", M.RESOLVED_PAGE))
	end
	if next(s.integrations) == nil then
		request(s, effects, "integrations", route, Irm.integrationsRequest())
	end
	local schedulesDue = s.schedules_ms == nil or env.now_ms - (s.schedules_ms :: number) >= M.SCHEDULES_REFRESH_MS
	if (s.view == "schedules" or s.me ~= nil) and schedulesDue then
		request(s, effects, "schedules", route, Irm.schedulesRequest())
	end
end

-- A new load generation; `full` re-reads discovery, permissions and the
-- service account's login too.
local function load(s: State, env: Env, effects: { Effect }, full: boolean)
	s.gen += 1
	s.waiting = {}
	s.loading = false
	local route, why = Target.grafana(env.config, s.context)
	if route == nil then
		s.problem = why
		s.grafana, s.oncall = nil, nil
		return
	end
	local r = route :: Route
	if s.grafana == nil or (s.grafana :: Route).context ~= r.context then
		full = true
		s.by_state, s.counts, s.groups = {}, {}, {}
		s.integrations, s.schedules, s.schedules_ms = {}, nil, nil
		s.login, s.can_write, s.detail, s.loaded_ms = nil, nil, nil, nil
	end
	s.grafana = r
	s.context = r.context
	s.problem = nil
	s.me = Settings.read(env.config).user
	if full or s.oncall == nil then
		request(s, effects, "settings", r, Irm.settingsRequest())
		request(s, effects, "perms", r, Irm.permissionsRequest())
		request(s, effects, "user", r, Irm.userRequest())
		return
	end
	readGroups(s, env, effects)
end

local function linkParams(args: { string }): { [string]: string }
	local first = args[1]
	if first == nil or first == "" then
		return {}
	end
	local link = Scheme.decode(first)
	if link == nil or link.action ~= "oncall" then
		return {}
	end
	return link.params
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local params = linkParams(args)
	local savedT = if type(saved) == "table" then saved else {}
	local view: "groups" | "schedules" = if params.view == "schedules"
			or (params.view == nil and savedT.view == "schedules")
		then "schedules"
		else "groups"
	local s: State = {
		contexts = Target.contexts(env.config),
		context = params.context or (if type(savedT.context) == "string" then savedT.context else nil),
		grafana = nil,
		oncall = nil,
		oncall_url = nil,
		version = nil,
		problem = nil,
		gen = 0,
		waiting = {},
		loading = false,
		view = view,
		by_state = {},
		counts = {},
		groups = {},
		groups_error = nil,
		show_resolved = savedT.show_resolved == true,
		integrations = {},
		schedules = nil,
		schedules_error = nil,
		schedules_ms = nil,
		login = nil,
		me = nil,
		can_write = nil,
		loaded_ms = nil,
		sel = 1,
		sel_id = params.group,
		schedule_sel = 1,
		detail = nil,
		want_detail = params.group,
		picking = nil,
		confirm = nil,
		writing = nil,
		write_tag = nil,
		write_seq = 0,
		note = nil,
		note_tone = nil,
	}
	if s.context and not table.find(s.contexts, s.context :: string) then
		s.context = nil
	end
	local effects: { Effect } = {}
	load(s, env, effects, true)
	return s, effects
end

local function openDetail(s: State, effects: { Effect }, g: AlertGroup)
	s.detail = { id = g.id, alerts = nil, count = nil, error = nil, loading = true }
	if s.oncall then
		table.insert(effects, {
			kind = "http",
			tag = "d:" .. g.id,
			route = s.oncall :: Route,
			request = Irm.alertsRequest(g.id, M.DETAIL_ALERTS),
		})
	end
	table.insert(effects, { kind = "reveal", id = "main.list.g" .. g.id, at = "start" })
end

local function onSettings(s: State, env: Env, effects: { Effect }, response: Response)
	local r = s.grafana :: Route
	local d, qe = Irm.parseDiscovery(response, env, r.endpoint.url)
	if d == nil then
		s.problem = if qe then qe.message else "IRM could not be read"
		return
	end
	s.version = d.version
	if d.oncall_url == nil then
		s.problem = d.oncall_problem
		return
	end
	s.oncall_url = d.oncall_url
	s.oncall = Irm.oncallRoute(r, d.oncall_url :: string)
	readGroups(s, env, effects)
end

local function onSchedules(s: State, env: Env, effects: { Effect }, response: Response)
	local list, qe = Irm.parseSchedules(response, env)
	if list == nil then
		s.schedules_error = if qe then qe.message else "schedules could not be read"
		return
	end
	s.schedules_error = nil
	s.schedules_ms = env.now_ms
	local rows: { ScheduleRow } = {}
	for i, sch in list do
		local row: ScheduleRow = { schedule = sch, now = nil, next = nil, error = nil }
		table.insert(rows, row)
		if i <= M.MAX_SCHEDULES and s.oncall then
			request(s, effects, "now:" .. sch.id, s.oncall :: Route, Irm.onCallRequest(sch.id, "current"))
			request(s, effects, "next:" .. sch.id, s.oncall :: Route, Irm.onCallRequest(sch.id, "next"))
		end
	end
	s.schedules = rows
	s.schedule_sel = math.clamp(s.schedule_sel, 1, math.max(1, #rows))
end

local function onOnCall(s: State, env: Env, which: string, id: string, response: Response)
	for _, row in (s.schedules or {}) :: { ScheduleRow } do
		if row.schedule.id == id then
			local oc, qe = Irm.parseOnCall(response, env)
			if oc == nil then
				row.error = if qe then qe.message else "could not be read"
			elseif which == "now" then
				row.now = oc
			else
				row.next = oc
			end
			return
		end
	end
end

local function settle(s: State, env: Env, name: string, response: Response, effects: { Effect })
	if name == "settings" then
		onSettings(s, env, effects, response)
	elseif name == "perms" then
		local perms = Irm.parsePermissions(response, env)
		s.can_write = if perms then perms[Irm.ALERT_GROUP_WRITE] == true else nil
	elseif name == "user" then
		s.login = Irm.parseLogin(response, env)
	elseif name == "integrations" then
		s.integrations = Irm.parseIntegrations(response, env) or {}
	elseif name == "schedules" then
		onSchedules(s, env, effects, response)
	elseif string.sub(name, 1, 2) == "g:" then
		local st = string.sub(name, 3)
		local list, count, qe = Irm.parseGroups(response, env)
		if list then
			s.by_state[st] = list
			s.counts[st] = count or #list
			s.groups_error = nil
		else
			s.groups_error = if qe then qe.message else "alert groups could not be read"
		end
		merge(s)
		local g = M.selected(s)
		if s.want_detail and g and g.id == s.want_detail then
			s.want_detail = nil
			openDetail(s, effects, g :: AlertGroup)
		end
	else
		local which, id = string.match(name, "^(%a+):(.+)$")
		if (which == "now" or which == "next") and id then
			onOnCall(s, env, which :: string, id :: string, response)
		end
	end
end

local function settleDetail(s: State, env: Env, id: string, response: Response)
	local d = s.detail
	if d == nil or d.id ~= id then
		return
	end
	local list, count, qe = Irm.parseAlerts(response, env)
	d.loading = false
	if list then
		d.alerts, d.count = list, count
	else
		d.error = if qe then qe.message else "alerts could not be read"
	end
end

local function audit(s: State, p: Pending, outcome: string, status: number?): AuditEffect
	return {
		kind = "irm_audit",
		block = "oncall",
		action = p.action,
		outcome = outcome :: any,
		context = s.context or "",
		target = p.group.id,
		duration_s = p.delay_s,
		status = status,
	}
end

-- Why `action` cannot be staged for `g`, or nil.
function M.refusal(s: State, action: GroupAction, g: AlertGroup): string?
	if s.oncall == nil then
		return "OnCall is not available for this context."
	end
	if s.can_write == false then
		return "Not sent: "
			.. Irm.NEEDS.alert_group_write
			.. " (Grafana's permission list for it has no "
			.. Irm.ALERT_GROUP_WRITE
			.. "; r reloads it)."
	end
	if not Actions.allowed(action, g.state) then
		return string.format("%s does not apply to a %s alert group.", Actions.SPECS[action].label, g.state)
	end
	return nil
end

-- Stages `action` on the selected group (nothing is sent). Silence first
-- asks for a duration.
local function stage(s: State, action: GroupAction)
	local g = M.selected(s)
	if g == nil or s.writing or s.confirm then
		return
	end
	local why = M.refusal(s, action, g :: AlertGroup)
	if why then
		setNote(s, why, "error")
		return
	end
	if action == "silence" then
		s.picking = { group = g :: AlertGroup, preset = Actions.DEFAULT_PRESET }
		return
	end
	s.confirm = { action = action, group = g :: AlertGroup, delay_s = nil }
end

local function pickDone(s: State)
	local p = s.picking
	if p == nil then
		return
	end
	s.picking = nil
	s.confirm = { action = "silence", group = p.group, delay_s = Actions.SILENCE_PRESETS[p.preset].s }
end

-- The user confirmed the staged action: the only place a write is sent.
local function confirm(s: State, env: Env, effects: { Effect })
	local p = s.confirm
	if p == nil or s.oncall == nil or s.writing then
		return
	end
	s.confirm = nil
	s.write_seq += 1
	s.writing = p
	s.write_tag = string.format("w%d", s.write_seq)
	setNote(s, Actions.SPECS[p.action].label .. ": sending...", "muted")
	table.insert(effects, audit(s, p, "sent"))
	table.insert(effects, {
		kind = "http",
		tag = s.write_tag :: string,
		route = s.oncall :: Route,
		request = Irm.groupActionRequest(p.group.id, p.action, p.delay_s, env.encode),
	})
end

local function cancel(s: State, effects: { Effect })
	local p = s.confirm
	s.picking = nil
	if p == nil then
		return
	end
	s.confirm = nil
	setNote(s, "Cancelled: nothing was sent.", "muted")
	table.insert(effects, audit(s, p, "cancelled"))
end

local function groupName(g: AlertGroup): string
	return if g.number then "#" .. tostring(g.number) else g.id
end

local function written(s: State, env: Env, response: Response, effects: { Effect })
	local p = s.writing :: Pending
	s.writing, s.write_tag = nil, nil
	local qe = Irm.failure(response, env, "alert_group_write")
	local spec = Actions.SPECS[p.action]
	if qe then
		-- Never retried: the user decides after reading why it failed.
		table.insert(effects, audit(s, p, "failed", response.status))
		setNote(s, string.format("%s %s failed: %s", spec.label, groupName(p.group), qe.message), "error")
		return
	end
	table.insert(effects, audit(s, p, "ok", response.status))
	setNote(
		s,
		string.format(
			"%s %s: done (now %s), recorded under the service account.",
			spec.label,
			groupName(p.group),
			spec.after
		),
		"ok"
	)
	s.sel_id = p.group.id
	load(s, env, effects, false)
end

local function switchContext(s: State, env: Env, name: string, effects: { Effect })
	if name == s.context or s.writing then
		return
	end
	s.context = name
	s.sel, s.sel_id = 1, nil
	s.confirm, s.picking = nil, nil
	setNote(s, nil)
	load(s, env, effects, true)
end

local function cycleContext(s: State, env: Env, step: number, effects: { Effect })
	local n = #s.contexts
	if n < 2 then
		return
	end
	local i = table.find(s.contexts, s.context or "") or 0
	switchContext(s, env, s.contexts[(i - 1 + step) % n + 1], effects)
end

local function setView(s: State, env: Env, view: "groups" | "schedules", effects: { Effect })
	if s.view == view then
		return
	end
	s.view = view
	if view == "schedules" and s.oncall and (s.schedules == nil or not s.loading) then
		local due = s.schedules_ms == nil or env.now_ms - (s.schedules_ms :: number) >= M.SCHEDULES_REFRESH_MS
		if due and not s.waiting.schedules then
			request(s, effects, "schedules", s.oncall :: Route, Irm.schedulesRequest())
		end
	end
end

local function moveSel(s: State, delta: number, effects: { Effect })
	if s.view == "schedules" then
		local n = if s.schedules then #(s.schedules :: { ScheduleRow }) else 0
		s.schedule_sel = math.clamp(s.schedule_sel + delta, 1, math.max(1, n))
		local row = if s.schedules then (s.schedules :: { ScheduleRow })[s.schedule_sel] else nil
		if row then
			table.insert(effects, { kind = "reveal", id = "main.list.s" .. row.schedule.id })
		end
		return
	end
	s.sel = math.clamp(s.sel + delta, 1, math.max(1, #s.groups))
	local g = M.selected(s)
	s.sel_id = if g then g.id else nil
	if g then
		table.insert(effects, { kind = "reveal", id = "main.list.g" .. g.id })
	end
end

local function toggleDetail(s: State, effects: { Effect })
	local g = M.selected(s)
	if g == nil then
		return
	end
	if s.detail and (s.detail :: Detail).id == g.id then
		s.detail = nil
	else
		openDetail(s, effects, g :: AlertGroup)
	end
end

local function pickKey(s: State, key: any): boolean
	local p = s.picking :: { group: AlertGroup, preset: number }
	local name, text = key.name, key.text
	local n = #Actions.SILENCE_PRESETS
	local digit = tonumber(text or "")
	if name == "left" or text == "h" then
		p.preset = (p.preset - 2) % n + 1
	elseif name == "right" or text == "l" or name == "tab" then
		p.preset = p.preset % n + 1
	elseif digit and digit >= 1 and digit <= n then
		p.preset = digit
	elseif name == "enter" then
		pickDone(s)
	elseif name == "escape" then
		s.picking = nil
	else
		return false
	end
	return true
end

local function listKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	local name, text = key.name, key.text
	if name == "down" or text == "j" then
		moveSel(s, 1, effects)
	elseif name == "up" or text == "k" then
		moveSel(s, -1, effects)
	elseif name == "home" then
		moveSel(s, -1e9, effects)
	elseif name == "end" then
		moveSel(s, 1e9, effects)
	elseif name == "tab" or text == "t" then
		setView(s, env, if s.view == "groups" then "schedules" else "groups", effects)
	elseif text == "r" then
		s.schedules_ms = nil
		load(s, env, effects, s.oncall == nil or s.can_write == false)
	elseif text == "c" then
		cycleContext(s, env, 1, effects)
	elseif text == "C" then
		cycleContext(s, env, -1, effects)
	elseif name == "escape" and (s.detail or s.note) then
		if s.detail then
			s.detail = nil
		else
			setNote(s, nil)
		end
	elseif s.view ~= "groups" then
		return false
	elseif name == "enter" or name == "space" then
		toggleDetail(s, effects)
	elseif text == "m" then
		s.show_resolved = not s.show_resolved
		if s.show_resolved and s.oncall then
			request(s, effects, "g:resolved", s.oncall :: Route, Irm.groupsRequest("resolved", M.RESOLVED_PAGE))
		else
			merge(s)
		end
	elseif text == "o" then
		local g = M.selected(s)
		if g and g.url then
			table.insert(effects, {
				kind = "open",
				target = Scheme.encode({
					action = "browse",
					params = { url = g.url :: string },
					vars = {},
				}),
			})
		end
	elseif text and Actions.byKey(text) then
		stage(s, Actions.byKey(text) :: GroupAction)
	else
		return false
	end
	return true
end

function M.key(s: State, key: any, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	if key.ctrl or key.meta or key.alt then
		return s, effects, false
	end
	local text: string = if type(key.text) == "string" then key.text else ""
	local name: string = if type(key.name) == "string" then key.name else ""
	local staged = s.confirm ~= nil
	local handled: boolean
	if s.confirm then
		-- Only an explicit `y` confirms; enter does not.
		handled = true
		if text == "y" then
			confirm(s, env, effects)
		elseif text == "n" or name == "escape" then
			cancel(s, effects)
		else
			handled = false
		end
	elseif s.picking then
		handled = pickKey(s, key)
	else
		handled = listKey(s, key, env, effects)
	end
	if not staged and s.confirm then
		table.insert(effects, { kind = "reveal", id = "main.confirm", at = "start" })
	end
	return s, effects, handled
end

local function onAction(s: State, act: string, value: string?, env: Env, effects: { Effect })
	local i = tonumber(value or "")
	if act == "confirm" then
		confirm(s, env, effects)
	elseif act == "cancel" then
		cancel(s, effects)
	elseif s.confirm then
		return
	elseif act == "preset" and s.picking and i and Actions.SILENCE_PRESETS[i] then
		(s.picking :: any).preset = i
		pickDone(s)
	elseif act == "ctx" and value and table.find(s.contexts, value) then
		switchContext(s, env, value, effects)
	elseif act == "view" and (value == "groups" or value == "schedules") then
		setView(s, env, value :: any, effects)
	elseif act == "reload" then
		s.schedules_ms = nil
		load(s, env, effects, s.oncall == nil or s.can_write == false)
	elseif act == "resolved" then
		listKey(s, { text = "m" }, env, effects)
	elseif act == "row" and i and s.groups[i] then
		s.sel = i
		s.sel_id = s.groups[i].id
		toggleDetail(s, effects)
	elseif act == "srow" and i then
		s.schedule_sel = i
	elseif act == "open" and i and s.groups[i] then
		s.sel, s.sel_id = i, s.groups[i].id
		listKey(s, { text = "o" }, env, effects)
	elseif
		(act == "acknowledge" or act == "unacknowledge" or act == "resolve" or act == "unresolve" or act == "silence")
		and i
		and s.groups[i]
	then
		s.sel, s.sel_id = i, s.groups[i].id
		stage(s, act :: GroupAction)
	end
end

function M.update(s: State, msg: any, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		local tag: string = msg.tag
		if s.write_tag and tag == s.write_tag and s.writing then
			written(s, env, msg.response, effects)
			return s, effects
		end
		local detailId = string.match(tag, "^d:(.+)$")
		if detailId then
			settleDetail(s, env, detailId, msg.response)
			return s, effects
		end
		local gen, name = string.match(tag, "^(%d+):(.+)$")
		if gen == nil or tonumber(gen) ~= s.gen or not s.waiting[name :: string] then
			return s, effects
		end
		s.waiting[name :: string] = nil
		settle(s, env, name :: string, msg.response, effects)
		if next(s.waiting) == nil and s.loading then
			s.loading = false
			s.loaded_ms = env.now_ms
			if s.oncall then
				table.insert(effects, { kind = "timer", tag = string.format("auto:%d", s.gen), ms = M.REFRESH_MS })
			end
		end
	elseif msg.kind == "tick" then
		if msg.tag == string.format("auto:%d", s.gen) and not s.loading and not s.writing then
			load(s, env, effects, false)
		end
	elseif msg.kind == "key" then
		local _, list = M.key(s, msg.key, env)
		return s, list
	elseif msg.kind == "event" then
		local ev: any = msg.ev
		if ev.ev == "action" and type(ev.act) == "string" then
			local staged = s.confirm ~= nil
			onAction(s, ev.act, ev.value, env, effects)
			if not staged and s.confirm then
				table.insert(effects, { kind = "reveal", id = "main.confirm", at = "start" })
			end
		end
	end
	return s, effects
end

function M.title(s: State): string?
	return if s.context then "On-call: " .. (s.context :: string) else "On-call"
end

function M.save(s: State): any
	return { context = s.context, view = s.view, show_resolved = s.show_resolved }
end

return M
