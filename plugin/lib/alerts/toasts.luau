--!strict
-- Toasts for newly firing alerts (config `alerts.toasts`, opt-in). Every
-- window checks the poller's kv summary; the fingerprints already announced
-- live in kv `tern-grafana.alerts.notified` with the summary time they came
-- from, so one poll is announced once across all windows (the first window
-- to see it records it; the others find it recorded). A context seen for the
-- first time, or after a gap (Tern was closed, polling was off), is recorded
-- without a toast: the first poll never announces what is already firing.
--
-- The kv record holds only context names, times and fingerprints (label
-- hashes); toasts say how many alerts started firing and how severe, since
-- the summary carries no labels.

local Summary = require("./summary")

export type Entry = { updated_ms: number, fingerprints: { string } }
export type Notified = { v: number, contexts: { [string]: Entry } }
export type Toast = { level: "error" | "info", text: string, sub: string? }

local M = {}

M.KEY = "tern-grafana.alerts.notified"
M.VERSION = 1
-- A record older than this many poll intervals (and at least MIN_GAP_MS) is
-- a gap: the next summary seeds instead of toasting.
M.GAP_POLLS = 3
M.MIN_GAP_MS = 5 * 60 * 1000

local ORDER = { "critical", "error", "warning", "info", "none" }

function M.read(raw: any): Notified
	if type(raw) ~= "table" or raw.v ~= M.VERSION or type(raw.contexts) ~= "table" then
		return { v = M.VERSION, contexts = {} }
	end
	local out: Notified = { v = M.VERSION, contexts = {} }
	for name, e in raw.contexts do
		if type(name) == "string" and type(e) == "table" and type(e.updated_ms) == "number" then
			local fps: { string } = {}
			if type(e.fingerprints) == "table" then
				for _, fp in e.fingerprints do
					if type(fp) == "string" then
						table.insert(fps, fp)
					end
				end
			end
			out.contexts[name] = { updated_ms = e.updated_ms, fingerprints = fps }
		end
	end
	return out
end

local function toastFor(context: string, counts: { [string]: number }, total: number): Toast
	local parts: { string } = {}
	local severe = false
	for _, sev in ORDER do
		local n = counts[sev]
		if n then
			table.insert(parts, string.format("%d %s", n, if sev == "none" then "without severity" else sev))
			if sev == "critical" or sev == "error" then
				severe = true
			end
		end
	end
	return {
		level = if severe then "error" else "info",
		text = string.format("%s: %d alert%s started firing", context, total, if total == 1 then "" else "s"),
		sub = table.concat(parts, ", ") .. "  (Grafana: Alerts)",
	}
end

-- (record to write or nil when unchanged, toasts to show) for the current
-- summary payload and notified record.
function M.check(summaryRaw: any, notifiedRaw: any): (Notified?, { Toast })
	local toasts: { Toast } = {}
	local payload = Summary.readPayload(summaryRaw)
	if payload == nil or payload.toast_severities == nil then
		return nil, toasts
	end
	local wanted: { [string]: boolean } = {}
	for _, sev in payload.toast_severities :: { string } do
		wanted[sev] = true
	end
	local notified = M.read(notifiedRaw)
	local gap = math.max(M.GAP_POLLS * payload.poll_s * 1000, M.MIN_GAP_MS)
	local changed = false
	local names: { string } = {}
	for name in payload.contexts do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local sum = payload.contexts[name]
		local entry = notified.contexts[name]
		if sum.error == nil and (entry == nil or sum.updated_ms > entry.updated_ms) then
			if entry and sum.updated_ms - entry.updated_ms <= gap then
				local prev: any = { fingerprints = entry.fingerprints }
				local fresh = Summary.diff(prev, sum)
				local sevOf: { [string]: string } = {}
				for i, fp in sum.fingerprints do
					sevOf[fp] = Summary.severityAt(sum, i)
				end
				local counts: { [string]: number } = {}
				local total = 0
				for _, fp in fresh do
					local sev = sevOf[fp]
					if wanted[sev] then
						counts[sev] = (counts[sev] or 0) + 1
						total += 1
					end
				end
				if total > 0 then
					table.insert(toasts, toastFor(name, counts, total))
				end
			end
			notified.contexts[name] = { updated_ms = sum.updated_ms, fingerprints = table.clone(sum.fingerprints) }
			changed = true
		end
	end
	for name in notified.contexts do
		if payload.contexts[name] == nil then
			notified.contexts[name] = nil
			changed = true
		end
	end
	return if changed then notified else nil, toasts
end

return M
