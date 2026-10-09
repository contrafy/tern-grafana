--!strict
-- Registers the Silences block (`tern-grafana.silence`). Every decision,
-- including when a write is sent, lives in lib/silences/state.luau; this file
-- only answers the machine's two host effects: the login user (the default
-- "created by") and the audit line of each write decision.

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
local function onAudit(e: State.AuditEffect, _send: (msg: any) -> ())
	local parts = {
		"action=" .. e.action,
		"outcome=" .. e.outcome,
		"context=" .. e.context,
		"target=" .. e.target,
	}
	if e.matchers then
		table.insert(parts, "matchers=" .. tostring(e.matchers))
	end
	if e.duration_s then
		table.insert(parts, "duration_s=" .. tostring(e.duration_s))
	end
	if e.id then
		table.insert(parts, "id=" .. e.id)
	end
	if e.status then
		table.insert(parts, "status=" .. tostring(e.status))
	end
	pcall(tern.log.info, "tern-grafana silence", table.concat(parts, " "))
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
