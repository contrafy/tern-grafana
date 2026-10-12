--!strict
-- The Investigate preview block (`tern-grafana.investigate`, G4): shows the
-- exact prompt an agent would get and sends it only when the user says so.
--
-- - Args are the `tern-grafana://investigate` link and the window's ticket
--   (lib/investigate/handoff.luau). The link holds the subject, or only a
--   prompt when the window wants it read again before it sends. save()
--   keeps the subject (no secrets, no raw samples) or that prompt, so a
--   restored block shows the same prompt.
-- - An alert subject carries its query but no samples: the block fetches the
--   recent values itself (read-only, also after a restore) and rebuilds the
--   prompt.
-- - Nothing is sent from init or a timer. Send opens a prompt link with the
--   ticket; the window starts the agent (plugin/investigate_window.luau).

local Effect = require("../effect")
local Env = require("../env")
local Handoff = require("./handoff")
local Metrics = require("../source/metrics")
local Prompt = require("./prompt")
local Route = require("../config/route")
local Settings = require("./settings")
local Step = require("../time/step")
local Subject = require("./subject")
local Compact = require("../carly/compact")

type Effect = Effect.Effect
type Msg = Effect.Msg
type Env = Env.Env
type Subject = Subject.Subject

export type Status = "ready" | "loading" | "expired"

export type State = {
	-- The window's ticket for this preview (args[2]); nil when restored
	-- without one, in which case the window previews the prompt again.
	ticket: string?,
	subject: Subject?,
	prompt: string,
	-- The title of a prompt-only preview (no subject).
	title: string?,
	status: Status,
	-- Why the block has nothing to show, or why values are missing.
	note: string?,
	gen: number,
	-- Epoch ms of the last send; enter sends only once, the button again.
	sent_ms: number?,
}

local M = {}

M.FETCH_TAG = "values:"
M.POINTS = 120

local function rebuild(s: State, env: Env)
	if s.subject then
		s.prompt = Prompt.build(s.subject :: Subject, env.now_ms)
	end
end

-- Fetches the recent values of an alert subject's query.
local function fetch(s: State, env: Env, effects: { Effect })
	local subject = s.subject
	if subject == nil or not subject.fetch or #subject.queries == 0 then
		return
	end
	local cfg = env.config
	if cfg == nil then
		s.note = "Recent values unavailable: no valid config."
		return
	end
	local route, err = Route.route(cfg, subject.context, "metrics")
	if route == nil then
		s.note = "Recent values unavailable: " .. (if err then err.message else "no metrics endpoint")
		return
	end
	local settings = Settings.read(cfg)
	local to = env.now_ms
	local from = to - settings.range_ms
	local span = settings.range_ms
	local step = Step.promStep(span, M.POINTS)
	local interval = Step.interval(span, M.POINTS).interval_ms
	local expr = Step.interpolate(subject.queries[1].expr, Step.macros(span, step, interval))
	s.gen += 1
	s.status = "loading"
	s.note = nil
	subject.range = { from = "now-" .. settings.range, to = "now", from_ms = from, to_ms = to }
	rebuild(s, env)
	table.insert(effects, {
		kind = "http",
		tag = M.FETCH_TAG .. s.gen,
		route = route,
		request = Metrics.rangeRequest(route, {
			expr = expr,
			from_ms = from,
			to_ms = to,
			step_ms = step,
			max_points = M.POINTS,
		}),
	})
end

local function onValues(s: State, response: any, env: Env)
	local subject = s.subject
	local cfg = env.config
	s.status = "ready"
	if subject == nil or cfg == nil or subject.range == nil then
		return
	end
	local route = Route.route(cfg, subject.context, "metrics")
	if route == nil then
		return
	end
	local big = #response.body > Compact.MAX_BODY_BYTES
	local result: any = if big then nil else Metrics.parse(route, response, env, "range")
	if result == nil or not result.ok then
		s.note = "Recent values unavailable: "
			.. (if result then result.error.message else "the result is too large to summarize")
		subject.values = nil
	else
		local r = subject.range :: Subject.TimeWindow
		local series, omitted =
			Compact.series(result.frames, { max_series = Subject.MAX_SERIES, spark = Subject.SPARK })
		subject.values = { series = series, omitted = omitted, from_ms = r.from_ms, to_ms = r.to_ms }
		s.note = nil
	end
	rebuild(s, env)
end

local PROMPT_ONLY_NOTE = "This prompt came from a link, not from a preview Tern Grafana opened in this window. "
	.. "Read it before you send it."

local function ticketOf(args: { string }): string?
	local raw = args[2]
	return if type(raw) == "string" and #raw <= 40 and string.match(raw, "^[%x%-]+$") then raw else nil
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local s: State = { ticket = ticketOf(args or {}), prompt = "", status = "ready", gen = 0 }
	local effects: { Effect } = {}
	local savedSubject = if type(saved) == "table" then Subject.read(saved.subject) else nil
	local savedPrompt = if type(saved) == "table" then saved.prompt else nil
	if savedSubject or (type(savedPrompt) == "string" and savedPrompt ~= "" and #savedPrompt <= Handoff.MAX_PROMPT) then
		s.subject = savedSubject
		if savedSubject == nil then
			s.prompt = savedPrompt
			s.title = if type(saved.title) == "string" then saved.title else nil
		end
		s.sent_ms = if type(saved.sent_ms) == "number" then saved.sent_ms else nil
	else
		local opened = Handoff.open((args or {})[1], env.decode)
		s.subject = opened.subject
		if opened.prompt then
			s.prompt = opened.prompt :: string
			s.title = opened.title
			s.note = PROMPT_ONLY_NOTE
		end
		if opened.err then
			s.note = opened.err
		end
	end
	if s.subject == nil then
		if s.prompt == "" then
			s.status = "expired"
		end
		return s, effects
	end
	rebuild(s, env)
	fetch(s, env, effects)
	return s, effects
end

local function titleOf(s: State): string
	return if s.subject then (s.subject :: Subject).title else s.title or "Investigation"
end

local function send(s: State, env: Env, effects: { Effect })
	if s.prompt == "" then
		return
	end
	for _, e in Handoff.send(s.prompt, titleOf(s), s.ticket) do
		table.insert(effects, e)
	end
	s.sent_ms = env.now_ms
end

local function copy(s: State, effects: { Effect })
	if s.prompt == "" then
		return
	end
	table.insert(effects, { kind = "copy", text = s.prompt })
	table.insert(effects, { kind = "toast", level = "info", text = "Copied the investigation prompt" })
end

local function act(s: State, name: string, env: Env, effects: { Effect })
	if name == "send" then
		send(s, env, effects)
	elseif name == "copy" then
		copy(s, effects)
	elseif name == "refresh" then
		fetch(s, env, effects)
	elseif name == "close" then
		table.insert(effects, { kind = "exit" })
	end
end

function M.key(s: State, key: any, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	if key.ctrl or key.meta or key.alt then
		return s, effects, false
	end
	local name, text = key.name, key.text
	if name == "enter" or name == "return" then
		if s.sent_ms ~= nil or s.status == "expired" then
			return s, effects, false
		end
		send(s, env, effects)
	elseif text == "y" then
		copy(s, effects)
	elseif text == "r" then
		if s.subject == nil or not (s.subject :: Subject).fetch then
			return s, effects, false
		end
		fetch(s, env, effects)
	elseif text == "q" or name == "escape" then
		table.insert(effects, { kind = "exit" })
	else
		return s, effects, false
	end
	return s, effects, true
end

function M.update(s: State, msg: Msg, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		if msg.tag == M.FETCH_TAG .. s.gen then
			onValues(s, msg.response, env)
		end
	elseif msg.kind == "key" then
		local _, list = M.key(s, msg.key, env)
		return s, list
	elseif msg.kind == "event" then
		local ev: any = msg.ev
		if ev.ev == "action" and type(ev.act) == "string" then
			act(s, ev.act, env, effects)
		end
	end
	return s, effects
end

function M.title(s: State): string?
	if s.subject or s.prompt ~= "" then
		return "Investigate: " .. titleOf(s)
	end
	return "Investigate"
end

-- The subject only (names, labels, queries and series statistics), or the
-- prompt of a prompt-only preview. Never the ticket: it dies with the window.
function M.save(s: State): any
	if s.subject then
		return { subject = s.subject, sent_ms = s.sent_ms }
	elseif s.prompt ~= "" then
		return { prompt = s.prompt, title = s.title, sent_ms = s.sent_ms }
	end
	return nil
end

return M
