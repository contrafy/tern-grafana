--!strict
-- Deploy annotations (G1) and the impact watch trigger (G2): the
-- `command_started` / `command_finished` hooks and the approve block
-- (`tern-grafana.annotate`). Decisions live in lib/annotations (trigger,
-- approval, state, session: pending drafts, toasts, audit lines); this file
-- pairs the hook events, gathers the facts only the host can (login user, git
-- short SHA of the cwd), and posts for contexts approved "always".
--
-- Pending drafts never leave host memory (no kv, no block args): the approve
-- link carries only a nonce, so a restarted Tern shows the request as gone
-- instead of posting a stale one, and a crafted link cannot supply the text.

local Api = require("./lib/annotations/api")
local Approval = require("./lib/annotations/approval")
local AnnotationSettings = require("./lib/annotations/settings")
local BlockRunner = require("./block_runner")
local Classify = require("./lib/transport/classify")
local ConfigHost = require("./config_host")
local EnvHost = require("./env_host")
local ImpactSettings = require("./lib/impact/settings")
local Pairing = require("./lib/annotations/pairing")
local Render = require("./lib/annotations/render")
local Route = require("./lib/config/route")
local Scheme = require("./lib/links/scheme")
local Session = require("./lib/annotations/session")
local State = require("./lib/annotations/state")
local TransportHost = require("./transport_host")
local Trigger = require("./lib/annotations/trigger")

type Draft = Api.Draft

local M = {}

M.GIT_TIMEOUT_MS = 2000

local tracker = Pairing.new()
local session = Session.new()
local registered = false
-- The config whose section problems were last logged.
local warnedFor: any = nil

local function audit(line: string)
	pcall(tern.log.info, "tern-grafana annotate", line)
end

local function warn(what: string, err: any)
	pcall(tern.log.warn, "tern-grafana annotations " .. what .. " failed", tostring(err))
end

local function kvGet(key: string): any
	local ok, v = pcall(tern.kv.get, key)
	return if ok then v else nil
end

local function toast(cx: EffectCx, level: ToastLevel, text: string, sub: string?)
	pcall(function()
		cx:toast(level, text, sub)
	end)
end

local function open(cx: EffectCx, target: string)
	local ok, err = pcall(function()
		cx:open(target)
	end)
	if not ok then
		warn("open", err)
	end
end

-- Login user and the cwd's git short SHA (no shell; failures just omit it).
local function gather(cwd: string?, done: (Api.Facts) -> ())
	local okUser, user = pcall(tern.getenv, "USER")
	local facts: Api.Facts = { user = if okUser and user ~= "" then user else nil, sha = nil }
	if cwd == nil then
		done(facts)
		return
	end
	local called = false
	local function finish()
		if not called then
			called = true
			done(facts)
		end
	end
	local ok, err = pcall(function()
		tern.process.run(Api.gitArgv(cwd :: string), { timeout_ms = M.GIT_TIMEOUT_MS }, function(res: ProcessResult)
			facts.sha = Api.parseSha(res.status, res.stdout)
			finish()
		end)
	end)
	if not ok then
		warn("git", err)
		finish()
	end
end

-- A context approved "always": post now (the command finishing is the
-- user event), toast the outcome, never retry.
local function postNow(draft: Draft, cx: EffectCx)
	local env = EnvHost.make(nil)
	local route, err = nil, nil
	if env.config then
		route, err = Route.route(env.config :: any, draft.context, "annotations")
	end
	if route == nil then
		toast(cx, "error", "Deploy annotation not posted", if err then err.message else "no valid config")
		return
	end
	audit(Session.sentLine(draft))
	local request = Api.request(draft, env.encode)
	local ok, raised = pcall(function()
		TransportHost.execute(route :: Route.Route, request, function(response)
			local qe = Classify.classify(response, tern.json.decode)
			local id = if qe then nil else Api.parseCreated(EnvHost.make(nil), response.body)
			local line, t = Session.outcome(draft, response.status, qe, id)
			audit(line)
			toast(cx, t.level, t.text, t.sub)
		end)
	end)
	if not ok then
		toast(cx, "error", "Deploy annotation failed (" .. draft.context .. ")", tostring(raised))
	end
end

local function onStarted(ev: CommandStartedEvent, _cx: EffectCx)
	if type(ev) ~= "table" or type(ev.pane) ~= "number" or type(ev.line) ~= "string" then
		return
	end
	Pairing.started(tracker, ev.pane, ev.line, ev.cwd, EnvHost.nowMs())
end

local function onFinished(ev: CommandFinishedEvent, cx: EffectCx)
	if type(ev) ~= "table" or type(ev.pane) ~= "number" or type(ev.line) ~= "string" then
		return
	end
	local run = Pairing.finished(tracker, ev.pane, ev.line, tonumber(ev.status) or -1, ev.took_ms, EnvHost.nowMs())
	pcall(ConfigHost.load)
	local current = ConfigHost.current()
	if current ~= warnedFor then
		warnedFor = current
		local _, annProblems = AnnotationSettings.read(current)
		local _, impProblems = ImpactSettings.read(current)
		for _, list in { annProblems, impProblems } do
			for _, p in list do
				pcall(tern.log.warn, "tern-grafana config: " .. p.path .. ": " .. p.message)
			end
		end
	end
	local env = EnvHost.make(nil)
	local plan = Trigger.plan(env.config, run, kvGet(Approval.KEY))
	if plan == nil then
		return
	end
	for _, problem in Session.fresh(session, plan.problems) do
		toast(cx, "info", "Tern Grafana", problem)
	end
	if plan.impact then
		open(cx, plan.impact :: string)
	end
	local ann = plan.annotate
	if ann == nil then
		return
	end
	gather(run.cwd, function(facts)
		local okDraft, draft = pcall(Api.draft, run, plan.match, ann.settings, ann.context, facts)
		if not okDraft then
			warn("draft", draft)
			return
		end
		if ann.decision == "post" then
			postNow(draft, cx)
		else
			local id = Session.store(session, draft, EnvHost.nowMs(), function()
				return math.random(0, 0xffffff)
			end)
			open(cx, Scheme.encode({ action = "annotate", params = { id = id, context = ann.context }, vars = {} }))
		end
	end)
end

local function onLoad(e: State.LoadEffect, send: (msg: any) -> ())
	send({ kind = "annotate_pending", draft = Session.load(session, e.id, EnvHost.nowMs()) })
end

local function onForget(e: State.ForgetEffect, _send: (msg: any) -> ())
	Session.forget(session, e.id)
end

local function onAudit(e: State.AuditEffect, _send: (msg: any) -> ())
	audit(Session.auditLine(e :: any))
end

function M.register()
	if registered then
		return
	end
	registered = true
	BlockRunner.define(
		"annotate",
		{
			init = State.init,
			update = State.update,
			view = Render.view,
			title = State.title,
			key = State.key,
		} :: any,
		{
			annotate_load = onLoad :: any,
			annotate_forget = onForget :: any,
			annotate_audit = onAudit :: any,
		}
	)
	tern.on("command_started", function(ev: CommandStartedEvent, cx: EffectCx)
		local ok, err = pcall(function()
			onStarted(ev, cx)
		end)
		if not ok then
			warn("command_started", err)
		end
	end)
	tern.on("command_finished", function(ev: CommandFinishedEvent, cx: EffectCx)
		local ok, err = pcall(function()
			onFinished(ev, cx)
		end)
		if not ok then
			warn("command_finished", err)
		end
	end)
end

return M
