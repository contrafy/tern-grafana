--!strict
-- Registers the IRM blocks: `tern-grafana.oncall` (OnCall schedules and
-- alert groups) and `tern-grafana.incidents`. Every decision, including when
-- a write is sent, lives in lib/irm/*_state.luau; this file only answers the
-- machines' one host effect: the audit line of each write decision.

local Audit = require("./lib/audit")
local BlockRunner = require("./block_runner")
local IncidentsRender = require("./lib/irm/incidents_render")
local IncidentsState = require("./lib/irm/incidents_state")
local OnCallRender = require("./lib/irm/oncall_render")
local OnCallState = require("./lib/irm/oncall_state")

local M = {}

-- Whitelisted fields only: never titles, notes, labels or credentials.
local AUDIT_ALWAYS = { "block", "action", "outcome", "context", "target" }
local AUDIT_OPTIONAL = { "duration_s", "status" }

local function onAudit(e: any, _send: (msg: any) -> ())
	pcall(tern.log.info, "tern-grafana irm", Audit.line(e, AUDIT_ALWAYS, AUDIT_OPTIONAL))
end

function M.register()
	BlockRunner.define(
		"oncall",
		{
			init = OnCallState.init,
			update = OnCallState.update,
			view = OnCallRender.view,
			title = OnCallState.title,
			save = OnCallState.save,
			key = OnCallState.key,
		} :: any,
		{ irm_audit = onAudit }
	)
	BlockRunner.define(
		"incidents",
		{
			init = IncidentsState.init,
			update = IncidentsState.update,
			view = IncidentsRender.view,
			title = IncidentsState.title,
			save = IncidentsState.save,
			key = IncidentsState.key,
		} :: any,
		{ irm_audit = onAudit }
	)
end

return M
