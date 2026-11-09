--!strict
-- The annotations host adapter's in-memory decisions: pending drafts for the
-- approve block (TTL, cap, ids), the problems already toasted this session,
-- and what an "always" post's outcome logs and toasts. The clock and the id
-- randomness are passed in; annotations_host only executes the result.
--
-- Pending drafts never leave host memory (no kv, no block args): the approve
-- link carries only a nonce.

local Api = require("./api")
local Audit = require("../audit")

type Draft = Api.Draft

local M = {}

M.PENDING_TTL_MS = 60 * 60 * 1000
M.MAX_PENDING = 16

export type Session = {
	pending: { [string]: { draft: Draft, created_ms: number } },
	-- Problems already toasted this session (one toast per cause).
	told: { [string]: boolean },
}

export type Toast = { level: "info" | "error", text: string, sub: string? }

function M.new(): Session
	return { pending = {}, told = {} }
end

-- Drops expired drafts, then the oldest one when the cap is reached.
local function prune(s: Session, now: number)
	local oldestId: string? = nil
	local oldest = math.huge
	local n = 0
	for id, p in s.pending do
		if now - p.created_ms > M.PENDING_TTL_MS then
			s.pending[id] = nil
		else
			n += 1
			if p.created_ms < oldest then
				oldestId, oldest = id, p.created_ms
			end
		end
	end
	if n >= M.MAX_PENDING and oldestId then
		s.pending[oldestId :: string] = nil
	end
end

-- Keeps `draft` and returns its fresh id; `random()` returns 0..0xffffff.
function M.store(s: Session, draft: Draft, now: number, random: () -> number): string
	prune(s, now)
	local id: string
	repeat
		id = string.format("%x%06x", math.floor(now), random())
	until s.pending[id] == nil
	s.pending[id] = { draft = draft, created_ms = now }
	return id
end

-- The pending draft for `id`, nil when unknown or expired (and then dropped).
function M.load(s: Session, id: string, now: number): Draft?
	local p = s.pending[id]
	if p and now - p.created_ms > M.PENDING_TTL_MS then
		s.pending[id] = nil
		return nil
	end
	return if p then p.draft else nil
end

function M.forget(s: Session, id: string)
	s.pending[id] = nil
end

-- The problems not toasted yet this session, marked as told.
function M.fresh(s: Session, problems: { string }): { string }
	local out: { string } = {}
	for _, problem in problems do
		if not s.told[problem] then
			s.told[problem] = true
			table.insert(out, problem)
		end
	end
	return out
end

local AUDIT_ALWAYS = { "action", "outcome", "context" }
local AUDIT_OPTIONAL = { "choice", "id", "status" }

-- The audit line (whitelisted fields only: never the annotation text or the
-- command line). `id` and `status` are written as given, tostring'd.
function M.auditLine(e: { [string]: any }): string
	return Audit.line(e, AUDIT_ALWAYS, AUDIT_OPTIONAL)
end

-- The audit line logged when an "always" post is sent.
function M.sentLine(draft: Draft): string
	return M.auditLine({ action = "post", outcome = "sent", context = draft.context, choice = "always" })
end

-- What an "always" post's answer logs and toasts: `failure` is the classified
-- query error (nil on success), `id` the created annotation id.
function M.outcome(draft: Draft, status: number, failure: { message: string? }?, id: any): (string, Toast)
	if failure then
		return M.auditLine({
			action = "post",
			outcome = "failed",
			context = draft.context,
			choice = "always",
			status = tostring(status),
		}),
			{ level = "error", text = "Deploy annotation failed (" .. draft.context .. ")", sub = failure.message }
	end
	return M.auditLine({
		action = "post",
		outcome = "ok",
		context = draft.context,
		choice = "always",
		id = tostring(id),
		status = tostring(status),
	}),
		{ level = "info", text = "Deploy annotated in Grafana (" .. draft.context .. ")", sub = draft.kind }
end

return M
