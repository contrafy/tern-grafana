--!strict
-- Per-context firing counts for kv `tern-grafana.alerts.summary`, which the
-- window's status segment reads inside a 4 ms formatter budget. kv is a
-- plain 0644 file shared by every window, so the payload carries counts,
-- severities, context names, fingerprints (label hashes) and an error kind:
-- never labels, annotations, URLs, server messages or credentials.

local Normalize = require("./normalize")

type Alert = Normalize.Alert
type Severity = Normalize.Severity

export type ErrorKind = "auth" | "network" | "timeout" | "http" | "parse" | "query" | "unsupported" | "config"

export type Summary = {
	firing: number,
	pending: number,
	silenced: number,
	inhibited: number,
	-- Firing alerts per severity.
	by_severity: { [string]: number },
	-- Worst severity among firing alerts; "none" when nothing fires.
	worst: Severity,
	updated_ms: number,
	-- Firing fingerprints, worst first, at most MAX_FINGERPRINTS (for diff).
	fingerprints: { string },
	-- The poll failed; the counts are the last good ones (or zero).
	error: ErrorKind?,
}

export type Payload = {
	v: number,
	updated_ms: number,
	poll_s: number,
	contexts: { [string]: Summary },
}

local M = {}

M.KEY = "tern-grafana.alerts.summary"
M.VERSION = 1
M.MAX_FINGERPRINTS = 64

local TONE: { [Severity]: string } = {
	critical = "error",
	error = "error",
	warning = "warning",
	info = "info",
	none = "muted",
}

function M.tone(severity: Severity): string
	return TONE[severity] or "muted"
end

function M.empty(now_ms: number): Summary
	return {
		firing = 0,
		pending = 0,
		silenced = 0,
		inhibited = 0,
		by_severity = {},
		worst = "none",
		updated_ms = now_ms,
		fingerprints = {},
	}
end

function M.summarize(alerts: { Alert }, now_ms: number): Summary
	local s = M.empty(now_ms)
	local firing: { Alert } = {}
	for _, a in alerts do
		if a.state == "firing" then
			s.firing += 1
			s.by_severity[a.severity] = (s.by_severity[a.severity] or 0) + 1
			if Normalize.SEVERITY_RANK[a.severity] > Normalize.SEVERITY_RANK[s.worst] then
				s.worst = a.severity
			end
			table.insert(firing, a)
		elseif a.state == "pending" then
			s.pending += 1
		elseif a.state == "silenced" then
			s.silenced += 1
		elseif a.state == "inhibited" then
			s.inhibited += 1
		end
	end
	-- Worst first so a truncated list still holds the alerts that matter.
	table.sort(firing, function(a: Alert, b: Alert): boolean
		local ra, rb = Normalize.SEVERITY_RANK[a.severity], Normalize.SEVERITY_RANK[b.severity]
		if ra ~= rb then
			return ra > rb
		end
		return a.fingerprint < b.fingerprint
	end)
	local seen: { [string]: boolean } = {}
	for _, a in firing do
		if #s.fingerprints >= M.MAX_FINGERPRINTS then
			break
		end
		if not seen[a.fingerprint] then
			seen[a.fingerprint] = true
			table.insert(s.fingerprints, a.fingerprint)
		end
	end
	return s
end

-- A failed poll keeps the last counts (an outage must not read as "all
-- clear") and records only the error kind.
function M.failed(prev: Summary?, kind: ErrorKind, now_ms: number): Summary
	local s: Summary = if prev then table.clone(prev :: Summary) else M.empty(now_ms)
	s.error = kind
	s.updated_ms = now_ms
	return s
end

-- Fingerprints firing in `next` that were not firing in `prev`. With no
-- previous summary nothing is new: the first poll after a start must not
-- announce every alert already firing.
function M.diff(prev: Summary?, next: Summary): { string }
	if prev == nil then
		return {}
	end
	local before: { [string]: boolean } = {}
	for _, fp in prev.fingerprints do
		before[fp] = true
	end
	local out: { string } = {}
	for _, fp in next.fingerprints do
		if not before[fp] then
			table.insert(out, fp)
		end
	end
	return out
end

function M.payload(contexts: { [string]: Summary }, now_ms: number, poll_s: number): Payload
	return { v = M.VERSION, updated_ms = now_ms, poll_s = poll_s, contexts = contexts }
end

-- The kv value as written by another VM (or an older version): nil unless it
-- has the expected shape.
function M.readPayload(raw: any): Payload?
	if type(raw) ~= "table" or raw.v ~= M.VERSION or type(raw.contexts) ~= "table" then
		return nil
	end
	if type(raw.updated_ms) ~= "number" then
		return nil
	end
	return raw :: Payload
end

-- Replaces one context's summary in a payload (the inbox refreshing the
-- context it shows), keeping the others.
function M.withContext(prev: Payload?, context: string, summary: Summary, now_ms: number, poll_s: number): Payload
	local contexts: { [string]: Summary } = {}
	if prev then
		for name, s in prev.contexts do
			contexts[name] = s
		end
	end
	contexts[context] = summary
	return M.payload(contexts, now_ms, if prev then prev.poll_s else poll_s)
end

return M
