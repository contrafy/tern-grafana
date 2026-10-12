--!strict
-- The approve block (`tern-grafana.annotate`). Opened by the command hook
-- with `id` naming a pending draft in host memory, it shows exactly what
-- would be posted (text, tags, times, target Grafana) and asks: Always (post
-- and remember for this context), Once (post, ask next time) or Never
-- (remember, post nothing). Nothing is posted from `init` (restored blocks
-- re-run it) or without one of those choices; a failed post is reported and
-- never retried by itself. Opened without `id` it lists the remembered
-- decisions so one can be forgotten.
--
-- The block may get focus while the user is still typing in the terminal, so
-- no single ordinary key decides: arrows/tab pick a choice and only `y`
-- confirms it (enter does not); buttons decide on click.

local Api = require("./api")
local Approval = require("./approval")
local Classify = require("../transport/classify")
local Effect = require("../effect")
local Env = require("../env")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Draft = Api.Draft
type Response = TransportTypes.Response

-- Asks the host for the pending draft; answered by
-- `{kind = "annotate_pending", draft = Draft?}`.
export type LoadEffect = { kind: "annotate_load", id: string }
-- Drops the pending draft (decided or dismissed).
export type ForgetEffect = { kind: "annotate_forget", id: string }
-- One log line per decision: whitelisted fields only (never the text).
export type AuditEffect = {
	kind: "annotate_audit",
	action: "post" | "decline" | "forget",
	outcome: "sent" | "ok" | "failed" | "remembered",
	context: string,
	choice: string?,
	id: number?,
	status: number?,
}
export type Effect = Effect.Effect | LoadEffect | ForgetEffect | AuditEffect

export type Phase = "loading" | "ask" | "posting" | "posted" | "declined" | "missing" | "manage"

export type State = {
	id: string?,
	phase: Phase,
	draft: Draft?,
	-- The Grafana the draft posts to.
	grafana: string?,
	-- Keyboard-picked choice (index into M.CHOICES); nil until picked.
	sel: number?,
	choice: Approval.Choice?,
	write_tag: string?,
	write_seq: number,
	posted_id: number?,
	note: string?,
	note_tone: string?,
	-- Manage view: remembered decisions and the selected row.
	approvals: { { context: string, decision: Approval.Remembered } },
	row: number,
}

local M = {}

M.CHOICES = table.freeze({ "always", "once", "never" } :: { Approval.Choice })

local function linkId(args: { string }): (string?, boolean)
	local first = args[1]
	if first == nil or first == "" then
		return nil, true
	end
	local link = Scheme.decode(first)
	if link == nil or link.action ~= "annotate" then
		return nil, false
	end
	return link.params.id, true
end

local function refreshApprovals(s: State, env: Env)
	local raw = if env.kv_get then env.kv_get(Approval.KEY) else nil
	s.approvals = Approval.list(Approval.read(raw))
	s.row = math.clamp(s.row, 1, math.max(1, #s.approvals))
end

function M.init(args: { string }, _saved: any, env: Env): (State, { Effect })
	local id, valid = linkId(args)
	local s: State = {
		id = id,
		phase = "loading",
		draft = nil,
		grafana = nil,
		sel = nil,
		choice = nil,
		write_tag = nil,
		write_seq = 0,
		posted_id = nil,
		note = nil,
		note_tone = nil,
		approvals = {},
		row = 1,
	}
	if id then
		return s, { { kind = "annotate_load", id = id } }
	end
	s.phase = "manage"
	if not valid then
		s.note, s.note_tone = "The link was not understood; showing the remembered decisions.", "warning"
	end
	refreshApprovals(s, env)
	return s, {}
end

local function audit(s: State, action: string, outcome: string, extra: { [string]: any }?): AuditEffect
	local e: any = {
		kind = "annotate_audit",
		action = action,
		outcome = outcome,
		context = if s.draft then (s.draft :: Draft).context else "",
		choice = s.choice,
	}
	if extra then
		for k, v in extra do
			e[k] = v
		end
	end
	return e :: AuditEffect
end

local function remember(s: State, env: Env, choice: Approval.Choice, effects: { Effect })
	local d = s.draft :: Draft
	local raw = if env.kv_get then env.kv_get(Approval.KEY) else nil
	local nextValue = Approval.apply(raw, d.context, choice)
	if nextValue then
		table.insert(effects, { kind = "kv_set", key = Approval.KEY, value = nextValue })
	end
end

local function forgetPending(s: State, effects: { Effect })
	if s.id then
		table.insert(effects, { kind = "annotate_forget", id = s.id :: string })
	end
end

-- The user chose: the only place an annotation is posted.
function M.choose(s: State, env: Env, choice: Approval.Choice, effects: { Effect })
	if s.phase ~= "ask" or s.draft == nil then
		return
	end
	local d = s.draft :: Draft
	s.choice = choice
	if choice == "never" then
		remember(s, env, choice, effects)
		s.phase = "declined"
		s.note, s.note_tone = string.format("Nothing posted. Deploys in %q will not be annotated.", d.context), "muted"
		forgetPending(s, effects)
		table.insert(effects, audit(s, "decline", "remembered"))
		return
	end
	local route: Route.Route?, err: Route.RouteError? = nil, nil
	if env.config then
		route, err = Route.route(env.config, d.context, "annotations")
	end
	if route == nil then
		s.note = "Cannot post: " .. (if err then err.message else "no valid config")
		s.note_tone = "error"
		return
	end
	if choice == "always" then
		remember(s, env, choice, effects)
	end
	s.write_seq += 1
	s.write_tag = string.format("w%d", s.write_seq)
	s.phase = "posting"
	s.note, s.note_tone = "Posting the annotation...", "muted"
	table.insert(effects, audit(s, "post", "sent"))
	table.insert(effects, {
		kind = "http",
		tag = s.write_tag :: string,
		route = route :: Route.Route,
		request = Api.request(d, env.encode),
	})
end

local function written(s: State, response: Response, env: Env, effects: { Effect })
	s.write_tag = nil
	local qe = Classify.classify(response, env.decode)
	if qe then
		-- Never retried: the user may choose again after reading why.
		s.phase = "ask"
		s.note, s.note_tone = "Posting failed: " .. qe.message, "error"
		table.insert(effects, audit(s, "post", "failed", { status = response.status }))
		return
	end
	s.posted_id = Api.parseCreated(env, response.body)
	s.phase = "posted"
	local remembered = if s.choice == "always" then " Future deploys here are annotated without asking." else ""
	s.note = string.format(
		"Annotation %s posted to %s.%s",
		if s.posted_id then tostring(s.posted_id) else "(no id returned)",
		s.grafana or "Grafana",
		remembered
	)
	s.note_tone = "success"
	forgetPending(s, effects)
	table.insert(effects, audit(s, "post", "ok", { id = s.posted_id, status = response.status }))
end

local function dismiss(s: State, effects: { Effect })
	if s.phase == "ask" or s.phase == "loading" then
		forgetPending(s, effects)
	end
	if s.phase ~= "posting" then
		table.insert(effects, { kind = "exit" })
	end
end

local function forgetRow(s: State, env: Env, i: number, effects: { Effect })
	local row = s.approvals[i]
	if row == nil then
		return
	end
	local raw = if env.kv_get then env.kv_get(Approval.KEY) else nil
	table.insert(effects, { kind = "kv_set", key = Approval.KEY, value = Approval.forget(raw, row.context) })
	table.insert(
		effects,
		{
			kind = "annotate_audit",
			action = "forget",
			outcome = "ok",
			context = row.context,
			choice = row.decision,
		} :: AuditEffect
	)
	table.remove(s.approvals, i)
	s.row = math.clamp(s.row, 1, math.max(1, #s.approvals))
	s.note, s.note_tone =
		string.format("Forgot the decision for %q: the next deploy there asks again.", row.context), "success"
end

local function manageKey(s: State, env: Env, key: any, effects: { Effect }): boolean
	local name, text = key.name, key.text
	local n = #s.approvals
	if name == "down" or text == "j" then
		s.row = math.min(math.max(1, n), s.row + 1)
	elseif name == "up" or text == "k" then
		s.row = math.max(1, s.row - 1)
	elseif text == "x" or name == "delete" then
		forgetRow(s, env, s.row, effects)
		return true
	elseif text == "r" then
		refreshApprovals(s, env)
		return true
	elseif name == "escape" then
		table.insert(effects, { kind = "exit" })
		return true
	else
		return false
	end
	if n > 0 then
		table.insert(effects, { kind = "reveal", id = "main.list.r" .. s.row })
	end
	return true
end

local function pick(s: State, step: number, effects: { Effect })
	local n = #M.CHOICES
	local cur = s.sel or (if step > 0 then 0 else n + 1)
	s.sel = math.clamp(cur + step, 1, n)
	table.insert(effects, { kind = "reveal", id = "main.choices.c" .. M.CHOICES[s.sel :: number] })
end

function M.key(s: State, key: any, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	if key.ctrl or key.meta or key.alt then
		return s, effects, false
	end
	local name: string = if type(key.name) == "string" then key.name else ""
	local text: string = if type(key.text) == "string" then key.text else ""
	if s.phase == "manage" then
		return s, effects, manageKey(s, env, key, effects)
	end
	if name == "escape" then
		dismiss(s, effects)
		return s, effects, true
	end
	if s.phase ~= "ask" then
		return s, effects, false
	end
	if name == "right" or name == "down" or name == "tab" then
		pick(s, 1, effects)
	elseif name == "left" or name == "up" or name == "backtab" then
		pick(s, -1, effects)
	elseif text == "y" and s.sel then
		M.choose(s, env, M.CHOICES[s.sel :: number], effects)
	else
		return s, effects, false
	end
	return s, effects, true
end

local function onAction(s: State, act: string, value: string?, env: Env, effects: { Effect })
	if act == "choose" and value and table.find(M.CHOICES, value :: any) then
		M.choose(s, env, value :: Approval.Choice, effects)
	elseif act == "dismiss" or act == "close" then
		dismiss(s, effects)
	elseif s.phase == "manage" and act == "forget" then
		local i = tonumber(value or "")
		if i then
			forgetRow(s, env, i, effects)
		end
	elseif s.phase == "manage" and act == "reload" then
		refreshApprovals(s, env)
	end
end

function M.update(s: State, msg: any, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "annotate_pending" then
		if s.phase ~= "loading" then
			return s, effects
		end
		local d = msg.draft
		if type(d) ~= "table" then
			s.phase = "missing"
			s.note = "This deploy annotation is no longer pending (already decided, dismissed, or Tern restarted)."
				.. " Nothing was posted from here."
			s.note_tone = "muted"
			return s, effects
		end
		s.draft = d
		local route = if env.config then Route.route(env.config, d.context, "annotations") else nil
		s.grafana = if route then route.endpoint.url else nil
		s.phase = "ask"
	elseif msg.kind == "http_done" then
		if s.write_tag and msg.tag == s.write_tag and s.phase == "posting" then
			written(s, msg.response, env, effects)
		end
	elseif msg.kind == "key" then
		local _, list = M.key(s, msg.key, env)
		return s, list
	elseif msg.kind == "event" then
		local ev: any = msg.ev
		if ev.ev == "action" and type(ev.act) == "string" then
			onAction(s, ev.act, ev.value, env, effects)
		end
	end
	return s, effects
end

function M.title(s: State): string?
	if s.phase == "manage" then
		return "Deploy annotations"
	end
	return if s.draft then "Annotate deploy: " .. (s.draft :: Draft).context else "Annotate deploy"
end

return M
