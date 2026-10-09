--!strict
-- Lens for `logcli query`: re-derives what was asked from argv (kingpin flag
-- rules), reads log output in all three modes (`default`, `--output=jsonl`,
-- `--output=raw`) and metric query output (logcli prints those as indented
-- JSON whatever the mode), and renders log lines with level tones, their
-- stream labels and the labels every stream shares, or a series grid. Errors
-- logcli logs to stderr become an error card. Anything it cannot read
-- faithfully returns nil, so Tern shows the raw output.
--
-- Output shapes are logcli's (pkg/logcli/output/*.go, pkg/logcli/print):
-- default lines are `<timestamp> <labels padded to the widest> <line>`,
-- jsonl lines are `{"labels", "line", "timestamp"}`, raw lines are the log
-- line alone; metadata and errors go through Go's `log` package, so they
-- carry its `YYYY/MM/DD HH:MM:SS ` prefix.
--
-- There is no "Open in Logs block" action until the logs block exists (M5).

local EnvModule = require("../env")
local Grid = require("../render/grid")
local LensTypes = require("./types")
local Promtool = require("./promtool_query")
local SeriesView = require("./series")
local ui = require("../ui")

type Env = EnvModule.Env
type Node = ui.Node
type Run = LensTypes.Run
type Effect = LensTypes.Effect
type Labels = { [string]: string }
type ViewState = SeriesView.ViewState

local M = {}

-- Past these the capture stays raw (memory and the 2 s view budget).
M.MAX_LINES = 50000
M.MAX_BYTES = 8 * 1024 * 1024

-- Invocation ---------------------------------------------------------------------

export type Mode = "default" | "raw" | "jsonl"

export type Invocation = {
	-- nil: not a logcli query this lens renders (`reason` says why).
	verb: "query"?,
	reason: string?,
	-- --addr without userinfo; nil when it comes from LOKI_ADDR or the default.
	addr: string?,
	expr: string?,
	-- A metric query (anything but a `{...}` stream selector first).
	metric: boolean,
	output: Mode,
	no_labels: boolean,
	quiet: boolean,
	limit: number?,
	since: string?,
	from: string?,
	to: string?,
	forward: boolean,
}

-- Long flags that take a value (`--name value` or `--name=value`). Values of
-- credential flags are skipped, never kept.
local VALUE_FLAGS: { [string]: boolean } = {
	addr = true,
	username = true,
	password = true,
	["ca-cert"] = true,
	cert = true,
	key = true,
	["org-id"] = true,
	["query-tags"] = true,
	["bearer-token"] = true,
	["bearer-token-file"] = true,
	retries = true,
	["min-backoff"] = true,
	["max-backoff"] = true,
	["auth-header"] = true,
	["proxy-url"] = true,
	header = true,
	output = true,
	timezone = true,
	["output-timestamp-format"] = true,
	["log.level"] = true,
	cpuprofile = true,
	memprofile = true,
	limit = true,
	since = true,
	from = true,
	to = true,
	step = true,
	interval = true,
	batch = true,
	["parallel-duration"] = true,
	["parallel-max-workers"] = true,
	["part-path-prefix"] = true,
	["exclude-label"] = true,
	["include-label"] = true,
	["labels-length"] = true,
	["store-config"] = true,
	["schema-store"] = true,
	["delay-for"] = true,
}

-- The values this lens reads; every other value is dropped.
local KEPT: { [string]: boolean } = {
	addr = true,
	output = true,
	limit = true,
	since = true,
	from = true,
	to = true,
}

local HELP_FLAGS: { [string]: boolean } = {
	help = true,
	["help-long"] = true,
	["help-man"] = true,
	version = true,
	["completion-script-bash"] = true,
	["completion-script-zsh"] = true,
}

local SHORT_VALUE: { [string]: string } = { o = "output", z = "timezone" }
local SHORT_BOOL: { [string]: string } = { q = "quiet", t = "tail", f = "follow" }

local function unsupported(inv: Invocation, reason: string): Invocation
	inv.verb = nil
	inv.reason = reason
	return inv
end

function M.withoutUserinfo(url: string): string
	return (string.gsub(url, "^(%a[%w+.-]*://)[^/@?#]*@", "%1"))
end

function M.parseArgs(program: string, args: { string }): Invocation
	local inv: Invocation = {
		verb = nil,
		reason = nil,
		addr = nil,
		expr = nil,
		metric = false,
		output = "default",
		no_labels = false,
		quiet = false,
		limit = nil,
		since = nil,
		from = nil,
		to = nil,
		forward = false,
	}
	if program ~= "logcli" then
		return unsupported(inv, "not logcli")
	end
	local positional: { string } = {}
	local values: { [string]: string } = {}
	local bools: { [string]: boolean } = {}
	local afterDashes = false
	local i = 1
	while i <= #args do
		local a = args[i]
		if afterDashes or a == "-" or string.sub(a, 1, 1) ~= "-" then
			table.insert(positional, a)
		elseif a == "--" then
			afterDashes = true
		elseif string.sub(a, 1, 2) == "--" then
			local inline, inlineValue = string.match(a, "^%-%-([^=]+)=(.*)$")
			local flag: string = inline or string.sub(a, 3)
			if HELP_FLAGS[flag] then
				return unsupported(inv, "help output")
			end
			if VALUE_FLAGS[flag] then
				local value: string? = inlineValue
				if inline == nil then
					i += 1
					value = args[i]
				end
				if value == nil then
					return unsupported(inv, "--" .. flag .. " has no value")
				end
				if KEPT[flag] then
					values[flag] = value
				end
			elseif string.sub(flag, 1, 3) == "no-" and flag ~= "no-labels" then
				bools[string.sub(flag, 4)] = false
			else
				bools[flag] = true
			end
		else
			local j = 2
			while j <= #a do
				local letter = string.sub(a, j, j)
				if letter == "h" then
					return unsupported(inv, "help output")
				end
				local long = SHORT_VALUE[letter]
				if long then
					local value: string? = string.sub(a, j + 1)
					if string.sub(value :: string, 1, 1) == "=" then
						value = string.sub(value :: string, 2)
					end
					if value == "" then
						i += 1
						value = args[i]
					end
					if value == nil then
						return unsupported(inv, "-" .. letter .. " has no value")
					end
					if KEPT[long] then
						values[long] = value
					end
					break
				end
				local bool = SHORT_BOOL[letter]
				if bool then
					bools[bool] = true
				end
				j += 1
			end
		end
		i += 1
	end

	if positional[1] ~= "query" then
		return unsupported(inv, "not a logcli query")
	end
	if #positional ~= 2 then
		-- An unquoted query split into several words; logcli refuses it.
		return unsupported(inv, "unexpected arguments")
	end
	if bools.tail or bools.follow then
		return unsupported(inv, "a live tail")
	end
	local output = values.output or "default"
	if output ~= "default" and output ~= "raw" and output ~= "jsonl" then
		return unsupported(inv, "unknown output mode " .. output)
	end
	local expr = positional[2]
	inv.verb = "query"
	inv.expr = expr
	inv.metric = string.find(expr, "^%s*{") == nil
	inv.output = output :: Mode
	inv.no_labels = bools["no-labels"] == true
	inv.quiet = bools.quiet == true
	inv.forward = bools.forward == true
	local addr = values.addr
	inv.addr = if addr then M.withoutUserinfo(addr) else nil
	local limit = tonumber(values.limit or "")
	inv.limit = if values.limit == nil then 30 elseif limit and limit > 0 then limit else nil
	inv.since = values.since
	inv.from = values.from
	inv.to = values.to
	return inv
end

-- Levels -----------------------------------------------------------------------------

-- "critical", "error", "warning", "info", "debug" or "unknown".
export type Level = string

local LEVEL_ALIASES: { [string]: Level } = {
	critical = "critical",
	crit = "critical",
	fatal = "critical",
	panic = "critical",
	emerg = "critical",
	emergency = "critical",
	alert = "critical",
	error = "error",
	err = "error",
	eror = "error",
	warning = "warning",
	warn = "warning",
	info = "info",
	information = "info",
	informational = "info",
	notice = "info",
	debug = "debug",
	dbug = "debug",
	trace = "debug",
}

-- Label names Loki and common shippers carry the level in, in order.
local LEVEL_LABELS = { "level", "detected_level", "severity", "lvl", "loglevel" }

local function levelWord(word: string?): Level?
	return if word then LEVEL_ALIASES[string.lower(word)] else nil
end

-- The entry's level: from its stream labels, then the labels every stream
-- shares, then the line itself (logfmt `level=`, JSON `"level":`, or a
-- leading `ERROR`/`[warn]` word).
function M.level(labels: Labels?, common: Labels, line: string): Level
	for _, set in { labels or {}, common } do
		for _, name in LEVEL_LABELS do
			local l = levelWord(set[name])
			if l then
				return l
			end
		end
	end
	local word = string.match(line, '%f[%w_]level="?(%a+)')
		or string.match(line, '%f[%w_]lvl="?(%a+)')
		or string.match(line, '"level"%s*:%s*"(%a+)"')
		or string.match(line, '"severity"%s*:%s*"(%a+)"')
		or string.match(line, "^%[?(%a+)%]?[%s:]")
	return levelWord(word) or "unknown"
end

local LEVEL_TONE: { [Level]: string } = {
	critical = "error",
	error = "error",
	warning = "warning",
	info = "info",
	debug = "muted",
	unknown = "neutral",
}

local LINE_STYLE: { [Level]: string } = {
	critical = "error",
	error = "error",
	warning = "warning",
	debug = "muted",
}

function M.levelTone(level: Level): string
	return LEVEL_TONE[level]
end

-- Output ---------------------------------------------------------------------------

export type Entry = {
	-- As logcli printed it; nil in raw mode.
	time: string?,
	-- The stream's labels minus the common ones (default mode), all of them
	-- (jsonl), or nil (raw, --no-labels).
	labels: Labels?,
	line: string,
}

export type ErrorKind = "network" | "timeout" | "auth" | "query" | "usage"

export type CliError = { kind: ErrorKind, message: string }

export type ResultKind = "logs" | "metric" | "empty" | "error" | "unreadable"

-- A metric query's value (logcli prints the API's `data.result` as JSON).
export type Metric = { kind: SeriesView.Kind, series: { SeriesView.Series } }

export type Result = {
	kind: ResultKind,
	entries: { Entry },
	-- From logcli's "Common labels:" line, or shared by every jsonl entry.
	common: Labels,
	metric: Metric?,
	errors: { CliError },
	unparsed: number,
}

local function containsAny(text: string, needles: { string }): boolean
	for _, n in needles do
		if string.find(text, n, 1, true) then
			return true
		end
	end
	return false
end

function M.errorKind(message: string): ErrorKind
	local lower = string.lower(message)
	if containsAny(lower, { "context deadline exceeded", "timeout", "i/o timeout" }) then
		return "timeout"
	elseif
		containsAny(lower, {
			"error sending request",
			"connection refused",
			"no such host",
			"dial tcp",
			"network is unreachable",
			"connection reset",
			"tls:",
			"x509:",
		})
	then
		return "network"
	elseif containsAny(lower, { "401", "403", "unauthorized", "forbidden", "no org id" }) then
		return "auth"
	end
	return "query"
end

-- Go's `log` prefix, as logcli's stderr carries it.
local LOG_PREFIX = "^%d%d%d%d/%d%d/%d%d %d%d:%d%d:%d%d (.*)$"

type Meta = { kind: "common", labels: Labels } | { kind: "error", error: CliError, fatal: boolean } | { kind: "note" }

-- logcli's own stderr messages; nil for anything else (a raw log line may
-- well start with a Go log prefix of its own).
local function metaOf(line: string): Meta?
	local usage = string.match(line, "^logcli: error: (.*)$")
	if usage then
		return { kind = "error", error = { kind = "usage", message = usage }, fatal = true }
	end
	local msg = string.match(line, LOG_PREFIX)
	if msg == nil then
		return nil
	end
	local common = string.match(msg, "^Common labels: (.*)$")
	if common then
		local labels, pos = Promtool.parseMetric(common, 1)
		if labels and pos == #common + 1 then
			return { kind = "common", labels = labels }
		end
		return nil
	end
	local failed = string.match(msg, "^Query failed: (.*)$")
	if failed then
		return { kind = "error", error = { kind = M.errorKind(failed), message = failed }, fatal = true }
	end
	local server = string.match(msg, "^error response from server: (.*)$")
	if server then
		local text = string.gsub(server, "%s*%(<nil>%)", "")
		text = string.gsub(text, "%s*attempts remaining: %d+$", "")
		return { kind = "error", error = { kind = M.errorKind(text), message = text }, fatal = false }
	end
	local sending = string.match(msg, "^(error sending request .*)$")
	if sending then
		return { kind = "error", error = { kind = M.errorKind(sending), message = sending }, fatal = false }
	end
	if
		string.find(msg, "^https?://")
		or string.find(msg, "^Ignoring labels key: ")
		or string.find(msg, "^Print only labels key: ")
	then
		return { kind = "note" }
	end
	return nil
end

-- Timestamp layouts logcli's --output-timestamp-format offers.
local TIME_PATTERNS = {
	-- rfc3339, rfc3339nano
	"^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%.%d]*[Z%+%-][%d:]*) ",
	-- rfc822z: 02 Jan 06 15:04 -0700
	"^(%d%d %a%a%a %d%d %d%d:%d%d [%+%-]%d%d%d%d) ",
	-- rfc1123z: Mon, 02 Jan 2006 15:04:05 -0700
	"^(%a%a%a, %d%d %a%a%a %d%d%d%d %d%d:%d%d:%d%d [%+%-]%d%d%d%d) ",
	-- unixdate: Mon Jan _2 15:04:05 MST 2006
	"^(%a%a%a %a%a%a [ %d]%d %d%d:%d%d:%d%d %S+ %d%d%d%d) ",
	-- stampmilli, stampmicro, stampnano: Jan _2 15:04:05.000
	"^(%a%a%a [ %d]%d %d%d:%d%d:%d%d[%.%d]*) ",
}

local function splitTime(line: string): (string?, string)
	for _, p in TIME_PATTERNS do
		local t = string.match(line, p)
		if t then
			return t, string.sub(line, #t + 2)
		end
	end
	return nil, line
end

local function defaultEntry(inv: Invocation, line: string): Entry?
	local time, rest = splitTime(line)
	if time == nil then
		-- An empty log line prints as the timestamp alone (blanks trimmed).
		local only = string.match(line, "^%S+$")
		if only and splitTime(only .. " ") then
			return { time = only, labels = if inv.no_labels then nil else {}, line = "" }
		end
		return nil
	end
	if inv.no_labels then
		return { time = time, labels = nil, line = rest }
	end
	local labels, pos = Promtool.parseMetric(rest, 1)
	if labels == nil or string.sub(rest, 1, 1) ~= "{" then
		return nil
	end
	return { time = time, labels = labels, line = (string.gsub(string.sub(rest, pos), "^ +", "")) }
end

local function stringLabels(v: any): Labels?
	if type(v) ~= "table" then
		return nil
	end
	local out: Labels = {}
	for k, val in v do
		if type(k) ~= "string" or type(val) ~= "string" then
			return nil
		end
		out[k] = val
	end
	return out
end

local function jsonlEntry(line: string, decode: (string) -> any): Entry?
	if string.sub(line, 1, 1) ~= "{" then
		return nil
	end
	local ok, doc = pcall(decode, line)
	if not ok or type(doc) ~= "table" or type(doc.line) ~= "string" or type(doc.timestamp) ~= "string" then
		return nil
	end
	return { time = doc.timestamp, labels = stringLabels(doc.labels), line = doc.line }
end

-- Labels every entry shares (jsonl prints them on every line).
local function sharedLabels(entries: { Entry }): Labels
	local first = entries[1]
	local shared: Labels = {}
	if first == nil or first.labels == nil or #entries < 2 then
		return shared
	end
	for k, v in first.labels :: Labels do
		shared[k] = v
	end
	for i = 2, #entries do
		local labels = entries[i].labels or {}
		for k, v in shared do
			if labels[k] ~= v then
				shared[k] = nil
			end
		end
	end
	return shared
end

local function newResult(): Result
	return { kind = "empty", entries = {}, common = {}, metric = nil, errors = {}, unparsed = 0 }
end

-- logcli prints a metric result (a JSON array, MarshalIndent) without a final
-- newline, so in a zsh pane PROMPT_SP's end-of-line mark (`%`, `#` for root)
-- lands right after the closing bracket and Tern captures `]%` (`[]%` for an
-- empty result). The mark is the shell's, not logcli's.
local function metricJson(data: { string }): string
	local n = #data
	local bracket = string.match(data[n], "^(%[?%])[%%#]$")
	if bracket == nil then
		return table.concat(data, "\n")
	end
	return table.concat(data, "\n", 1, n - 1) .. (if n > 1 then "\n" else "") .. bracket
end

-- Reads a finished capture. `decode` is the JSON decoder (tern.json.decode on
-- the host).
function M.build(inv: Invocation, lines: { string }, decode: (string) -> any): Result
	local result = newResult()
	if inv.verb == nil then
		result.kind = "unreadable"
		return result
	end
	local fatal: CliError? = nil
	local data: { string } = {}
	for _, line in lines do
		if string.find(line, "^%s*$") then
			continue
		end
		local meta = metaOf(line)
		if meta == nil then
			table.insert(data, line)
		elseif meta.kind == "common" then
			result.common = meta.labels
		elseif meta.kind == "error" then
			if meta.fatal then
				fatal = meta.error
			else
				table.insert(result.errors, meta.error)
			end
		end
	end
	-- "Query failed: run out of attempts" only says that the attempts above
	-- failed; it leads only when nothing more specific was logged.
	if fatal and (#result.errors == 0 or fatal.kind == "usage") then
		table.insert(result.errors, 1, fatal)
	end

	if inv.metric then
		if #data > 0 then
			local ok, doc = pcall(decode, metricJson(data))
			if ok then
				local kind, series, unparsed = SeriesView.readJson(doc)
				result.unparsed += unparsed
				if kind and #series > 0 then
					result.metric = { kind = kind :: SeriesView.Kind, series = series }
					result.kind = "metric"
				end
			else
				result.unparsed += #data
			end
		end
	else
		for _, line in data do
			local entry: Entry?
			if inv.output == "jsonl" then
				entry = jsonlEntry(line, decode)
			elseif inv.output == "raw" then
				entry = { time = nil, labels = nil, line = line }
			else
				entry = defaultEntry(inv, line)
			end
			if entry then
				table.insert(result.entries, entry)
			else
				result.unparsed += 1
			end
		end
		if #result.entries > 0 then
			result.kind = "logs"
			if inv.output == "jsonl" then
				result.common = sharedLabels(result.entries)
			end
		end
	end
	if result.kind == "empty" then
		if #result.errors > 0 then
			result.kind = "error"
		elseif result.unparsed > 0 then
			result.kind = "unreadable"
		end
	end
	return result
end

-- Rendering -----------------------------------------------------------------------------

local ERROR_TITLES: { [ErrorKind]: string } = {
	network = "Cannot reach Loki",
	timeout = "Loki timed out",
	auth = "Not authorized",
	usage = "logcli rejected the arguments",
	query = "Query failed",
}

local LEVEL_ORDER: { Level } = { "critical", "error", "warning", "info", "debug", "unknown" }

local function labelsText(labels: Labels, skip: Labels): string
	local keys: { string } = {}
	for k, v in labels do
		if skip[k] ~= v then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	local parts: { string } = table.create(#keys)
	for i, k in keys do
		parts[i] = k .. "=" .. labels[k]
	end
	return table.concat(parts, " ")
end

local function item(key: string, value: ui.SpanLike): { { ui.SpanLike } }
	return { { key }, { value } }
end

local function summaryItems(inv: Invocation, result: Result): { { { ui.SpanLike } } }
	local items: { { { ui.SpanLike } } } = {}
	table.insert(items, item("Loki", ui.span(inv.addr or "LOKI_ADDR or http://localhost:3100", "mono")))
	local range: string
	if inv.from or inv.to then
		range = (inv.from or "now - " .. (inv.since or "1h")) .. "  to  " .. (inv.to or "now")
	else
		range = "last " .. (inv.since or "1h")
	end
	table.insert(items, item("Range", range))
	if next(result.common) ~= nil then
		table.insert(items, item("Common labels", ui.span(SeriesView.seriesName(result.common), "code")))
	end
	return items
end

local function textCell(s: string, style: string?, title: string?, action: string?): Node
	local cell = Grid.text(s, style)
	local p = cell.p :: { [string]: any }
	if title then
		p.title = title
	end
	if action then
		p.actions = { click = action }
	end
	return cell
end

local function isLevelLabel(name: string): boolean
	return table.find(LEVEL_LABELS, name) ~= nil
end

-- The Stream cell: the entry's labels minus the common ones and, when the
-- Level column shows it, the level labels. The cell's title keeps them all.
local function streamText(labels: Labels, common: Labels, hideLevel: boolean): string
	local shown: Labels = {}
	for k, v in labels do
		if common[k] ~= v and not (hideLevel and isLevelLabel(k)) then
			shown[k] = v
		end
	end
	return labelsText(shown, {})
end

local function logGrid(entries: { Entry }, levels: { Level }, shown: number, common: Labels): Node
	local withTime, withLabels, withLevel = false, false, false
	for i = 1, shown do
		withTime = withTime or entries[i].time ~= nil
		withLevel = withLevel or levels[i] ~= "unknown"
	end
	for i = 1, shown do
		local labels = entries[i].labels
		withLabels = withLabels or (labels ~= nil and streamText(labels, common, withLevel) ~= "")
	end
	local columns: { Grid.Column } = {}
	if withTime then
		table.insert(columns, { head = "Time" })
	end
	if withLevel then
		table.insert(columns, { head = "Level" })
	end
	if withLabels then
		table.insert(columns, { head = "Stream" })
	end
	table.insert(columns, { head = "Line" })
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		local e = entries[i]
		local level = levels[i]
		local cells: { Node } = {}
		if withTime then
			table.insert(cells, Grid.text(e.time or "", "muted"))
		end
		if withLevel then
			table.insert(cells, if level == "unknown" then Grid.text("") else ui.badge(level, LEVEL_TONE[level]))
		end
		if withLabels then
			local labels = e.labels
			local text = if labels then streamText(labels, common, withLevel) else ""
			table.insert(cells, textCell(text, "muted", if labels then labelsText(labels, common) else nil))
		end
		table.insert(cells, textCell(e.line, LINE_STYLE[level], e.line, "copy"))
		rows[i] = { key = "l" .. i, cells = cells }
	end
	return Grid.grid("logs", columns, rows, "tern-grafana.lens-logs")
end

local function levelCounts(levels: { Level }): Node?
	local counts: { [Level]: number } = {}
	for _, l in levels do
		counts[l] = (counts[l] or 0) + 1
	end
	local badges: { Node } = {}
	for _, l in LEVEL_ORDER do
		local n = counts[l]
		if n and l ~= "unknown" then
			table.insert(badges, ui.badge(string.format("%d %s", n, l), LEVEL_TONE[l]))
		end
	end
	return if #badges > 0 then ui.row(badges, { key = "levels" }) else nil
end

local function errorCard(inv: Invocation, result: Result): Node
	local children: { Node } = {}
	for i, e in result.errors do
		table.insert(
			children,
			ui.text({ ui.span(e.message, "error") }, { key = "e" .. i, actions = { click = "copy" }, title = "Copy" })
		)
	end
	local first = result.errors[1]
	if first.kind == "network" or first.kind == "timeout" then
		table.insert(children, ui.muted("Loki: " .. (inv.addr or "LOKI_ADDR or http://localhost:3100")))
	end
	return ui.card({ ui.span(ERROR_TITLES[first.kind], "strong error") }, children, { tone = "error" })
end

local function headSpans(inv: Invocation, result: Result): { ui.SpanLike }
	local count: string
	if result.kind == "logs" then
		count = SeriesView.countText(#result.entries, "line", "lines")
		if inv.limit and #result.entries >= inv.limit then
			count ..= " (limit reached)"
		end
	elseif result.kind == "metric" then
		local metric = result.metric :: Metric
		count = if metric.kind == "scalar" then "scalar" else SeriesView.countText(#metric.series, "series", "series")
	else
		count = "no data"
	end
	return { ui.span("logcli query", "strong"), ui.span("  " .. count, "muted") }
end

-- The native view for a finished capture, or nil for raw.
function M.render(inv: Invocation, result: Result, vs: ViewState): Node?
	local kind = result.kind
	if inv.verb == nil or kind == "unreadable" then
		return nil
	end
	if kind == "error" then
		return errorCard(inv, result)
	end
	local children: { Node } = {}
	table.insert(
		children,
		ui.text({ ui.span(inv.expr or "", "code") }, { key = "expr", actions = { click = "copy" }, title = "Copy" })
	)
	table.insert(children, ui.kv(summaryItems(inv, result)))
	for _, e in result.errors do
		table.insert(children, ui.text({ ui.span(e.message, "error") }))
	end
	if kind == "logs" then
		local entries = result.entries
		local levels: { Level } = table.create(#entries)
		for i, e in entries do
			levels[i] = M.level(e.labels, result.common, e.line)
		end
		local counts = levelCounts(levels)
		if counts then
			table.insert(children, counts)
		end
		local shown = SeriesView.shownCount(#entries, vs)
		table.insert(children, logGrid(entries, levels, shown, result.common))
		SeriesView.overflow(#entries, shown, vs, children)
	elseif kind == "metric" then
		local metric = result.metric :: Metric
		if metric.kind == "matrix" then
			local tools: { Node } = {}
			SeriesView.viewChips(vs, tools)
			table.insert(children, ui.row(tools, { key = "tools" }))
		end
		SeriesView.body(metric.kind, metric.series, vs, SeriesView.commonLabels(metric.series), children)
	else
		table.insert(children, ui.muted("No data", { key = "body" }))
	end
	if result.unparsed > 0 then
		table.insert(
			children,
			ui.muted(
				string.format(
					"%s not shown (Raw shows everything)",
					SeriesView.countText(result.unparsed, "line", "lines")
				)
			)
		)
	end
	return ui.card(headSpans(inv, result), children)
end

-- Lens --------------------------------------------------------------------------------------

export type State = {
	invocation: Invocation,
	lines: { string },
	bytes: number,
	overflow: boolean,
	status: number?,
	view: ViewState,
	result: Result?,
}

function M.open(run: Run): State
	return {
		invocation = M.parseArgs(run.program, run.args),
		lines = {},
		bytes = 0,
		overflow = false,
		status = nil,
		view = SeriesView.defaultView(),
		result = nil,
	}
end

function M.line(state: State, text: string)
	if state.invocation.verb == nil or state.overflow then
		return
	end
	state.bytes += #text + 1
	if #state.lines >= M.MAX_LINES or state.bytes > M.MAX_BYTES then
		state.overflow = true
		state.lines = {}
		return
	end
	table.insert(state.lines, text)
end

function M.finish(state: State, status: number)
	state.status = status
end

local function resultOf(state: State, env: Env): Result
	local cached = state.result
	if cached then
		return cached
	end
	local result = M.build(state.invocation, state.lines, env.decode)
	state.result = result
	return result
end

-- Raw while logcli runs: metric output is JSON, only valid whole, and a log
-- view would jump as batches arrive.
function M.view(state: State, env: Env): Node?
	if state.invocation.verb == nil or state.overflow or state.status == nil then
		return nil
	end
	return M.render(state.invocation, resultOf(state, env), state.view)
end

function M.event(state: State, ev: LensTypes.Event, _env: Env): { Effect }
	if ev.ev == "action" and ev.act == "v" then
		state.view = SeriesView.decodeView(ev.value or "")
	end
	return {}
end

local lens: LensTypes.Lens<State> = {
	open = M.open,
	line = M.line,
	finish = M.finish,
	view = M.view,
	event = M.event,
}
M.lens = lens

return M
