--!strict
-- Toasts for watch transitions: a watch that starts firing, and one that
-- stops. Every window checks the poller's kv summary; what was announced
-- lives in kv `tern-grafana.watches.notified` (watch name -> status and since
-- time), so one transition is announced once across all windows (the first
-- window to see it records it). A transition older than the freshness window
-- (Tern was closed, the poller was stopped) is recorded without a toast.

local Poll = require("./poll")

export type Mark = { status: string, since_ms: number }
export type Notified = { v: number, watches: { [string]: Mark } }
export type Toast = { level: "error" | "info" | "success", text: string, sub: string? }

local M = {}

M.KEY = "tern-grafana.watches.notified"
M.VERSION = 1
-- A transition is fresh for this many of its watch's intervals (and at least
-- MIN_FRESH_MS) after it happened.
M.FRESH_INTERVALS = 3
M.MIN_FRESH_MS = 5 * 60 * 1000

function M.read(raw: any): Notified
	local out: Notified = { v = M.VERSION, watches = {} }
	if type(raw) ~= "table" or raw.v ~= M.VERSION or type(raw.watches) ~= "table" then
		return out
	end
	for name, m in raw.watches do
		if
			type(name) == "string"
			and type(m) == "table"
			and type(m.status) == "string"
			and type(m.since_ms) == "number"
		then
			out.watches[name] = { status = m.status, since_ms = m.since_ms }
		end
	end
	return out
end

local function formatValue(v: number?): string
	if v == nil then
		return "?"
	end
	if v == math.floor(v) and math.abs(v) < 1e15 then
		return string.format("%d", v)
	end
	return string.format("%.4g", v)
end

local function firingToast(e: Poll.Entry): Toast
	local where = if e.context then " (" .. e.context .. ")" else ""
	return {
		level = if e.severity == "critical" or e.severity == "error" then "error" else "info",
		text = string.format("Watch %s is firing%s", e.name, where),
		sub = string.format(
			"%s: %s %s %s; %d of %d series",
			e.severity,
			formatValue(e.value),
			e.op,
			formatValue(e.threshold),
			e.matching,
			e.series
		),
	}
end

local function resolvedToast(e: Poll.Entry): Toast
	local where = if e.context then " (" .. e.context .. ")" else ""
	return {
		level = "success",
		text = string.format("Watch %s resolved%s", e.name, where),
		sub = if e.no_data then "no data" else string.format("value %s", formatValue(e.value)),
	}
end

-- (record to write or nil when unchanged, toasts to show).
function M.check(summaryRaw: any, notifiedRaw: any, now_ms: number): (Notified?, { Toast })
	local toasts: { Toast } = {}
	local payload = Poll.read(summaryRaw)
	if payload == nil then
		return nil, toasts
	end
	local notified = M.read(notifiedRaw)
	local changed = false
	local present: { [string]: boolean } = {}
	for _, e in payload.watches do
		present[e.name] = true
		local mark = notified.watches[e.name]
		-- Pending is not announced: the mark keeps the last firing/ok status.
		local status = if e.status == "pending" then "ok" else e.status
		local since = e.since_ms
		if e.status == "pending" then
			since = if mark then mark.since_ms else e.since_ms
		end
		if mark == nil or mark.status ~= status or (status == "firing" and mark.since_ms ~= since) then
			local fresh = now_ms - e.since_ms <= math.max(M.FRESH_INTERVALS * e.interval_ms, M.MIN_FRESH_MS)
			if fresh then
				if status == "firing" then
					table.insert(toasts, firingToast(e))
				elseif mark and mark.status == "firing" then
					table.insert(toasts, resolvedToast(e))
				end
			end
			notified.watches[e.name] = { status = status, since_ms = since }
			changed = true
		end
	end
	for name in notified.watches do
		if not present[name] then
			notified.watches[name] = nil
			changed = true
		end
	end
	return if changed then notified else nil, toasts
end

return M
