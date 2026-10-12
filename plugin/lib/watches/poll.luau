--!strict
-- The background watch poller's decisions: which watches are due, the
-- request each one sends, when to wake up next, the kv summary the window
-- reads, and the state restored from that summary when the host restarts (so
-- a restart neither re-announces a firing watch nor restarts a `for` timer).
-- plugin/watches_poll_host.luau runs the timer and the requests.
--
-- kv `tern-grafana.watches.summary` is a 0644 file shared by every window: it
-- holds watch names, contexts, expressions (the user's own config), states,
-- times, counts and error kinds; never server messages or credentials.

local ConfigTypes = require("../config/types")
local Env = require("../env")
local Evaluate = require("./evaluate")
local Metrics = require("../source/metrics")
local Route = require("../config/route")
local Settings = require("./settings")
local TransportTypes = require("../transport/types")

type Config = ConfigTypes.Config
type Env = Env.Env
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type RouteT = Route.Route
type State = Evaluate.State
type Status = Evaluate.Status
type Watch = Settings.Watch

export type Job = {
	watch: Watch,
	-- nil when the watch cannot be routed (error says why).
	route: RouteT?,
	request: Request?,
	error: string?,
}

export type Entry = {
	name: string,
	context: string?,
	expr: string,
	op: string,
	threshold: number,
	severity: string,
	status: Status,
	since_ms: number,
	active_ms: number?,
	eval_ms: number?,
	interval_ms: number,
	def: string,
	series: number,
	matching: number,
	value: number?,
	no_data: boolean,
	error: string?,
}

export type Payload = { v: number, updated_ms: number, watches: { Entry } }

local M = {}

M.KEY = "tern-grafana.watches.summary"
M.VERSION = 1
-- Never wake sooner than this, even when several watches fall due apart.
M.MIN_DELAY_MS = 1000
-- How often a poller without watches looks at the config again.
M.IDLE_MS = 60000
-- A summary older than this many intervals (and at least MIN_RESTORE_MS) is
-- not restored: too much may have happened while nothing watched.
M.RESTORE_INTERVALS = 3
M.MIN_RESTORE_MS = 5 * 60 * 1000

-- Watches whose interval has elapsed since their last evaluation.
function M.due(watches: { Watch }, states: { [string]: State }, now_ms: number): { Watch }
	local out: { Watch } = {}
	for _, w in watches do
		local s = states[w.name]
		local last = if s and s.def == w.def then s.eval_ms else nil
		if last == nil or now_ms - last >= w.interval_ms then
			table.insert(out, w)
		end
	end
	return out
end

-- Milliseconds until the next watch falls due; IDLE_MS without watches.
function M.nextDelay(watches: { Watch }, states: { [string]: State }, now_ms: number): number
	local best: number? = nil
	for _, w in watches do
		local s = states[w.name]
		local last = if s and s.def == w.def then s.eval_ms else nil
		local wait = if last == nil then 0 else last + w.interval_ms - now_ms
		if best == nil or wait < best then
			best = wait
		end
	end
	if best == nil then
		return M.IDLE_MS
	end
	return math.max(M.MIN_DELAY_MS, best :: number)
end

-- The request for one watch; `config` already carries the host default.
function M.job(config: Config, watch: Watch, now_ms: number): Job
	local route, err = Route.route(config, watch.context, "metrics")
	if route == nil then
		return { watch = watch, error = if err then err.message else "unroutable" }
	end
	return {
		watch = watch,
		route = route,
		request = Metrics.instantRequest(route, { expr = watch.expr, time_ms = now_ms }),
	}
end

-- The state after a job's response (or its routing failure).
function M.finish(env: Env, prev: State?, job: Job, response: Response?, now_ms: number): State
	local obs: Evaluate.Observation
	if job.route == nil or response == nil then
		obs = { series = 0, matching = 0, nan = 0, value = nil, error = "config" }
	else
		obs = Evaluate.observe(job.watch, Metrics.parse(job.route :: RouteT, response, env, "instant"))
	end
	return Evaluate.step(prev, job.watch, obs, now_ms)
end

function M.payload(watches: { Watch }, states: { [string]: State }, config: Config?, now_ms: number): Payload
	local out: { Entry } = {}
	for _, w in watches do
		local s = states[w.name]
		if s and s.def == w.def then
			table.insert(out, {
				name = w.name,
				context = w.context or (if config then Route.defaultContext(config) else nil),
				expr = w.expr,
				op = w.op :: string,
				threshold = w.threshold,
				severity = w.severity :: string,
				status = s.status,
				since_ms = s.since_ms,
				active_ms = s.active_ms,
				eval_ms = s.eval_ms,
				interval_ms = w.interval_ms,
				def = w.def,
				series = s.series,
				matching = s.matching,
				value = s.value,
				no_data = s.no_data,
				error = s.error,
			})
		end
	end
	return { v = M.VERSION, updated_ms = now_ms, watches = out }
end

local STATUSES: { [string]: boolean } = { ok = true, pending = true, firing = true }

local function num(v: any): number?
	return if type(v) == "number" and v == v then v else nil
end

-- The payload as written, or nil when it is not one.
function M.read(raw: any): Payload?
	if type(raw) ~= "table" or raw.v ~= M.VERSION or num(raw.updated_ms) == nil or type(raw.watches) ~= "table" then
		return nil
	end
	local out: { Entry } = {}
	for _, e in raw.watches do
		if
			type(e) == "table"
			and type(e.name) == "string"
			and type(e.expr) == "string"
			and type(e.def) == "string"
			and STATUSES[e.status]
			and num(e.since_ms)
		then
			table.insert(out, {
				name = e.name,
				context = if type(e.context) == "string" then e.context else nil,
				expr = e.expr,
				op = if type(e.op) == "string" then e.op else "",
				threshold = num(e.threshold) or 0,
				severity = if type(e.severity) == "string" then e.severity else Settings.DEFAULT_SEVERITY,
				status = e.status,
				since_ms = e.since_ms,
				active_ms = num(e.active_ms),
				eval_ms = num(e.eval_ms),
				interval_ms = num(e.interval_ms) or Settings.DEFAULT_INTERVAL_MS,
				def = e.def,
				series = num(e.series) or 0,
				matching = num(e.matching) or 0,
				value = num(e.value),
				no_data = e.no_data == true,
				error = if type(e.error) == "string" then e.error else nil,
			})
		end
	end
	return { v = M.VERSION, updated_ms = raw.updated_ms, watches = out }
end

-- States to resume from the previous summary: only for watches whose
-- definition is unchanged and whose summary is recent.
function M.restore(raw: any, watches: { Watch }, now_ms: number): { [string]: State }
	local states: { [string]: State } = {}
	local payload = M.read(raw)
	if payload == nil then
		return states
	end
	local byName: { [string]: Entry } = {}
	for _, e in payload.watches do
		byName[e.name] = e
	end
	for _, w in watches do
		local e = byName[w.name]
		local limit = math.max(M.RESTORE_INTERVALS * w.interval_ms, M.MIN_RESTORE_MS)
		if e and e.def == w.def and now_ms - payload.updated_ms <= limit then
			states[w.name] = {
				status = e.status,
				since_ms = e.since_ms,
				active_ms = e.active_ms,
				eval_ms = e.eval_ms,
				def = e.def,
				series = e.series,
				matching = e.matching,
				value = e.value,
				error = e.error,
				no_data = e.no_data,
			}
		end
	end
	return states
end

return M
