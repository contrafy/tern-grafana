--!strict
-- Carly's request context (G3): one line on what fires, from the alert
-- summary the host poller writes to kv (lib/alerts/summary). It runs inside
-- a 4 ms provider budget and Tern keeps at most 400 characters per plugin,
-- so it reads only that small payload and cuts itself to MAX_CHARS.

local Normalize = require("../alerts/normalize")
local Summary = require("../alerts/summary")

local M = {}

M.MAX_CHARS = 400
-- A summary older than this many poll intervals is reported as stale.
M.STALE_POLLS = 5

local function age(ms: number): string
	local sec = math.max(0, math.floor(ms / 1000))
	if sec < 60 then
		return sec .. "s"
	elseif sec < 3600 then
		return (sec // 60) .. "m"
	elseif sec < 86400 then
		return (sec // 3600) .. "h"
	end
	return (sec // 86400) .. "d"
end

local ORDER: { Normalize.Severity } = { "critical", "error", "warning", "info", "none" }

local function contextLine(name: string, s: Summary.Summary): string
	if s.error and s.firing == 0 then
		return string.format("%s: unknown (poll failed: %s)", name, s.error :: string)
	end
	if s.firing == 0 then
		local tail = if s.pending > 0 then string.format(", %d pending", s.pending) else ""
		return string.format("%s: 0 firing%s", name, tail)
	end
	local parts: { string } = {}
	for _, sev in ORDER do
		local n = s.by_severity[sev]
		if n and n > 0 then
			table.insert(parts, string.format("%d %s", n, if sev == "none" then "no severity" else sev))
		end
	end
	local text = string.format("%s: %d firing (%s)", name, s.firing, table.concat(parts, ", "))
	if s.pending > 0 then
		text ..= string.format(", %d pending", s.pending)
	end
	if s.error then
		text ..= string.format(" [last poll failed: %s]", s.error :: string)
	end
	return text
end

-- The context line for kv value `raw`, or nil when nothing was polled yet.
function M.text(raw: any, now_ms: number): string?
	local payload = Summary.readPayload(raw)
	if payload == nil then
		return nil
	end
	local p = payload :: Summary.Payload
	local names: { string } = {}
	for name, s in p.contexts do
		if type(name) == "string" and type(s) == "table" then
			table.insert(names, name)
		end
	end
	if #names == 0 then
		return nil
	end
	-- Contexts with firing alerts first, most firing first.
	table.sort(names, function(a: string, b: string): boolean
		local fa, fb = p.contexts[a].firing or 0, p.contexts[b].firing or 0
		if fa ~= fb then
			return fa > fb
		end
		return a < b
	end)
	local head = string.format("Tern Grafana alerts (as of %s ago", age(now_ms - p.updated_ms))
	if p.poll_s > 0 and now_ms - p.updated_ms > p.poll_s * 1000 * M.STALE_POLLS then
		head ..= ", stale"
	end
	head ..= "): "
	local tail = '. Details: plugins["tern-grafana"].alerts(context)'
	local text = head
	for i, name in names do
		local line = contextLine(name, p.contexts[name])
		local sep = if i == 1 then "" else "; "
		local rest = #names - i
		local more = if rest > 0 then string.format("; +%d more", rest) else ""
		-- Keep room for the tail and a "+N more" marker after this line.
		if #text + #sep + #line + #more + #tail > M.MAX_CHARS then
			text ..= string.format("%s+%d more", sep, #names - i + 1)
			break
		end
		text ..= sep .. line
	end
	text ..= tail
	if #text > M.MAX_CHARS then
		text = string.sub(text, 1, M.MAX_CHARS - 3) .. "..."
	end
	return text
end

return M
