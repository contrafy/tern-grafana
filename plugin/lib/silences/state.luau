--!strict
-- The `silence` block: a context's silences (list, expire) and the form that
-- creates one, usually opened from an alert with its labels prefilled.
--
-- Writes are never automatic: "Create" and "expire" only stage a pending
-- write (`confirm`) that the view spells out (matchers, times, how many
-- current alerts it covers, which server); the request is sent only when the
-- user confirms that exact staged write with `y` or the Confirm button. A
-- failed write is reported and never retried. Comments are user text that
-- may hold anything: they go into the request body only, never into logs,
-- saved state or block args.

local Api = require("./api")
local Classify = require("../transport/classify")
local Duration = require("./duration")
local Effect = require("../effect")
local Env = require("../env")
local Matchers = require("./matchers")
local Normalize = require("../alerts/normalize")
local Scheme = require("../links/scheme")
local Sources = require("../alerts/sources")
local TransportTypes = require("../transport/types")

type Alert = Normalize.Alert
type Env = Env.Env
type Matcher = Matchers.Matcher
type Plan = Sources.Plan
type Response = TransportTypes.Response
type Silence = Api.Silence

-- Asks the host for the login user (created_by default); answered by
-- `{kind = "user", name = string?}`.
export type UserEffect = { kind: "silence_user" }
-- One log line per write decision: whitelisted fields only (never the
-- comment, matcher values or credentials).
export type AuditEffect = {
	kind: "silence_audit",
	action: "create" | "expire",
	outcome: "sent" | "ok" | "failed" | "cancelled",
	context: string,
	target: string,
	matchers: number?,
	duration_s: number?,
	id: string?,
	status: number?,
}
export type Effect = Effect.Effect | UserEffect | AuditEffect

export type Field = "matcher" | "add" | "duration" | "comment" | "created_by" | "submit"
export type FormRow = { field: Field, index: number? }

export type Form = {
	matchers: { Matcher },
	-- 1..#Duration.PRESETS, or Duration.CUSTOM.
	preset: number,
	custom: string,
	comment: string,
	created_by: string,
	sel: number,
	-- Why the last "Create" was refused.
	error: string?,
}

export type Edit = { field: Field, index: number?, text: string, error: string? }

export type Pending = { kind: "create", draft: Api.Draft } | { kind: "expire", silence: Silence }

export type State = {
	contexts: { string },
	context: string?,
	plan: Plan?,
	target: Api.Target?,
	problem: string?,
	gen: number,
	loading: boolean,
	responses: { [string]: Response },
	alerts: { Alert },
	alerts_error: string?,
	silences: { Silence },
	silences_error: string?,
	loaded_ms: number?,
	show_expired: boolean,
	page: "list" | "form",
	-- Index into M.visible(s).
	sel: number,
	-- The silence to select once the next load lands.
	focus_id: string?,
	form: Form?,
	editing: Edit?,
	-- A staged write waiting for the user's explicit confirmation.
	confirm: Pending?,
	-- The confirmed write in flight, and its tag.
	writing: Pending?,
	write_tag: string?,
	write_seq: number,
	note: string?,
	note_tone: string?,
	user: string?,
}

local M = {}

M.REFRESH_MS = 60 * 1000
M.DEFAULT_PRESET = 2 -- 2h

local SIL_TAG = "sil"

local function sortedContexts(env: Env): { string }
	local out: { string } = {}
	if env.config then
		for name in env.config.contexts do
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

function M.visible(s: State): { Silence }
	if s.show_expired then
		return s.silences
	end
	local out: { Silence } = {}
	for _, x in s.silences do
		if x.state ~= "expired" then
			table.insert(out, x)
		end
	end
	return out
end

function M.selected(s: State): Silence?
	return M.visible(s)[s.sel]
end

local function clampSel(s: State)
	local n = #M.visible(s)
	s.sel = math.clamp(s.sel, 1, math.max(1, n))
end

function M.formRows(form: Form): { FormRow }
	local rows: { FormRow } = {}
	for i in form.matchers do
		table.insert(rows, { field = "matcher", index = i })
	end
	table.insert(rows, { field = "add" })
	table.insert(rows, { field = "duration" })
	table.insert(rows, { field = "comment" })
	table.insert(rows, { field = "created_by" })
	table.insert(rows, { field = "submit" })
	return rows
end

local function newForm(s: State, matchers: { Matcher }): Form
	return {
		matchers = matchers,
		preset = M.DEFAULT_PRESET,
		custom = "",
		comment = "",
		created_by = s.user or "",
		-- Start on the comment: the one field that is always empty.
		sel = #matchers + 3,
		error = nil,
	}
end

-- Seconds of the form's duration, or nil and why.
function M.durationOf(form: Form): (number?, string?)
	if form.preset < Duration.CUSTOM then
		return Duration.PRESETS[form.preset].s, nil
	end
	return Duration.parse(form.custom)
end

-- The silence this form would create, or nil and what to fix.
function M.draft(form: Form): (Api.Draft?, string?)
	local err = Matchers.validate(form.matchers)
	if err then
		return nil, err
	end
	local seconds, durErr = M.durationOf(form)
	if seconds == nil then
		return nil, durErr
	end
	local comment = string.match(form.comment, "^%s*(.-)%s*$") or ""
	if comment == "" then
		return nil, "a comment is required: say why the alert is silenced"
	end
	local by = string.match(form.created_by, "^%s*(.-)%s*$") or ""
	if by == "" then
		return nil, "created by is required"
	end
	return { matchers = form.matchers, duration_s = seconds :: number, comment = comment, created_by = by }, nil
end

-- Current alerts the form's matchers cover (nil when they are invalid).
function M.affected(s: State, matchers: { Matcher }): { Alert }?
	if #matchers == 0 then
		return nil
	end
	local list = Matchers.affected(matchers, s.alerts)
	return list
end

-- Alerts a silence currently mutes, per Alertmanager's own silencedBy.
function M.silencing(s: State, id: string): number
	local n = 0
	for _, a in s.alerts do
		if table.find(a.silenced_by, id) then
			n += 1
		end
	end
	return n
end

local function load(s: State, env: Env, effects: { Effect })
	s.gen += 1
	s.responses = {}
	local cfg = env.config
	if cfg == nil then
		s.problem = "No valid config: open Grafana: Settings or see docs/configuration.md."
		s.plan, s.target, s.loading = nil, nil, false
		return
	end
	local plan, err = Sources.plan(cfg, s.context)
	if plan == nil then
		s.problem = err
		s.plan, s.target, s.loading = nil, nil, false
		return
	end
	local target, why = Api.target(plan)
	if target == nil then
		s.problem = why
		s.plan, s.target, s.loading = plan, nil, false
		s.context = plan.context
		return
	end
	if s.plan == nil or (s.plan :: Plan).context ~= plan.context then
		s.alerts, s.silences = {}, {}
		s.loaded_ms, s.alerts_error, s.silences_error = nil, nil, nil
	end
	s.problem = nil
	s.plan, s.target = plan, target
	s.context = plan.context
	s.loading = true
	for _, f in plan.fetches do
		table.insert(effects, {
			kind = "http",
			tag = string.format("%d:a:%s", s.gen, f.tag),
			route = f.route,
			request = f.request,
		})
	end
	table.insert(effects, {
		kind = "http",
		tag = string.format("%d:%s", s.gen, SIL_TAG),
		route = plan.route,
		request = Api.listRequest(target :: Api.Target),
	})
end

local function settle(s: State, env: Env, effects: { Effect })
	local plan = s.plan :: Plan
	local alertResponses: { [string]: Response } = {}
	for _, f in plan.fetches do
		alertResponses[f.tag] = s.responses["a:" .. f.tag]
	end
	local result = Sources.combine(env, plan, alertResponses)
	if result.ok then
		s.alerts = result.alerts
		s.alerts_error = nil
	else
		s.alerts_error = result.error
	end
	local response = s.responses[SIL_TAG]
	local qe = Classify.classify(response, env.decode)
	if qe then
		s.silences_error = qe.message
	else
		local list, err = Api.parseList(env, response.body)
		if list then
			s.silences = list
			s.silences_error = nil
		else
			s.silences_error = err
		end
	end
	s.loading = false
	s.responses = {}
	s.loaded_ms = env.now_ms
	if s.focus_id then
		for i, x in M.visible(s) do
			if x.id == s.focus_id then
				s.sel = i
				break
			end
		end
		s.focus_id = nil
	end
	clampSel(s)
	table.insert(effects, { kind = "timer", tag = string.format("auto:%d", s.gen), ms = M.REFRESH_MS })
end

local function linkParams(args: { string }): { [string]: string }
	local first = args[1]
	if first == nil or first == "" then
		return {}
	end
	local link = Scheme.decode(first)
	if link == nil or link.action ~= "silence" then
		return {}
	end
	return link.params
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local params = linkParams(args)
	local savedT = if type(saved) == "table" then saved else {}
	local s: State = {
		contexts = sortedContexts(env),
		context = params.context or (if type(savedT.context) == "string" then savedT.context else nil),
		plan = nil,
		target = nil,
		problem = nil,
		gen = 0,
		loading = false,
		responses = {},
		alerts = {},
		alerts_error = nil,
		silences = {},
		silences_error = nil,
		loaded_ms = nil,
		show_expired = savedT.show_expired == true,
		page = "list",
		sel = 1,
		focus_id = params.id,
		form = nil,
		editing = nil,
		confirm = nil,
		writing = nil,
		write_tag = nil,
		write_seq = 0,
		note = nil,
		note_tone = nil,
		user = nil,
	}
	if s.context and env.config and env.config.contexts[s.context :: string] == nil then
		s.context = nil
	end
	if params.matchers then
		local list, err = Matchers.parseList(params.matchers)
		s.page = "form"
		s.form = newForm(s, list or {})
		if list == nil then
			s.note, s.note_tone = "The link's matchers were not understood: " .. tostring(err), "error"
		end
	end
	local effects: { Effect } = { { kind = "silence_user" } }
	load(s, env, effects)
	return s, effects
end

local function setNote(s: State, text: string?, tone: string?)
	s.note, s.note_tone = text, tone
end

local function audit(s: State, p: Pending, outcome: string, extra: { [string]: any }?): AuditEffect
	local e: any = {
		kind = "silence_audit",
		action = p.kind,
		outcome = outcome,
		context = s.context or "",
		target = if s.target then (s.target :: Api.Target).kind else "",
	}
	if p.kind == "create" then
		local d = (p :: any).draft :: Api.Draft
		e.matchers = #d.matchers
		e.duration_s = d.duration_s
	else
		e.id = ((p :: any).silence :: Silence).id
	end
	if extra then
		for k, v in extra do
			e[k] = v
		end
	end
	return e :: AuditEffect
end

-- Stages the form's silence for confirmation (nothing is sent).
local function review(s: State)
	local form = s.form
	if form == nil or s.writing then
		return
	end
	local draft, err = M.draft(form)
	if draft == nil then
		form.error = err
		return
	end
	form.error = nil
	s.confirm = { kind = "create", draft = draft }
end

local function stageExpire(s: State)
	if s.writing then
		return
	end
	local x = M.selected(s)
	if x == nil then
		return
	end
	if x.state == "expired" then
		setNote(s, "That silence has already expired.", "warning")
		return
	end
	s.confirm = { kind = "expire", silence = x }
end

-- The user confirmed the staged write: the only place a write is sent.
local function confirm(s: State, env: Env, effects: { Effect })
	local p = s.confirm
	local target = s.target
	if p == nil or target == nil or s.plan == nil or s.writing then
		return
	end
	s.confirm = nil
	s.write_seq += 1
	local request
	if p.kind == "create" then
		local body = Api.createBody((p :: any).draft, env.now_ms)
		request = Api.createRequest(target :: Api.Target, body, env.encode)
	else
		request = Api.expireRequest(target :: Api.Target, ((p :: any).silence :: Silence).id)
	end
	s.writing = p
	s.write_tag = string.format("w%d:%s", s.write_seq, p.kind)
	setNote(s, if p.kind == "create" then "Creating the silence..." else "Expiring the silence...", "muted")
	table.insert(effects, audit(s, p, "sent"))
	table.insert(effects, {
		kind = "http",
		tag = s.write_tag :: string,
		route = (s.plan :: Plan).route,
		request = request,
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

local function written(s: State, response: Response, env: Env, effects: { Effect })
	local p = s.writing :: Pending
	s.writing = nil
	s.write_tag = nil
	local qe = Classify.classify(response, env.decode)
	if qe then
		-- Never retried: the user decides after reading why it failed.
		table.insert(effects, audit(s, p, "failed", { status = response.status }))
		setNote(
			s,
			string.format(
				"%s failed: %s",
				if p.kind == "create" then "Creating the silence" else "Expiring the silence",
				qe.message
			),
			"error"
		)
		return
	end
	if p.kind == "create" then
		local id = Api.parseCreated(env, response.body)
		local d = (p :: any).draft :: Api.Draft
		table.insert(effects, audit(s, p, "ok", { id = id, status = response.status }))
		setNote(
			s,
			string.format("Silence %s created: ends in %s.", id or "(no id returned)", Duration.format(d.duration_s)),
			"ok"
		)
		s.page = "list"
		s.form = nil
		s.editing = nil
		s.focus_id = id
	else
		local x = (p :: any).silence :: Silence
		table.insert(effects, audit(s, p, "ok", { status = response.status }))
		setNote(s, string.format("Silence %s expired.", x.id), "ok")
		s.focus_id = x.id
	end
	load(s, env, effects)
end

local function openForm(s: State, matchers: { Matcher })
	if s.target == nil then
		return
	end
	s.page = "form"
	s.form = newForm(s, matchers)
	s.editing = nil
	setNote(s, nil)
end

local function backToList(s: State)
	s.page = "list"
	s.form = nil
	s.editing = nil
	s.confirm = nil
end

local function switchContext(s: State, env: Env, name: string, effects: { Effect })
	if name == s.context or s.page ~= "list" or s.writing then
		return
	end
	s.context = name
	s.sel = 1
	s.confirm = nil
	setNote(s, nil)
	load(s, env, effects)
end

local function cycleContext(s: State, env: Env, step: number, effects: { Effect })
	local n = #s.contexts
	if n < 2 then
		return
	end
	local i = table.find(s.contexts, s.context or "") or 0
	switchContext(s, env, s.contexts[(i - 1 + step) % n + 1], effects)
end

-- Starts editing the form row `row` (or acts on it when it is not text).
local function activateRow(s: State, row: FormRow)
	local form = s.form :: Form
	if row.field == "matcher" then
		local m = form.matchers[row.index :: number]
		s.editing = { field = "matcher", index = row.index, text = Matchers.format(m) }
	elseif row.field == "add" then
		s.editing = { field = "matcher", index = nil, text = "" }
	elseif row.field == "duration" then
		if form.preset == Duration.CUSTOM then
			s.editing = { field = "duration", text = form.custom }
		else
			form.preset = form.preset % Duration.CUSTOM + 1
			if form.preset == Duration.CUSTOM then
				s.editing = { field = "duration", text = form.custom }
			end
		end
	elseif row.field == "comment" then
		s.editing = { field = "comment", text = form.comment }
	elseif row.field == "created_by" then
		s.editing = { field = "created_by", text = form.created_by }
	elseif row.field == "submit" then
		review(s)
	end
end

local function commitEdit(s: State)
	local form = s.form :: Form
	local e = s.editing :: Edit
	if e.field == "matcher" then
		if e.index == nil and string.match(e.text, "^%s*$") then
			s.editing = nil
			return
		end
		local m, err = Matchers.parse(e.text)
		if m == nil then
			e.error = err
			return
		end
		if e.index then
			form.matchers[e.index :: number] = m :: Matcher
		elseif #form.matchers >= Matchers.MAX_MATCHERS then
			e.error = string.format("at most %d matchers", Matchers.MAX_MATCHERS)
			return
		else
			table.insert(form.matchers, m :: Matcher)
			form.sel = #form.matchers
		end
	elseif e.field == "duration" then
		local _, err = Duration.parse(e.text)
		if err then
			e.error = err
			return
		end
		form.custom = e.text
	elseif e.field == "comment" then
		form.comment = e.text
	elseif e.field == "created_by" then
		form.created_by = e.text
	end
	form.error = nil
	s.editing = nil
end

local function editKey(s: State, key: any): boolean
	local e = s.editing :: Edit
	local name = key.name
	if name == "escape" then
		s.editing = nil
	elseif name == "enter" then
		commitEdit(s)
	elseif name == "backspace" then
		e.text = string.sub(e.text, 1, (utf8.offset(e.text, -1) or (#e.text + 1)) - 1)
		e.error = nil
	elseif name == "paste" and type(key.text) == "string" then
		e.text ..= string.gsub(key.text, "%c", " ")
	elseif key.ctrl and name == "u" then
		e.text = ""
	elseif key.text and key.text ~= "" and not key.ctrl and not key.meta then
		e.text ..= key.text
	else
		return false
	end
	return true
end

local function removeMatcher(s: State, index: number)
	local form = s.form :: Form
	if form.matchers[index] then
		table.remove(form.matchers, index)
		form.sel = math.clamp(form.sel, 1, #M.formRows(form))
	end
end

local function formKey(s: State, key: any, effects: { Effect }): boolean
	local form = s.form :: Form
	local rows = M.formRows(form)
	local name, text = key.name, key.text
	local row = rows[form.sel]
	if name == "down" or text == "j" or name == "tab" then
		form.sel = math.min(#rows, form.sel + 1)
		table.insert(effects, { kind = "reveal", id = "main.form.f" .. form.sel })
	elseif name == "up" or text == "k" then
		form.sel = math.max(1, form.sel - 1)
		table.insert(effects, { kind = "reveal", id = "main.form.f" .. form.sel })
	elseif name == "enter" or name == "space" then
		if row then
			activateRow(s, row)
			if s.editing then
				table.insert(effects, { kind = "focus", id = "main.edit" })
			end
		end
	elseif (name == "left" or name == "right") and row and row.field == "duration" then
		local n = Duration.CUSTOM
		form.preset = (form.preset - 1 + (if name == "right" then 1 else -1)) % n + 1
	elseif (text == "x" or name == "delete") and row and row.field == "matcher" then
		removeMatcher(s, row.index :: number)
	elseif text == "a" then
		s.editing = { field = "matcher", index = nil, text = "" }
		table.insert(effects, { kind = "focus", id = "main.edit" })
	elseif text == "S" then
		review(s)
	elseif name == "escape" then
		backToList(s)
		setNote(s, "Discarded the new silence.", "muted")
	else
		return false
	end
	return true
end

local function listKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	local name, text = key.name, key.text
	local n = #M.visible(s)
	local moved = true
	if name == "down" or text == "j" then
		s.sel = math.min(math.max(1, n), s.sel + 1)
	elseif name == "up" or text == "k" then
		s.sel = math.max(1, s.sel - 1)
	elseif name == "home" then
		s.sel = 1
	elseif name == "end" then
		s.sel = math.max(1, n)
	else
		moved = false
	end
	if moved then
		local x = M.selected(s)
		if x then
			table.insert(effects, { kind = "reveal", id = "main.list.s" .. x.id })
		end
		return true
	end
	if text == "x" then
		stageExpire(s)
	elseif text == "n" then
		openForm(s, {})
	elseif text == "e" then
		local x = M.selected(s)
		if x then
			-- A new silence like the selected one (Alertmanager's "recreate").
			openForm(s, table.clone(x.matchers))
		end
	elseif text == "m" then
		s.show_expired = not s.show_expired
		clampSel(s)
	elseif text == "r" then
		load(s, env, effects)
	elseif text == "c" then
		cycleContext(s, env, 1, effects)
	elseif text == "C" then
		cycleContext(s, env, -1, effects)
	elseif name == "escape" and s.note then
		setNote(s, nil)
	else
		return false
	end
	return true
end

function M.key(s: State, key: any, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	local handled = false
	local kname: string = if type(key.name) == "string" then key.name else ""
	local ktext: string = if type(key.text) == "string" then key.text else ""
	local ctrlU: boolean = s.editing ~= nil and key.name == "u"
	if (key.ctrl and not ctrlU) or key.meta or key.alt then
		return s, effects, false
	end
	local staged = s.confirm ~= nil
	if s.confirm then
		-- Only an explicit `y` confirms; enter does not (a repeated enter on
		-- "Create" must not send).
		if ktext == "y" then
			confirm(s, env, effects)
			handled = true
		elseif ktext == "n" or kname == "escape" then
			cancel(s, effects)
			handled = true
		end
	elseif s.editing then
		handled = editKey(s, key)
	elseif s.page == "form" and s.form then
		handled = formKey(s, key, effects)
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
		-- Everything else waits until the staged write is confirmed or cancelled.
		return
	elseif act == "ctx" and value and table.find(s.contexts, value) then
		switchContext(s, env, value, effects)
	elseif act == "reload" then
		load(s, env, effects)
	elseif act == "expired" then
		s.show_expired = not s.show_expired
		clampSel(s)
	elseif act == "new" then
		openForm(s, {})
	elseif act == "back" then
		backToList(s)
	elseif act == "row" and i and M.visible(s)[i] then
		s.sel = i
	elseif act == "expire" and i and M.visible(s)[i] then
		s.sel = i
		stageExpire(s)
	elseif act == "recreate" and i and M.visible(s)[i] then
		s.sel = i
		openForm(s, table.clone((M.visible(s)[i] :: Silence).matchers))
	elseif s.form and act == "frow" and i then
		local form = s.form :: Form
		local rows = M.formRows(form)
		if rows[i] then
			s.editing = nil
			form.sel = i
			activateRow(s, rows[i])
			if s.editing then
				table.insert(effects, { kind = "focus", id = "main.edit" })
			end
		end
	elseif s.form and act == "dur" and i and i >= 1 and i <= Duration.CUSTOM then
		local form = s.form :: Form
		form.preset = i
		if i == Duration.CUSTOM then
			s.editing = { field = "duration", text = form.custom }
			table.insert(effects, { kind = "focus", id = "main.edit" })
		end
	elseif s.form and act == "rm" and i then
		removeMatcher(s, i)
	elseif s.form and act == "submit" then
		review(s)
	end
end

function M.update(s: State, msg: any, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		if s.write_tag and msg.tag == s.write_tag and s.writing then
			written(s, msg.response, env, effects)
			return s, effects
		end
		local gen, tag = string.match(msg.tag, "^(%d+):(.+)$")
		if gen == nil or tonumber(gen) ~= s.gen or s.plan == nil or not s.loading then
			return s, effects
		end
		s.responses[tag :: string] = msg.response
		if s.responses[SIL_TAG] == nil then
			return s, effects
		end
		for _, f in (s.plan :: Plan).fetches do
			if s.responses["a:" .. f.tag] == nil then
				return s, effects
			end
		end
		settle(s, env, effects)
	elseif msg.kind == "tick" then
		if msg.tag == string.format("auto:%d", s.gen) and not s.loading then
			load(s, env, effects)
		end
	elseif msg.kind == "user" then
		local name = if type(msg.name) == "string" and msg.name ~= "" then msg.name else nil
		s.user = name
		if name and s.form and (s.form :: Form).created_by == "" then
			(s.form :: Form).created_by = name
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
	local base = if s.page == "form" then "New silence" else "Silences"
	return if s.context then base .. ": " .. (s.context :: string) else base
end

-- Only what to reopen with: never a draft (its comment is free text).
function M.save(s: State): any
	return { context = s.context, show_expired = s.show_expired }
end

return M
