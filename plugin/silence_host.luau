--!strict
-- Registers the Silences block (`tern-grafana.silence`). Every decision,
-- including when a write is sent, lives in lib/silences/state.luau; this file
-- only answers the machine's two host effects: the login user (the default
-- "created by") and the audit line of each write decision.

local Audit = require("./lib/audit")
local BlockRunner = require("./block_runner")
local Render = require("./lib/silences/render")
local State = require("./lib/silences/state")

local M = {}

M.ID = "silence"

local function onUser(_effect: any, send: (msg: any) -> ())
	local ok, name = pcall(tern.getenv, "USER")
	send({ kind = "user", name = if ok then name else nil })
end

-- Whitelisted fields only: never the comment, matcher values or headers.
local AUDIT_ALWAYS = { "action", "outcome", "context", "target" }
local AUDIT_OPTIONAL = { "matchers", "duration_s", "id", "status" }

local function onAudit(e: State.AuditEffect, _send: (msg: any) -> ())
	pcall(tern.log.info, "tern-grafana silence", Audit.line(e :: any, AUDIT_ALWAYS, AUDIT_OPTIONAL))
end

function M.register()
	BlockRunner.define(
		"silence",
		{
			init = State.init,
			update = State.update,
			view = Render.view,
			title = State.title,
			save = State.save,
			key = State.key,
		} :: any,
		{
			silence_user = onUser,
			silence_audit = onAudit :: any,
		}
	)
end

return M
