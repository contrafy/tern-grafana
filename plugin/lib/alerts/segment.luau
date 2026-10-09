--!strict
-- Status-line segments from the kv summary: one per context with firing
-- alerts, toned by its worst severity, or one quiet segment when nothing
-- fires. Pure and cheap: it runs inside the 4 ms chrome formatter budget.

local Summary = require("./summary")

type Payload = Summary.Payload

export type Segment = { text: string, icon: string?, tone: string?, command: string? }

local M = {}

M.COMMAND = "plugin.tern-grafana.alerts"
M.ICON = "flame"

-- A summary older than this many poll intervals means the poller stopped.
M.STALE_POLLS = 3
M.MIN_STALE_MS = 5 * 60 * 1000

local function sortedNames(contexts: { [string]: any }): { string }
	local names: { string } = {}
	for name in contexts do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function M.stale(payload: Payload, now_ms: number): boolean
	local limit = math.max(M.STALE_POLLS * (payload.poll_s or 60) * 1000, M.MIN_STALE_MS)
	return now_ms - payload.updated_ms > limit
end

-- nil when there is no summary (polling is off or has not run yet).
function M.segments(raw: any, now_ms: number): { Segment }?
	local payload = Summary.readPayload(raw)
	if payload == nil then
		return nil
	end
	local stale = M.stale(payload, now_ms)
	local out: { Segment } = {}
	local failed: { string } = {}
	local names = sortedNames(payload.contexts)
	local multi = #names > 1
	for _, name in names do
		local s = payload.contexts[name]
		if s.firing > 0 then
			local text = if multi then string.format("%s %d", name, s.firing) else string.format("%d firing", s.firing)
			if s.error or stale then
				text ..= " ?"
			end
			table.insert(out, {
				text = text,
				icon = M.ICON,
				tone = if stale then "muted" else Summary.tone(s.worst),
				command = M.COMMAND,
			})
		elseif s.error then
			table.insert(failed, name)
		end
	end
	if #out == 0 then
		local text = if #failed > 0 then "alerts ?" elseif stale then "alerts ?" else "alerts 0"
		table.insert(out, { text = text, icon = M.ICON, tone = "muted", command = M.COMMAND })
	end
	return out
end

-- Changes exactly when the rendered segments change; the window refreshes
-- the chrome only then.
function M.signature(segments: { Segment }?): string
	if segments == nil then
		return ""
	end
	local parts: { string } = {}
	for _, s in segments do
		table.insert(parts, s.text .. "\1" .. (s.tone or ""))
	end
	return table.concat(parts, "\2")
end

return M
