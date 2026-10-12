--!strict
-- The impact watch block (`tern-grafana.impact`), opened by the command hook
-- after a matching deploy. It compares each signal's mean over the window
-- before the command started with the window after it finished (lib/impact/
-- delta.luau) and re-queries until the after window is over. Signals are the
-- configured ones for the context, else RED queries guessed from the metric
-- names (lib/impact/signals.luau). Read-only: init may query (a restored
-- block shows the same comparison again).

local Delta = require("./delta")
local Effect = require("../effect")
local Env = require("../env")
local Metrics = require("../source/metrics")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Settings = require("./settings")
local Signals = require("./signals")
local Step = require("../time/step")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Effect = Effect.Effect
type Response = TransportTypes.Response
type Signal = Signals.Signal

export type SeriesResult = {
	name: string,
	cmp: Delta.Comparison,
	before: { number? },
	after: { number? },
}

export type Row = {
	signal: Signal,
	loading: boolean,
	error: string?,
	series: { SeriesResult },
	-- Series beyond MAX_SERIES.
	more: number,
}

export type State = {
	context: string?,
	start_ms: number,
	finish_ms: number,
	window_ms: number,
	kind: string?,
	vars: Signals.Vars,
	route: Route.Route?,
	problem: string?,
	phase: "probing" | "querying" | "ready" | "idle",
	gen: number,
	rows: { Row },
	skipped: { Signals.Skipped },
	guessed: boolean,
	-- Probe state: metric names, then label names per candidate counter.
	counters: { string },
	labels: { [string]: { string } },
	names: { string },
	pending: number,
	sel: number,
	loaded_ms: number?,
	final: boolean,
}

local M = {}

M.MAX_SERIES = 5
M.SPARK_POINTS = 30
M.MIN_STEP_MS = 15000
-- Points per query across before + command + after.
M.MAX_POINTS = 120
M.MIN_REFRESH_MS = 15000
M.MAX_REFRESH_MS = 60000

function M.stepMs(s: State): number
	local span = 2 * s.window_ms + math.max(0, s.finish_ms - s.start_ms)
	return math.max(M.MIN_STEP_MS, math.ceil(span / M.MAX_POINTS / 1000) * 1000)
end

function M.refreshMs(s: State): number
	return math.clamp(math.floor(s.window_ms / 15), M.MIN_REFRESH_MS, M.MAX_REFRESH_MS)
end

-- The rate window of guessed queries: Grafana's $__rate_interval at the step.
function M.rateWindow(s: State): string
	return Step.formatDuration(Step.rateInterval(M.stepMs(s)))
end

local function linkParams(args: { string }): { [string]: string }?
	local first = args[1]
	if first == nil or first == "" then
		return nil
	end
	local link = Scheme.decode(first)
	if link == nil or link.action ~= "impact" then
		return nil
	end
	return link.params
end

local function blank(): State
	return {
		context = nil,
		start_ms = 0,
		finish_ms = 0,
		window_ms = 0,
		kind = nil,
		vars = {},
		route = nil,
		problem = nil,
		phase = "idle",
		gen = 0,
		rows = {},
		skipped = {},
		guessed = false,
		counters = {},
		labels = {},
		names = {},
		pending = 0,
		sel = 1,
		loaded_ms = nil,
		final = false,
	}
end

local function rowsOf(signals: { Signal }): { Row }
	local out: { Row } = {}
	for _, sig in signals do
		table.insert(out, { signal = sig, loading = true, error = nil, series = {}, more = 0 })
	end
	return out
end

local function query(s: State, env: Env, effects: { Effect })
	local route = s.route :: Route.Route
	s.gen += 1
	s.phase = "querying"
	s.pending = #s.rows
	local to = math.min(env.now_ms, s.finish_ms + s.window_ms)
	local from = s.start_ms - s.window_ms
	local step = M.stepMs(s)
	for i, row in s.rows do
		row.loading = true
		table.insert(effects, {
			kind = "http",
			tag = string.format("%d:q:%d", s.gen, i),
			route = route,
			request = Metrics.rangeRequest(route, {
				expr = row.signal.expr,
				from_ms = from,
				to_ms = math.max(to, from + step),
				step_ms = step,
				max_points = M.MAX_POINTS,
				ref_id = "A",
			}),
		})
	end
	if #s.rows == 0 then
		s.phase = "ready"
	end
end

local function probeNames(s: State, env: Env, effects: { Effect })
	s.gen += 1
	s.phase = "probing"
	s.pending = 1
	table.insert(effects, {
		kind = "http",
		tag = string.format("%d:names", s.gen),
		route = s.route :: Route.Route,
		request = Metrics.labelValuesRequest(s.route :: Route.Route, "__name__", {
			from_ms = s.start_ms - s.window_ms,
			to_ms = math.max(env.now_ms, s.start_ms),
		}),
	})
end

function M.init(args: { string }, _saved: any, env: Env): (State, { Effect })
	local s = blank()
	local effects: { Effect } = {}
	local params = linkParams(args)
	if params == nil then
		s.problem = "This block is opened by a deploy command (see docs/annotations.md, impact)."
		return s, effects
	end
	local settings = Settings.read(env.config)
	s.start_ms = tonumber(params.start) :: number
	s.finish_ms = math.max(tonumber(params.finish) :: number, s.start_ms)
	s.window_ms = settings.window_ms
	s.kind = params.kind
	s.vars = { namespace = params.ns, service = params.svc, cwd_basename = params.dir }
	if env.config == nil then
		s.problem = "No valid config: open Grafana: Settings or see docs/configuration.md."
		return s, effects
	end
	local route, err = Route.route(env.config :: any, params.context, "metrics")
	if route == nil then
		s.problem = if err then err.message else "no metrics route"
		return s, effects
	end
	s.route = route
	s.context = route.context
	local specs = Settings.signalsFor(settings, route.context)
	if specs then
		local signals, skipped = Signals.configured(specs, s.vars)
		s.rows = rowsOf(signals)
		s.skipped = skipped
		if #signals == 0 then
			s.problem = "No configured signal could be filled for this command."
			return s, effects
		end
		query(s, env, effects)
	else
		s.guessed = true
		probeNames(s, env, effects)
	end
	return s, effects
end

local function guessFrom(s: State, env: Env, effects: { Effect })
	local counter: string? = nil
	for _, c in s.counters do
		local labels = s.labels[c]
		if labels and Signals.statusLabel(labels) then
			counter = c
			break
		end
	end
	counter = counter or s.counters[1]
	local labels = if counter then s.labels[counter] or {} else {}
	local probe: Signals.Probe = {
		counter = counter,
		status_label = Signals.statusLabel(labels),
		labels = labels,
		histogram = Signals.histogram(s.names, counter),
	}
	local signals = Signals.guess(probe, s.vars, M.rateWindow(s))
	s.names = {}
	if #signals == 0 then
		s.phase = "ready"
		s.problem = "No request metrics found to guess from (no *_requests_total or "
			.. "*_request_duration_seconds_bucket). Configure impact.signals for this context."
		return
	end
	s.rows = rowsOf(signals)
	query(s, env, effects)
end

local function onNames(s: State, env: Env, response: Response, effects: { Effect })
	local result = Metrics.parseList(s.route :: Route.Route, response, env)
	if not result.ok then
		s.phase = "ready"
		s.problem = "Could not list metric names to guess signals: " .. (result :: any).error.message
		return
	end
	s.names = (result :: any).values
	local counters = Signals.counters(s.names)
	s.counters = table.move(counters, 1, math.min(#counters, Signals.MAX_PROBES), 1, {})
	if #s.counters == 0 then
		guessFrom(s, env, effects)
		return
	end
	s.pending = #s.counters
	for i, c in s.counters do
		table.insert(effects, {
			kind = "http",
			tag = string.format("%d:labels:%d", s.gen, i),
			route = s.route :: Route.Route,
			request = Metrics.labelsRequest(s.route :: Route.Route, {
				match = { c },
				from_ms = s.start_ms - s.window_ms,
				to_ms = math.max(env.now_ms, s.start_ms),
			}),
		})
	end
end

local function onRange(s: State, env: Env, i: number, response: Response)
	local row = s.rows[i]
	if row == nil then
		return
	end
	row.loading = false
	local result = Metrics.parse(s.route :: Route.Route, response, env, "range")
	if not result.ok then
		row.error = (result :: any).error.message
		return
	end
	row.error = nil
	local all = Delta.series((result :: any).frames)
	local w: Delta.Window = { start_ms = s.start_ms, finish_ms = s.finish_ms, window_ms = s.window_ms }
	row.series = {}
	row.more = math.max(0, #all - M.MAX_SERIES)
	for k = 1, math.min(#all, M.MAX_SERIES) do
		local series = all[k]
		local before, after = Delta.sides(series, w)
		table.insert(row.series, {
			name = series.name,
			cmp = Delta.compare(before, after, row.signal.bad),
			before = Delta.buckets(series, s.start_ms - s.window_ms, s.start_ms, M.SPARK_POINTS),
			after = Delta.buckets(series, s.finish_ms, s.finish_ms + s.window_ms, M.SPARK_POINTS),
		})
	end
end

local function settled(s: State, env: Env, effects: { Effect })
	s.phase = "ready"
	s.loaded_ms = env.now_ms
	-- One last query once the after window is fully in the past.
	if env.now_ms >= s.finish_ms + s.window_ms + M.stepMs(s) then
		s.final = true
		return
	end
	local wait = math.min(M.refreshMs(s), math.max(1000, s.finish_ms + s.window_ms + M.stepMs(s) - env.now_ms))
	table.insert(effects, { kind = "timer", tag = string.format("auto:%d", s.gen), ms = wait })
end

function M.selectedLink(s: State): string?
	local row = s.rows[s.sel]
	if row == nil or s.context == nil then
		return nil
	end
	return Scheme.encode({
		action = "query",
		params = {
			context = s.context :: string,
			expr = row.signal.expr,
			from = string.format("%d", s.start_ms - s.window_ms),
			to = string.format("%d", s.finish_ms + s.window_ms),
		},
		vars = {},
	})
end

local function selectRow(s: State, i: number, effects: { Effect })
	if #s.rows == 0 then
		return
	end
	s.sel = math.clamp(i, 1, #s.rows)
	table.insert(effects, { kind = "reveal", id = "main.sigs.s" .. s.sel })
end

local function reload(s: State, env: Env, effects: { Effect })
	if s.route == nil or s.phase == "probing" then
		return
	end
	s.final = false
	if #s.rows > 0 then
		query(s, env, effects)
	elseif s.guessed then
		s.problem = nil
		probeNames(s, env, effects)
	end
end

function M.key(s: State, key: any, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	if key.ctrl or key.meta or key.alt then
		return s, effects, false
	end
	local name: string = if type(key.name) == "string" then key.name else ""
	local text: string = if type(key.text) == "string" then key.text else ""
	if name == "down" or text == "j" then
		selectRow(s, s.sel + 1, effects)
	elseif name == "up" or text == "k" then
		selectRow(s, s.sel - 1, effects)
	elseif text == "r" then
		reload(s, env, effects)
	elseif name == "enter" or text == "o" then
		local link = M.selectedLink(s)
		if link == nil then
			return s, effects, false
		end
		table.insert(effects, { kind = "open", target = link })
	else
		return s, effects, false
	end
	return s, effects, true
end

function M.update(s: State, msg: any, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		local gen, what, idx = string.match(msg.tag, "^(%d+):(%a+):?(%d*)$")
		if gen == nil or tonumber(gen) ~= s.gen or s.route == nil then
			return s, effects
		end
		local phase: string = s.phase
		if what == "names" and phase == "probing" then
			s.pending = 0
			onNames(s, env, msg.response, effects)
		elseif what == "labels" and phase == "probing" then
			local c = s.counters[tonumber(idx) or 0]
			if c then
				local result = Metrics.parseList(s.route :: Route.Route, msg.response, env)
				s.labels[c] = if result.ok then (result :: any).values else {}
			end
			s.pending -= 1
			if s.pending <= 0 then
				guessFrom(s, env, effects)
			end
		elseif what == "q" and phase == "querying" then
			onRange(s, env, tonumber(idx) or 0, msg.response)
			s.pending -= 1
			if s.pending <= 0 then
				settled(s, env, effects)
			end
		end
	elseif msg.kind == "tick" then
		if msg.tag == string.format("auto:%d", s.gen) and s.phase == "ready" and not s.final then
			query(s, env, effects)
		end
	elseif msg.kind == "key" then
		local _, list = M.key(s, msg.key, env)
		return s, list
	elseif msg.kind == "event" then
		local ev: any = msg.ev
		if ev.ev == "action" and type(ev.act) == "string" then
			local i = tonumber(ev.value or "")
			if ev.act == "reload" then
				reload(s, env, effects)
			elseif ev.act == "row" and i then
				selectRow(s, i, effects)
			elseif ev.act == "open" and i and s.rows[i] then
				s.sel = i
				local link = M.selectedLink(s)
				if link then
					table.insert(effects, { kind = "open", target = link })
				end
			end
		end
	end
	return s, effects
end

function M.title(s: State): string?
	local what = s.vars.service or s.kind or "deploy"
	return "Impact: " .. what
end

return M
