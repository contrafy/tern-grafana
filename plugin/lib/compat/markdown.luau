--!strict
-- The whole compatibility report as Markdown, for the clipboard (`m`). It
-- names dashboards and panels (the user's own data, copied by the user) but
-- never a URL, token or header.

local Analyze = require("./analyze")
local Range = require("../time/range")

local M = {}

export type Meta = {
	context: string,
	version: string?,
	renderer: boolean,
	-- Dashboards the search found (at least this many when capped).
	found: number,
	max: number,
	capped: boolean,
	-- The scan is still running.
	partial: boolean,
	at_ms: number,
}

local MODE_TEXT = { native = "native", png = "Grafana PNG", browser = "browser" }

-- One table cell: pipes escaped, line breaks flattened.
local function cell(s: string): string
	s = string.gsub(s, "[\r\n]+", " ")
	s = string.gsub(s, "|", "\\|")
	return s
end

local function pct(n: number, total: number): string
	if total == 0 then
		return "0%"
	end
	return string.format("%d%%", math.floor(n * 100 / total + 0.5))
end

function M.modeText(mode: string): string
	return (MODE_TEXT :: any)[mode] or mode
end

-- Where the panel sits: row, collapsed, repeats, library.
function M.placement(p: Analyze.PanelResult): string
	local parts: { string } = {}
	if p.row and p.row ~= "" then
		table.insert(parts, "row " .. (p.row :: string) .. (if p.collapsed then " (collapsed)" else ""))
	elseif p.collapsed then
		table.insert(parts, "collapsed row")
	end
	if p.row_repeat_var then
		table.insert(parts, "row repeats by $" .. (p.row_repeat_var :: string))
	end
	if p.repeat_var then
		table.insert(parts, "repeats by $" .. (p.repeat_var :: string))
	end
	if p.library then
		table.insert(parts, "library panel")
	end
	return table.concat(parts, ", ")
end

function M.report(meta: Meta, results: { Analyze.DashResult }, summary: Analyze.Summary): string
	local out: { string } = {}
	local function line(s: string?)
		table.insert(out, s or "")
	end
	line("# Grafana compatibility report: " .. meta.context)
	line()
	line(
		string.format(
			"Grafana %s, image renderer %s. Generated %s UTC%s.",
			meta.version or "(unknown version)",
			if meta.renderer then "available" else "not available",
			Range.formatMs(meta.at_ms),
			if meta.partial then " while the scan was still running" else ""
		)
	)
	line()
	if meta.capped then
		line(
			string.format(
				"Capped: scanned the first %d of at least %d dashboards (config `compat.max_dashboards`).",
				meta.max,
				meta.found
			)
		)
	else
		line(string.format("Dashboards found: %d.", meta.found))
	end
	line(
		string.format(
			"Dashboards analyzed: %d (%d could not be loaded). Panels: %d; native %d (%s), Grafana PNG %d (%s), browser %d (%s).",
			summary.dashboards,
			summary.failed,
			summary.panels,
			summary.native,
			pct(summary.native, summary.panels),
			summary.png,
			pct(summary.png, summary.panels),
			summary.browser,
			pct(summary.browser, summary.panels)
		)
	)
	line()
	line("Repeated panels and rows count once. Panels in collapsed rows are included.")
	line()
	line("## Not native, by reason")
	line()
	if #summary.reasons == 0 then
		line("Every panel is native.")
	else
		line("| Panels | Dashboards | Rung | Reason | Panel types |")
		line("| ---: | ---: | --- | --- | --- |")
		for _, r in summary.reasons do
			line(
				string.format(
					"| %d | %d | %s | %s | %s |",
					r.panels,
					r.dashboards,
					M.modeText(r.mode),
					cell(r.reason),
					cell(Analyze.typesText(r.types))
				)
			)
		end
	end
	line()
	line("## Native panel types")
	line()
	line(if #summary.native_types == 0 then "None." else Analyze.typesText(summary.native_types))
	line()
	line("## Dashboards")
	for _, r in results do
		line()
		local head = "### " .. cell(r.title)
		if r.folder and r.folder ~= "" then
			head ..= " (" .. cell(r.folder :: string) .. ")"
		end
		line(head)
		line()
		line(string.format("uid `%s`", r.uid))
		line()
		if r.error then
			line("Could not be analyzed: " .. cell(r.error :: string))
			continue
		end
		if #r.panels == 0 then
			line("No panels.")
			continue
		end
		line(string.format("native %d, Grafana PNG %d, browser %d", r.native, r.png, r.browser))
		line()
		line("| Panel | Id | Type | Rung | Reason | Where |")
		line("| --- | ---: | --- | --- | --- | --- |")
		for _, p in r.panels do
			line(
				string.format(
					"| %s | %d | %s | %s | %s | %s |",
					cell(if p.title == "" then "(untitled)" else p.title),
					p.id,
					cell(p.type),
					M.modeText(p.mode),
					cell(p.blocker or ""),
					cell(M.placement(p))
				)
			)
		end
	end
	line()
	return table.concat(out, "\n")
end

return M
