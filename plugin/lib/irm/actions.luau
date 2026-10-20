--!strict
-- Alert-group actions: which apply in which state, what each changes, the
-- silence durations offered, and what a confirmation must warn about.

local Irm = require("../source/irm")

type GroupState = Irm.GroupState
type GroupAction = Irm.GroupAction

export type Spec = {
	action: GroupAction,
	label: string,
	key: string,
	-- The state the group is in once IRM accepted the action.
	after: GroupState,
	from: { GroupState },
	-- What else happens, said in the confirmation.
	warning: string?,
}

local M = {}

local ORDER: { GroupAction } = { "acknowledge", "unacknowledge", "resolve", "unresolve", "silence" }
M.ORDER = ORDER

local SPECS: { [GroupAction]: Spec } = {
	acknowledge = {
		action = "acknowledge",
		label = "Acknowledge",
		key = "a",
		after = "acknowledged",
		from = { "firing" },
		warning = "Escalation stops for this alert group.",
	},
	unacknowledge = {
		action = "unacknowledge",
		label = "Unacknowledge",
		key = "A",
		after = "firing",
		from = { "acknowledged" },
		warning = "Escalation restarts from its first step: people may be paged.",
	},
	resolve = {
		action = "resolve",
		label = "Resolve",
		key = "x",
		after = "resolved",
		from = { "firing", "acknowledged", "silenced" },
		warning = "New alerts for the same grouping start a new alert group.",
	},
	unresolve = {
		action = "unresolve",
		label = "Unresolve",
		key = "X",
		after = "firing",
		from = { "resolved" },
		warning = "The group fires again and escalation restarts: people may be paged.",
	},
	silence = {
		action = "silence",
		label = "Silence",
		key = "s",
		after = "silenced",
		from = { "firing", "acknowledged" },
		warning = "Escalation pauses until the silence ends, then resumes.",
	},
}
M.SPECS = SPECS

export type Preset = { label: string, s: number }

local SILENCE_PRESETS: { Preset } = {
	{ label = "30m", s = 1800 },
	{ label = "1h", s = 3600 },
	{ label = "2h", s = 7200 },
	{ label = "6h", s = 21600 },
	{ label = "12h", s = 43200 },
	{ label = "24h", s = 86400 },
}
M.SILENCE_PRESETS = SILENCE_PRESETS

M.DEFAULT_PRESET = 2

function M.allowed(action: GroupAction, state: GroupState): boolean
	return table.find(M.SPECS[action].from, state) ~= nil
end

-- The actions that apply to a group in `state`, in display order.
function M.available(state: GroupState): { Spec }
	local out: { Spec } = {}
	for _, a in M.ORDER do
		if M.allowed(a, state) then
			table.insert(out, M.SPECS[a])
		end
	end
	return out
end

-- The action bound to a key, if any.
function M.byKey(text: string): GroupAction?
	for _, a in M.ORDER do
		if M.SPECS[a].key == text then
			return a
		end
	end
	return nil
end

return M
