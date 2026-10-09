--!strict
-- Lens for `amtool alert [query]` and `amtool silence [query]`: re-derives
-- what was asked from argv (kingpin flag rules), reads the output in any of
-- amtool's formats (`simple`, the default, `extended`, `json`, and the bare
-- IDs of `silence query -q`) and renders alert and silence grids with
-- severity and state tones, plus an "Open alerts inbox" action. The format
-- is read from the output itself, because amtool's config file can change
-- the default. Anything it cannot read faithfully returns nil, so Tern shows
-- the raw output.
--
-- Output shapes are amtool's (cli/format/format_simple.go,
-- format_extended.go): tabwriter tables padded with at least two spaces
-- (widths counted in runes), and encoding/json of the API v2 models.

local ConfigTypes = require("../config/types")
local EnvModule = require("../env")
local GrafanaUrl = require("../links/grafana_url")
local Grid = require("../render/grid")
local LensTypes = require("./types")
local Normalize = require("../alerts/normalize")
local Scheme = require("../links/scheme")
local Summary = require("../alerts/summary")
local ui = require("../ui")

type Config = ConfigTypes.Config
type Env = EnvModule.Env
type Node = ui.Node
type Run = LensTypes.Run
type Effect = LensTypes.Effect
type Labels = { [string]: string }

local M = {}

-- Rows shown before "Show all", and the hard cap behind it.
M.MAX_ROWS = 50
M.MAX_ALL_ROWS = 500
-- Past these the capture stays raw (memory and the 2 s view budget).
M.MAX_LINES = 20000
M.MAX_BYTES = 8 * 1024 * 1024

-- Invocation ---------------------------------------------------------------------

export type Verb = "alerts" | "silences"

export type Invocation = {
	-- nil: not an amtool query this lens renders (`reason` says why).
	verb: Verb?,
	reason: string?,
	-- --alertmanager.url without userinfo; nil when it comes from amtool's
	-- config file.
	url: string?,
	-- --output as typed; nil for the default (which the config file may set).
	output: string?,
	-- Matcher groups as amtool sends them: a first argument without an
	-- operator reads as `alertname="<arg>"`.
	matchers: { string },
	-- `alert query` state flags given (inhibited, silenced, active, unprocessed).
	states: { string },
	receiver: string?,
	-- `silence query` flags.
	expired: boolean,
	quiet: boolean,
	within: string?,
	created_by: string?,
	id: string?,
}

-- Long flags that take a value (`--name value` or `--name=value`).
local VALUE_FLAGS: { [string]: boolean } = {
	["alertmanager.url"] = true,
	output = true,
	timeout = true,
	["http.config.file"] = true,
	["enable-feature"] = true,
	["date.format"] = true,
	receiver = true,
	["created-by"] = true,
	id = true,
	within = true,
}

local HELP_FLAGS: { [string]: boolean } = {
	help = true,
	["help-long"] = true,
	["help-man"] = true,
	version = true,
	["completion-script-bash"] = true,
	["completion-script-zsh"] = true,
}

-- Short flags: value flags map to their long name, bools to theirs.
local SHORT_VALUE: { [string]: string } = { o = "output", r = "receiver" }
local SHORT_BOOL: { [string]: string } = {
	v = "verbose",
	i = "inhibited",
	s = "silenced",
	a = "active",
	u = "unprocessed",
	q = "quiet",
}

local STATE_FLAGS = { "inhibited", "silenced", "active", "unprocessed" }

-- Subcommands of `alert` and `silence` other than `query`: their output is
-- not a listing.
local OTHER_SUBCOMMANDS: { [string]: { [string]: boolean } } = {
	alert = { add = true },
	silence = { add = true, expire = true, import = true, update = true },
}

local function unsupported(inv: Invocation, reason: string): Invocation
	inv.verb = nil
	inv.reason = reason
	return inv
end

-- The URL with any `user:password@` removed: it is shown and never needed.
function M.withoutUserinfo(url: string): string
	return (string.gsub(url, "^(%a[%w+.-]*://)[^/@?#]*@", "%1"))
end

local function hasOperator(m: string): boolean
	return string.find(m, "^[^=!~]*[=!]") ~= nil
end

local function goQuote(s: string): string
	local escaped = string.gsub(s, '[\\"\n\t]', function(c: string): string
		if c == "\n" then
			return "\\n"
		elseif c == "\t" then
			return "\\t"
		end
		return "\\" .. c
	end)
	return '"' .. escaped .. '"'
end

-- Kingpin rules: flags anywhere after the program, `--name=value`,
-- `--name value`, `-o json`, `-ojson`, bool clusters (`-sa`); `--` ends
-- flags. An unknown flag is left to amtool, which rejects it.
function M.parseArgs(program: string, args: { string }): Invocation
	local inv: Invocation = {
		verb = nil,
		reason = nil,
		url = nil,
		output = nil,
		matchers = {},
		states = {},
		receiver = nil,
		expired = false,
		quiet = false,
		within = nil,
		created_by = nil,
		id = nil,
	}
	if program ~= "amtool" then
		return unsupported(inv, "not amtool")
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
				values[flag] = value
			elseif string.sub(flag, 1, 3) == "no-" then
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
					values[long] = value
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

	local command = positional[1]
	if command ~= "alert" and command ~= "silence" then
		return unsupported(inv, "not an amtool alert or silence query")
	end
	local first = 2
	local sub = positional[2]
	if sub == "query" then
		first = 3
	elseif sub and OTHER_SUBCOMMANDS[command][sub] then
		return unsupported(inv, "amtool " .. command .. " " .. sub .. " is not rendered")
	end
	for k = first, #positional do
		local m = positional[k]
		if k == first and not hasOperator(m) then
			m = "alertname=" .. goQuote(m)
		end
		table.insert(inv.matchers, m)
	end
	local output = values.output
	if output and output ~= "simple" and output ~= "extended" and output ~= "json" then
		return unsupported(inv, "unknown output format " .. output)
	end
	inv.verb = if command == "alert" then "alerts" else "silences"
	inv.output = output
	local url = values["alertmanager.url"]
	inv.url = if url then M.withoutUserinfo(url) else nil
	if command == "alert" then
		for _, s in STATE_FLAGS do
			if bools[s] then
				table.insert(inv.states, s)
			end
		end
		inv.receiver = values.receiver
	else
		inv.expired = bools.expired == true
		inv.quiet = bools.quiet == true
		inv.within = values.within
		inv.created_by = values["created-by"]
		inv.id = values.id
	end
	return inv
end

-- Output ---------------------------------------------------------------------------

export type Alert = {
	name: string,
	-- nil in the simple format, which prints no labels.
	labels: Labels?,
	annotations: Labels?,
	summary: string,
	starts: string,
	ends: string?,
	generator: string?,
	-- Alertmanager's state: "active", "suppressed" or "unprocessed".
	state: string,
	-- Why a suppressed alert is muted ("silenced", "inhibited"), JSON only.
	muted_by: string?,
	-- nil when the output has no labels.
	severity: Normalize.Severity?,
}

export type Silence = {
	id: string,
	matchers: string,
	starts: string?,
	ends: string,
	updated: string?,
	created_by: string,
	comment: string,
	-- "active", "pending" or "expired", JSON only.
	state: string?,
}

export type ErrorKind = "network" | "timeout" | "auth" | "usage" | "query"

export type CliError = { kind: ErrorKind, message: string }

export type Format = "simple" | "extended" | "json" | "quiet"

export type ResultKind = "alerts" | "silences" | "ids" | "empty" | "error" | "unreadable"

export type Result = {
	kind: ResultKind,
	format: Format?,
	alerts: { Alert },
	silences: { Silence },
	ids: { string },
	errors: { CliError },
	warnings: { string },
	-- Non-empty lines that were neither data nor a recognized message.
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

-- Kingpin's and Go's net/http error texts, matched loosely.
function M.errorKind(message: string): ErrorKind
	local lower = string.lower(message)
	if containsAny(lower, { "context deadline exceeded", "timeout", "i/o timeout" }) then
		return "timeout"
	elseif
		containsAny(lower, {
			"connection refused",
			"no such host",
			"dial tcp",
			"network is unreachable",
			"connection reset",
			"tls:",
			"x509:",
			"eof",
		})
	then
		return "network"
	elseif containsAny(lower, { "[401]", "[403]", "unauthorized", "forbidden" }) then
		return "auth"
	elseif
		containsAny(lower, {
			"required flag",
			"unknown long flag",
			"unknown short flag",
			"expected command",
			"unexpected ",
			"try --help",
			"enum value must be",
		})
	then
		return "usage"
	end
	return "query"
end

local function newResult(): Result
	return {
		kind = "empty",
		format = nil,
		alerts = {},
		silences = {},
		ids = {},
		errors = {},
		warnings = {},
		unparsed = 0,
	}
end

-- Tables ----------------------------------------------------------------------------

-- A line as runes (tabwriter pads by rune count); nil for invalid UTF-8.
local function runes(line: string): { string }?
	if utf8.len(line) == nil then
		return nil
	end
	local out: { string } = {}
	for _, code in utf8.codes(line) do
		table.insert(out, utf8.char(code))
	end
	return out
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

type Column = { name: string, start: number }

-- Header cells start after two or more spaces ("Starts At" keeps its one).
local function headerColumns(line: string): { Column }?
	local r = runes(line)
	if r == nil or #r == 0 or r[1] == " " then
		return nil
	end
	local starts: { number } = {}
	for i = 1, #r do
		if r[i] ~= " " and (i == 1 or (i > 2 and r[i - 1] == " " and r[i - 2] == " ")) then
			table.insert(starts, i)
		end
	end
	local cols: { Column } = table.create(#starts)
	for k, s in starts do
		local stop = if starts[k + 1] then starts[k + 1] - 1 else #r
		cols[k] = { name = trim(table.concat(r, "", s, stop)), start = s }
	end
	return cols
end

-- One row cut at the header's column starts; nil when the padding does not
-- line up (a cell holding a newline breaks the table).
local function rowCells(line: string, cols: { Column }): { [string]: string }?
	local r = runes(line)
	if r == nil then
		return nil
	end
	local cells: { [string]: string } = {}
	for k, col in cols do
		local start = col.start
		if k > 1 and #r >= start and (r[start - 1] ~= " " or r[start - 2] ~= " ") then
			return nil
		end
		local nextCol = cols[k + 1]
		local stop = math.min(#r, if nextCol then nextCol.start - 1 else #r)
		cells[col.name] = if start <= stop then trim(table.concat(r, "", start, stop)) else ""
	end
	return cells
end

-- `name="value" name="value"` as extended output prints labels and
-- annotations: values are not escaped, so a value ends at the quote before
-- ` <name>="` or the end.
function M.parsePairs(s: string): Labels?
	local out: Labels = {}
	local pos = 1
	local n = #s
	while pos <= n do
		local name = string.match(s, "^[%a_][%w_]*", pos)
		if name == nil or string.sub(s, pos + #name, pos + #name + 1) ~= '="' then
			return nil
		end
		local vstart = pos + #name + 2
		local search = vstart
		local vend: number? = nil
		while true do
			local q = string.find(s, '"', search, true)
			if q == nil then
				break
			end
			if q == n or string.find(s, '^ [%a_][%w_]*="', q + 1) then
				vend = q
				break
			end
			search = q + 1
		end
		if vend == nil then
			return nil
		end
		out[name] = string.sub(s, vstart, vend - 1)
		pos = vend + 2
	end
	return out
end

local function severityOf(labels: Labels?): Normalize.Severity?
	return if labels then Normalize.severity(labels) else nil
end

local function parseAlertTable(cols: { Column }, rows: { string }, result: Result)
	local extended = cols[1].name == "Labels"
	result.format = if extended then "extended" else "simple"
	for _, line in rows do
		local cells = rowCells(line, cols)
		local state = if cells then cells["State"] else nil
		if cells == nil or state == nil or state == "" then
			result.unparsed += 1
			continue
		end
		local alert: Alert
		if extended then
			local labels = M.parsePairs(cells["Labels"] or "")
			local annotations = M.parsePairs(cells["Annotations"] or "")
			if labels == nil or annotations == nil then
				result.unparsed += 1
				continue
			end
			alert = {
				name = labels.alertname or "",
				labels = labels,
				annotations = annotations,
				summary = annotations.summary or "",
				starts = cells["Starts At"] or "",
				ends = cells["Ends At"],
				generator = cells["Generator URL"],
				state = state,
				muted_by = nil,
				severity = severityOf(labels),
			}
		else
			alert = {
				name = cells["Alertname"] or "",
				labels = nil,
				annotations = nil,
				summary = cells["Summary"] or "",
				starts = cells["Starts At"] or "",
				ends = nil,
				generator = nil,
				state = state,
				muted_by = nil,
				severity = nil,
			}
		end
		table.insert(result.alerts, alert)
	end
	result.kind = "alerts"
end

local function parseSilenceTable(cols: { Column }, rows: { string }, result: Result)
	result.format = if cols[3] and cols[3].name == "Starts At" then "extended" else "simple"
	for _, line in rows do
		local cells = rowCells(line, cols)
		local id = if cells then cells["ID"] else nil
		if cells == nil or id == nil or id == "" then
			result.unparsed += 1
			continue
		end
		table.insert(result.silences, {
			id = id,
			matchers = cells["Matchers"] or "",
			starts = cells["Starts At"],
			ends = cells["Ends At"] or "",
			updated = cells["Updated At"],
			created_by = cells["Created By"] or "",
			comment = cells["Comment"] or "",
			state = nil,
		})
	end
	result.kind = "silences"
end

-- JSON ------------------------------------------------------------------------------

-- `2026-10-09T20:16:30.000Z` as amtool's default date format prints it.
function M.isoText(v: any): string
	if type(v) ~= "string" then
		return ""
	end
	local date, clock = string.match(v, "^(%d+%-%d+%-%d+)T(%d+:%d+:%d+)[%.%d]*Z$")
	if date and clock then
		return date .. " " .. clock .. " UTC"
	end
	return v
end

local function stringMap(v: any): Labels?
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

local function nonEmptyList(v: any): boolean
	return type(v) == "table" and v[1] ~= nil
end

local function str(v: any): string
	return if type(v) == "string" then v else ""
end

local function jsonAlert(e: any): Alert?
	if type(e) ~= "table" then
		return nil
	end
	local labels = stringMap(e.labels)
	if labels == nil then
		return nil
	end
	local annotations: Labels = stringMap(e.annotations) or {}
	local status = if type(e.status) == "table" then e.status else {}
	local mutedBy: string? = nil
	if nonEmptyList(status.silencedBy) then
		mutedBy = "silenced"
	elseif nonEmptyList(status.inhibitedBy) then
		mutedBy = "inhibited"
	end
	return {
		name = labels.alertname or "",
		labels = labels,
		annotations = annotations,
		summary = annotations.summary or "",
		starts = M.isoText(e.startsAt),
		ends = M.isoText(e.endsAt),
		generator = if type(e.generatorURL) == "string" and e.generatorURL ~= "" then e.generatorURL else nil,
		state = str(status.state),
		muted_by = mutedBy,
		severity = Normalize.severity(labels),
	}
end

-- labels.Matcher.String() of an API matcher.
local function matcherText(m: any): string?
	if type(m) ~= "table" or type(m.name) ~= "string" or type(m.value) ~= "string" then
		return nil
	end
	local isEqual = m.isEqual ~= false
	local op = if m.isRegex == true then (if isEqual then "=~" else "!~") elseif isEqual then "=" else "!="
	return m.name .. op .. goQuote(m.value)
end

local function jsonSilence(e: any): Silence?
	if type(e) ~= "table" or type(e.id) ~= "string" or type(e.matchers) ~= "table" then
		return nil
	end
	local parts: { string } = {}
	for _, m in e.matchers do
		local text = matcherText(m)
		if text == nil then
			return nil
		end
		table.insert(parts, text)
	end
	local status = if type(e.status) == "table" then e.status else {}
	return {
		id = e.id,
		matchers = table.concat(parts, " "),
		starts = M.isoText(e.startsAt),
		ends = M.isoText(e.endsAt),
		updated = M.isoText(e.updatedAt),
		created_by = str(e.createdBy),
		comment = str(e.comment),
		state = if type(status.state) == "string" then status.state else nil,
	}
end

local function parseJson(inv: Invocation, doc: any, result: Result)
	result.format = "json"
	if type(doc) ~= "table" then
		result.unparsed += 1
		return
	end
	for _, e in doc do
		if inv.verb == "alerts" then
			local a = jsonAlert(e)
			if a then
				table.insert(result.alerts, a)
			else
				result.unparsed += 1
			end
		else
			local s = jsonSilence(e)
			if s then
				table.insert(result.silences, s)
			else
				result.unparsed += 1
			end
		end
	end
	result.kind = if inv.verb == "alerts" then "alerts" else "silences"
end

-- Reads a finished capture. `decode` is the JSON decoder (tern.json.decode on
-- the host).
function M.build(inv: Invocation, lines: { string }, decode: (string) -> any): Result
	local result = newResult()
	local verb = inv.verb
	if verb == nil then
		result.kind = "unreadable"
		return result
	end
	local data: { string } = {}
	for _, line in lines do
		if string.find(line, "^%s*$") then
			continue
		end
		local err = string.match(line, "^amtool: error: (.*)$")
		local warning = string.match(line, "^Warning: (.*)$")
		if err then
			table.insert(result.errors, { kind = M.errorKind(err), message = err })
		elseif warning then
			table.insert(result.warnings, warning)
		else
			table.insert(data, line)
		end
	end
	local head = data[1]
	if head then
		local cols = if string.sub(head, 1, 1) == "[" then nil else headerColumns(head)
		local rest = table.move(data, 2, #data, 1, {})
		if string.sub(head, 1, 1) == "[" then
			local ok, doc = pcall(decode, table.concat(data, "\n"))
			if ok then
				parseJson(inv, doc, result)
			else
				result.unparsed += #data
			end
		elseif verb == "alerts" and cols and (cols[1].name == "Alertname" or cols[1].name == "Labels") then
			parseAlertTable(cols, rest, result)
		elseif verb == "silences" and cols and cols[1].name == "ID" and cols[2] and cols[2].name == "Matchers" then
			parseSilenceTable(cols, rest, result)
		elseif verb == "silences" and inv.quiet then
			result.format = "quiet"
			for _, line in data do
				if string.match(line, "^[%w%-]+$") then
					table.insert(result.ids, line)
				else
					result.unparsed += 1
				end
			end
			result.kind = "ids"
		else
			result.unparsed += #data
		end
	end
	local hasData = #result.alerts > 0 or #result.silences > 0 or #result.ids > 0
	if not hasData then
		if #result.errors > 0 then
			result.kind = "error"
		elseif result.unparsed > 0 then
			result.kind = "unreadable"
		elseif result.kind ~= "alerts" and result.kind ~= "silences" and result.kind ~= "ids" then
			result.kind = "empty"
		end
	end
	return result
end

-- Links -----------------------------------------------------------------------------

local function sortedContexts(cfg: Config): { string }
	local names: { string } = {}
	for name in cfg.contexts do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

local function samePlace(a: GrafanaUrl.ParsedUrl, b: GrafanaUrl.ParsedUrl): boolean
	return a.scheme == b.scheme and a.authority == b.authority
end

-- The configured context amtool's Alertmanager URL belongs to: a context
-- whose alertmanager endpoint is that URL, else one whose Grafana serves it
-- (`<grafana>/api/alertmanager/<grafana|uid>`).
function M.contextFor(url: string?, cfg: Config?): string?
	if url == nil or cfg == nil then
		return nil
	end
	local target = GrafanaUrl.parse(url)
	if target == nil then
		return nil
	end
	local names = sortedContexts(cfg)
	for _, name in names do
		local am = cfg.contexts[name].alertmanager
		local base = if am then GrafanaUrl.parse(am.url .. am.path_prefix) else nil
		if base and samePlace(base, target) and base.path == target.path then
			return name
		end
	end
	for _, name in names do
		local g = cfg.contexts[name].grafana
		local base = if g then GrafanaUrl.parse(g.url .. g.path_prefix) else nil
		if base and samePlace(base, target) then
			local prefix = string.gsub(base.path, "%p", "%%%0")
			if string.match(target.path, "^" .. prefix .. "/api/alertmanager/[^/]+$") then
				return name
			end
		end
	end
	return nil
end

local function alertsLink(context: string?, filter: string?): string?
	local params: { [string]: string } = {}
	if context then
		params.context = context
	end
	if filter then
		params.filter = filter
	end
	local link: Scheme.Link = { action = "alerts", params = params, vars = {} }
	return if Scheme.validate(link) then Scheme.encode(link) else nil
end

-- `tern-grafana://alerts?...` for the run (filtered by its matchers), or for
-- one alert of it (`alertname="..."`).
function M.inboxLink(inv: Invocation, cfg: Config?, alert: Alert?): string?
	local context = M.contextFor(inv.url, cfg)
	local filter: string? = nil
	if alert and alert.name ~= "" then
		filter = "alertname=" .. goQuote(alert.name)
	elseif alert == nil and inv.verb == "alerts" and #inv.matchers > 0 then
		filter = table.concat(inv.matchers, " ")
	end
	-- A filter Tern links cannot carry falls back to the unfiltered inbox.
	return (filter and alertsLink(context, filter)) or alertsLink(context, nil)
end

-- View state --------------------------------------------------------------------------

-- Carried whole in every action ("v=all:1"), so a click on a rehydrated lens
-- lands on the same view.
export type ViewState = { all: boolean }

function M.defaultView(): ViewState
	return { all = false }
end

function M.encodeView(vs: ViewState): string
	return if vs.all then "all:1" else ""
end

-- Unknown fields are ignored (actions from another plugin version).
function M.decodeView(s: string): ViewState
	local vs = M.defaultView()
	for part in string.gmatch(s, "[^;]+") do
		local k, v = string.match(part, "^([^:]+):(.*)$")
		if k == "all" then
			vs.all = v == "1"
		end
	end
	return vs
end

-- Rendering -----------------------------------------------------------------------------

local ERROR_TITLES: { [ErrorKind]: string } = {
	network = "Cannot reach Alertmanager",
	timeout = "Alertmanager timed out",
	auth = "Not authorized",
	usage = "amtool rejected the arguments",
	query = "Query failed",
}

-- Alertmanager's state, refined by JSON's silencedBy/inhibitedBy.
function M.stateText(a: Alert): string
	if a.state == "suppressed" and a.muted_by then
		return a.muted_by
	end
	return a.state
end

function M.stateTone(a: Alert): string
	if a.state == "active" then
		return "error"
	elseif a.state == "unprocessed" then
		return "warning"
	end
	return "muted"
end

function M.severityTone(a: Alert): string
	if a.state ~= "active" then
		return "muted"
	end
	return Summary.tone(a.severity or "none")
end

local SILENCE_TONE: { [string]: string } = { active = "accent", pending = "info", expired = "muted" }

local function countText(n: number, one: string, many: string): string
	return string.format("%d %s", n, if n == 1 then one else many)
end

local function chip(text: string, action: string, title: string?): Node
	return ui.badge(text, "neutral", { actions = { click = action }, title = title })
end

local function shownCount(total: number, vs: ViewState): number
	return math.min(total, if vs.all then M.MAX_ALL_ROWS else M.MAX_ROWS)
end

local function overflowNodes(total: number, shown: number, vs: ViewState, out: { Node })
	if total <= shown then
		return
	end
	if not vs.all then
		table.insert(
			out,
			ui.row({
				ui.muted(string.format("%d more", total - shown)),
				chip(string.format("Show all %d", total), "v=" .. M.encodeView({ all = true })),
			})
		)
	else
		table.insert(out, ui.muted(string.format("... %d more (Raw shows everything)", total - shown)))
	end
end

-- Labels worth a column: not alertname or severity (shown already), not
-- Grafana's or Prometheus' reserved `__x__` names.
local function labelText(labels: Labels): string
	local keys: { string } = {}
	for k in labels do
		if k ~= "alertname" and k ~= "severity" and not Normalize.isInternal(k) then
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

local function textCell(s: string, style: string?, title: string?): Node
	local cell = Grid.text(s, style)
	if title then
		(cell.p :: any).title = title
	end
	return cell
end

local function alertGrid(alerts: { Alert }, shown: number): Node
	local withLabels = alerts[1] ~= nil and alerts[1].labels ~= nil
	local columns: { Grid.Column } = {}
	if withLabels then
		table.insert(columns, { head = "Severity" })
	end
	table.insert(columns, { head = "Alert" })
	table.insert(columns, { head = "State" })
	table.insert(columns, { head = "Starts At" })
	table.insert(columns, { head = "Summary" })
	if withLabels then
		table.insert(columns, { head = "Labels" })
	end
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		local a = alerts[i]
		local cells: { Node } = {}
		local labels = a.labels
		if withLabels then
			local sev = a.severity or "none"
			table.insert(cells, ui.badge(sev, M.severityTone(a)))
		end
		table.insert(cells, textCell(a.name, "strong"))
		table.insert(cells, ui.badge(M.stateText(a), M.stateTone(a)))
		table.insert(cells, Grid.text(a.starts, "muted"))
		table.insert(cells, textCell(a.summary, nil, a.summary))
		if withLabels then
			local text = if labels then labelText(labels) else ""
			table.insert(cells, textCell(text, "muted", text))
		end
		rows[i] = { key = "a" .. i, cells = cells, action = "inbox=" .. i }
	end
	return Grid.grid("alerts", columns, rows, "tern-grafana.lens-alerts")
end

local function silenceGrid(silences: { Silence }, shown: number, inv: Invocation, extended: boolean): Node
	local withState = silences[1] ~= nil and silences[1].state ~= nil
	local columns: { Grid.Column } = { { head = "ID" }, { head = "Matchers" } }
	if withState then
		table.insert(columns, { head = "State" })
	end
	if extended then
		table.insert(columns, { head = "Starts At" })
	end
	table.insert(columns, { head = if inv.expired then "Ended At" else "Ends At" })
	table.insert(columns, { head = "Created By" })
	table.insert(columns, { head = "Comment" })
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		local s = silences[i]
		local cells: { Node } = {
			textCell(string.sub(s.id, 1, 8), "code", s.id),
			textCell(s.matchers, "code", s.matchers),
		}
		if withState then
			local state = s.state or ""
			table.insert(cells, ui.badge(state, SILENCE_TONE[state] or "neutral"))
		end
		if extended then
			table.insert(cells, Grid.text(s.starts or "", "muted"))
		end
		table.insert(cells, Grid.text(s.ends, "muted"))
		table.insert(cells, Grid.text(s.created_by))
		table.insert(cells, textCell(s.comment, nil, s.comment))
		rows[i] = { key = "s" .. i, cells = cells, action = "id=" .. i }
	end
	return Grid.grid("silences", columns, rows, "tern-grafana.lens-silences")
end

local function idGrid(ids: { string }, shown: number): Node
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		rows[i] = { key = "i" .. i, cells = { Grid.text(ids[i], "code") }, action = "id=" .. i }
	end
	return Grid.grid("ids", { { head = "ID" } }, rows, "tern-grafana.lens-silences")
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
	if (first.kind == "network" or first.kind == "timeout") and inv.url then
		table.insert(children, ui.muted("Alertmanager: " .. inv.url))
	end
	return ui.card({ ui.span(ERROR_TITLES[first.kind], "strong error") }, children, { tone = "error" })
end

local function item(key: string, value: ui.SpanLike): { { ui.SpanLike } }
	return { { key }, { value } }
end

local function summaryItems(inv: Invocation): { { { ui.SpanLike } } }
	local items: { { { ui.SpanLike } } } = {}
	table.insert(items, item("Alertmanager", ui.span(inv.url or "from amtool's config file", "mono")))
	if #inv.matchers > 0 then
		table.insert(items, item("Matchers", ui.span(table.concat(inv.matchers, " "), "code")))
	end
	if inv.verb == "alerts" then
		local states = if #inv.states > 0 then table.concat(inv.states, ", ") else "active"
		table.insert(items, item("Showing", states))
		if inv.receiver then
			table.insert(items, item("Receiver", ui.span(inv.receiver, "code")))
		end
	else
		local showing = if inv.expired then "expired" else "active and pending"
		if inv.within then
			showing ..= (if inv.expired then ", ended within " else ", ending within ") .. inv.within
		end
		table.insert(items, item("Showing", showing))
		if inv.created_by then
			table.insert(items, item("Created by", inv.created_by))
		end
		if inv.id then
			table.insert(items, item("ID", ui.span(inv.id, "code")))
		end
	end
	return items
end

local function headSpans(inv: Invocation, result: Result): { ui.SpanLike }
	local title = if inv.verb == "alerts" then "amtool alert query" else "amtool silence query"
	local count = if result.kind == "alerts"
		then countText(#result.alerts, "alert", "alerts")
		elseif result.kind == "silences" then countText(#result.silences, "silence", "silences")
		elseif result.kind == "ids" then countText(#result.ids, "silence", "silences")
		elseif inv.verb == "alerts" then "no alerts"
		else "no silences"
	return { ui.span(title, "strong"), ui.span("  " .. count, "muted") }
end

-- The native view for a finished capture, or nil for raw.
function M.render(inv: Invocation, result: Result, vs: ViewState, cfg: Config?): Node?
	local kind = result.kind
	if inv.verb == nil or kind == "unreadable" then
		return nil
	end
	if kind == "error" then
		return errorCard(inv, result)
	end
	local children: { Node } = { ui.kv(summaryItems(inv)) }
	local tools: { Node } = {}
	local link = M.inboxLink(inv, cfg, nil)
	if link then
		table.insert(tools, chip("Open alerts inbox", "inbox", link))
	end
	if inv.url and M.contextFor(inv.url, cfg) == nil then
		table.insert(tools, ui.muted("no configured context serves this Alertmanager; opens the default context"))
	end
	if #tools > 0 then
		table.insert(children, ui.row(tools, { key = "tools" }))
	end
	for _, w in result.warnings do
		table.insert(children, ui.text({ ui.span(w, "warning") }))
	end
	for _, e in result.errors do
		table.insert(children, ui.text({ ui.span(e.message, "error") }))
	end

	if kind == "empty" then
		table.insert(children, ui.muted(if inv.verb == "alerts" then "No alerts" else "No silences", { key = "body" }))
	elseif kind == "alerts" then
		local total = #result.alerts
		if total == 0 then
			table.insert(children, ui.muted("No alerts", { key = "body" }))
		else
			local shown = shownCount(total, vs)
			table.insert(children, alertGrid(result.alerts, shown))
			overflowNodes(total, shown, vs, children)
			if result.format == "simple" then
				table.insert(children, ui.muted("Severity and labels need -o extended or -o json"))
			end
		end
	elseif kind == "silences" then
		local total = #result.silences
		if total == 0 then
			table.insert(children, ui.muted("No silences", { key = "body" }))
		else
			local shown = shownCount(total, vs)
			table.insert(children, silenceGrid(result.silences, shown, inv, result.format == "extended"))
			overflowNodes(total, shown, vs, children)
		end
	else
		local shown = shownCount(#result.ids, vs)
		table.insert(children, idGrid(result.ids, shown))
		overflowNodes(#result.ids, shown, vs, children)
	end
	if result.unparsed > 0 then
		table.insert(
			children,
			ui.muted(string.format("%s not shown (Raw shows everything)", countText(result.unparsed, "line", "lines")))
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
		view = M.defaultView(),
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

-- Raw while amtool runs: it prints everything at the end, and JSON is only
-- valid whole.
function M.view(state: State, env: Env): Node?
	if state.invocation.verb == nil or state.overflow or state.status == nil then
		return nil
	end
	return M.render(state.invocation, resultOf(state, env), state.view, env.config)
end

local function indexOf(value: string?): number?
	local n = tonumber(value or "")
	return if n and n >= 1 and n == math.floor(n) then n else nil
end

function M.event(state: State, ev: LensTypes.Event, env: Env): { Effect }
	if ev.ev ~= "action" or state.invocation.verb == nil then
		return {}
	end
	if ev.act == "v" then
		state.view = M.decodeView(ev.value or "")
		return {}
	end
	local result = resultOf(state, env)
	if ev.act == "inbox" then
		local index = indexOf(ev.value)
		local alert = if index then result.alerts[index] else nil
		local link = M.inboxLink(state.invocation, env.config, alert)
		if link then
			return { { kind = "open", target = link } }
		end
		return { { kind = "toast", level = "error", text = "Cannot open the alerts inbox" } }
	elseif ev.act == "id" then
		local index = indexOf(ev.value)
		local silence = if index then result.silences[index] else nil
		local id = if silence then silence.id elseif index then result.ids[index] else nil
		if id then
			return {
				{ kind = "copy", text = id },
				{ kind = "toast", level = "info", text = "Copied silence ID", sub = id },
			}
		end
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
