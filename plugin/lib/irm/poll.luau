--!strict
-- One background IRM poll for the status segment. Per context: discover the
-- IRM app (cached for DISCOVERY_TTL_MS), then read open alert-group counts
-- (one tiny page per state), open incidents and, when `irm.names` allows,
-- the schedules and users that say who is on call now. The answers become
-- the kv summary (lib/irm/summary.luau). plugin/irm_poll_host.luau runs it:
-- it calls `step` whenever a job's requested fetches have all answered and
-- sends what comes back, until `step` returns none.

local ConfigTypes = require("../config/types")
local Env = require("../env")
local Irm = require("../source/irm")
local Route = require("../config/route")
local Settings = require("./settings")
local Summary = require("./summary")
local Target = require("./target")
local TransportTypes = require("../transport/types")

type Config = ConfigTypes.Config
type Env = Env.Env
type Route = Route.Route
type Request = TransportTypes.Request
type Response = TransportTypes.Response
type ContextSummary = Summary.ContextSummary

export type Fetch = { tag: string, route: Route, request: Request }

-- What the host keeps between polls, per context.
-- `url` is the Grafana URL it was discovered from: a config change re-discovers.
export type Cached = {
	url: string,
	discovery: Irm.Discovery?,
	problem: string?,
	error: string?,
	fetched_ms: number,
}
export type Cache = { [string]: Cached }

export type Job = {
	context: string,
	grafana: Route?,
	-- Why this context cannot be polled at all (config).
	problem: string?,
	-- "shifts" reads current_oncall of the schedules `user` is on call in,
	-- for when their shift ends.
	stage: "discover" | "read" | "shifts" | "done",
	names: boolean,
	user: string?,
	responses: { [string]: Response },
}

local M = {}

M.DISCOVERY_TTL_MS = 30 * 60 * 1000
-- A failed discovery (network, auth) is retried sooner.
M.DISCOVERY_RETRY_MS = 5 * 60 * 1000
-- Schedules whose shift end is read for `irm.user`.
M.MAX_SHIFT_SCHEDULES = 4

local GROUP_STATES: { Irm.GroupState } = { "firing", "acknowledged", "silenced" }

-- (jobs, settings); no jobs when polling is off or nothing is configured.
function M.jobs(config: Config?): ({ Job }, Settings.Settings)
	local settings = Settings.read(config)
	if config == nil or settings.poll_s == 0 then
		return {}, settings
	end
	local jobs: { Job } = {}
	for _, name in settings.contexts do
		local route, why = Target.grafana(config, name)
		table.insert(jobs, {
			context = name,
			grafana = route,
			problem = why,
			stage = if route then "discover" else "done",
			names = settings.names,
			user = settings.user,
			responses = {},
		})
	end
	return jobs, settings
end

local function fresh(c: Cached?, url: string, now_ms: number): boolean
	if c == nil or c.url ~= url then
		return false
	end
	local ttl = if c.error then M.DISCOVERY_RETRY_MS else M.DISCOVERY_TTL_MS
	return now_ms - c.fetched_ms < ttl
end

local function readFetches(job: Job, cached: Cached, env: Env): { Fetch }
	local grafana = job.grafana :: Route
	local out: { Fetch } = {
		{ tag = "incidents", route = grafana, request = Irm.openIncidentsRequest(Irm.MAX_INCIDENTS, env.encode) },
	}
	local d = cached.discovery
	if d and d.oncall_url then
		local oncall = Irm.oncallRoute(grafana, d.oncall_url :: string)
		for _, state in GROUP_STATES do
			table.insert(out, { tag = "g:" .. state, route = oncall, request = Irm.groupsRequest(state, 1) })
		end
		if job.names or job.user then
			table.insert(out, { tag = "schedules", route = oncall, request = Irm.schedulesRequest() })
			table.insert(out, { tag = "users", route = oncall, request = Irm.usersRequest() })
		end
	end
	return out
end

-- `irm.user` against the schedules and users read: the user's OnCall ids
-- and the schedules they are on call in now; nil and the error kind when
-- either list could not be read.
local function mine(env: Env, job: Job): ({ [string]: boolean }?, { Irm.Schedule }?, string?)
	local sResp, uResp = job.responses.schedules, job.responses.users
	if sResp == nil or uResp == nil then
		return nil, nil, "network"
	end
	local schedules, sErr = Irm.parseSchedules(sResp, env)
	if schedules == nil then
		return nil, nil, if sErr then sErr.kind else "parse"
	end
	local users, uErr = Irm.parseUsers(uResp, env)
	if users == nil then
		return nil, nil, if uErr then uErr.kind else "parse"
	end
	local ids: { [string]: boolean } = {}
	for id, u in users do
		if u.email == job.user then
			ids[id] = true
		end
	end
	local on: { Irm.Schedule } = {}
	for _, sch in schedules do
		for _, id in sch.on_call_now do
			if ids[id] then
				table.insert(on, sch)
				break
			end
		end
	end
	return ids, on, nil
end

-- current_oncall of the schedules `irm.user` is on call in, for the end of
-- their shift.
local function shiftFetches(job: Job, cached: Cached?, env: Env): { Fetch }
	local d = if cached then cached.discovery else nil
	if job.user == nil or d == nil or d.oncall_url == nil then
		return {}
	end
	local _, on = mine(env, job)
	local out: { Fetch } = {}
	local oncall = Irm.oncallRoute(job.grafana :: Route, d.oncall_url :: string)
	for _, sch in (on or {}) :: { Irm.Schedule } do
		if #out >= M.MAX_SHIFT_SCHEDULES then
			break
		end
		table.insert(out, { tag = "now:" .. sch.id, route = oncall, request = Irm.onCallRequest(sch.id, "current") })
	end
	return out
end

-- The fetches to send next for `job` (all its earlier ones have answered);
-- none once it is done. Updates `cache` with a fresh discovery.
function M.step(job: Job, cache: Cache, env: Env): { Fetch }
	if job.stage == "discover" then
		local cached = cache[job.context]
		if not fresh(cached, (job.grafana :: Route).endpoint.url, env.now_ms) then
			local response = job.responses.settings
			if response == nil then
				return {
					{ tag = "settings", route = job.grafana :: Route, request = Irm.settingsRequest() },
				}
			end
			local d, qe = Irm.parseDiscovery(response, env, (job.grafana :: Route).endpoint.url)
			cached = {
				url = (job.grafana :: Route).endpoint.url,
				discovery = d,
				problem = if qe and qe.kind == "unsupported" then qe.message else nil,
				error = if qe and qe.kind ~= "unsupported" then qe.kind else nil,
				fetched_ms = env.now_ms,
			}
			cache[job.context] = cached
		end
		local c = cached :: Cached
		if c.discovery == nil then
			job.stage = "done"
			return {}
		end
		job.stage = "read"
		return readFetches(job, c, env)
	elseif job.stage == "read" then
		local fetches = shiftFetches(job, cache[job.context], env)
		job.stage = if #fetches > 0 then "shifts" else "done"
		return fetches
	elseif job.stage == "shifts" then
		job.stage = "done"
	end
	return {}
end

-- Whether `irm.user` is on call now, in which schedules, and until when.
local function youOf(env: Env, job: Job): (Summary.You?, string?)
	if job.user == nil then
		return nil, nil
	end
	local ids, on, kind = mine(env, job)
	if ids == nil or on == nil then
		return nil, kind
	end
	local names: { string } = {}
	local until_ms: number? = nil
	for _, sch in on :: { Irm.Schedule } do
		if #names < Summary.MAX_SCHEDULES then
			table.insert(names, sch.name)
		end
		local response = job.responses["now:" .. sch.id]
		local oc = if response then Irm.parseOnCall(response, env) else nil
		for _, shift in (if oc then oc.shifts else {}) :: { Irm.Shift } do
			local in_shift = false
			for _, id in shift.users do
				in_shift = in_shift or (ids :: { [string]: boolean })[id] == true
			end
			if in_shift and shift.end_ms and (until_ms == nil or shift.end_ms > until_ms) then
				until_ms = shift.end_ms
			end
		end
	end
	return {
		known = next(ids :: { [string]: boolean }) ~= nil,
		now = #names > 0,
		until_ms = until_ms,
		schedules = names,
	},
		nil
end

local function onCallNow(env: Env, job: Job): ({ Summary.OnCallNow }?, string?)
	local sResp, uResp = job.responses.schedules, job.responses.users
	if sResp == nil then
		return nil, nil
	end
	local schedules, qe = Irm.parseSchedules(sResp, env)
	if schedules == nil then
		return nil, if qe then qe.kind else "parse"
	end
	-- Without user names (no user-settings:read) a schedule still shows a count.
	local names = if uResp then Irm.parseUsers(uResp, env) else nil
	local out: { Summary.OnCallNow } = {}
	for _, s in schedules do
		if #out >= Summary.MAX_SCHEDULES then
			break
		end
		local now: { string } = {}
		for _, id in s.on_call_now do
			if #now >= Summary.MAX_NAMES then
				break
			end
			table.insert(now, if names and names[id] then names[id].name else "1 person")
		end
		table.insert(out, { schedule = s.name, now = now })
	end
	return out, nil
end

-- A job's response for `tag`; one that never arrived reads as a network failure.
local function answer(job: Job, tag: string): Response
	return job.responses[tag]
		or {
			status = 0,
			headers = {},
			body = "",
			timed_out = false,
			failure = { kind = "network", message = "no answer" },
		}
end

local function summarize(env: Env, job: Job, cached: Cached?, before: ContextSummary?): ContextSummary
	local s: ContextSummary = {
		firing = nil,
		acknowledged = nil,
		silenced = nil,
		incidents = nil,
		incidents_more = false,
		severities = {},
		oncall = nil,
		you = nil,
		error = nil,
		unavailable = nil,
	}
	if job.problem then
		s.error = "config"
		return s
	end
	if cached == nil or cached.discovery == nil then
		s.unavailable = if cached then cached.problem else nil
		s.error = if cached then cached.error else "network"
		if s.error and before then
			-- Discovery failed (network, auth): keep showing the last counts.
			before.error = s.error
			return before
		end
		return s
	end
	local d = cached.discovery :: Irm.Discovery
	local firstError: string? = nil
	local function failed(kind: string)
		firstError = firstError or kind
	end
	if d.oncall_url == nil then
		s.unavailable = d.oncall_problem
	else
		for _, state in GROUP_STATES do
			local _, count, qe = Irm.parseGroups(answer(job, "g:" .. state), env)
			if count then
				(s :: any)[state] = count
			else
				failed(if qe then qe.kind else "parse");
				(s :: any)[state] = if before then (before :: any)[state] else nil
			end
		end
		if job.names then
			local oncall, kind = onCallNow(env, job)
			if kind then
				failed(kind)
			end
			s.oncall = oncall or (if before then before.oncall else nil)
		end
		if job.user then
			local you, kind = youOf(env, job)
			if kind then
				failed(kind)
			end
			s.you = you or (if before then before.you else nil)
		end
	end
	local incidents, more, qe = Irm.parseIncidents(answer(job, "incidents"), env)
	if incidents then
		s.incidents = #incidents
		s.incidents_more = more
		for _, x in incidents do
			local label = if x.severity ~= "" then x.severity else "none"
			s.severities[label] = (s.severities[label] or 0) + 1
		end
	else
		failed(if qe then qe.kind else "parse")
		if before then
			s.incidents, s.incidents_more, s.severities = before.incidents, before.incidents_more, before.severities
		end
	end
	s.error = firstError
	return s
end

-- The kv payload after a poll; a part that failed keeps its previous value
-- with the error kind set.
function M.payload(env: Env, jobs: { Job }, cache: Cache, prevRaw: any, poll_s: number): Summary.Payload
	local prev = Summary.read(prevRaw)
	local contexts: { [string]: ContextSummary } = {}
	for _, job in jobs do
		local before = if prev then prev.contexts[job.context] else nil
		contexts[job.context] = summarize(env, job, cache[job.context], before)
	end
	return { v = Summary.VERSION, updated_ms = env.now_ms, poll_s = poll_s, contexts = contexts }
end

return M
