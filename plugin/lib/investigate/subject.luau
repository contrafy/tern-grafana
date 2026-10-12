--!strict
-- What an Investigate prompt is about (G4): an alert, a query or a dashboard
-- panel, reduced to plain JSON values. The block that starts an
-- investigation builds the subject; it travels in the link to the preview
-- block (lib/investigate/handoff.luau), which also saves it. It holds names,
-- labels, queries, series statistics and http(s) links built from the
-- config's endpoint URLs, never credentials or raw samples: links with
-- userinfo or a credential-named query parameter are left out.

local Compact = require("../carly/compact")
local ConfigTypes = require("../config/types")
local Frame = require("../frame/types")
local GrafanaUrl = require("../links/grafana_url")
local Normalize = require("../alerts/normalize")
local Scheme = require("../links/scheme")
local Sources = require("../alerts/sources")

type Config = ConfigTypes.Config
type Alert = Normalize.Alert
type Frame = Frame.Frame

export type Kind = "alert" | "query" | "panel"

export type Query = { ref: string?, expr: string, datasource: string? }

export type Link = { label: string, url: string }

export type AlertInfo = {
	name: string,
	state: string,
	severity: string,
	summary: string,
	description: string?,
	since_ms: number,
	labels: { [string]: string },
	annotations: { [string]: string },
	value: string?,
	source: string,
}

export type PanelInfo = {
	title: string,
	type: string,
	dashboard: string?,
	uid: string?,
	id: number?,
}

export type TimeWindow = { from: string, to: string, from_ms: number, to_ms: number }

export type Values = {
	series: { Compact.Series },
	omitted: number,
	from_ms: number,
	to_ms: number,
	-- Series were dropped (counted in `omitted`) so the subject fits in its link.
	trimmed: boolean?,
}

export type Subject = {
	kind: Kind,
	context: string?,
	title: string,
	alert: AlertInfo?,
	panel: PanelInfo?,
	queries: { Query },
	range: TimeWindow?,
	values: Values?,
	-- The preview block fetches recent values of queries[1] itself (alerts,
	-- whose source block has no samples).
	fetch: boolean?,
	links: { Link },
}

export type QueryInput = {
	context: string?,
	expr: string,
	ds: string?,
	range: TimeWindow,
	frames: { Frame }?,
}

export type PanelInput = {
	context: string?,
	dashboard: string?,
	uid: string?,
	panel_id: number?,
	title: string,
	type: string,
	queries: { Query },
	range: TimeWindow,
	vars: { [string]: { string } }?,
	frames: { Frame }?,
}

local M = {}

M.MAX_SERIES = 10
M.SPARK = 8
M.MAX_LABELS = 24
M.MAX_ANNOTATIONS = 12
M.MAX_QUERIES = 8
M.MAX_VALUE = 1000
M.MAX_EXPR = 4000

local KINDS: { [string]: boolean } = { alert = true, query = true, panel = true }

-- An http(s) URL with no userinfo and no credential-named query parameter
-- (`?token=`, `?api_key=`): subjects end up in links and block args.
local function isHttp(url: string?): boolean
	local parsed = if url then GrafanaUrl.parse(url :: string) else nil
	if parsed == nil then
		return false
	end
	for part in string.gmatch(parsed.query, "[^&;]+") do
		local name = string.match(part, "^[^=]*") :: string
		if Scheme.isCredentialName(Scheme.percentDecode(name, true) or name) then
			return false
		end
	end
	return true
end

local function base(config: Config?, context: string?): string?
	if context == nil then
		return nil
	end
	for _, b in GrafanaUrl.bases(config) do
		if b.context == context then
			return b.url
		end
	end
	return nil
end

-- The Grafana page for a tern-grafana link on `context`, when the context
-- has Grafana and the link is valid.
local function page(config: Config?, context: string?, link: Scheme.Link, encode: (any) -> string): string?
	local b = base(config, context)
	if b == nil or Scheme.validate(link) == nil then
		return nil
	end
	local ok, url = pcall(GrafanaUrl.build, link, b, encode)
	return if ok and isHttp(url) then url else nil
end

local function addLink(links: { Link }, label: string, url: string?)
	if url and isHttp(url) then
		for _, l in links do
			if l.url == url then
				return
			end
		end
		table.insert(links, { label = label, url = url :: string })
	end
end

local function values(frames: { Frame }?, range: TimeWindow): Values?
	if frames == nil then
		return nil
	end
	local series, omitted = Compact.series(frames :: { Frame }, { max_series = M.MAX_SERIES, spark = M.SPARK })
	return { series = series, omitted = omitted, from_ms = range.from_ms, to_ms = range.to_ms }
end

local function clipMap(src: { [string]: string }, max: number, skip: (string) -> boolean): { [string]: string }
	local names: { string } = {}
	for name in src do
		if not skip(name) then
			table.insert(names, name)
		end
	end
	table.sort(names)
	local out: { [string]: string } = {}
	for i = 1, math.min(#names, max) do
		out[names[i]] = Compact.clip(src[names[i]], M.MAX_VALUE)
	end
	return out
end

-- The PromQL behind a Prometheus alert (its generator URL's `g0.expr`).
local function alertExpr(alert: Alert): string?
	local target = Sources.generatorTarget(alert)
	if target == nil or not Scheme.isLink(target) then
		return nil
	end
	local l = Scheme.decode(target)
	return if l then l.params.expr else nil
end

local SHOWN_ANNOTATIONS = { summary = true, description = true, runbook_url = true }

function M.fromAlert(alert: Alert, config: Config?, encode: (any) -> string): Subject
	local name = alert.labels.alertname or alert.summary
	local links: { Link } = {}
	addLink(links, "Runbook", alert.runbook_url)
	if alert.dashboard_uid then
		local params: { [string]: string } = { uid = alert.dashboard_uid :: string }
		if alert.panel_id then
			params.panel = tostring(alert.panel_id)
		end
		addLink(
			links,
			"Dashboard",
			page(config, alert.context, { action = "dashboard", params = params, vars = {} }, encode)
		)
	end
	addLink(links, "Dashboard", alert.dashboard_url)
	addLink(links, "Alert source", alert.generator_url)
	local expr = alertExpr(alert)
	return {
		kind = "alert",
		context = alert.context,
		title = Compact.clip(name, 120),
		alert = {
			name = Compact.clip(name, 200),
			state = alert.state :: string,
			severity = alert.severity :: string,
			summary = Compact.clip(alert.summary, M.MAX_VALUE),
			description = if alert.description then Compact.clip(alert.description :: string, M.MAX_VALUE) else nil,
			since_ms = alert.starts_at_ms,
			labels = clipMap(alert.labels, M.MAX_LABELS, function(n: string): boolean
				return n == "alertname" or Normalize.isInternal(n)
			end),
			annotations = clipMap(alert.annotations, M.MAX_ANNOTATIONS, function(n: string): boolean
				return SHOWN_ANNOTATIONS[n] == true or Normalize.isInternal(n)
			end),
			value = if alert.value then Compact.clip(alert.value :: string, M.MAX_VALUE) else nil,
			source = alert.source :: string,
		},
		queries = if expr then { { expr = Compact.clip(expr, M.MAX_EXPR) } } else {},
		fetch = if expr then true else nil,
		links = links,
	}
end

function M.fromQuery(q: QueryInput, config: Config?, encode: (any) -> string): Subject
	local links: { Link } = {}
	local ctx = if q.context and config then config.contexts[q.context :: string] else nil
	local g = if ctx then ctx.grafana else nil
	local ds = q.ds or (if g and g.datasources then g.datasources.prometheus else nil)
	local params: { [string]: string } = { expr = q.expr, from = q.range.from, to = q.range.to }
	if ds then
		params.ds = ds
	end
	addLink(links, "Grafana Explore", page(config, q.context, { action = "query", params = params, vars = {} }, encode))
	return {
		kind = "query",
		context = q.context,
		title = "PromQL " .. Compact.clip(q.expr, 60),
		queries = { { expr = Compact.clip(q.expr, M.MAX_EXPR), datasource = q.ds } },
		range = q.range,
		values = values(q.frames, q.range),
		links = links,
	}
end

function M.fromPanel(p: PanelInput, config: Config?, encode: (any) -> string): Subject
	local links: { Link } = {}
	if p.uid and p.panel_id then
		local params: { [string]: string } = {
			uid = p.uid :: string,
			panel = tostring(p.panel_id),
			from = p.range.from,
			to = p.range.to,
		}
		addLink(
			links,
			"Grafana panel",
			page(config, p.context, { action = "panel", params = params, vars = p.vars or {} }, encode)
		)
	end
	local queries: { Query } = {}
	for i = 1, math.min(#p.queries, M.MAX_QUERIES) do
		local q = p.queries[i]
		table.insert(queries, { ref = q.ref, expr = Compact.clip(q.expr, M.MAX_EXPR), datasource = q.datasource })
	end
	local title = if p.title ~= "" then p.title else "Panel " .. tostring(p.panel_id or "")
	return {
		kind = "panel",
		context = p.context,
		title = Compact.clip(title, 120),
		panel = {
			title = Compact.clip(title, 200),
			type = p.type,
			dashboard = if p.dashboard then Compact.clip(p.dashboard :: string, 200) else nil,
			uid = p.uid,
			id = p.panel_id,
		},
		queries = queries,
		range = p.range,
		values = values(p.frames, p.range),
		links = links,
	}
end

local function stringMap(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	for k, x in v do
		if type(k) ~= "string" or type(x) ~= "string" then
			return false
		end
	end
	return true
end

-- `raw` (from kv or saved state, written by another VM or an older version)
-- as a Subject, or nil when it does not have the expected shape.
function M.read(raw: any): Subject?
	if type(raw) ~= "table" or not KINDS[raw.kind] or type(raw.title) ~= "string" then
		return nil
	end
	if raw.context ~= nil and type(raw.context) ~= "string" then
		return nil
	end
	if type(raw.queries) ~= "table" or type(raw.links) ~= "table" then
		return nil
	end
	for _, q in raw.queries do
		if type(q) ~= "table" or type(q.expr) ~= "string" then
			return nil
		end
	end
	for _, l in raw.links do
		if type(l) ~= "table" or type(l.label) ~= "string" or not isHttp(l.url) then
			return nil
		end
	end
	local a = raw.alert
	if a ~= nil then
		if type(a) ~= "table" or type(a.name) ~= "string" or type(a.since_ms) ~= "number" then
			return nil
		end
		if not stringMap(a.labels) or not stringMap(a.annotations) then
			return nil
		end
	end
	local r = raw.range
	if r ~= nil and (type(r) ~= "table" or type(r.from_ms) ~= "number" or type(r.to_ms) ~= "number") then
		return nil
	end
	local v = raw.values
	if v ~= nil and (type(v) ~= "table" or type(v.series) ~= "table") then
		return nil
	end
	return raw :: Subject
end

return M
