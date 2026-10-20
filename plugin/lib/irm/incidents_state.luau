--!strict
-- The `incidents` block: a context's open Grafana IRM incidents (severity,
-- status, how long they have been open), one incident's detail with its
-- timeline, and the writes: declare an incident, change its status or
-- severity, add a note.
--
-- Writes are never automatic: a key or button only stages the write
-- (`confirm`); the view spells out what will change, that IRM's incident
-- hooks may notify people, and that IRM records it under the service
-- account. The request is sent only when the user confirms that exact
-- staged write with `y` or the Confirm button. A failed write is reported
-- and never retried. Titles and notes are user text: they go into the
-- request body only, never into logs, saved state or block args.

local Effect = require("../effect")
local Env = require("../env")
local Irm = require("../source/irm")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Target = require("./target")
local TransportTypes = require("../transport/types")
local Common = require("./common")

type Env = Env.Env
type Route = Route.Route
type Response = TransportTypes.Response
type Incident = Irm.Incident

export type AuditEffect = {
	kind: "irm_audit",
	block: "incidents",
	action: string,
	outcome: "sent" | "ok" | "failed" | "cancelled",
	context: string,
	target: string,
	status: number?,
}
export type Effect = Effect.Effect | AuditEffect

export type Pending =
	{ kind: "declare", title: string, severity: string }
	| { kind: "status", incident: Incident, status: Irm.Status }
	| { kind: "severity", incident: Incident, severity: string }
	| { kind: "note", incident: Incident, body: string }

export type Detail = {
	id: string,
	incident: Incident?,
	activity: { Irm.Activity }?,
	error: string?,
	activity_error: string?,
	loading: boolean,
}

export type Form = { title: string, severity: number, row: number, error: string? }

export type Picker = { kind: "status" | "severity", index: number }

export type Editing = { field: "title" | "note", text: string }

export type State = {
	contexts: { string },
	context: string?,
	grafana: Route?,
	problem: string?,
	gen: number,
	waiting: { [string]: boolean },
	loading: boolean,
	incidents: { Incident },
	more: boolean,
	list_error: string?,
	statuses: { Irm.Status }?,
	-- From GetOrgSeverities; nil when this IRM version does not offer it.
	org_severities: { string }?,
	login: string?,
	loaded_ms: number?,
	sel: number,
	sel_id: string?,
	page: "list" | "detail" | "declare",
	detail: Detail?,
	detail_seq: number,
	form: Form?,
	picker: Picker?,
	editing: Editing?,
	confirm: Pending?,
	writing: Pending?,
	write_tag: string?,
	write_seq: number,
	note: string?,
	note_tone: string?,
}

local M = {}

M.REFRESH_MS = 60 * 1000
M.ACTIVITY = 50
M.MAX_TITLE = 512
M.MAX_NOTE = 4000
-- IRM's own defaults, offered when the org's list cannot be read.
M.DEFAULT_SEVERITIES = { "Minor", "Major", "Critical" }
local DEFAULT_STATUSES: { Irm.Status } = {
	{ slug = "active", name = "Active", category = "active" },
	{ slug = "resolved", name = "Resolved", category = "resolved" },
}
M.DEFAULT_STATUSES = DEFAULT_STATUSES

-- Form rows of the declare page.
M.FORM_ROWS = 3

local function setNote(s: State, text: string?, tone: string?)
	s.note, s.note_tone = text, tone
end

local function request(s: State, effects: { Effect }, name: string, req: TransportTypes.Request)
	s.waiting[name] = true
	s.loading = true
	table.insert(
		effects,
		{ kind = "http", tag = string.format("%d:%s", s.gen, name), route = s.grafana :: Route, request = req }
	)
end

function M.selected(s: State): Incident?
	return s.incidents[s.sel]
end

-- Severity choices: the org's, else the ones seen on incidents plus IRM's
-- defaults.
function M.severities(s: State): { string }
	if s.org_severities then
		return s.org_severities :: { string }
	end
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(label: string)
		local key = string.lower(label)
		if label ~= "" and not seen[key] then
			seen[key] = true
			table.insert(out, label)
		end
	end
	for _, d in M.DEFAULT_SEVERITIES do
		add(d)
	end
	for _, x in s.incidents do
		add(x.severity)
	end
	return out
end

function M.statuses(s: State): { Irm.Status }
	if s.statuses and #(s.statuses :: { Irm.Status }) > 0 then
		return s.statuses :: { Irm.Status }
	end
	return M.DEFAULT_STATUSES
end

local function statusOf(s: State, slug: string): Irm.Status?
	for _, st in M.statuses(s) do
		if st.slug == slug then
			return st
		end
	end
	return nil
end

local function load(s: State, env: Env, effects: { Effect }, full: boolean)
	s.gen += 1
	s.waiting = {}
	s.loading = false
	local route, why = Target.grafana(env.config, s.context)
	if route == nil then
		s.problem = why
		s.grafana = nil
		return
	end
	local r = route :: Route
	if s.grafana == nil or (s.grafana :: Route).context ~= r.context then
		full = true
		s.incidents, s.more, s.statuses, s.org_severities = {}, false, nil, nil
		s.login, s.loaded_ms, s.detail = nil, nil, nil
	end
	s.grafana = r
	s.context = r.context
	s.problem = nil
	request(s, effects, "list", Irm.openIncidentsRequest(Irm.MAX_INCIDENTS, env.encode))
	if full then
		request(s, effects, "statuses", Irm.statusesRequest(env.encode))
		request(s, effects, "severities", Irm.severitiesRequest())
		request(s, effects, "user", Irm.userRequest())
	end
end

local function loadDetail(s: State, env: Env, effects: { Effect }, id: string)
	if s.grafana == nil then
		return
	end
	s.detail_seq += 1
	local keep = if s.detail and (s.detail :: Detail).id == id then s.detail else nil
	s.detail = {
		id = id,
		incident = if keep then keep.incident else nil,
		activity = if keep then keep.activity else nil,
		error = nil,
		activity_error = nil,
		loading = true,
	}
	local prefix = string.format("d%d:", s.detail_seq)
	table.insert(effects, {
		kind = "http",
		tag = prefix .. "incident",
		route = s.grafana :: Route,
		request = Irm.incidentRequest(id, env.encode),
	})
	table.insert(effects, {
		kind = "http",
		tag = prefix .. "activity",
		route = s.grafana :: Route,
		request = Irm.activityRequest(id, M.ACTIVITY, env.encode),
	})
end

local function openDetail(s: State, env: Env, effects: { Effect }, id: string)
	s.page = "detail"
	s.sel_id = id
	loadDetail(s, env, effects, id)
end

local function linkParams(args: { string }): { [string]: string }
	local first = args[1]
	if first == nil or first == "" then
		return {}
	end
	local link = Scheme.decode(first)
	if link == nil or link.action ~= "incidents" then
		return {}
	end
	return link.params
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local params = linkParams(args)
	local savedT = if type(saved) == "table" then saved else {}
	local s: State = {
		contexts = Target.contexts(env.config),
		context = params.context or (if type(savedT.context) == "string" then savedT.context else nil),
		grafana = nil,
		problem = nil,
		gen = 0,
		waiting = {},
		loading = false,
		incidents = {},
		more = false,
		list_error = nil,
		statuses = nil,
		org_severities = nil,
		login = nil,
		loaded_ms = nil,
		sel = 1,
		sel_id = nil,
		page = "list",
		detail = nil,
		detail_seq = 0,
		form = nil,
		picker = nil,
		editing = nil,
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
	if params.id and s.grafana then
		openDetail(s, env, effects, params.id)
	end
	return s, effects
end

-- Open incidents only: a custom status in the resolved category is closed.
local function openOnly(s: State, list: { Incident }): { Incident }
	local out: { Incident } = {}
	for _, x in list do
		local st = statusOf(s, x.status)
		if not (st and st.category == "resolved") and x.status ~= "resolved" then
			table.insert(out, x)
		end
	end
	return out
end

local function reselect(s: State)
	if s.sel_id then
		for i, x in s.incidents do
			if x.id == s.sel_id then
				s.sel = i
				return
			end
		end
	end
	s.sel = math.clamp(s.sel, 1, math.max(1, #s.incidents))
end

local function settle(s: State, env: Env, name: string, response: Response)
	if name == "list" then
		local list, more, qe = Irm.parseIncidents(response, env)
		if list then
			s.incidents = openOnly(s, list)
			s.more = more
			s.list_error = nil
			reselect(s)
		else
			s.list_error = if qe then qe.message else "incidents could not be read"
			if qe and qe.kind == "unsupported" then
				s.problem = qe.message
			end
		end
	elseif name == "statuses" then
		s.statuses = Irm.parseStatuses(response, env)
		s.incidents = openOnly(s, s.incidents)
		reselect(s)
	elseif name == "severities" then
		s.org_severities = Irm.parseSeverities(response, env)
	elseif name == "user" then
		s.login = Irm.parseLogin(response, env)
	end
end

local function settleDetail(s: State, env: Env, part: string, response: Response)
	local d = s.detail
	if d == nil then
		return
	end
	if part == "incident" then
		local x, qe = Irm.parseIncident(response, env)
		if x then
			d.incident = x
		else
			d.error = if qe then qe.message else "the incident could not be read"
		end
	else
		local list, qe = Irm.parseActivity(response, env)
		if list then
			d.activity = list
		else
			d.activity_error = if qe then qe.message else "the timeline could not be read"
		end
	end
	d.loading = d.incident == nil and d.error == nil
end

local function current(s: State): Incident?
	if s.page == "detail" and s.detail then
		return (s.detail :: Detail).incident
	end
	return M.selected(s)
end

local function pendingTarget(p: Pending): string
	if p.kind == "declare" then
		return "new"
	end
	return (p :: any).incident.id
end

local function audit(s: State, p: Pending, outcome: string, status: number?): AuditEffect
	return {
		kind = "irm_audit",
		block = "incidents",
		action = p.kind,
		outcome = outcome :: any,
		context = s.context or "",
		target = pendingTarget(p),
		status = status,
	}
end

local function writeRequest(p: Pending, env: Env): TransportTypes.Request
	if p.kind == "declare" then
		local d = p :: any
		return Irm.createIncidentRequest({ title = d.title, severity = d.severity }, env.encode)
	elseif p.kind == "status" then
		local d = p :: any
		return Irm.updateStatusRequest(d.incident.id, d.status.slug, env.encode)
	elseif p.kind == "severity" then
		local d = p :: any
		return Irm.updateSeverityRequest(d.incident.id, d.severity, env.encode)
	end
	local d = p :: any
	return Irm.addNoteRequest(d.incident.id, d.body, env.encode)
end

local VERB: { [string]: string } = {
	declare = "Declaring the incident",
	status = "Changing the status",
	severity = "Changing the severity",
	note = "Adding the note",
}

local function confirm(s: State, env: Env, effects: { Effect })
	local p = s.confirm
	if p == nil or s.grafana == nil or s.writing then
		return
	end
	s.confirm = nil
	s.write_seq += 1
	s.writing = p
	s.write_tag = string.format("w%d", s.write_seq)
	setNote(s, VERB[p.kind] .. "...", "muted")
	table.insert(effects, audit(s, p, "sent"))
	table.insert(effects, {
		kind = "http",
		tag = s.write_tag :: string,
		route = s.grafana :: Route,
		request = writeRequest(p, env),
	})
end

local function cancel(s: State, effects: { Effect })
	local p = s.confirm
	if p == nil then
		return
	end
	s.confirm = nil
	setNote(s, "Cancelled: nothing was sent.", "muted")
	table.insert(effects, audit(s, p, "cancelled"))
end

local function written(s: State, env: Env, response: Response, effects: { Effect })
	local p = s.writing :: Pending
	s.writing, s.write_tag = nil, nil
	local id: string? = nil
	local qe: TransportTypes.QueryError? = nil
	if p.kind == "note" then
		local _, err = Irm.parseNoteAdded(response, env)
		qe = err
	else
		local x, err = Irm.parseIncident(response, env, "incident_write")
		qe = err
		id = if x then x.id else nil
	end
	if qe then
		-- Never retried: the user decides after reading why it failed.
		table.insert(effects, audit(s, p, "failed", response.status))
		setNote(s, string.format("%s failed: %s", VERB[p.kind], (qe :: TransportTypes.QueryError).message), "error")
		return
	end
	table.insert(effects, audit(s, p, "ok", response.status))
	if p.kind == "declare" then
		s.form = nil
		setNote(s, "Incident declared" .. (if id then " (" .. (id :: string) .. ")" else "") .. ".", "ok")
		load(s, env, effects, false)
		if id then
			openDetail(s, env, effects, id :: string)
		else
			s.page = "list"
		end
		return
	end
	local done: { [string]: string } =
		{ status = "Status changed.", severity = "Severity changed.", note = "Note added." }
	setNote(s, done[p.kind], "ok")
	load(s, env, effects, false)
	loadDetail(s, env, effects, (p :: any).incident.id)
end

-- Why a write on the current incident cannot be staged, or nil.
local function stageCheck(s: State): Incident?
	if s.writing or s.confirm then
		return nil
	end
	local x = current(s)
	if x == nil then
		setNote(s, "Open an incident first (enter on a row).", "warning")
	end
	return x
end

local function openPicker(s: State, kind: "status" | "severity")
	local x = stageCheck(s)
	if x == nil then
		return
	end
	local options = if kind == "status" then M.statuses(s) else nil
	local index = 1
	if options then
		for i, st in options do
			if st.slug == (x :: Incident).status then
				index = i
			end
		end
	else
		local sev = M.severities(s)
		index = table.find(sev, (x :: Incident).severity) or 1
	end
	s.picker = { kind = kind, index = index }
end

local function pickerCount(s: State): number
	local p = s.picker :: Picker
	return if p.kind == "status" then #M.statuses(s) else #M.severities(s)
end

local function stagePicker(s: State)
	local p = s.picker :: Picker
	local x = current(s)
	s.picker = nil
	if x == nil then
		return
	end
	if p.kind == "status" then
		local st = M.statuses(s)[p.index]
		if st == nil or st.slug == (x :: Incident).status then
			setNote(s, "The status is unchanged: nothing to send.", "muted")
			return
		end
		s.confirm = { kind = "status", incident = x :: Incident, status = st }
	else
		local sev = M.severities(s)[p.index]
		if sev == nil or sev == (x :: Incident).severity then
			setNote(s, "The severity is unchanged: nothing to send.", "muted")
			return
		end
		s.confirm = { kind = "severity", incident = x :: Incident, severity = sev }
	end
end

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

-- The declare form's staged incident, or why not.
function M.draft(s: State): (Pending?, string?)
	local form = s.form
	if form == nil then
		return nil, nil
	end
	local title = trim(form.title)
	if title == "" then
		return nil, "a title is required"
	end
	if #title > M.MAX_TITLE then
		return nil, string.format("the title is longer than %d characters", M.MAX_TITLE)
	end
	local sev = M.severities(s)[form.severity]
	if sev == nil then
		return nil, "choose a severity"
	end
	return { kind = "declare", title = title, severity = sev }, nil
end

local function stageDeclare(s: State)
	if s.writing or s.confirm or s.form == nil then
		return
	end
	local p, err = M.draft(s);
	(s.form :: Form).error = err
	if p then
		s.confirm = p
	end
end

local function stageNote(s: State, text: string)
	local x = current(s)
	local body = trim(text)
	if x == nil then
		return
	end
	if body == "" then
		setNote(s, "An empty note is not sent.", "muted")
		return
	end
	if #body > M.MAX_NOTE then
		setNote(s, string.format("The note is longer than %d characters.", M.MAX_NOTE), "error")
		return
	end
	s.confirm = { kind = "note", incident = x :: Incident, body = body }
end

local function openDeclare(s: State)
	if s.grafana == nil or s.writing then
		return
	end
	local sev = M.severities(s)
	s.page = "declare"
	s.form = { title = "", severity = math.max(1, math.min(#sev, 1)), row = 1, error = nil }
	s.editing = { field = "title", text = "" }
end

local function switchContext(s: State, env: Env, name: string, effects: { Effect })
	if name == s.context or s.writing then
		return
	end
	s.context = name
	s.sel, s.sel_id = 1, nil
	s.page, s.form, s.picker, s.editing, s.confirm = "list", nil, nil, nil, nil
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

local function openBrowser(s: State, effects: { Effect })
	local x = current(s)
	local grafana = if s.grafana then (s.grafana :: Route).endpoint.url else nil
	local url = if x then Common.absolute(x.url, grafana) else nil
	if url == nil and x and grafana then
		url = (string.gsub(grafana :: string, "/+$", "")) .. "/a/grafana-irm-app/incidents/" .. (x :: Incident).id
	end
	if url then
		table.insert(effects, {
			kind = "open",
			target = Scheme.encode({ action = "browse", params = { url = url :: string }, vars = {} }),
		})
	end
end

local function editKey(s: State, key: any): boolean
	local e = s.editing :: Editing
	if key.name == "escape" then
		s.editing = nil
		return true
	elseif key.name == "enter" then
		s.editing = nil
		if e.field == "title" and s.form then
			(s.form :: Form).title = e.text;
			(s.form :: Form).row = 2
		elseif e.field == "note" then
			stageNote(s, e.text)
		end
		return true
	end
	local text, used = Common.editKey(e.text, key)
	e.text = text
	return used
end

local function pickerKey(s: State, key: any): boolean
	local p = s.picker :: Picker
	local n = pickerCount(s)
	if key.name == "down" or key.text == "j" or key.name == "right" or key.text == "l" then
		p.index = p.index % math.max(1, n) + 1
	elseif key.name == "up" or key.text == "k" or key.name == "left" or key.text == "h" then
		p.index = (p.index - 2) % math.max(1, n) + 1
	elseif key.name == "enter" then
		stagePicker(s)
	elseif key.name == "escape" then
		s.picker = nil
	else
		return false
	end
	return true
end

local function formKey(s: State, key: any): boolean
	local form = s.form :: Form
	local name, text = key.name, key.text
	local n = #M.severities(s)
	if name == "down" or text == "j" or name == "tab" then
		form.row = math.min(M.FORM_ROWS, form.row + 1)
	elseif name == "up" or text == "k" then
		form.row = math.max(1, form.row - 1)
	elseif (name == "left" or name == "right") and form.row == 2 then
		form.severity = (form.severity - 1 + (if name == "right" then 1 else -1)) % math.max(1, n) + 1
	elseif name == "enter" or name == "space" then
		if form.row == 1 then
			s.editing = { field = "title", text = form.title }
		elseif form.row == 2 then
			form.severity = form.severity % math.max(1, n) + 1
		else
			stageDeclare(s)
		end
	elseif text == "D" then
		stageDeclare(s)
	elseif name == "escape" then
		s.page, s.form = "list", nil
		setNote(s, "Discarded the new incident.", "muted")
	else
		return false
	end
	return true
end

local function listKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	local name, text = key.name, key.text
	if name == "down" or text == "j" then
		s.sel = math.min(math.max(1, #s.incidents), s.sel + 1)
	elseif name == "up" or text == "k" then
		s.sel = math.max(1, s.sel - 1)
	elseif name == "home" then
		s.sel = 1
	elseif name == "end" then
		s.sel = math.max(1, #s.incidents)
	elseif name == "enter" then
		local x = M.selected(s)
		if x then
			openDetail(s, env, effects, x.id)
		end
		return true
	elseif text == "n" then
		openDeclare(s)
		return true
	elseif text == "r" then
		load(s, env, effects, false)
		return true
	elseif text == "c" then
		cycleContext(s, env, 1, effects)
		return true
	elseif text == "C" then
		cycleContext(s, env, -1, effects)
		return true
	elseif text == "o" then
		openBrowser(s, effects)
		return true
	elseif text == "s" then
		openPicker(s, "status")
		return true
	elseif text == "v" then
		openPicker(s, "severity")
		return true
	elseif name == "escape" and s.note then
		setNote(s, nil)
		return true
	else
		return false
	end
	local x = M.selected(s)
	s.sel_id = if x then x.id else nil
	if x then
		table.insert(effects, { kind = "reveal", id = "main.list.i" .. x.id })
	end
	return true
end

local function detailKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	local name, text = key.name, key.text
	if name == "escape" then
		s.page = "list"
		reselect(s)
	elseif text == "s" then
		openPicker(s, "status")
	elseif text == "v" then
		openPicker(s, "severity")
	elseif text == "a" then
		if current(s) and not s.writing then
			s.editing = { field = "note", text = "" }
			table.insert(effects, { kind = "focus", id = "main.edit" })
		end
	elseif text == "r" and s.detail then
		loadDetail(s, env, effects, (s.detail :: Detail).id)
	elseif text == "o" then
		openBrowser(s, effects)
	else
		return false
	end
	return true
end

function M.key(s: State, key: any, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	local editingU = s.editing ~= nil and key.name == "u"
	if (key.ctrl and not editingU) or key.meta or key.alt then
		return s, effects, false
	end
	local text: string = if type(key.text) == "string" then key.text else ""
	local name: string = if type(key.name) == "string" then key.name else ""
	local staged = s.confirm ~= nil
	local handled: boolean
	if s.confirm then
		handled = true
		if text == "y" then
			confirm(s, env, effects)
		elseif text == "n" or name == "escape" then
			cancel(s, effects)
		else
			handled = false
		end
	elseif s.editing then
		local wasTitle = (s.editing :: Editing).field == "title"
		handled = editKey(s, key)
		if s.editing == nil and wasTitle then
			table.insert(effects, { kind = "focus", id = nil })
		end
	elseif s.picker then
		handled = pickerKey(s, key)
	elseif s.page == "declare" and s.form then
		handled = formKey(s, key)
		if s.editing then
			table.insert(effects, { kind = "focus", id = "main.edit" })
		end
	elseif s.page == "detail" then
		handled = detailKey(s, key, env, effects)
	else
		handled = listKey(s, key, env, effects)
		if s.editing then
			table.insert(effects, { kind = "focus", id = "main.edit" })
		end
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
	elseif act == "ctx" and value and table.find(s.contexts, value) then
		switchContext(s, env, value, effects)
	elseif act == "reload" then
		load(s, env, effects, false)
		if s.page == "detail" and s.detail then
			loadDetail(s, env, effects, (s.detail :: Detail).id)
		end
	elseif act == "row" and i and s.incidents[i] then
		s.sel = i
		openDetail(s, env, effects, s.incidents[i].id)
	elseif act == "back" then
		s.page, s.form, s.editing, s.picker = "list", nil, nil, nil
		reselect(s)
	elseif act == "declare" then
		openDeclare(s)
		table.insert(effects, { kind = "focus", id = "main.edit" })
	elseif act == "status" then
		openPicker(s, "status")
	elseif act == "severity" then
		openPicker(s, "severity")
	elseif act == "pick" and s.picker and i then
		(s.picker :: Picker).index = i
		stagePicker(s)
	elseif act == "addnote" and current(s) then
		s.editing = { field = "note", text = "" }
		table.insert(effects, { kind = "focus", id = "main.edit" })
	elseif act == "open" then
		openBrowser(s, effects)
	elseif act == "frow" and s.form and i then
		(s.form :: Form).row = i
		formKey(s, { name = "enter" })
		if s.editing then
			table.insert(effects, { kind = "focus", id = "main.edit" })
		end
	elseif act == "sev" and s.form and i and M.severities(s)[i] then
		(s.form :: Form).severity = i
	elseif act == "submit" then
		stageDeclare(s)
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
		local seq, part = string.match(tag, "^d(%d+):(%a+)$")
		if seq then
			if tonumber(seq) == s.detail_seq then
				settleDetail(s, env, part :: string, msg.response)
			end
			return s, effects
		end
		local gen, name = string.match(tag, "^(%d+):(.+)$")
		if gen == nil or tonumber(gen) ~= s.gen or not s.waiting[name :: string] then
			return s, effects
		end
		s.waiting[name :: string] = nil
		settle(s, env, name :: string, msg.response)
		if next(s.waiting) == nil and s.loading then
			s.loading = false
			s.loaded_ms = env.now_ms
			table.insert(effects, { kind = "timer", tag = string.format("auto:%d", s.gen), ms = M.REFRESH_MS })
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
	local base = if s.page == "declare" then "Declare incident" else "Incidents"
	return if s.context then base .. ": " .. (s.context :: string) else base
end

-- Only what to reopen with: never a draft title or note (free text).
function M.save(s: State): any
	return { context = s.context }
end

return M
