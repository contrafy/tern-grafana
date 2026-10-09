--!strict
-- Lens for `promtool query instant|range|series|labels`: re-derives what was
-- asked from argv (kingpin flag rules), reads the output in either format
-- (`-o promql`, the default, or `-o json`) and renders it natively: a
-- per-series spark grid for range queries, a table for instant vectors,
-- label sets for `series`, values for `labels`, and an error card for
-- `query error:` lines. Anything it cannot read faithfully returns nil, so
-- Tern shows the raw output.
--
-- Output shapes are promtool's (cmd/promtool/query.go): the default printer
-- writes prometheus/common model values with String(), the json printer
-- encodes the same values with encoding/json.

local ConfigTypes = require("../config/types")
local EnvModule = require("../env")
local Format = require("../units/format")
local Frame = require("../frame/types")
local GrafanaUrl = require("../links/grafana_url")
local Grid = require("../render/grid")
local LensTypes = require("./types")
local Lttb = require("../time/lttb")
local Range = require("../time/range")
local Scheme = require("../links/scheme")
local TableView = require("../render/table")
local ui = require("../ui")

type Config = ConfigTypes.Config
type Env = EnvModule.Env
type Node = ui.Node
type Run = LensTypes.Run
type Effect = LensTypes.Effect
type Labels = { [string]: string }

local M = {}

-- Bars in one spark; a spark bar is 4 px, so 60 fit a narrow pane.
M.MAX_SPARK = 60
-- Rows shown before "Show all", and the hard cap behind it.
M.MAX_ROWS = 50
M.MAX_ALL_ROWS = 500
-- Past these the capture stays raw (memory and the 2 s view budget).
M.MAX_LINES = 50000
M.MAX_BYTES = 8 * 1024 * 1024
-- promtool's range defaults: end = now, start = end - 5m.
local DEFAULT_RANGE_MS = 5 * 60 * 1000
-- The window an instant query at --time opens with in the Query block.
local INSTANT_WINDOW_MS = 60 * 60 * 1000

-- Invocation ---------------------------------------------------------------------

export type Verb = "instant" | "range" | "series" | "labels"

export type Invocation = {
	-- nil: not a promtool query this lens renders (`reason` says why).
	verb: Verb?,
	reason: string?,
	server: string?,
	expr: string?,
	-- `query labels <server> <name>`.
	label: string?,
	-- `--match` selectors (series, labels).
	matches: { string },
	format: "promql" | "json",
	-- Raw flag values as typed: --time, --start, --end, --step.
	time: string?,
	start: string?,
	stop: string?,
	step: string?,
}

-- Long flags that take a value (`--name value` or `--name=value`).
local VALUE_FLAGS: { [string]: boolean } = {
	format = true,
	["http.config.file"] = true,
	time = true,
	header = true,
	start = true,
	["end"] = true,
	step = true,
	match = true,
	["enable-feature"] = true,
}

-- Flags whose output is help or a version banner, never a query result.
local HELP_FLAGS: { [string]: boolean } = {
	help = true,
	["help-long"] = true,
	["help-man"] = true,
	version = true,
	["completion-script-bash"] = true,
	["completion-script-zsh"] = true,
}

local SHORT_VALUE: { [string]: string } = { o = "format" }

-- Positional arguments after `query <verb>`.
local ARITY: { [string]: number } = { instant = 2, range = 2, series = 1, labels = 2 }

local function unsupported(inv: Invocation, reason: string): Invocation
	inv.verb = nil
	inv.reason = reason
	return inv
end

-- Kingpin rules: flags anywhere after the program, `--name=value`,
-- `--name value`, `-o json`, `-ojson`; `--` ends flags. An unknown flag is
-- left to promtool, which rejects it (the output then says so).
function M.parseArgs(program: string, args: { string }): Invocation
	local inv: Invocation = {
		verb = nil,
		reason = nil,
		server = nil,
		expr = nil,
		label = nil,
		matches = {},
		format = "promql",
		time = nil,
		start = nil,
		stop = nil,
		step = nil,
	}
	if program ~= "promtool" then
		return unsupported(inv, "not promtool")
	end
	local positional: { string } = {}
	local flags: { [string]: string } = {}
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
			local value: string? = inlineValue
			if inline == nil and VALUE_FLAGS[flag] then
				i += 1
				value = args[i]
				if value == nil then
					return unsupported(inv, "--" .. flag .. " has no value")
				end
			end
			if HELP_FLAGS[flag] then
				return unsupported(inv, "help output")
			elseif flag == "match" and value ~= nil then
				table.insert(inv.matches, value)
			elseif value ~= nil then
				flags[flag] = value
			end
		else
			local letter = string.sub(a, 2, 2)
			if letter == "h" then
				return unsupported(inv, "help output")
			end
			local long = SHORT_VALUE[letter]
			if long then
				local value: string? = string.sub(a, 3)
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
				flags[long] = value
			end
		end
		i += 1
	end

	if positional[1] ~= "query" then
		return unsupported(inv, "not a promtool query")
	end
	local verb = positional[2]
	local arity = if verb then ARITY[verb] else nil
	if verb == nil or arity == nil then
		return unsupported(inv, "promtool query " .. (verb or "") .. " is not rendered")
	end
	if #positional ~= 2 + arity then
		-- An unquoted expression split into several words; promtool refuses it.
		return unsupported(inv, "unexpected arguments")
	end
	local format = flags.format or "promql"
	if format ~= "promql" and format ~= "json" then
		return unsupported(inv, "unknown output format " .. format)
	end
	inv.verb = verb :: Verb
	inv.format = format :: "promql" | "json"
	inv.server = positional[3]
	if verb == "instant" or verb == "range" then
		inv.expr = positional[4]
	elseif verb == "labels" then
		inv.label = positional[4]
	end
	inv.time = flags.time
	inv.start = flags.start
	inv.stop = flags["end"]
	inv.step = flags.step
	return inv
end

-- Output ---------------------------------------------------------------------------

export type Series = { labels: Labels, times: { number }, values: { number } }

export type ErrorKind = "network" | "timeout" | "auth" | "query" | "usage"

export type QueryError = { kind: ErrorKind, message: string }

export type ResultKind =
	"vector"
	| "matrix"
	| "scalar"
	| "series"
	| "labels"
	| "empty"
	| "error"
	-- Output this lens cannot read (raw is shown).
	| "unreadable"

export type Result = {
	kind: ResultKind,
	series: { Series },
	label_sets: { Labels },
	values: { string },
	errors: { QueryError },
	-- Non-empty lines that were neither data nor a recognized error.
	unparsed: number,
}

local ERROR_PATTERNS: { { pattern: string, kind: ErrorKind? } } = {
	{ pattern = "^query error: (.*)$", kind = nil },
	{ pattern = "^error creating API client: (.*)$", kind = nil },
	{ pattern = "^(error parsing .*)$", kind = "usage" },
	{ pattern = "^promtool: error: (.*)$", kind = "usage" },
}

local function containsAny(text: string, needles: { string }): boolean
	for _, n in needles do
		if string.find(text, n, 1, true) then
			return true
		end
	end
	return false
end

-- Go's net/http and client_golang error texts, matched loosely.
local function errorKind(message: string): ErrorKind
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
	elseif containsAny(lower, { "401", "403", "unauthorized", "forbidden" }) then
		return "auth"
	end
	return "query"
end

function M.errorOf(line: string): QueryError?
	for _, p in ERROR_PATTERNS do
		local message = string.match(line, p.pattern)
		if message then
			return { kind = p.kind or errorKind(message), message = message }
		end
	end
	return nil
end

local ESCAPES: { [string]: string } = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" }

-- A Go %q string starting at `pos` (the opening quote): value and the
-- position after the closing quote.
local function readQuoted(s: string, pos: number): (string?, number)
	if string.sub(s, pos, pos) ~= '"' then
		return nil, pos
	end
	local parts: { string } = {}
	local i = pos + 1
	local n = #s
	while i <= n do
		local c = string.sub(s, i, i)
		if c == '"' then
			return table.concat(parts), i + 1
		elseif c == "\\" then
			local e = string.sub(s, i + 1, i + 1)
			local simple = ESCAPES[e]
			if simple then
				table.insert(parts, simple)
				i += 2
			elseif e == "x" then
				local hex = string.match(s, "^%x%x", i + 2)
				if hex == nil then
					return nil, pos
				end
				table.insert(parts, string.char(tonumber(hex, 16) :: number))
				i += 4
			elseif e == "u" or e == "U" then
				local width = if e == "u" then 4 else 8
				local hex = string.match(s, "^" .. string.rep("%x", width), i + 2)
				if hex == nil then
					return nil, pos
				end
				table.insert(parts, utf8.char(tonumber(hex, 16) :: number))
				i += 2 + width
			else
				return nil, pos
			end
		else
			table.insert(parts, c)
			i += 1
		end
	end
	return nil, pos
end

-- `name{a="b", c="d"}`, `{a="b"}`, `name`, or the UTF-8 form
-- `{"my.metric", "a.b"="c"}`: labels and the position after the metric.
function M.parseMetric(s: string, start: number?): (Labels?, number)
	local pos = start or 1
	local labels: Labels = {}
	local name = string.match(s, "^[%a_:][%w_:]*", pos)
	if name then
		labels.__name__ = name
		pos += #name
	end
	if string.sub(s, pos, pos) ~= "{" then
		return if name then labels else nil, pos
	end
	pos += 1
	while true do
		pos = (string.find(s, "[^ ]", pos) or #s + 1) :: number
		local c = string.sub(s, pos, pos)
		if c == "}" then
			return labels, pos + 1
		end
		local key: string?
		local quoted = c == '"'
		if quoted then
			key, pos = readQuoted(s, pos)
		else
			key = string.match(s, "^[%a_][%w_]*", pos)
			if key then
				pos += #key
			end
		end
		if key == nil then
			return nil, pos
		end
		if string.sub(s, pos, pos) == "=" then
			local value
			value, pos = readQuoted(s, pos + 1)
			if value == nil then
				return nil, pos
			end
			labels[key] = value
		elseif quoted then
			labels.__name__ = key
		else
			return nil, pos
		end
		local sep = string.sub(s, pos, pos)
		if sep == "," then
			pos += 1
		elseif sep ~= "}" then
			return nil, pos
		end
	end
end

-- model.SampleValue.String(): strconv 'f' formatting, NaN, +Inf, -Inf.
local function sampleValue(text: string): number?
	if text == "NaN" then
		return 0 / 0
	elseif text == "+Inf" then
		return math.huge
	elseif text == "-Inf" then
		return -math.huge
	elseif string.match(text, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*$") then
		return tonumber(text)
	end
	return nil
end

-- Unix seconds (model.Time.String(), or a JSON number) to epoch ms.
local function secondsToMs(v: any): number?
	local n = if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
	if n == nil or n ~= n then
		return nil
	end
	return math.floor(n * 1000 + 0.5)
end

-- `<value> @[<seconds>]`.
local function parseSample(text: string): (number?, number?)
	local v, ts = string.match(text, "^(%S+) @%[([%d%.]+)%]$")
	if v == nil or ts == nil then
		return nil, nil
	end
	local value = sampleValue(v)
	local t = secondsToMs(ts)
	if value == nil or t == nil then
		return nil, nil
	end
	return t, value
end

local function newResult(): Result
	return { kind = "empty", series = {}, label_sets = {}, values = {}, errors = {}, unparsed = 0 }
end

local function parseTextQuery(lines: { string }, result: Result)
	local current: Series? = nil
	local sawVector, sawMatrix, sawScalar = false, false, false
	for _, line in lines do
		local scalarText = string.match(line, "^scalar: (.*)$")
		if scalarText then
			local t, v = parseSample(scalarText)
			if t and v then
				table.insert(result.series, { labels = {}, times = { t }, values = { v } })
				sawScalar = true
				current = nil
				continue
			end
		end
		local labels, pos = M.parseMetric(line, 1)
		if labels then
			local rest = string.sub(line, pos)
			if rest == " =>" then
				local s: Series = { labels = labels, times = {}, values = {} }
				table.insert(result.series, s)
				current = s
				sawMatrix = true
				continue
			end
			local sampleText = string.match(rest, "^ => (.*)$")
			if sampleText then
				local t, v = parseSample(sampleText)
				if t and v then
					table.insert(result.series, { labels = labels, times = { t }, values = { v } })
					sawVector = true
					current = nil
					continue
				end
			end
		end
		local cur = current
		if cur then
			local t, v = parseSample(line)
			if t and v then
				table.insert(cur.times, t)
				table.insert(cur.values, v)
				continue
			end
		end
		result.unparsed += 1
	end
	if sawMatrix then
		result.kind = "matrix"
	elseif sawVector then
		result.kind = "vector"
	elseif sawScalar then
		result.kind = "scalar"
	end
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

local function jsonSample(pair: any): (number?, number?)
	if type(pair) ~= "table" or type(pair[2]) ~= "string" then
		return nil, nil
	end
	local t = secondsToMs(pair[1])
	local v = sampleValue(pair[2])
	if t == nil or v == nil then
		return nil, nil
	end
	return t, v
end

local function parseJsonQuery(doc: any, result: Result)
	if type(doc) ~= "table" then
		result.unparsed += 1
		return
	end
	if type(doc[1]) == "number" then
		local t, v = jsonSample(doc)
		if t and v then
			table.insert(result.series, { labels = {}, times = { t }, values = { v } })
			result.kind = "scalar"
		else
			result.unparsed += 1
		end
		return
	end
	for _, entry in doc do
		local labels = if type(entry) == "table" then stringLabels(entry.metric) else nil
		if labels == nil then
			result.unparsed += 1
			continue
		end
		if type(entry.values) == "table" then
			local s: Series = { labels = labels, times = {}, values = {} }
			for _, pair in entry.values do
				local t, v = jsonSample(pair)
				if t and v then
					table.insert(s.times, t)
					table.insert(s.values, v)
				end
			end
			table.insert(result.series, s)
			result.kind = "matrix"
		elseif type(entry.value) == "table" then
			local t, v = jsonSample(entry.value)
			if t and v then
				table.insert(result.series, { labels = labels, times = { t }, values = { v } })
				if result.kind ~= "matrix" then
					result.kind = "vector"
				end
			else
				result.unparsed += 1
			end
		else
			-- Native histograms ("histogram"/"histograms") have no plain value.
			result.unparsed += 1
		end
	end
end

local function parseJsonList(verb: "series" | "labels", doc: any, result: Result)
	if type(doc) ~= "table" then
		result.unparsed += 1
		return
	end
	for _, entry in doc do
		if verb == "labels" and type(entry) == "string" then
			table.insert(result.values, entry)
		elseif verb == "series" and stringLabels(entry) then
			table.insert(result.label_sets, stringLabels(entry) :: Labels)
		else
			result.unparsed += 1
		end
	end
	result.kind = verb
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
		local err = M.errorOf(line)
		if err then
			table.insert(result.errors, err)
		else
			table.insert(data, line)
		end
	end
	if #data > 0 then
		if inv.format == "json" then
			local ok, doc = pcall(decode, table.concat(data, "\n"))
			if not ok then
				result.unparsed += #data
			elseif verb == "series" or verb == "labels" then
				parseJsonList(verb, doc, result)
			else
				parseJsonQuery(doc, result)
			end
		elseif verb == "labels" then
			for _, line in data do
				table.insert(result.values, line)
			end
			result.kind = "labels"
		elseif verb == "series" then
			for _, line in data do
				local labels, pos = M.parseMetric(line, 1)
				if labels and pos == #line + 1 then
					table.insert(result.label_sets, labels)
				else
					result.unparsed += 1
				end
			end
			result.kind = "series"
		else
			parseTextQuery(data, result)
		end
	end
	local hasData = #result.series > 0 or #result.label_sets > 0 or #result.values > 0
	if not hasData then
		if #result.errors > 0 then
			result.kind = "error"
		elseif result.unparsed > 0 then
			result.kind = "unreadable"
		else
			result.kind = "empty"
		end
	end
	return result
end

-- Spark -----------------------------------------------------------------------------

export type SparkBar = { value: number?, title: string }

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

-- At most `maxBars` bars (LTTB keeps the shape; a gap-heavy series is then
-- thinned evenly). Tern scales bars to the tallest, so values are mapped
-- onto 0.1..1 of the series' own min..max: a flat series at 1000 and one
-- moving 1000..1001 both stay readable. Missing samples (NaN, Inf) draw as
-- stubs.
function M.spark(times: { number }, values: { number }, maxBars: number?): { SparkBar }
	local limit = math.max(2, maxBars or M.MAX_SPARK)
	local t, v = Lttb.downsample(times, values, limit, Frame.NULL)
	local n = #t
	local picked: { number } = {}
	if n > limit then
		for i = 1, limit do
			picked[i] = math.floor((i - 1) * (n - 1) / (limit - 1)) + 1
		end
	else
		for i = 1, n do
			picked[i] = i
		end
	end
	local lo, hi = math.huge, -math.huge
	for _, i in picked do
		local x = v[i]
		if type(x) == "number" and finite(x) then
			lo = math.min(lo, x)
			hi = math.max(hi, x)
		end
	end
	local bars: { SparkBar } = table.create(#picked)
	for k, i in picked do
		local x = v[i]
		local when = Range.formatMs(t[i])
		if type(x) == "number" and finite(x) then
			local h = if hi > lo then 0.1 + 0.9 * (x - lo) / (hi - lo) else 1
			bars[k] = { value = h, title = Format.text(x) .. " at " .. when }
		else
			bars[k] =
				{ value = nil, title = (if type(x) == "number" then Format.text(x) else "no value") .. " at " .. when }
		end
	end
	return bars
end

-- Links -----------------------------------------------------------------------------

export type Target = { context: string, ds: string? }

local function samePlace(a: GrafanaUrl.ParsedUrl, b: GrafanaUrl.ParsedUrl): boolean
	return a.scheme == b.scheme and a.authority == b.authority
end

local function sortedContexts(cfg: Config): { string }
	local names: { string } = {}
	for name in cfg.contexts do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- The configured context promtool's server URL belongs to: a context whose
-- prometheus endpoint is that URL, else a Grafana datasource proxy URL
-- (`<grafana>/api/datasources/proxy/uid/<uid>`) of a configured Grafana.
function M.targetFor(server: string?, cfg: Config?): Target?
	if server == nil or cfg == nil then
		return nil
	end
	local url = GrafanaUrl.parse(server)
	if url == nil then
		return nil
	end
	for _, name in sortedContexts(cfg) do
		local prom = cfg.contexts[name].prometheus
		local base = if prom then GrafanaUrl.parse(prom.url .. prom.path_prefix) else nil
		if base and samePlace(base, url) and base.path == url.path then
			return { context = name }
		end
	end
	for _, base in GrafanaUrl.bases(cfg) do
		if base.scheme == url.scheme and base.authority == url.authority then
			local prefix = string.gsub(base.path, "%p", "%%%0")
			local uid = string.match(url.path, "^" .. prefix .. "/api/datasources/proxy/uid/([^/]+)$")
			if uid then
				return { context = base.context, ds = uid }
			end
		end
	end
	return nil
end

-- A promtool time flag (RFC3339 or Unix seconds) in epoch ms.
local function flagMs(text: string?): number?
	if text == nil or Range.isRelative(text) then
		return nil
	end
	return (Range.parse(text, false, { now_ms = 0 }))
end

-- Link times are epoch ms; smaller numbers would read back as seconds.
local function msParam(ms: number?): string?
	if ms == nil or ms < 1e11 then
		return nil
	end
	return string.format("%d", ms)
end

-- `tern-grafana://query?...` for the run, or nil and the reason.
function M.queryLink(inv: Invocation, cfg: Config?): (string?, string?)
	local verb = inv.verb
	local expr = inv.expr
	if verb == "series" and #inv.matches == 1 then
		expr = inv.matches[1]
	end
	if (verb ~= "instant" and verb ~= "range" and verb ~= "series") or expr == nil then
		return nil, "nothing to query"
	end
	local target = M.targetFor(inv.server, cfg)
	if target == nil then
		return nil, string.format("no configured context serves %s", inv.server or "this server")
	end
	local params: { [string]: string } = { context = target.context, expr = expr }
	if target.ds then
		params.ds = target.ds
	end
	if verb == "range" then
		params.mode = "graph"
		local stop = flagMs(inv.stop)
		local start = flagMs(inv.start)
		local to = if inv.stop == nil then "now" else msParam(stop)
		local from = if start
			then msParam(start)
			elseif inv.start ~= nil then nil
			elseif inv.stop == nil then "now-5m"
			else msParam(if stop then stop - DEFAULT_RANGE_MS else nil)
		if from and to then
			params.from = from
			params.to = to
		end
	else
		params.mode = "table"
		local at = flagMs(inv.time)
		local to = msParam(at)
		local from = msParam(if at then at - INSTANT_WINDOW_MS else nil)
		if from and to then
			params.from = from
			params.to = to
		end
	end
	local link: Scheme.Link = { action = "query", params = params, vars = {} }
	local ok, err = Scheme.validate(link)
	if not ok then
		return nil, if err then err.message else "invalid link"
	end
	return Scheme.encode(link), nil
end

-- View state --------------------------------------------------------------------------

-- Carried whole in every action ("v=table:1;all:1"), so a click on a
-- rehydrated lens lands on the same view.
export type ViewState = { table: boolean, all: boolean }

function M.defaultView(): ViewState
	return { table = false, all = false }
end

function M.encodeView(vs: ViewState): string
	local parts: { string } = {}
	if vs.table then
		table.insert(parts, "table:1")
	end
	if vs.all then
		table.insert(parts, "all:1")
	end
	return table.concat(parts, ";")
end

-- Unknown fields are ignored (actions from another plugin version).
function M.decodeView(s: string): ViewState
	local vs = M.defaultView()
	for part in string.gmatch(s, "[^;]+") do
		local k, v = string.match(part, "^([^:]+):(.*)$")
		if k == "table" then
			vs.table = v == "1"
		elseif k == "all" then
			vs.all = v == "1"
		end
	end
	return vs
end

local function viewAction(vs: ViewState): string
	return "v=" .. M.encodeView(vs)
end

-- Rendering -----------------------------------------------------------------------------

local ERROR_TITLES: { [ErrorKind]: string } = {
	network = "Cannot reach the server",
	timeout = "The query timed out",
	auth = "Not authorized",
	query = "Query failed",
	usage = "promtool rejected the arguments",
}

function M.seriesName(labels: Labels): string
	local name = (labels.__name__ or "") .. Frame.formatLabels(labels)
	return if name == "" then "{}" else name
end

local function chip(text: string, action: string, active: boolean, title: string?): Node
	return ui.badge(text, if active then "accent" else "neutral", { actions = { click = action }, title = title })
end

local function timeText(ms: number?): string
	return if ms then Range.formatMs(ms) .. " UTC" else "?"
end

local function dataSpan(result: Result): (number?, number?)
	local lo, hi = math.huge, -math.huge
	for _, s in result.series do
		for _, t in s.times do
			lo = math.min(lo, t)
			hi = math.max(hi, t)
		end
	end
	if lo > hi then
		return nil, nil
	end
	return lo, hi
end

local function item(key: string, value: ui.SpanLike): { { ui.SpanLike } }
	return { { key }, { value } }
end

local function summaryItems(inv: Invocation, result: Result): { { { ui.SpanLike } } }
	local items: { { { ui.SpanLike } } } = {}
	table.insert(items, item("Server", ui.span(inv.server or "?", "mono")))
	local lo, hi = dataSpan(result)
	if inv.verb == "range" then
		local from = flagMs(inv.start) or lo
		local to = flagMs(inv.stop) or hi
		local text = timeText(from) .. "  to  " .. timeText(to)
		if inv.step then
			text ..= "  step " .. inv.step
		end
		table.insert(items, item("Range", text))
	elseif inv.verb == "instant" and hi then
		table.insert(items, item("Time", timeText(hi)))
	end
	if #inv.matches > 0 then
		table.insert(items, item("Match", ui.span(table.concat(inv.matches, "  "), "code")))
	end
	return items
end

local function countText(n: number, one: string, many: string): string
	return string.format("%d %s", n, if n == 1 then one else many)
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
				chip(string.format("Show all %d", total), viewAction({ table = vs.table, all = true }), false),
			})
		)
	else
		table.insert(out, ui.muted(string.format("... %d more (Raw shows everything)", total - shown)))
	end
end

local function rangeGrid(series: { Series }, shown: number): Node
	local columns: { Grid.Column } = {
		{ head = "Series" },
		{ head = "Trend" },
		{ head = "Last", numeric = true },
		{ head = "Min", numeric = true },
		{ head = "Max", numeric = true },
	}
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		local s = series[i]
		local lo, hi = math.huge, -math.huge
		for _, v in s.values do
			if finite(v) then
				lo = math.min(lo, v)
				hi = math.max(hi, v)
			end
		end
		local n = #s.values
		local name = M.seriesName(s.labels)
		rows[i] = {
			key = "s" .. i,
			cells = {
				{ k = "text", p = { spans = { { t = name } }, title = name } },
				{ k = "chart", p = { kind = "spark", series = M.spark(s.times, s.values), token = "accent" } },
				Grid.text(if n > 0 then Format.text(s.values[n]) else TableView.NO_VALUE),
				Grid.text(if lo <= hi then Format.text(lo) else TableView.NO_VALUE),
				Grid.text(if lo <= hi then Format.text(hi) else TableView.NO_VALUE),
			},
		}
	end
	return Grid.grid("series", columns, rows, "tern-grafana.lens-series")
end

local function framesOf(series: { Series }, shown: number): { Frame.Frame }
	local frames: { Frame.Frame } = table.create(shown)
	for i = 1, shown do
		local s = series[i]
		frames[i] = Frame.timeSeries(s.labels, s.times, s.values)
	end
	return frames
end

local function labelSetGrid(sets: { Labels }, shown: number): Node
	local keySet: { [string]: boolean } = {}
	local hasName = false
	for i = 1, shown do
		for k in sets[i] do
			if k == "__name__" then
				hasName = true
			else
				keySet[k] = true
			end
		end
	end
	local keys: { string } = {}
	for k in keySet do
		table.insert(keys, k)
	end
	table.sort(keys)
	if hasName then
		table.insert(keys, 1, "__name__")
	end
	while #keys > Grid.MAX_COLUMNS do
		table.remove(keys)
	end
	local columns: { Grid.Column } = table.create(#keys)
	for i, k in keys do
		columns[i] = { head = k }
	end
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		local cells: { Node } = table.create(#keys)
		for j, k in keys do
			cells[j] = Grid.text(sets[i][k] or "")
		end
		rows[i] = { key = "l" .. i, cells = cells }
	end
	return Grid.grid("series", columns, rows, "tern-grafana.lens-series")
end

local function valuesGrid(head: string, values: { string }, shown: number): Node
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		rows[i] = { key = "v" .. i, cells = { Grid.text(values[i]) } }
	end
	return Grid.grid("values", { { head = head } }, rows, "tern-grafana.lens-values")
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
		table.insert(children, ui.muted("Server: " .. (inv.server or "?")))
	end
	return ui.card({ ui.span(ERROR_TITLES[first.kind], "strong error") }, children, { tone = "error" })
end

local function headSpans(inv: Invocation, result: Result): { ui.SpanLike }
	local head: { ui.SpanLike } = { ui.span("promtool query " .. (inv.verb or ""), "strong") }
	local count = if result.kind == "labels"
		then countText(#result.values, "value", "values")
		elseif result.kind == "series" then countText(#result.label_sets, "series", "series")
		elseif result.kind == "scalar" then "scalar"
		elseif result.kind == "empty" then "no data"
		else countText(#result.series, "series", "series")
	table.insert(head, ui.span("  " .. count, "muted"))
	return head
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
	local children: { Node } = {}
	local exprText = inv.expr or (if inv.verb == "labels" then inv.label else nil)
	if exprText then
		table.insert(
			children,
			ui.text({ ui.span(exprText, "code") }, { key = "expr", actions = { click = "copy" }, title = "Copy" })
		)
	end
	table.insert(children, ui.kv(summaryItems(inv, result)))

	local tools: { Node } = {}
	if kind == "matrix" then
		table.insert(tools, chip("Graph", viewAction({ table = false, all = vs.all }), not vs.table))
		table.insert(tools, chip("Table", viewAction({ table = true, all = vs.all }), vs.table))
	end
	local link, why = M.queryLink(inv, cfg)
	if link then
		table.insert(tools, chip("Open in Query block", "query", false, link))
	elseif inv.verb ~= "labels" then
		table.insert(tools, ui.muted("Open in Query block: " .. (why or "unavailable")))
	end
	if #tools > 0 then
		table.insert(children, ui.row(tools, { key = "tools" }))
	end

	for _, e in result.errors do
		table.insert(children, ui.text({ ui.span(e.message, "error") }))
	end

	if kind == "empty" then
		table.insert(children, ui.muted("No data", { key = "body" }))
	elseif kind == "scalar" then
		local s = result.series[1]
		table.insert(children, ui.text({ ui.span(Format.text(s.values[1]), "strong num") }, { key = "body" }))
	elseif kind == "series" then
		local shown = shownCount(#result.label_sets, vs)
		table.insert(children, labelSetGrid(result.label_sets, shown))
		overflowNodes(#result.label_sets, shown, vs, children)
	elseif kind == "labels" then
		local shown = shownCount(#result.values, vs)
		table.insert(children, valuesGrid(inv.label or "value", result.values, shown))
		overflowNodes(#result.values, shown, vs, children)
	else
		local shown = shownCount(#result.series, vs)
		if kind == "matrix" and not vs.table then
			table.insert(children, rangeGrid(result.series, shown))
		else
			table.insert(
				children,
				TableView.view(framesOf(result.series, shown), { key = "table", show_time = kind == "matrix" })
			)
		end
		overflowNodes(#result.series, shown, vs, children)
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

-- Raw while promtool runs: it prints everything at the end, and JSON is only
-- valid whole.
function M.view(state: State, env: Env): Node?
	if state.invocation.verb == nil or state.overflow or state.status == nil then
		return nil
	end
	return M.render(state.invocation, resultOf(state, env), state.view, env.config)
end

function M.event(state: State, ev: LensTypes.Event, env: Env): { Effect }
	if ev.ev ~= "action" then
		return {}
	end
	if ev.act == "v" then
		state.view = M.decodeView(ev.value or "")
	elseif ev.act == "query" then
		local link, why = M.queryLink(state.invocation, env.config)
		if link then
			return { { kind = "open", target = link } }
		end
		return { { kind = "toast", level = "error", text = "Cannot open in the Query block", sub = why } }
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
