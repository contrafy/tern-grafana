--!strict
-- The Investigate prompt (G4): plain text built from a Subject, shown in the
-- preview block before anything is sent and handed to the agent unchanged.
-- It asks for a read-only investigation and carries what the user saw: the
-- alert's labels, annotations and runbook, the queries and time range, a
-- summary of the recent values and links back to Grafana.

local Compact = require("../carly/compact")
local Subject = require("./subject")

type Subject = Subject.Subject

local M = {}

M.MAX_CHARS = 8000

local INTRO: { [string]: string } = {
	alert = "Investigate this %s Grafana alert and find its most likely cause.",
	query = "Investigate this Prometheus query result: explain what it shows and anything unusual.",
	panel = "Investigate this Grafana dashboard panel: explain what it shows and anything unusual.",
}

local GUIDE = "Use the queries and links below and your tools (kubectl, logs, the repository in this directory) "
	.. "as needed. Do not change anything without asking me first. Reply with the likely cause, the evidence, "
	.. "and suggested next steps."

local function num(v: number?): string
	if v == nil then
		return "-"
	end
	return string.format("%.4g", v)
end

local function sortedKeys(t: { [string]: string }): { string }
	local keys: { string } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

local function duration(ms: number): string
	local sec = math.max(0, math.floor(ms / 1000))
	if sec < 60 then
		return sec .. "s"
	elseif sec < 3600 then
		return (sec // 60) .. "m"
	elseif sec < 86400 then
		return string.format("%dh%dm", sec // 3600, sec % 3600 // 60)
	end
	return string.format("%dd%dh", sec // 86400, sec % 86400 // 3600)
end

local function pairsBlock(out: { string }, head: string, map: { [string]: string })
	local keys = sortedKeys(map)
	if #keys == 0 then
		return
	end
	table.insert(out, head)
	for _, k in keys do
		table.insert(out, string.format("  %s: %s", k, map[k]))
	end
end

local function valuesBlock(out: { string }, s: Subject)
	local v = s.values
	if v == nil then
		return
	end
	local vals = v :: Subject.Values
	table.insert(
		out,
		string.format(
			"Recent values (%s to %s, %d series%s):",
			Compact.iso(vals.from_ms),
			Compact.iso(vals.to_ms),
			#vals.series + vals.omitted,
			if vals.omitted > 0 then string.format(", the %d with the largest last value", #vals.series) else ""
		)
	)
	if #vals.series == 0 then
		table.insert(out, "  (no data in this range)")
		return
	end
	for _, series in vals.series do
		local line = string.format(
			"  %s: last %s, min %s, max %s, avg %s (%d points)",
			Compact.clip(series.name, 300),
			num(series.last),
			num(series.min),
			num(series.max),
			num(series.avg),
			series.points
		)
		if series.trend and #series.trend > 1 then
			local parts: { string } = {}
			for _, x in series.trend :: { number } do
				table.insert(parts, num(x))
			end
			line ..= "; trend " .. table.concat(parts, " ")
		end
		table.insert(out, line)
	end
end

function M.build(s: Subject, now_ms: number): string
	local out: { string } = {}
	local a = s.alert
	local intro = INTRO[s.kind] or INTRO.query
	table.insert(out, if a then string.format(intro, a.state) else intro)
	table.insert(out, GUIDE)
	table.insert(out, "")
	if a then
		local info = a :: Subject.AlertInfo
		table.insert(
			out,
			string.format(
				"Alert: %s (severity %s, %s since %s, %s)",
				info.name,
				info.severity,
				info.state,
				Compact.iso(info.since_ms),
				duration(now_ms - info.since_ms)
			)
		)
		if s.context then
			table.insert(out, string.format("Context: %s (alerts from %s)", s.context :: string, info.source))
		end
		table.insert(out, "Summary: " .. info.summary)
		if info.description and info.description ~= info.summary then
			table.insert(out, "Description: " .. (info.description :: string))
		end
		if info.value then
			table.insert(out, "Value when evaluated: " .. (info.value :: string))
		end
		pairsBlock(out, "Labels:", info.labels)
		pairsBlock(out, "Annotations:", info.annotations)
	else
		local p = s.panel
		if p then
			if p.dashboard then
				table.insert(
					out,
					string.format(
						"Dashboard: %s%s",
						p.dashboard :: string,
						if p.uid then string.format(" (uid %s)", p.uid :: string) else ""
					)
				)
			end
			table.insert(out, string.format("Panel: %s (%s)", p.title, p.type))
		end
		if s.context then
			table.insert(out, "Context: " .. (s.context :: string))
		end
	end
	if s.range then
		local r = s.range :: Subject.TimeWindow
		table.insert(
			out,
			string.format("Time range: %s to %s (%s to %s)", r.from, r.to, Compact.iso(r.from_ms), Compact.iso(r.to_ms))
		)
	end
	if #s.queries == 1 and s.queries[1].ref == nil then
		table.insert(out, "Query (PromQL): " .. s.queries[1].expr)
	elseif #s.queries > 0 then
		table.insert(out, "Queries:")
		for i, q in s.queries do
			table.insert(out, string.format("  %s: %s", q.ref or tostring(i), q.expr))
		end
	end
	valuesBlock(out, s)
	if #s.links > 0 then
		table.insert(out, "Links:")
		for _, l in s.links do
			table.insert(out, string.format("  %s: %s", l.label, l.url))
		end
	end
	local text = table.concat(out, "\n")
	if #text > M.MAX_CHARS then
		text = string.sub(text, 1, M.MAX_CHARS - 13) .. "\n[truncated]"
	end
	return text
end

return M
