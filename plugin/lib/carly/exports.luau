--!strict
-- Carly's exports (G3): argument validation, the requests each export sends
-- and the compact answer built from the responses. plugin/carly_window.luau
-- registers them with tern.carly.export and only runs the fetches.
--
-- Answers are summaries, never raw matrices or log dumps: series statistics,
-- the first lines of a log query, alert headlines. Every answer is cut to
-- Compact.MAX_BYTES so it crosses into Carly's VM (16 KiB cap), and no
-- answer carries credentials: only names, values and http(s) URLs from the
-- config's endpoint `url`s, which never hold userinfo.

local Compact = require("./compact")
local ConfigTypes = require("../config/types")
local Env = require("../env")
local Frame = require("../frame/types")
local GrafanaUrl = require("../links/grafana_url")
local Loki = require("../source/loki")
local Metrics = require("../source/metrics")
local Normalize = require("../alerts/normalize")
local Range = require("../time/range")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Search = require("../dashboard/search")
local Sources = require("../alerts/sources")
local Step = require("../time/step")
local TransportTypes = require("../transport/types")

type Config = ConfigTypes.Config
type Env = Env.Env
type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type Alert = Normalize.Alert

export type Fetch = { tag: string, route: Route, request: Request }

-- What one export call does: send `fetches` (concurrently), then hand every
-- response, keyed by tag, to `finish`, which answers (value) or fails
-- (nil, message).
export type Plan = {
	fetches: { Fetch },
	finish: (responses: { [string]: Response }, env: Env) -> (any, string?),
}

export type Window = { from: string, to: string, from_ms: number, to_ms: number }

local M = {}

M.MAX_EXPR = 8192
M.MAX_QUERY = 256
-- Points per series a range query asks for; summaries need no more.
M.RANGE_POINTS = 120
M.INSTANT_SPAN_MS = 5 * 60 * 1000
M.DEFAULT_LOGS_RANGE = "1h"
M.LOG_LIMIT = 100
M.LOG_LINE_CHARS = 300
M.MAX_STREAMS = 20
M.MAX_ALERTS = 50
M.MAX_LABELS = 12
M.MAX_DASHBOARDS = 20

local function fail(message: string): (nil, string)
	return nil, message
end

local function contextNames(config: Config): string
	local names: { string } = {}
	for name in config.contexts do
		table.insert(names, name)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

-- Free text argument: a non-empty string of at most `max` bytes without
-- control characters other than tab and newline.
function M.text(v: any, what: string, max: number, allow_empty: boolean?): (string?, string?)
	if type(v) ~= "string" then
		return fail(string.format("%s must be a string", what))
	end
	local trimmed = string.match(v, "^%s*(.-)%s*$") or ""
	if trimmed == "" and not allow_empty then
		return fail(string.format("%s must not be empty", what))
	end
	if #trimmed > max then
		return fail(string.format("%s is longer than %d bytes", what, max))
	end
	if string.find(trimmed, "[%z\1-\8\11-\31\127]") then
		return fail(string.format("%s contains control characters", what))
	end
	return trimmed, nil
end

-- The context to use: the named one, which must exist, else the default.
function M.context(config: Config?, v: any): (string?, string?)
	if config == nil then
		return fail("Tern Grafana has no valid config (see docs/configuration.md)")
	end
	local cfg = config :: Config
	if v == nil then
		local name = cfg.default_context
		if name == nil then
			return fail(
				string.format("no context given and default_context is not set (contexts: %s)", contextNames(cfg))
			)
		end
		return name, nil
	end
	if type(v) ~= "string" then
		return fail("context must be a string")
	end
	if cfg.contexts[v] == nil then
		return fail(string.format("no context named %q (contexts: %s)", v, contextNames(cfg)))
	end
	return v, nil
end

local function window(from: string, to: string, now_ms: number): (Window?, string?)
	local r, err = Range.resolve(from, to, { now_ms = now_ms })
	if r == nil then
		return fail("range: " .. (err or "invalid"))
	end
	if r.to_ms <= r.from_ms then
		return fail("range: from must be before to")
	end
	return { from = from, to = to, from_ms = r.from_ms, to_ms = r.to_ms }, nil
end

-- A range argument: a duration back from now ("1h"), a Grafana start
-- ("now-6h", absolute times too) or {from, to}.
function M.range(v: any, now_ms: number): (Window?, string?)
	if type(v) == "string" then
		local text = string.match(v, "^%s*(.-)%s*$") or ""
		if #text == 0 or #text > 64 then
			return fail('range must be a duration such as "1h" or a time such as "now-6h"')
		end
		local d = Step.parseDuration(text)
		if d ~= nil then
			if d <= 0 then
				return fail("range must be longer than zero")
			end
			return window("now-" .. text, "now", now_ms)
		end
		return window(text, "now", now_ms)
	elseif type(v) == "table" then
		local from, to = v.from, v.to
		if type(from) ~= "string" or (to ~= nil and type(to) ~= "string") or #from > 64 or (to and #to > 64) then
			return fail('range {from, to} needs string times such as "now-6h" and "now"')
		end
		return window(from, to or "now", now_ms)
	end
	return fail("range must be a string or {from, to}")
end

local function tooBig(response: Response?): string?
	if response and #response.body > Compact.MAX_BODY_BYTES then
		return string.format(
			"the result is too large (%d bytes): aggregate it (sum by, topk) or shorten the range",
			#response.body
		)
	end
	return nil
end

local function single(route: Route, request: Request, finish: (Response, Env) -> (any, string?)): Plan
	return {
		fetches = { { tag = "q", route = route, request = request } },
		finish = function(responses: { [string]: Response }, env: Env): (any, string?)
			local response = responses.q
			if response == nil then
				return fail("no response")
			end
			local big = tooBig(response)
			if big then
				return fail(big)
			end
			return finish(response, env)
		end,
	}
end

local function routeError(err: Route.RouteError?): string
	return if err then err.message else "the context cannot serve this"
end

function M.promql(args: { any }, env: Env): (Plan?, string?)
	local expr, exprErr = M.text(args[1], "expr", M.MAX_EXPR)
	if expr == nil then
		return fail(exprErr :: string)
	end
	local context, ctxErr = M.context(env.config, args[3])
	if context == nil then
		return fail(ctxErr :: string)
	end
	local route, routeErr = Route.route(env.config :: Config, context, "metrics")
	if route == nil then
		return fail(routeError(routeErr))
	end
	local r: Route = route
	local win: Window
	local kind: "instant" | "range" = if args[2] == nil then "instant" else "range"
	if kind == "range" then
		local w, err = M.range(args[2], env.now_ms)
		if w == nil then
			return fail(err :: string)
		end
		win = w
	else
		win = { from = "now", to = "now", from_ms = env.now_ms - M.INSTANT_SPAN_MS, to_ms = env.now_ms }
	end
	local span = math.max(1, win.to_ms - win.from_ms)
	local step = Step.promStep(span, M.RANGE_POINTS)
	local interval = Step.interval(span, M.RANGE_POINTS).interval_ms
	local sent = Step.interpolate(expr :: string, Step.macros(span, step, interval))
	local request = if kind == "range"
		then Metrics.rangeRequest(r, {
			expr = sent,
			from_ms = win.from_ms,
			to_ms = win.to_ms,
			step_ms = step,
			max_points = M.RANGE_POINTS,
		})
		else Metrics.instantRequest(r, { expr = sent, time_ms = win.to_ms })
	return single(r, request, function(response: Response, e: Env): (any, string?)
		local result = Metrics.parse(r, response, e, kind)
		if not result.ok then
			return fail((result :: any).error.message)
		end
		local series, omitted = Compact.series((result :: any).frames, { spark = if kind == "range" then nil else 0 })
		local out: { [string]: any } = {
			context = context,
			expr = expr,
			kind = kind,
			from = Compact.iso(if kind == "range" then win.from_ms else win.to_ms),
			to = Compact.iso(win.to_ms),
			step = if kind == "range" then Step.formatDuration(step) else nil,
			warnings = (result :: any).warnings or {},
			omitted = omitted,
			series = series,
		}
		return Compact.fit(out, "series", e), nil
	end),
		nil
end

local function alertLabels(a: Alert): { [string]: string }
	local names: { string } = {}
	for name in a.labels do
		if name ~= "alertname" and name ~= "severity" and not Normalize.isInternal(name) then
			table.insert(names, name)
		end
	end
	table.sort(names)
	local out: { [string]: string } = {}
	for i = 1, math.min(#names, M.MAX_LABELS) do
		out[names[i]] = Compact.clip(a.labels[names[i]], 120)
	end
	return out
end

local STATE_RANK: { [string]: number } = { firing = 2, pending = 1 }

function M.alerts(args: { any }, env: Env): (Plan?, string?)
	local context, ctxErr = M.context(env.config, args[1])
	if context == nil then
		return fail(ctxErr :: string)
	end
	local plan, planErr = Sources.plan(env.config :: Config, context)
	if plan == nil then
		return fail(planErr or "the context has no alert source")
	end
	local p: Sources.Plan = plan
	local fetches: { Fetch } = {}
	for _, f in p.fetches do
		table.insert(fetches, { tag = f.tag, route = f.route, request = f.request })
	end
	return {
		fetches = fetches,
		finish = function(responses: { [string]: Response }, e: Env): (any, string?)
			for _, f in p.fetches do
				local big = tooBig(responses[f.tag])
				if big then
					return fail(big)
				end
			end
			local result = Sources.combine(e, p, responses)
			if not result.ok then
				return fail(result.error or "the alerts could not be read")
			end
			local counts = { firing = 0, pending = 0, silenced = 0, inhibited = 0 }
			local shown: { Alert } = {}
			for _, a in result.alerts do
				if (counts :: any)[a.state] ~= nil then
					(counts :: any)[a.state] += 1
				end
				if STATE_RANK[a.state] then
					table.insert(shown, a)
				end
			end
			table.sort(shown, function(a: Alert, b: Alert): boolean
				if a.state ~= b.state then
					return STATE_RANK[a.state] > STATE_RANK[b.state]
				end
				local ra, rb = Normalize.SEVERITY_RANK[a.severity], Normalize.SEVERITY_RANK[b.severity]
				if ra ~= rb then
					return ra > rb
				end
				if a.starts_at_ms ~= b.starts_at_ms then
					return a.starts_at_ms < b.starts_at_ms
				end
				return a.fingerprint < b.fingerprint
			end)
			local list: { any } = {}
			for i = 1, math.min(#shown, M.MAX_ALERTS) do
				local a = shown[i]
				table.insert(list, {
					name = a.labels.alertname or Compact.clip(a.summary, 120),
					state = a.state,
					severity = a.severity,
					summary = Compact.clip(a.summary, 200),
					since = Compact.iso(a.starts_at_ms),
					labels = alertLabels(a),
					runbook = Sources.runbookTarget(a),
					dashboard = Sources.dashboardTarget(a),
					source = Sources.generatorTarget(a),
					fingerprint = a.fingerprint,
				})
			end
			local out: { [string]: any } = {
				context = context,
				counts = counts,
				warnings = result.warnings,
				omitted = #shown - #list,
				alerts = list,
			}
			return Compact.fit(out, "alerts", e), nil
		end,
	},
		nil
end

-- The Grafana page of a tern-grafana link on `context`, if it has Grafana.
function M.grafanaPage(config: Config?, context: string, link: Scheme.Link, encode: (any) -> string): string?
	for _, b in GrafanaUrl.bases(config) do
		if b.context == context then
			return GrafanaUrl.build(link, b.url, encode)
		end
	end
	return nil
end

function M.find_dashboard(args: { any }, env: Env): (Plan?, string?)
	local query, queryErr = M.text(args[1], "query", M.MAX_QUERY, true)
	if query == nil then
		return fail(queryErr :: string)
	end
	local context, ctxErr = M.context(env.config, args[2])
	if context == nil then
		return fail(ctxErr :: string)
	end
	local route, routeErr = Route.route(env.config :: Config, context, "dashboards")
	if route == nil then
		return fail(routeError(routeErr))
	end
	return single(route, Search.request(query :: string), function(response: Response, e: Env): (any, string?)
		local hits, err = Search.parse(response, e)
		if hits == nil then
			return fail(err or "the search failed")
		end
		local list: { any } = {}
		for i = 1, math.min(#hits, M.MAX_DASHBOARDS) do
			local h = hits[i]
			local l: Scheme.Link = { action = "dashboard", params = { context = context, uid = h.uid }, vars = {} }
			local ok, link = pcall(Scheme.encode, l)
			if not ok then
				continue
			end
			table.insert(list, {
				uid = h.uid,
				title = Compact.clip(h.title, 200),
				folder = h.folder,
				tags = h.tags,
				url = M.grafanaPage(e.config, context :: string, l, e.encode),
				link = link,
			})
		end
		local out: { [string]: any } = {
			context = context,
			query = query,
			omitted = #hits - #list,
			dashboards = list,
		}
		return Compact.fit(out, "dashboards", e), nil
	end),
		nil
end

function M.logs(args: { any }, env: Env): (Plan?, string?)
	local expr, exprErr = M.text(args[1], "expr", M.MAX_EXPR)
	if expr == nil then
		return fail(exprErr :: string)
	end
	local context, ctxErr = M.context(env.config, args[3])
	if context == nil then
		return fail(ctxErr :: string)
	end
	local route, routeErr = Route.route(env.config :: Config, context, "logs")
	if route == nil then
		return fail(routeError(routeErr))
	end
	local r: Route = route
	local win, rangeErr = M.range(if args[2] == nil then M.DEFAULT_LOGS_RANGE else args[2], env.now_ms)
	if win == nil then
		return fail(rangeErr :: string)
	end
	local w: Window = win
	local span = math.max(1, w.to_ms - w.from_ms)
	local request = Loki.rangeRequest(r, {
		expr = expr :: string,
		from_ms = w.from_ms,
		to_ms = w.to_ms,
		limit = M.LOG_LIMIT,
		direction = "backward",
		step_ms = Step.promStep(span, M.RANGE_POINTS),
		max_points = M.RANGE_POINTS,
	}, env)
	return single(r, request, function(response: Response, e: Env): (any, string?)
		local result = Loki.parse(r, response, e)
		if not result.ok then
			return fail((result :: any).error.message)
		end
		local res: any = result
		local out: { [string]: any } = {
			context = context,
			expr = expr,
			kind = res.kind,
			from = Compact.iso(w.from_ms),
			to = Compact.iso(w.to_ms),
			warnings = res.warnings or {},
			omitted = 0,
		}
		if res.kind ~= "streams" then
			local series, omitted = Compact.series(res.frames)
			out.series = series
			out.omitted = omitted
			return Compact.fit(out, "series", e), nil
		end
		local streams: { string } = {}
		local index: { [string]: number } = {}
		local lines: { any } = {}
		for _, line in res.lines do
			local key = Frame.formatLabels(line.labels)
			local s = index[key]
			if s == nil then
				if #streams < M.MAX_STREAMS then
					table.insert(streams, key)
					s = #streams
				else
					s = 0
				end
				index[key] = s
			end
			table.insert(lines, {
				t = Compact.iso(line.time_ms),
				level = line.level,
				line = Compact.clip(line.line, M.LOG_LINE_CHARS),
				s = s,
			})
		end
		out.streams = streams
		out.lines = lines
		return Compact.fit(out, "lines", e), nil
	end),
		nil
end

local PLANS: { [string]: (args: { any }, env: Env) -> (Plan?, string?) } = {
	promql = M.promql,
	alerts = M.alerts,
	find_dashboard = M.find_dashboard,
	logs = M.logs,
}

-- The plan for export `name` called with positional `args`.
function M.plan(name: string, args: { any }, env: Env): (Plan?, string?)
	local build = PLANS[name]
	if build == nil then
		return fail("unknown export " .. name)
	end
	return build(args, env)
end

return M
