--!strict
-- The Zabbix Problems panel (alexanderzobnin-zabbix-triggers-panel from
-- alexanderzobnin-zabbix-app 6.10.2, src/panel-triggers), read-only: the
-- problems frames of its Zabbix targets (lib/datasources/zabbix_api) as the
-- panel lists them.
--
-- ProblemsPanel.tsx: every frame's first field holds problems; each gets
-- its first host's name, technical name, IP and proxy, tags (none when
-- empty); problems are filtered by showTriggers (acknowledged or not) and by
-- the `show` flag of their severity in triggerSeverity (indexed by
-- severity), then sorted by sortProblems: priority (severity, time, event id
-- descending) or lastchange (time, severity, event id descending).
-- Problems.tsx (layout table): the columns its visibility options turn on,
-- in its order (Host, Host (Technical Name), Host IP, Host Groups, Proxy,
-- Severity, Status, Problem, Operational data, Ack, custom tag columns,
-- Tags, Datasource, Age, Time); the first page of pageSize rows (default
-- 10) and the "Page 1 of N" footer; "No problems found" without rows.
-- Severity cells are filled with the severity's color (the OK color for
-- resolved problems, the ack color when markAckEvents), tags are badges
-- colored by a hash of the tag name (EventTag.tsx). Times are the viewer's
-- local time, "DD MMM YYYY HH:mm:ss" unless customLastChangeFormat; age is
-- moment's fromNow without the suffix.
-- AlertList/AlertCard.tsx (layout list): one card per problem with the
-- severity's color, name, host, tags, status/severity/age line, description
-- and last change.
--
-- Not reproduced: acknowledging, scripts, the expanded problem details and
-- timeline, tag filter clicks, data links, paging past the first page, the
-- search filter and font size. Panels saved before the panel's React
-- migration (no options) migrate in Grafana's browser: ladder.

local Assets = require("../render/assets")
local ClockFormat = require("./clock_format")
local Common = require("./common")
local Env = require("../env")
local FieldDisplay = require("./fielddisplay")
local Frame = require("../frame/types")
local Grid = require("../render/grid")
local Json = require("./json")
local TsGradient = require("../render/ts_gradient")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node

local M = {}

M.types = { "alexanderzobnin-zabbix-triggers-panel" }

export type Severity = { priority: number, severity: string, color: string, show: boolean }

-- types.ts DEFAULT_SEVERITY.
M.DEFAULT_SEVERITY = table.freeze({
	{ priority = 0, severity = "Not classified", color = "rgb(108, 108, 108)", show = true },
	{ priority = 1, severity = "Information", color = "rgb(120, 158, 183)", show = true },
	{ priority = 2, severity = "Warning", color = "rgb(175, 180, 36)", show = true },
	{ priority = 3, severity = "Average", color = "rgb(255, 137, 30)", show = true },
	{ priority = 4, severity = "High", color = "rgb(255, 101, 72)", show = true },
	{ priority = 5, severity = "Disaster", color = "rgb(215, 0, 0)", show = true },
} :: { Severity })

local DEFAULT_TIME_FORMAT = "DD MMM YYYY HH:mm:ss"
local DEFAULT_OK_COLOR = "rgb(56, 189, 113)"
local DEFAULT_PROBLEM_COLOR = "rgb(215, 0, 0)"

export type Options = {
	layout: string,
	sortProblems: string,
	pageSize: number,
	showTriggers: string?,
	hostField: boolean,
	hostTechNameField: boolean,
	hostIpField: boolean,
	hostGroups: boolean,
	hostProxy: boolean,
	showTags: boolean,
	statusField: boolean,
	severityField: boolean,
	ackField: boolean,
	ageField: boolean,
	opdataField: boolean,
	descriptionField: boolean,
	descriptionAtNewLine: boolean,
	showDatasourceName: boolean,
	customLastChangeFormat: boolean,
	lastChangeFormat: string,
	customTagColumns: string,
	markAckEvents: boolean,
	ackEventColor: string,
	okEventColor: string,
	triggerSeverity: { Severity },
}

-- The panel's options over module.tsx's defaults (defaultPanelOptions).
function M.options(panel: any, env: Env): Options
	local o = Json.obj(env, panel.options)
	local function flag(k: string, default: boolean): boolean
		local v = Json.bool(env, o[k])
		return if v == nil then default else v
	end
	local severities: { Severity } = {}
	local raw = Json.tbl(env, o.triggerSeverity)
	if raw then
		for i, s in Json.list(env, raw) do
			local st = Json.obj(env, s)
			local fallback = M.DEFAULT_SEVERITY[i] or M.DEFAULT_SEVERITY[1]
			table.insert(severities, {
				priority = Json.num(env, st.priority) or fallback.priority,
				severity = Json.str(env, st.severity) or fallback.severity,
				color = Json.str(env, st.color) or fallback.color,
				show = Json.bool(env, st.show) ~= false,
			})
		end
	else
		severities = table.clone(M.DEFAULT_SEVERITY) :: { Severity }
	end
	local pageSize = Json.num(env, o.pageSize)
	return {
		layout = Json.str(env, o.layout) or "table",
		sortProblems = Json.str(env, o.sortProblems) or "lastchange",
		pageSize = if pageSize and pageSize > 0 then math.floor(pageSize) else 10,
		showTriggers = Json.str(env, o.showTriggers),
		hostField = flag("hostField", true),
		hostTechNameField = flag("hostTechNameField", false),
		hostIpField = flag("hostIpField", false),
		hostGroups = flag("hostGroups", false),
		hostProxy = flag("hostProxy", false),
		showTags = flag("showTags", true),
		statusField = flag("statusField", true),
		severityField = flag("severityField", true),
		ackField = flag("ackField", true),
		ageField = flag("ageField", false),
		opdataField = flag("opdataField", false),
		descriptionField = flag("descriptionField", true),
		descriptionAtNewLine = flag("descriptionAtNewLine", false),
		showDatasourceName = flag("showDatasourceName", false),
		customLastChangeFormat = flag("customLastChangeFormat", false),
		lastChangeFormat = Json.str(env, o.lastChangeFormat) or "",
		customTagColumns = Json.str(env, o.customTagColumns) or "",
		markAckEvents = flag("markAckEvents", false),
		ackEventColor = Json.str(env, o.ackEventColor) or "rgb(56, 219, 156)",
		okEventColor = Json.str(env, o.okEventColor) or DEFAULT_OK_COLOR,
		triggerSeverity = severities,
	}
end

function M.supports(panel: any, env: Env): (boolean, string?)
	local o = Json.tbl(env, panel.options)
	if
		(o == nil or next(o) == nil) and (Json.tbl(env, panel.triggerSeverity) or Json.num(env, panel.schemaVersion))
	then
		return false, "a Problems panel saved before its React migration migrates in Grafana's browser"
	end
	return true, nil
end

-- A problem as the panel shows it (formatTrigger over a ProblemDTO).
export type Row = {
	problem: { [string]: any },
	severity: number,
	timestamp: number,
	eventid: string,
	host: string?,
	host_tech: string?,
	host_ip: string?,
	proxy: string?,
	tags: { { tag: string, value: string } },
}

local function s(env: Env, v: any): string?
	v = Env.value(env, v)
	if type(v) == "string" then
		return v
	elseif type(v) == "number" then
		return if v == math.floor(v) then string.format("%d", v) else tostring(v)
	end
	return nil
end

local function formatRow(env: Env, p: { [string]: any }): Row
	local hosts = Json.list(env, p.hosts)
	local h = Json.obj(env, hosts[1])
	local tags: { { tag: string, value: string } } = {}
	for _, t in Json.list(env, p.tags) do
		local tt = Json.obj(env, t)
		table.insert(tags, { tag = s(env, tt.tag) or "", value = s(env, tt.value) or "" })
	end
	return {
		problem = p,
		severity = tonumber(s(env, p.severity) or s(env, p.priority)) or 0,
		timestamp = tonumber(Env.value(env, p.timestamp)) or 0,
		eventid = s(env, p.eventid) or "",
		host = s(env, h.name),
		host_tech = s(env, h.host),
		host_ip = s(env, h.hostIp),
		proxy = s(env, h.proxy),
		tags = tags,
	}
end

-- lodash orderBy descending on the problem's raw values (strings compare as
-- strings, as they do in the browser).
local function rawDesc(a: any, b: any): boolean?
	if a == b then
		return nil
	elseif a == nil then
		return false
	elseif b == nil then
		return true
	elseif type(a) == type(b) then
		return a > b
	end
	return tostring(a) > tostring(b)
end

local function sortRows(rows: { Row }, keys: { string }): { Row }
	local indexed = table.create(#rows)
	for i, r in rows do
		indexed[i] = { r = r, i = i }
	end
	table.sort(indexed, function(x, y)
		for _, k in keys do
			local c = rawDesc(x.r.problem[k], y.r.problem[k])
			if c ~= nil then
				return c
			end
		end
		return x.i < y.i
	end)
	local out = table.create(#indexed)
	for i, e in indexed do
		out[i] = e.r
	end
	return out
end

-- prepareProblems: the rows the panel lists, in its order.
function M.rows(frames: { Frame.Frame }, o: Options, env: Env): { Row }
	local rows: { Row } = {}
	for _, frame in frames do
		local field = frame.fields[1]
		if field == nil then
			continue
		end
		for _, p in field.values do
			if type(p) == "table" then
				table.insert(rows, formatRow(env, p))
			end
		end
	end
	local kept: { Row } = {}
	for _, r in rows do
		local acks = #Json.list(env, r.problem.acknowledges)
		if o.showTriggers == "unacknowledged" and acks > 0 then
			continue
		elseif o.showTriggers == "acknowledged" and acks == 0 then
			continue
		end
		local sev = o.triggerSeverity[r.severity + 1]
		if sev and sev.show then
			table.insert(kept, r)
		end
	end
	if o.sortProblems == "priority" then
		return sortRows(kept, { "severity", "timestamp", "eventid" })
	elseif o.sortProblems == "lastchange" then
		return sortRows(kept, { "timestamp", "severity", "eventid" })
	end
	return kept
end

local function severityOf(o: Options, r: Row): Severity?
	for _, sv in o.triggerSeverity do
		if sv.priority == r.severity then
			return sv
		end
	end
	return nil
end

-- SeverityCell / AlertCard: the OK color for a resolved problem, the ack
-- color for an acknowledged one under markAckEvents, else the severity's.
local function problemColor(o: Options, r: Row, sev: Severity?, okFirst: boolean, env: Env): string
	local acked = s(env, r.problem.acknowledged) == "1"
	local resolved = s(env, r.problem.value) == "0"
	if okFirst and resolved then
		return o.okEventColor
	end
	if o.markAckEvents and acked then
		return o.ackEventColor
	end
	return if sev then sev.color else DEFAULT_PROBLEM_COLOR
end

local function colorClass(color: string, opts: Common.Options): string
	return TsGradient.fixedClass(color, opts.theme)
end

-- EventTag.tsx TAG_COLORS.
local TAG_COLORS = {
	"#E24D42",
	"#1F78C1",
	"#BA43A9",
	"#705DA0",
	"#466803",
	"#508642",
	"#447EBC",
	"#C15C17",
	"#890F02",
	"#757575",
	"#0A437C",
	"#6D1F62",
	"#584477",
	"#629E51",
	"#2F4F4F",
	"#BF1B00",
	"#806EB7",
	"#8a2eb8",
	"#699e00",
	"#000000",
	"#3F6833",
	"#2F575E",
	"#99440A",
	"#E0752D",
	"#0E4AB4",
	"#58140C",
	"#052B51",
	"#511749",
	"#3F2B5B",
}

local function int32(n: number): number
	n = n % 4294967296
	return if n >= 2147483648 then n - 4294967296 else n
end

-- djb2 over UTF-16 code units as JavaScript computes it (`hash << 5` wraps
-- to 32 bits, the sum does not).
function M.djb2(text: string): number
	local hash = 5381
	for _, cp in utf8.codes(text) do
		local units: { number } = if cp >= 0x10000
			then { 0xD800 + (cp - 0x10000) // 0x400, 0xDC00 + (cp - 0x10000) % 0x400 }
			else { cp }
		for _, u in units do
			hash = int32(int32(hash) * 32) + hash + u
		end
	end
	return hash
end

function M.tagColor(name: string): string
	local h = M.djb2(string.lower(name))
	local idx = math.abs(math.fmod(h, #TAG_COLORS))
	return TAG_COLORS[idx + 1]
end

local function tagText(t: { tag: string, value: string }): string
	return if t.value ~= "" then t.tag .. ": " .. t.value else t.tag
end

local function tagsNode(rows: { { tag: string, value: string } }, opts: Common.Options, key: string): Node
	local pills: { Node } = table.create(#rows)
	for i, t in rows do
		pills[i] = {
			k = "el",
			p = {
				tag = "span",
				key = "t" .. i,
				class = "tgz-tag " .. colorClass(M.tagColor(t.tag), opts),
				text = tagText(t),
			},
		}
	end
	return { k = "el", p = { tag = "div", key = key, class = "tgz-tags" }, c = pills }
end

local function localTime(env: Env, opts: Common.Options, o: Options, ts: number): string
	local offset = opts.local_offset_min or env.local_offset_min or 0
	local fmt = if o.customLastChangeFormat and o.lastChangeFormat ~= ""
		then o.lastChangeFormat
		else DEFAULT_TIME_FORMAT
	return ClockFormat.format(fmt, ts * 1000, offset, "")
end

-- moment.unix(ts).fromNow(true).
local function age(env: Env, opts: Common.Options, ts: number): string
	local text = FieldDisplay.fromNow(ts * 1000, env.now_ms, opts.local_offset_min or env.local_offset_min or 0)
	text = string.gsub(text, " ago$", "")
	text = string.gsub(text, "^in ", "")
	return text
end

local function groupNames(env: Env, p: { [string]: any }): string
	local names: { string } = {}
	for _, g in Json.list(env, p.groups) do
		table.insert(names, s(env, Json.obj(env, g).name) or "")
	end
	return table.concat(names, ", ")
end

local function customTagNames(spec: string): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, piece in string.split(spec, ",") do
		local name = string.match(piece, "^%s*(.-)%s*$") or ""
		if name ~= "" and not seen[name] then
			seen[name] = true
			table.insert(out, name)
		end
	end
	return out
end

local function capitalize(text: string): string
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

local function severityCell(o: Options, r: Row, opts: Common.Options, env: Env): Node
	local sev = severityOf(o, r)
	local color = problemColor(o, r, sev, false, env)
	return {
		k = "el",
		p = { tag = "div", class = "tgz-sev " .. colorClass(color, opts) },
		c = { Grid.text(if sev then sev.severity else "") },
	}
end

local function statusCell(r: Row, env: Env, opts: Common.Options): Node
	local resolved = s(env, r.problem.value) == "0"
	return {
		k = "el",
		p = {
			tag = "span",
			class = "tgz-status " .. colorClass(if resolved then DEFAULT_OK_COLOR else DEFAULT_PROBLEM_COLOR, opts),
			text = if resolved then "RESOLVED" else "PROBLEM",
		},
	}
end

local function hostCell(name: string?, r: Row): Node
	if r.problem.hostInMaintenance == true then
		return Grid.text((name or "") .. " (maintenance)")
	end
	return Grid.text(name or "")
end

type Column = { head: string, cell: (Row) -> Node }

local function columns(o: Options, opts: Common.Options, env: Env, ds: string?): { Column }
	local cols: { Column } = {}
	local function add(show: boolean, head: string, cell: (Row) -> Node)
		if show then
			table.insert(cols, { head = head, cell = cell })
		end
	end
	add(o.hostField, "Host", function(r)
		return hostCell(r.host, r)
	end)
	add(o.hostTechNameField, "Host (Technical Name)", function(r)
		return hostCell(r.host_tech, r)
	end)
	add(o.hostIpField, "Host IP", function(r)
		return Grid.text(r.host_ip or "")
	end)
	add(o.hostGroups, "Host Groups", function(r)
		return Grid.text(groupNames(env, r.problem))
	end)
	add(o.hostProxy, "Proxy", function(r)
		return Grid.text(r.proxy or "")
	end)
	add(o.severityField, "Severity", function(r)
		return severityCell(o, r, opts, env)
	end)
	add(o.statusField, "Status", function(r)
		return statusCell(r, env, opts)
	end)
	add(true, "Problem", function(r)
		return Grid.text(s(env, r.problem.name) or "")
	end)
	add(o.opdataField, "Operational data", function(r)
		return Grid.text(s(env, r.problem.opdata) or "")
	end)
	add(o.ackField, "Ack", function(r)
		local n = #Json.list(env, r.problem.acknowledges)
		return Grid.text(if n > 0 then string.format("(%d)", n) else "", "muted")
	end)
	for _, name in customTagNames(o.customTagColumns) do
		add(true, capitalize(name), function(r)
			local values: { string } = {}
			for _, t in r.tags do
				if t.tag == name and t.value ~= "" then
					table.insert(values, t.value)
				end
			end
			return Grid.text(table.concat(values, ", "))
		end)
	end
	add(o.showTags, "Tags", function(r)
		return tagsNode(r.tags, opts, "tg")
	end)
	add(o.showDatasourceName, "Datasource", function(_)
		return Grid.text(ds or "")
	end)
	add(o.ageField, "Age", function(r)
		return Grid.text(age(env, opts, r.timestamp))
	end)
	add(true, "Time", function(r)
		return Grid.text(localTime(env, opts, o, r.timestamp))
	end)
	return cols
end

-- The datasource name of the problems (the first problem's datasource uid).
local function dsName(rows: { Row }, env: Env): string?
	local first = rows[1]
	local ds = if first then Json.tbl(env, first.problem.datasource) else nil
	return if ds then s(env, ds.uid) else nil
end

local function tableView(rows: { Row }, o: Options, env: Env, opts: Common.Options): Node
	local cols = columns(o, opts, env, dsName(rows, env))
	local gridCols: { Grid.Column } = table.create(#cols)
	for i, c in cols do
		gridCols[i] = { head = c.head }
	end
	local pageRows: { Grid.Row } = {}
	for i = 1, math.min(#rows, o.pageSize) do
		local r = rows[i]
		local cells: { Node } = table.create(#cols)
		for j, c in cols do
			cells[j] = c.cell(r)
		end
		table.insert(pageRows, { key = "r" .. i, cells = cells })
	end
	local children: { Node } = { Grid.grid("g", gridCols, pageRows) }
	if #rows == 0 then
		table.insert(children, ui.muted("No problems found", { key = "none" }))
	end
	local pages = math.ceil(#rows / o.pageSize)
	table.insert(
		children,
		ui.text({
			ui.span(string.format("Page 1 of %d", pages), "muted"),
			ui.span(string.format("  %d rows", o.pageSize), "muted"),
		}, { key = "pg" })
	)
	return { k = "el", p = { tag = "div", key = opts.key, class = "tgz-p tgp-table" }, c = children }
end

local function hostLine(o: Options, r: Row): string
	local host = ""
	if o.hostField and o.hostTechNameField then
		host = string.format("%s (%s)", r.host or "", r.host_tech or "")
	elseif o.hostField then
		host = r.host or ""
	elseif o.hostTechNameField then
		host = r.host_tech or ""
	end
	if o.hostProxy and r.proxy and r.proxy ~= "" then
		host = r.proxy .. ": " .. host
	end
	return host
end

local function card(r: Row, i: number, o: Options, env: Env, opts: Common.Options): Node
	local sev = severityOf(o, r)
	local color = problemColor(o, r, sev, true, env)
	local p = r.problem
	local head: { Node } = {
		ui.text({ ui.span(s(env, p.description) or s(env, p.name) or "", "strong") }, { key = "n" }),
	}
	if o.hostField or o.hostTechNameField then
		table.insert(head, ui.text({ ui.span(hostLine(o, r), "muted") }, { key = "h" }))
	end
	if o.hostIpField and r.host_ip and r.host_ip ~= "" then
		table.insert(head, ui.text({ ui.span(r.host_ip :: string, "muted") }, { key = "ip" }))
	end
	if o.hostGroups then
		table.insert(head, ui.text({ ui.span(groupNames(env, p), "muted") }, { key = "gr" }))
	end
	if o.showTags and #r.tags > 0 then
		table.insert(head, tagsNode(r.tags, opts, "tg"))
	end
	local line: { ui.Span } = {}
	if o.statusField then
		local resolved = s(env, p.value) == "0"
		table.insert(
			line,
			ui.span(if resolved then "RESOLVED " else "PROBLEM ", if resolved then "success" else "error")
		)
	end
	if o.severityField and sev then
		table.insert(line, ui.span((sev :: Severity).severity .. " "))
	end
	if o.ageField then
		table.insert(line, ui.span("for " .. age(env, opts, r.timestamp) .. " ", "muted"))
	end
	local comments = s(env, p.comments) or ""
	if o.descriptionField and not o.descriptionAtNewLine and comments ~= "" then
		table.insert(line, ui.span(comments, "muted"))
	end
	local body: { Node } = { { k = "el", p = { tag = "div", key = "hd", class = "tgz-card-head" }, c = head } }
	if #line > 0 then
		table.insert(body, ui.text(line, { key = "ln" }))
	end
	if o.descriptionField and o.descriptionAtNewLine and comments ~= "" then
		table.insert(body, ui.text({ ui.span(comments, "muted") }, { key = "ds" }))
	end
	local children: { Node } = {
		{ k = "el", p = { tag = "div", key = "ic", class = "tgz-bar " .. colorClass(color, opts) } },
		{ k = "el", p = { tag = "div", key = "b", class = "tgz-card-body" }, c = body },
		ui.text({ ui.span(localTime(env, opts, o, r.timestamp), "muted") }, { key = "t" }),
	}
	return { k = "el", p = { tag = "div", key = "c" .. i, class = "tgz-card" }, c = children }
end

local function listView(rows: { Row }, o: Options, env: Env, opts: Common.Options): Node
	local children: { Node } = {}
	for i = 1, math.min(#rows, o.pageSize) do
		table.insert(children, card(rows[i], i, o, env, opts))
	end
	local pages = math.ceil(#rows / o.pageSize)
	if pages > 1 then
		table.insert(children, ui.text({ ui.span(string.format("Page 1 of %d", pages), "muted") }, { key = "pg" }))
	end
	return { k = "el", p = { tag = "div", key = opts.key, class = "tgz-p tgz-list" }, c = children }
end

function M.view(panel: any, frames: { Frame.Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local o = M.options(panel, env)
	local rows = M.rows(frames, o, env)
	if o.layout == "list" then
		return listView(rows, o, env, opts), nil
	end
	return tableView(rows, o, env, opts), nil
end

return M
