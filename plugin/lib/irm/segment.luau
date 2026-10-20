--!strict
-- The IRM status-line segment from the kv summary: "IRM: you are on call
-- until 22:00, 2 alert groups, 1 incident" per polled context (named when
-- several are polled), toned error while an alert group is firing (not
-- acknowledged), warning while only acknowledged groups or incidents are
-- open, info while the user (`irm.user`) is on call and nothing is open.
-- Silenced groups are left out: someone chose to quiet them. Nothing shows
-- while all is quiet or IRM is unavailable; "IRM ?" when every poll failed
-- or the poller stopped.
-- Pure and cheap: it runs inside the 4 ms chrome formatter budget.

local Common = require("./common")
local Summary = require("./summary")

export type Segment = { text: string, icon: string?, tone: string?, command: string? }

local M = {}

M.COMMAND = "plugin.tern-grafana.oncall"
M.ICON = "flame"
M.STALE_POLLS = 3
M.MIN_STALE_MS = 5 * 60 * 1000

local function plural(n: number, one: string, many: string): string
	return string.format("%d %s", n, if n == 1 then one else many)
end

function M.stale(payload: Summary.Payload, now_ms: number): boolean
	local limit = math.max(M.STALE_POLLS * payload.poll_s * 1000, M.MIN_STALE_MS)
	return now_ms - payload.updated_ms > limit
end

-- nil when there is nothing to show. Times are shown at `offset_min`
-- minutes east of UTC (the viewer's zone).
function M.segments(raw: any, now_ms: number, offset_min: number?): { Segment }?
	local payload = Summary.read(raw)
	if payload == nil then
		return nil
	end
	local stale = M.stale(payload, now_ms)
	local names: { string } = {}
	for name in payload.contexts do
		table.insert(names, name)
	end
	table.sort(names)
	local out: { Segment } = {}
	local failed = 0
	for _, name in names do
		local c = payload.contexts[name]
		local groups = (c.firing or 0) + (c.acknowledged or 0)
		local incidents = c.incidents or 0
		local parts: { string } = {}
		local you = c.you
		local onCall = you ~= nil and you.now
		if you and you.now then
			table.insert(
				parts,
				"you are on call"
					.. (
						if you.until_ms
							then " until " .. Common.clockAt(you.until_ms :: number, now_ms, offset_min or 0)
							else ""
					)
			)
		end
		if groups > 0 then
			table.insert(parts, plural(groups, "alert group", "alert groups"))
		end
		if incidents > 0 then
			table.insert(parts, plural(incidents, "incident", "incidents") .. (if c.incidents_more then "+" else ""))
		end
		if #parts > 0 then
			local head = if #names > 1 then "IRM " .. name .. ": " else "IRM: "
			local text = head .. table.concat(parts, ", ")
			if c.error or stale then
				text ..= " ?"
			end
			local tone = if stale
				then "muted"
				elseif (c.firing or 0) > 0 then "error"
				elseif groups > 0 or incidents > 0 then "warning"
				elseif onCall then "info"
				else "warning"
			table.insert(out, { text = text, icon = M.ICON, tone = tone, command = M.COMMAND })
		elseif c.error then
			failed += 1
		end
	end
	if #out == 0 then
		if failed > 0 or (stale and #names > 0) then
			return { { text = "IRM ?", icon = M.ICON, tone = "muted", command = M.COMMAND } }
		end
		return nil
	end
	return out
end

return M
