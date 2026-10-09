--!strict
-- Lens for `curl` against Prometheus-compatible query APIs
-- (`/api/v1/query`, `/api/v1/query_range`, `/api/v1/query_exemplars`, Loki's
-- `/loki/api/v1/query*`, the same paths through Grafana's datasource proxy)
-- and Grafana's `/api/ds/query`. The claim hides Tern's built-in HTTP/JSON
-- lens for these commands, so every Prometheus or Grafana JSON body renders
-- here, errors included; a body that is neither (plain text, HTML, nothing
-- written to the terminal) stays raw.
--
-- The output is the raw body. `-i` and `-v` add header and trace lines around
-- it; those are skipped, and the HTTP status they show is kept. The request
-- (URL, query string, form or JSON data) comes from argv, so the view can
-- reopen the query in the Query block.

local ConfigTypes = require("../config/types")
local EnvModule = require("../env")
local Format = require("../units/format")
local Frame = require("../frame/types")
local FrameGrafana = require("../frame/grafana")
local FrameProm = require("../frame/prom")
local GrafanaUrl = require("../links/grafana_url")
local Grid = require("../render/grid")
local LensTypes = require("./types")
local Range = require("../time/range")
local Scheme = require("../links/scheme")
local SeriesView = require("./series")
local Target = require("./target")
local ui = require("../ui")

type Config = ConfigTypes.Config
type Env = EnvModule.Env
type Node = ui.Node
type Run = LensTypes.Run
type Effect = LensTypes.Effect
type Series = SeriesView.Series
type ViewState = SeriesView.ViewState

local M = {}

-- Claimed command lines (plugin.toml [[lenses]] id "curl"). Tern matches
-- them against the unquoted argv joined by spaces, so the path can sit in any
-- argument: `parseArgs` re-checks the URL.
M.MATCH = {
	"curl *api/v1/query*",
	"curl *api/ds/query*",
}

-- Past these the capture stays raw (memory and the 2 s view budget).
M.MAX_LINES = 50000
M.MAX_BYTES = 8 * 1024 * 1024
-- Log lines and exemplars drawn before "N more".
M.MAX_ENTRIES = 200

-- Invocation ---------------------------------------------------------------------

export type Endpoint = "instant" | "range" | "exemplars" | "ds_query"

export type Invocation = {
	-- nil: not a request this lens renders (`reason` says why).
	endpoint: Endpoint?,
	reason: string?,
	url: string?,
	-- The URL before `/api/v1/query*` or `/api/ds/query`.
	base: string?,
	-- `/loki/api/v1/...`: LogQL, not PromQL.
	loki: boolean,
	method: string,
	-- Query string and form data, decoded (`query`, `time`, `start`, ...).
	params: { [string]: string },
	-- The JSON request body (`-d`, `--data-raw`, `--json`), when one was given inline.
	body: string?,
	include: boolean,
	verbose: boolean,
}

-- Long options that take a value. Anything else long is a switch.
local LONG_VALUE: { [string]: boolean } = {
	["abstract-unix-socket"] = true,
	["alt-svc"] = true,
	["aws-sigv4"] = true,
	cacert = true,
	capath = true,
	cert = true,
	["cert-type"] = true,
	ciphers = true,
	config = true,
	["connect-timeout"] = true,
	["connect-to"] = true,
	cookie = true,
	["cookie-jar"] = true,
	data = true,
	["data-ascii"] = true,
	["data-binary"] = true,
	["data-raw"] = true,
	["data-urlencode"] = true,
	["dns-servers"] = true,
	["doh-url"] = true,
	["dump-header"] = true,
	["expect100-timeout"] = true,
	form = true,
	["form-string"] = true,
	header = true,
	interface = true,
	json = true,
	["keepalive-time"] = true,
	key = true,
	["key-type"] = true,
	["limit-rate"] = true,
	["local-port"] = true,
	["max-filesize"] = true,
	["max-redirs"] = true,
	["max-time"] = true,
	["netrc-file"] = true,
	noproxy = true,
	["oauth2-bearer"] = true,
	output = true,
	["output-dir"] = true,
	pass = true,
	pinnedpubkey = true,
	proto = true,
	["proto-redir"] = true,
	proxy = true,
	["proxy-user"] = true,
	quote = true,
	range = true,
	referer = true,
	request = true,
	["request-target"] = true,
	resolve = true,
	retry = true,
	["retry-delay"] = true,
	["retry-max-time"] = true,
	stderr = true,
	["tls-max"] = true,
	trace = true,
	["trace-ascii"] = true,
	["unix-socket"] = true,
	["upload-file"] = true,
	url = true,
	user = true,
	["user-agent"] = true,
	variable = true,
	["write-out"] = true,
}

-- Short options that take a value (the rest of the word, or the next one).
local SHORT_VALUE: { [string]: string } = {
	A = "user-agent",
	b = "cookie",
	c = "cookie-jar",
	C = "continue-at",
	d = "data",
	D = "dump-header",
	e = "referer",
	E = "cert",
	F = "form",
	H = "header",
	K = "config",
	m = "max-time",
	o = "output",
	P = "ftp-port",
	Q = "quote",
	r = "range",
	t = "telnet-option",
	T = "upload-file",
	u = "user",
	U = "proxy-user",
	w = "write-out",
	x = "proxy",
	X = "request",
	y = "speed-time",
	Y = "speed-limit",
	z = "time-cond",
}

local SHORT_SWITCH: { [string]: string } = {
	i = "include",
	v = "verbose",
	G = "get",
	I = "head",
	O = "remote-name",
}

-- Options whose output is not the response body.
local NO_BODY: { [string]: boolean } = {
	head = true,
	output = true,
	["remote-name"] = true,
	["remote-name-all"] = true,
	["output-dir"] = true,
	help = true,
	manual = true,
	version = true,
}

local DATA_FORM: { [string]: boolean } = {
	data = true,
	["data-ascii"] = true,
	["data-binary"] = true,
	["data-raw"] = true,
}

local function unsupported(inv: Invocation, reason: string): Invocation
	inv.endpoint = nil
	inv.reason = reason
	return inv
end

local ENDPOINTS: { { suffix: string, endpoint: Endpoint } } = {
	{ suffix = "/api/v1/query", endpoint = "instant" },
	{ suffix = "/api/v1/query_range", endpoint = "range" },
	{ suffix = "/api/v1/query_exemplars", endpoint = "exemplars" },
	{ suffix = "/api/ds/query", endpoint = "ds_query" },
}

-- Form pairs (`a=1&b=2`) into `params`; `raw` data from --data-urlencode is
-- taken as typed.
local function addForm(params: { [string]: string }, text: string)
	local pairs_ = Scheme.parseQuery(text)
	if pairs_ then
		for _, p in pairs_ do
			params[p.name] = p.value
		end
	end
end

-- --data-urlencode forms: `content`, `=content`, `name=content`, `@file`,
-- `name@file`; only `name=content` names a parameter we can read.
local function addUrlencoded(params: { [string]: string }, text: string)
	local name, content = string.match(text, "^([^=@]+)=(.*)$")
	if name and content then
		params[name] = content
	end
end

-- curl's own argv rules: options anywhere, `--name value`, `--name=value` is
-- not curl syntax (it reads `=value` as part of the name), combined short
-- switches (`-sS`), a short option's value glued on (`-XPOST`) or next.
function M.parseArgs(program: string, args: { string }): Invocation
	local inv: Invocation = {
		endpoint = nil,
		reason = nil,
		url = nil,
		base = nil,
		loki = false,
		method = "GET",
		params = {},
		body = nil,
		include = false,
		verbose = false,
	}
	if program ~= "curl" then
		return unsupported(inv, "not curl")
	end
	local urls: { string } = {}
	local data: { { kind: string, value: string } } = {}
	local options: { [string]: string } = {}
	local i = 1
	local afterDashes = false
	while i <= #args do
		local a = args[i]
		if afterDashes or string.sub(a, 1, 1) ~= "-" or a == "-" then
			table.insert(urls, a)
		elseif a == "--" then
			afterDashes = true
		elseif string.sub(a, 1, 2) == "--" then
			local name = string.sub(a, 3)
			if LONG_VALUE[name] then
				i += 1
				local value = args[i]
				if value == nil then
					return unsupported(inv, a .. " has no value")
				end
				if name == "url" then
					table.insert(urls, value)
				elseif DATA_FORM[name] or name == "data-urlencode" or name == "json" then
					table.insert(data, { kind = name :: string, value = value })
				else
					options[name] = value
				end
			else
				options[name] = ""
			end
		else
			local k = 2
			while k <= #a do
				local letter = string.sub(a, k, k)
				local long = SHORT_VALUE[letter]
				if long then
					local value: string? = string.sub(a, k + 1)
					if value == "" then
						i += 1
						value = args[i]
					end
					if value == nil then
						return unsupported(inv, "-" .. letter .. " has no value")
					end
					if long == "data" then
						table.insert(data, { kind = "data", value = value })
					else
						options[long] = value
					end
					break
				end
				local switch = SHORT_SWITCH[letter]
				if switch then
					options[switch] = ""
				elseif letter == "h" or letter == "M" or letter == "V" then
					options.help = ""
				end
				k += 1
			end
		end
		i += 1
	end
	for name in options do
		if NO_BODY[name] then
			return unsupported(inv, "--" .. name .. " writes no body to the terminal")
		end
	end
	if #urls ~= 1 then
		return unsupported(inv, if #urls == 0 then "no URL" else "several URLs")
	end
	local url = urls[1]
	if not string.find(url, "://", 1, true) then
		url = "http://" .. url
	end
	local parsed = GrafanaUrl.parse(url)
	if parsed == nil then
		return unsupported(inv, "not an http(s) URL")
	end
	for _, e in ENDPOINTS do
		local n = #e.suffix
		if string.sub(parsed.path, -n) == e.suffix then
			inv.endpoint = e.endpoint
			local prefix = string.sub(parsed.path, 1, #parsed.path - n)
			inv.base = parsed.scheme .. "://" .. parsed.authority .. prefix
			inv.loki = e.endpoint ~= "ds_query" and string.sub(prefix, -5) == "/loki"
		end
	end
	if inv.endpoint == nil then
		return unsupported(inv, "not a query API path")
	end
	inv.url = url
	inv.include = options.include ~= nil
	inv.verbose = options.verbose ~= nil
	addForm(inv.params, parsed.query)
	for _, d in data do
		local kind: string = d.kind
		local isJson = kind == "json"
		-- `@file` names a file whose content is not in argv (--data-raw sends it literally).
		local fromFile = string.sub(d.value, 1, 1) == "@" and kind ~= "data-raw"
		if kind == "data-urlencode" then
			addUrlencoded(inv.params, d.value)
		elseif fromFile then
			continue
		elseif isJson or string.match(d.value, "^%s*{") then
			inv.body = d.value
		else
			addForm(inv.params, d.value)
		end
	end
	local method = options.request
	if method then
		inv.method = string.upper(method)
	elseif #data > 0 and options.get == nil then
		inv.method = "POST"
	end
	return inv
end

-- Body ---------------------------------------------------------------------------

export type Body = {
	-- The decoded JSON body, or nil when there is none.
	doc: any,
	-- From `-i` or `-v` header lines.
	http_status: number?,
}

-- `-v` trace lines (`* `, `> `, `< `, `{ [n bytes data]`), keeping the
-- status of the last response header.
local function stripVerbose(lines: { string }): ({ string }, number?)
	local out: { string } = {}
	local status: number? = nil
	for _, line in lines do
		local code = string.match(line, "^< HTTP/[%d.]+ (%d%d%d)")
		if code then
			status = tonumber(code)
		elseif string.match(line, "^[*<>] ") or line == "<" or line == ">" or string.match(line, "^[{}] %[") then
			continue
		else
			-- The body has no trailing newline, so curl's closing trace line
			-- lands on the same row.
			local cut = string.find(line, "%* Connection #%d+ to host .- left intact$")
				or string.find(line, "%* Closing connection.*$")
			table.insert(out, if cut then string.sub(line, 1, cut - 1) else line)
		end
	end
	return out, status
end

-- `-i` header blocks (`HTTP/1.1 200 OK` ... blank line), possibly several
-- (100 Continue, proxies); keeps the last status.
local function stripHeaders(lines: { string }): ({ string }, number?)
	local i = 1
	while i <= #lines and string.find(lines[i], "^%s*$") do
		i += 1
	end
	local status: number? = nil
	while i <= #lines do
		local code = string.match(lines[i], "^HTTP/[%d.]+ (%d%d%d)")
		if code == nil then
			break
		end
		status = tonumber(code)
		i += 1
		while i <= #lines and not string.find(lines[i], "^%s*$") do
			i += 1
		end
		i += 1
	end
	local out: { string } = {}
	for k = i, #lines do
		table.insert(out, lines[k])
	end
	return out, status
end

-- The JSON object in the output: the body as printed, else the text from the
-- first `{` to the last `}` (what `-w` or a stray trace line leaves around it).
function M.readBody(inv: Invocation, lines: { string }, decode: (string) -> any): Body
	local status: number? = nil
	local rest = lines
	if inv.verbose then
		rest, status = stripVerbose(rest)
	end
	local headerStatus: number?
	rest, headerStatus = stripHeaders(rest)
	status = headerStatus or status
	local text = table.concat(rest, "\n")
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" then
		local first = string.find(text, "{", 1, true)
		local last: number? = nil
		local from = 1
		while true do
			local at = string.find(text, "}", from, true)
			if at == nil then
				break
			end
			last = at
			from = at + 1
		end
		doc = nil
		if first and last and last > first then
			local ok2, doc2 = pcall(decode, string.sub(text, first, last))
			if ok2 and type(doc2) == "table" then
				doc = doc2
			end
		end
	end
	return { doc = doc, http_status = status }
end

-- Results ---------------------------------------------------------------------------

export type LogEntry = { time: number, labels: { [string]: string }, line: string }

export type Exemplar = { series: { [string]: string }, labels: { [string]: string }, value: number?, time: number? }

export type Section = {
	-- Grafana refId; nil for a Prometheus response.
	ref: string?,
	kind: "vector" | "matrix" | "scalar" | "string" | "streams" | "exemplars" | "frames" | "empty" | "error",
	series: { Series },
	-- Frames that are not number series (logs, tables, traces).
	frames: { Frame.Frame },
	entries: { LogEntry },
	exemplars: { Exemplar },
	text: string?,
	error: string?,
	-- Prometheus errorType, Grafana errorSource.
	error_type: string?,
	warnings: { string },
	-- Entries of the response that could not be read.
	unparsed: number,
}

export type Result = {
	-- nil when the body is not Prometheus or Grafana JSON (raw is shown).
	source: ("prometheus" | "grafana")?,
	sections: { Section },
	-- A Grafana API error (`{message, messageId, statusCode}`).
	error: string?,
	http_status: number?,
}

local function newSection(ref: string?): Section
	return {
		ref = ref,
		kind = "empty",
		series = {},
		frames = {},
		entries = {},
		exemplars = {},
		text = nil,
		error = nil,
		error_type = nil,
		warnings = {},
		unparsed = 0,
	}
end

local function str(env: Env, v: any): string?
	local x = EnvModule.value(env, v)
	return if type(x) == "string" then x else nil
end

local function nsToMs(v: any): number?
	local n = if type(v) == "string" then tonumber(v) elseif type(v) == "number" then v else nil
	return if n then math.floor(n / 1e6) else nil
end

local function readStreams(section: Section, result: any)
	section.kind = "streams"
	if type(result) ~= "table" then
		return
	end
	for _, stream in result do
		local labels = if type(stream) == "table" then SeriesView.stringLabels(stream.stream) else nil
		if labels == nil or type(stream.values) ~= "table" then
			section.unparsed += 1
			continue
		end
		for _, pair in stream.values do
			local t = if type(pair) == "table" then nsToMs(pair[1]) else nil
			local line = if type(pair) == "table" then pair[2] else nil
			if t and type(line) == "string" then
				table.insert(section.entries, { time = t, labels = labels, line = line })
			else
				section.unparsed += 1
			end
		end
	end
	-- Newest first, as Loki returns a backward query and logcli prints it.
	table.sort(section.entries, function(a: LogEntry, b: LogEntry): boolean
		return a.time > b.time
	end)
end

local function readExemplars(section: Section, data: any)
	section.kind = "exemplars"
	for _, group in data do
		local series = if type(group) == "table" then SeriesView.stringLabels(group.seriesLabels) else nil
		if series == nil or type(group.exemplars) ~= "table" then
			section.unparsed += 1
			continue
		end
		for _, e in group.exemplars do
			local labels = if type(e) == "table" then SeriesView.stringLabels(e.labels) else nil
			if labels == nil then
				section.unparsed += 1
				continue
			end
			table.insert(section.exemplars, {
				series = series,
				labels = labels,
				value = if type(e.value) == "string" then SeriesView.sampleValue(e.value) else nil,
				time = SeriesView.secondsToMs(e.timestamp),
			})
		end
	end
end

local function readPrometheus(doc: any, env: Env): Section
	local section = newSection(nil)
	if doc.status == "error" then
		section.kind = "error"
		section.error = str(env, doc.error) or "the query failed"
		section.error_type = str(env, doc.errorType)
		section.warnings = FrameProm.annotations(doc)
		return section
	end
	section.warnings = FrameProm.annotations(doc)
	local data = doc.data
	if type(data) ~= "table" then
		section.kind = "error"
		section.error = "the response has no data"
		return section
	end
	if data.resultType == nil and (#data > 0 or next(data) == nil) then
		readExemplars(section, data)
		if #section.exemplars == 0 then
			section.kind = "empty"
		end
		return section
	end
	local resultType = data.resultType
	if resultType == "streams" then
		readStreams(section, data.result)
		if #section.entries == 0 then
			section.kind = "empty"
		end
	elseif resultType == "string" then
		local r = data.result
		section.kind = "string"
		section.text = if type(r) == "table" and type(r[2]) == "string" then r[2] else nil
		if section.text == nil then
			section.unparsed += 1
			section.kind = "empty"
		end
	else
		local kind, series, unparsed = SeriesView.readJson(data.result)
		section.series = series
		section.unparsed = unparsed
		section.kind = if kind then kind :: any else "empty"
	end
	return section
end

local function isSeriesFrame(frame: Frame.Frame): boolean
	local hasTime, hasNumber = false, false
	for _, f in frame.fields do
		if f.type == "time" then
			hasTime = true
		elseif f.type == "number" then
			hasNumber = true
		else
			return false
		end
	end
	return hasTime and hasNumber
end

-- Number fields of time series frames as series; missing samples dropped.
local function framesToSeries(frames: { Frame.Frame }, section: Section)
	local multi = false
	for _, frame in frames do
		local tf = Frame.timeField(frame)
		if tf == nil then
			continue
		end
		for _, field in Frame.numberFields(frame) do
			local labels: { [string]: string } = if field.labels then table.clone(field.labels) else {}
			local s: Series = { labels = labels, times = {}, values = {} }
			for i, v in field.values do
				local t = tf.values[i]
				if type(v) == "number" and type(t) == "number" then
					table.insert(s.times, t)
					table.insert(s.values, v)
				end
			end
			if #s.times > 1 then
				multi = true
			end
			table.insert(section.series, s)
		end
	end
	section.kind = if #section.series == 0 then "empty" elseif multi then "matrix" else "vector"
end

local function readGrafana(doc: any, env: Env): { Section }
	local sections: { Section } = {}
	local results = FrameGrafana.parseResults(doc, env)
	local refs: { string } = {}
	for ref in results do
		table.insert(refs, ref)
	end
	table.sort(refs)
	local raw = if type(doc.results) == "table" then doc.results else {}
	for _, ref in refs do
		local r = results[ref]
		local section = newSection(ref)
		if r.ok == false then
			section.kind = "error"
			section.error = r.error.message
			local rawRef = raw[ref]
			section.error_type = if type(rawRef) == "table" then str(env, rawRef.errorSource) else nil
		else
			section.warnings = r.warnings
			local seriesFrames: { Frame.Frame } = {}
			for _, frame in r.frames do
				if isSeriesFrame(frame) then
					table.insert(seriesFrames, frame)
				else
					table.insert(section.frames, frame)
				end
			end
			if #section.frames > 0 then
				section.kind = "frames"
				-- Mixed results: show every frame as a table.
				for _, frame in seriesFrames do
					table.insert(section.frames, frame)
				end
			else
				framesToSeries(seriesFrames, section)
			end
		end
		table.insert(sections, section)
	end
	return sections
end

-- Reads a finished capture: Prometheus envelopes (`status`), Grafana query
-- results (`results`) and Grafana API errors (`message`).
function M.build(inv: Invocation, lines: { string }, env: Env): Result
	local result: Result = { source = nil, sections = {}, error = nil, http_status = nil }
	if inv.endpoint == nil then
		return result
	end
	local body = M.readBody(inv, lines, env.decode)
	result.http_status = body.http_status
	local doc = body.doc
	if type(doc) ~= "table" then
		return result
	end
	if doc.status == "success" or doc.status == "error" then
		result.source = "prometheus"
		table.insert(result.sections, readPrometheus(doc, env))
	elseif type(doc.results) == "table" then
		result.source = "grafana"
		result.sections = readGrafana(doc, env)
	elseif type(str(env, doc.message)) == "string" then
		result.source = "grafana"
		result.error = str(env, doc.message)
		local code = EnvModule.value(env, doc.statusCode)
		if result.http_status == nil and type(code) == "number" then
			result.http_status = code
		end
	end
	return result
end

-- Links -----------------------------------------------------------------------------

export type GrafanaQuery = { ref: string, expr: string?, uid: string?, type: string?, instant: boolean }

-- The queries of an inline `/api/ds/query` request body, and its from/to.
function M.dsRequest(inv: Invocation, decode: (string) -> any): ({ GrafanaQuery }, string?, string?)
	local out: { GrafanaQuery } = {}
	local text = inv.body
	if text == nil then
		return out, nil, nil
	end
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" or type(doc.queries) ~= "table" then
		return out, nil, nil
	end
	for _, q in doc.queries do
		if type(q) ~= "table" then
			continue
		end
		local ds = if type(q.datasource) == "table" then q.datasource else {}
		table.insert(out, {
			ref = if type(q.refId) == "string" then q.refId else "A",
			expr = if type(q.expr) == "string" and q.expr ~= "" then q.expr else nil,
			uid = if type(ds.uid) == "string" then ds.uid else nil,
			type = if type(ds.type) == "string" then ds.type else nil,
			instant = q.instant == true and q.range ~= true,
		})
	end
	local from = if type(doc.from) == "string" then doc.from else nil
	local to = if type(doc.to) == "string" then doc.to else nil
	return out, from, to
end

local function promLink(inv: Invocation, cfg: Config?): (string?, string?)
	local expr = inv.params.query
	if expr == nil or expr == "" then
		return nil, "the request has no inline query"
	end
	local target = Target.targetFor(inv.base, cfg)
	if target == nil then
		return nil, string.format("no configured context serves %s", inv.base or "this server")
	end
	local params: { [string]: string } = { context = target.context, expr = expr }
	if target.ds then
		params.ds = target.ds
	end
	if inv.endpoint == "range" then
		params.mode = "graph"
		local from = Target.msParam(Target.timeMs(inv.params.start))
		local to = Target.msParam(Target.timeMs(inv.params["end"]))
		if from and to then
			params.from = from
			params.to = to
		end
	else
		params.mode = "table"
		local at = Target.timeMs(inv.params.time)
		local from = Target.msParam(if at then at - Target.INSTANT_WINDOW_MS else nil)
		local to = Target.msParam(at)
		if from and to then
			params.from = from
			params.to = to
		end
	end
	return Target.queryLink(params)
end

local function grafanaLink(inv: Invocation, ref: string?, env: Env): (string?, string?)
	local queries, from, to = M.dsRequest(inv, env.decode)
	local q: GrafanaQuery? = nil
	for _, candidate in queries do
		if candidate.expr and (ref == nil or candidate.ref == ref) then
			q = candidate
			break
		end
	end
	if q == nil then
		return nil, "the request has no inline query"
	end
	local url = if inv.url then GrafanaUrl.parse(inv.url) else nil
	local context = if url then Target.grafanaFor(url, "/api/ds/query", env.config) else nil
	if context == nil then
		return nil, "no configured Grafana serves " .. (inv.base or "this URL")
	end
	if q.type and q.type ~= "prometheus" then
		return nil, q.type .. " queries do not open in the Query block"
	end
	for _, base in GrafanaUrl.bases(env.config) do
		if base.context == context and q.uid and base.loki_ds == q.uid then
			return nil, "Loki queries do not open in the Query block"
		end
	end
	local params: { [string]: string } = {
		context = context,
		expr = q.expr :: string,
		mode = if q.instant then "table" else "graph",
	}
	if q.uid then
		params.ds = q.uid
	end
	if from and to then
		params.from = from
		params.to = to
	end
	return Target.queryLink(params)
end

-- `tern-grafana://query?...` for the request (Grafana: refId `ref`), or nil
-- and why not.
function M.queryLink(inv: Invocation, ref: string?, env: Env): (string?, string?)
	if inv.endpoint == "ds_query" then
		return grafanaLink(inv, ref, env)
	elseif inv.loki then
		return nil, "LogQL does not open in the Query block"
	elseif inv.endpoint == "exemplars" then
		return nil, "exemplars do not open in the Query block"
	end
	return promLink(inv, env.config)
end

-- Rendering -----------------------------------------------------------------------------

local function more(hidden: number, out: { Node })
	if hidden > 0 then
		table.insert(out, ui.muted(string.format("... %d more (Raw shows everything)", hidden)))
	end
end

local function labelText(labels: { [string]: string }): string
	local text = Frame.formatLabels(labels)
	return if text == "" then "{}" else text
end

local function streamsGrid(entries: { LogEntry }, out: { Node })
	local shown = math.min(#entries, M.MAX_ENTRIES)
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		local e = entries[i]
		rows[i] = {
			key = "l" .. i,
			cells = {
				Grid.text(Range.formatMs(e.time), "muted"),
				{ k = "text", p = { spans = { { t = e.line, s = "mono" } }, title = labelText(e.labels) } },
			},
		}
	end
	table.insert(out, Grid.grid("logs", { { head = "Time" }, { head = "Line" } }, rows, "tern-grafana.lens-logs"))
	more(#entries - shown, out)
end

local function exemplarsGrid(exemplars: { Exemplar }, out: { Node })
	local shown = math.min(#exemplars, M.MAX_ENTRIES)
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		local e = exemplars[i]
		rows[i] = {
			key = "x" .. i,
			cells = {
				Grid.text(SeriesView.seriesName(e.series)),
				Grid.text(labelText(e.labels), "mono"),
				Grid.text(if e.value then Format.text(e.value) else "-"),
				Grid.text(if e.time then Range.formatMs(e.time) else "-", "muted"),
			},
		}
	end
	local columns: { Grid.Column } = {
		{ head = "Series" },
		{ head = "Exemplar" },
		{ head = "Value", numeric = true },
		{ head = "Time" },
	}
	table.insert(out, Grid.grid("exemplars", columns, rows, "tern-grafana.lens-series"))
	more(#exemplars - shown, out)
end

local function cellText(field: Frame.Field, v: any, env: Env): string
	if Frame.isNull(v) then
		return ""
	elseif field.type == "time" and type(v) == "number" then
		return Range.formatMs(v)
	elseif type(v) == "number" then
		return Format.text(v)
	elseif type(v) == "string" then
		return v
	elseif type(v) == "boolean" then
		return tostring(v)
	end
	local ok, text = pcall(env.encode, v)
	return if ok then text else "?"
end

local function frameGrid(frame: Frame.Frame, key: string, env: Env, out: { Node })
	local fields: { Frame.Field } = {}
	for _, f in frame.fields do
		if #fields < Grid.MAX_COLUMNS then
			table.insert(fields, f)
		end
	end
	local columns: { Grid.Column } = table.create(#fields)
	local length = 0
	for i, f in fields do
		columns[i] = { head = f.name, numeric = f.type == "number" }
		length = math.max(length, #f.values)
	end
	local shown = math.min(length, M.MAX_ENTRIES)
	local rows: { Grid.Row } = table.create(shown)
	for r = 1, shown do
		local cells: { Node } = table.create(#fields)
		for c, f in fields do
			cells[c] = Grid.text(cellText(f, f.values[r], env))
		end
		rows[r] = { key = "r" .. r, cells = cells }
	end
	if frame.name and frame.name ~= "" then
		table.insert(out, ui.muted(frame.name))
	end
	table.insert(out, Grid.grid(key, columns, rows, "tern-grafana.lens-values"))
	more(length - shown, out)
end

local function countOf(section: Section): string
	local k = section.kind
	if k == "scalar" or k == "string" then
		return k
	elseif k == "empty" then
		return "no data"
	elseif k == "error" then
		return "error"
	elseif k == "streams" then
		return SeriesView.countText(#section.entries, "line", "lines")
	elseif k == "exemplars" then
		return SeriesView.countText(#section.exemplars, "exemplar", "exemplars")
	elseif k == "frames" then
		return SeriesView.countText(#section.frames, "frame", "frames")
	end
	return SeriesView.countText(#section.series, "series", "series")
end

local function errorNodes(section: Section, out: { Node })
	table.insert(
		out,
		ui.text(
			{ ui.span(section.error or "the query failed", "error") },
			{ key = "err", actions = { click = "copy" }, title = "Copy" }
		)
	)
	if section.error_type then
		table.insert(out, ui.muted("Error type: " .. section.error_type))
	end
end

local function linkTools(inv: Invocation, ref: string?, env: Env, tools: { Node })
	local link, why = M.queryLink(inv, ref, env)
	if link then
		local action = if ref then "query=" .. ref else "query"
		table.insert(tools, SeriesView.chip("Open in Query block", action, false, link))
	elseif not inv.loki and inv.endpoint ~= "exemplars" then
		table.insert(tools, ui.muted("Open in Query block: " .. (why or "unavailable")))
	end
end

-- One result: errors, warnings, tools and the body.
local function sectionNodes(inv: Invocation, section: Section, vs: ViewState, env: Env, out: { Node })
	if section.kind == "error" then
		errorNodes(section, out)
	end
	for _, w in section.warnings do
		table.insert(out, ui.text({ ui.span(w, "warning") }))
	end
	local tools: { Node } = {}
	if section.kind == "matrix" then
		SeriesView.viewChips(vs, tools)
	end
	if section.kind ~= "error" then
		linkTools(inv, section.ref, env, tools)
	end
	if #tools > 0 then
		table.insert(out, ui.row(tools, { key = "tools" }))
	end
	local kind = section.kind
	if kind == "vector" or kind == "matrix" or kind == "scalar" then
		local common = if kind == "matrix" then SeriesView.commonLabels(section.series) else {}
		if next(common) ~= nil then
			table.insert(out, ui.kv({ { { "Common labels" }, { ui.span(SeriesView.seriesName(common), "code") } } }))
		end
		SeriesView.body(kind, section.series, vs, common, out)
	elseif kind == "string" then
		table.insert(out, ui.text({ ui.span(section.text or "", "strong") }, { key = "body" }))
	elseif kind == "streams" then
		streamsGrid(section.entries, out)
	elseif kind == "exemplars" then
		exemplarsGrid(section.exemplars, out)
	elseif kind == "frames" then
		for i, frame in section.frames do
			if i > Grid.MAX_COLUMNS then
				more(#section.frames - i + 1, out)
				break
			end
			frameGrid(frame, "frame" .. i, env, out)
		end
	elseif kind == "empty" then
		table.insert(out, ui.muted("No data", { key = "body" }))
	end
	if section.unparsed > 0 then
		table.insert(
			out,
			ui.muted(
				string.format(
					"%s not shown (Raw shows everything)",
					SeriesView.countText(section.unparsed, "entry", "entries")
				)
			)
		)
	end
end

local function pathOf(inv: Invocation): string
	local url = if inv.url then GrafanaUrl.parse(inv.url) else nil
	return if url then url.path else "?"
end

-- The native view for a finished capture, or nil for raw.
function M.render(inv: Invocation, result: Result, vs: ViewState, env: Env): Node?
	if inv.endpoint == nil or result.source == nil then
		return nil
	end
	local failed = result.error ~= nil
	for _, s in result.sections do
		if s.kind == "error" then
			failed = true
		end
	end
	local head: { ui.SpanLike } = { ui.span(inv.method .. " " .. pathOf(inv), "strong") }
	if result.http_status then
		table.insert(
			head,
			ui.span("  HTTP " .. result.http_status, if result.http_status >= 400 then "error" else "muted")
		)
	end
	if #result.sections == 1 then
		table.insert(head, ui.span("  " .. countOf(result.sections[1]), "muted"))
	end
	local children: { Node } = {}
	local expr = inv.params.query
	if expr and expr ~= "" then
		table.insert(
			children,
			ui.text({ ui.span(expr, "code") }, { key = "expr", actions = { click = "copy" }, title = "Copy" })
		)
	end
	local items: { { { ui.SpanLike } } } = { { { "Server" }, { ui.span(inv.base or "?", "mono") } } }
	if inv.endpoint == "range" and inv.params.start and inv.params["end"] then
		local text = SeriesView.timeText(Target.timeMs(inv.params.start))
			.. "  to  "
			.. SeriesView.timeText(Target.timeMs(inv.params["end"]))
		if inv.params.step then
			text ..= "  step " .. inv.params.step
		end
		table.insert(items, { { "Range" }, { text } })
	elseif inv.endpoint == "instant" and inv.params.time then
		table.insert(items, { { "Time" }, { SeriesView.timeText(Target.timeMs(inv.params.time)) } })
	end
	table.insert(children, ui.kv(items))
	if result.error then
		table.insert(
			children,
			ui.text({ ui.span(result.error, "error") }, { key = "err", actions = { click = "copy" }, title = "Copy" })
		)
	end
	if inv.endpoint == "ds_query" then
		local queries = M.dsRequest(inv, env.decode)
		local exprs: { [string]: string } = {}
		for _, q in queries do
			if q.expr then
				exprs[q.ref] = q.expr
			end
		end
		for i, section in result.sections do
			local body: { Node } = {}
			local refExpr = if section.ref then exprs[section.ref] else nil
			if refExpr then
				table.insert(
					body,
					ui.text(
						{ ui.span(refExpr, "code") },
						{ key = "expr", actions = { click = "copy" }, title = "Copy" }
					)
				)
			end
			sectionNodes(inv, section, vs, env, body)
			local refHead: { ui.SpanLike } = {
				ui.span(section.ref or "?", "strong"),
				ui.span("  " .. countOf(section), if section.kind == "error" then "error" else "muted"),
			}
			table.insert(
				children,
				ui.section(refHead, body, { key = "ref" .. i, tone = if section.kind == "error" then "error" else nil })
			)
		end
		if #result.sections == 0 and result.error == nil then
			table.insert(children, ui.muted("No results", { key = "body" }))
		end
	elseif result.sections[1] then
		sectionNodes(inv, result.sections[1], vs, env, children)
	end
	return ui.card(head, children, { tone = if failed then "error" else nil })
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
	if state.invocation.endpoint == nil or state.overflow then
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

-- Raw while curl runs: JSON is only valid whole.
function M.view(state: State, env: Env): Node?
	if state.invocation.endpoint == nil or state.overflow or state.status == nil then
		return nil
	end
	local result = state.result
	if result == nil then
		result = M.build(state.invocation, state.lines, env)
		state.result = result
	end
	return M.render(state.invocation, result :: Result, state.view, env)
end

function M.event(state: State, ev: LensTypes.Event, env: Env): { Effect }
	if ev.ev ~= "action" then
		return {}
	end
	if ev.act == "v" then
		state.view = SeriesView.decodeView(ev.value or "")
	elseif ev.act == "query" then
		local link, why = M.queryLink(state.invocation, ev.value, env)
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
