--!strict
-- How an investigation travels between the halves (G4). kv is the only
-- shared channel and links carry no payload, so each step stores a record
-- under `tern-grafana.investigate.<nonce>` and opens
-- `tern-grafana://investigate?id=<nonce>`:
--
--   1. The source block (alerts detail, query, dashboard panel) stores a
--      draft (the Subject) and opens the link; the window answers with the
--      preview block, whose init takes the draft and deletes it.
--   2. "Send" in the preview stores the final prompt under a new nonce and
--      opens the link; the window deletes the record and starts the agent.
--
-- Records are small and non-secret (kv is a 0644 file). A record older than
-- its TTL is stale and refused, so a link clicked again later (or one
-- printed in a terminal) never starts an agent.

local Effect = require("../effect")
local Env = require("../env")
local Scheme = require("../links/scheme")
local Subject = require("./subject")

type Effect = Effect.Effect
type Env = Env.Env
type Subject = Subject.Subject

export type Draft = { v: number, stage: "draft", created_ms: number, subject: Subject }
export type Send = { v: number, stage: "send", created_ms: number, prompt: string, title: string }

export type Decision =
	{ kind: "preview", link: string }
	| { kind: "send", prompt: string, title: string }
	| { kind: "refused", message: string, delete: boolean }

local M = {}

M.PREFIX = "tern-grafana.investigate."
M.VERSION = 1
M.BLOCK = "tern-grafana.investigate"
-- The preview opens right after the draft is stored; minutes leave room for
-- a slow window, not for reuse.
M.DRAFT_TTL_MS = 10 * 60 * 1000
M.SEND_TTL_MS = 2 * 60 * 1000
M.MAX_PROMPT = 16000

function M.key(nonce: string): string
	return M.PREFIX .. nonce
end

-- FNV-1a 32-bit; the prime 16777619 = 2^24 + 403 keeps products exact.
local function fnv32(s: string): number
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = (h * 403 + bit32.lshift(h, 24)) % 4294967296
	end
	return h
end

-- A fresh handoff key: the time and a hash of `seed` mixed with `rand`
-- (math.random by default), lower-case hex.
function M.nonce(now_ms: number, seed: string, rand: number?): string
	local r = rand or math.random(0, 0x7fffffff)
	return string.format("%x-%08x", math.floor(math.max(0, now_ms)), bit32.bxor(fnv32(seed), r))
end

function M.link(nonce: string): string
	return Scheme.encode({ action = "investigate", params = { id = nonce }, vars = {} })
end

-- The effects that start an investigation from a source block: store the
-- draft, open the preview through the window.
function M.start(subject: Subject, env: Env, rand: number?): { Effect }
	local nonce = M.nonce(env.now_ms, subject.kind .. subject.title, rand)
	local draft: Draft = { v = M.VERSION, stage = "draft", created_ms = env.now_ms, subject = subject }
	return {
		{ kind = "kv_set", key = M.key(nonce), value = draft },
		{ kind = "open", target = M.link(nonce) },
	}
end

-- The effects of "Send": store the prompt, open the link the window acts on.
function M.send(prompt: string, title: string, env: Env, rand: number?): { Effect }
	local nonce = M.nonce(env.now_ms, prompt, rand)
	local record: Send = { v = M.VERSION, stage = "send", created_ms = env.now_ms, prompt = prompt, title = title }
	return {
		{ kind = "kv_set", key = M.key(nonce), value = record },
		{ kind = "open", target = M.link(nonce) },
	}
end

local function stale(raw: any, ttl: number, now_ms: number): boolean
	local age = now_ms - raw.created_ms
	-- A record from the future (clock jump, another machine) is as
	-- suspicious as an old one.
	return age > ttl or age < -ttl
end

-- What the window does with link id `nonce`, given the kv value under its
-- key. `delete` says whether the record must be removed (anything the
-- window refuses is useless afterwards).
function M.decide(nonce: string, raw: any, now_ms: number): Decision
	if raw == nil then
		return {
			kind = "refused",
			message = "This investigation link was already used or has expired.",
			delete = false,
		}
	end
	if type(raw) ~= "table" or raw.v ~= M.VERSION or type(raw.created_ms) ~= "number" then
		return { kind = "refused", message = "This investigation record is not readable.", delete = true }
	end
	if raw.stage == "draft" then
		if stale(raw, M.DRAFT_TTL_MS, now_ms) then
			return { kind = "refused", message = "This investigation draft has expired.", delete = true }
		end
		return { kind = "preview", link = M.link(nonce) }
	elseif raw.stage == "send" then
		if stale(raw, M.SEND_TTL_MS, now_ms) then
			return { kind = "refused", message = "This investigation request has expired.", delete = true }
		end
		local prompt, title = raw.prompt, raw.title
		if type(prompt) ~= "string" or prompt == "" or #prompt > M.MAX_PROMPT or type(title) ~= "string" then
			return { kind = "refused", message = "This investigation request is not readable.", delete = true }
		end
		return { kind = "send", prompt = prompt, title = title }
	end
	return { kind = "refused", message = "This investigation record is not readable.", delete = true }
end

-- The preview block's draft: (subject, nil) or (nil, why not).
function M.takeDraft(raw: any, now_ms: number): (Subject?, string?)
	if raw == nil then
		return nil, "This investigation draft was already opened or has expired."
	end
	if type(raw) ~= "table" or raw.v ~= M.VERSION or raw.stage ~= "draft" or type(raw.created_ms) ~= "number" then
		return nil, "This investigation draft is not readable."
	end
	if stale(raw, M.DRAFT_TTL_MS, now_ms) then
		return nil, "This investigation draft has expired."
	end
	local subject = Subject.read(raw.subject)
	if subject == nil then
		return nil, "This investigation draft is not readable."
	end
	return subject, nil
end

return M
