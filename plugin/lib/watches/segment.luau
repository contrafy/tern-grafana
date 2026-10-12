--!strict
-- The watches status-line segment from the kv summary: nothing while every
-- watch is ok (the alerts segment already says the plugin is alive), one
-- segment when watches fire (named when only one does, toned by the worst
-- severity), a muted one while watches are only pending, and "watch ?" when
-- evaluations fail or the poller stopped. Pure and cheap: it runs inside the
-- 4 ms chrome formatter budget.

local Poll = require("./poll")
local Tbl = require("../tbl")

export type Segment = { text: string, icon: string?, tone: string?, command: string? }

local M = {}

M.COMMAND = "plugin.tern-grafana.watches"
M.ICON = "eye"
-- A summary older than this many of the shortest interval (and at least
-- MIN_STALE_MS) means the poller stopped.
M.STALE_INTERVALS = 3
M.MIN_STALE_MS = 5 * 60 * 1000

local RANK: { [string]: number } = { critical = 4, error = 3, warning = 2, info = 1 }
local TONE: { [string]: string } = { critical = "error", error = "error", warning = "warning", info = "info" }

function M.stale(payload: Poll.Payload, now_ms: number): boolean
	local shortest: number? = nil
	for _, e in payload.watches do
		if shortest == nil or e.interval_ms < shortest then
			shortest = e.interval_ms
		end
	end
	local limit = math.max(M.STALE_INTERVALS * (shortest or 60000), M.MIN_STALE_MS)
	return now_ms - payload.updated_ms > limit
end

-- nil when there is nothing to say (no summary, or every watch is ok).
function M.segments(raw: any, now_ms: number): { Segment }?
	local payload = Poll.read(raw)
	if payload == nil or #payload.watches == 0 then
		return nil
	end
	local stale = M.stale(payload, now_ms)
	local firing: { Poll.Entry } = {}
	local pending = 0
	local failed = 0
	local worst = ""
	for _, e in payload.watches do
		if e.status == "firing" then
			table.insert(firing, e)
			if (RANK[e.severity] or 0) > (RANK[worst] or 0) then
				worst = e.severity
			end
		elseif e.status == "pending" then
			pending += 1
		end
		if e.error then
			failed += 1
		end
	end
	local suffix = if failed > 0 or stale then " ?" else ""
	local text: string
	local tone: string
	if #firing == 1 then
		text, tone = "watch " .. firing[1].name .. suffix, TONE[worst] or "warning"
	elseif #firing > 1 then
		text, tone = string.format("%d watches", #firing) .. suffix, TONE[worst] or "warning"
	elseif pending > 0 then
		text, tone = string.format("%d pending", pending) .. suffix, "muted"
	elseif failed > 0 or stale then
		text, tone = "watch ?", "muted"
	else
		return nil
	end
	if stale then
		tone = "muted"
	end
	return { { text = text, icon = M.ICON, tone = tone, command = M.COMMAND } }
end

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

-- The watch a click should show: the worst firing one, else the first
-- pending, else the first failing; nil when all are ok.
function M.focus(raw: any): Poll.Entry?
	local payload = Poll.read(raw)
	if payload == nil then
		return nil
	end
	local best: Poll.Entry? = nil
	local bestRank = -1
	for _, e in payload.watches do
		local rank = if e.status == "firing"
			then 10 + (RANK[e.severity] or 0)
			elseif e.status == "pending" then 5
			elseif e.error then 1
			else -1
		if rank > bestRank then
			best, bestRank = e, rank
		end
	end
	return if bestRank >= 0 then best else nil
end

-- Tern keeps one status formatter per plugin: the alerts formatter shows
-- its segments followed by the watches ones. nil when neither has any.
function M.append(first: { Segment }?, second: { Segment }?): { Segment }?
	if second == nil or #second == 0 then
		return first
	end
	local out: { Segment } = if first then Tbl.copy(first) else {}
	for _, s in second do
		table.insert(out, s)
	end
	return out
end

-- The query link a click opens for `entry`: its expression over the last
-- hour (at least 12 intervals) in the context it was evaluated in.
function M.link(entry: Poll.Entry): { action: string, params: { [string]: string }, vars: { [string]: { string } } }
	local span_ms = math.max(60 * 60 * 1000, 12 * entry.interval_ms)
	local params: { [string]: string } = {
		expr = entry.expr,
		from = "now-" .. tostring(math.ceil(span_ms / 60000)) .. "m",
		to = "now",
	}
	if entry.context then
		params.context = entry.context
	end
	return { action = "query", params = params, vars = {} }
end

return M
