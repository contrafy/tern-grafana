--!strict
-- Registers the IRM blocks: `tern-grafana.oncall` (OnCall schedules and
-- alert groups) and `tern-grafana.incidents`. Every decision, including when
-- a write is sent, lives in lib/irm/*_state.luau; this file only answers the
-- machines' one host effect: the audit line of each write decision.

local BlockRunner = require("./block_runner")
local IncidentsRender = require("./lib/irm/incidents_render")
local IncidentsState = require("./lib/irm/incidents_state")
local OnCallRender = require("./lib/irm/oncall_render")
local OnCallState = require("./lib/irm/oncall_state")

local M = {}

-- Whitelisted fields only: never titles, notes, labels or credentials.
local function onAudit(e: any, _send: (msg: any) -> ())
	local parts = {
		"block=" .. tostring(e.block),
		"action=" .. tostring(e.action),
		"outcome=" .. tostring(e.outcome),
		"context=" .. tostring(e.context),
		"target=" .. tostring(e.target),
	}
	if e.duration_s then
		table.insert(parts, "duration_s=" .. tostring(e.duration_s))
	end
	if e.status then
		table.insert(parts, "status=" .. tostring(e.status))
	end
	pcall(tern.log.info, "tern-grafana irm", table.concat(parts, " "))
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
