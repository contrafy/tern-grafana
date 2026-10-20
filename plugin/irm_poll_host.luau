--!strict
-- Background IRM poll for the status segment: every `irm.poll_s` seconds
-- runs lib/irm/poll.luau for each context in `irm.contexts` through
-- transport_host and writes the summary to kv `tern-grafana.irm.summary`
-- (counts and on-call usernames only; see lib/irm/summary.luau). Decisions
-- live in lib/irm/poll.luau; this file only runs the timer and the requests.

local ConfigHost = require("./config_host")
local EnvHost = require("./env_host")
local Poll = require("./lib/irm/poll")
local Summary = require("./lib/irm/summary")
local TransportHost = require("./transport_host")

local M = {}

-- First poll after the alerts poller's, so the two do not start together.
M.FIRST_DELAY_MS = 8000
M.IDLE_MS = 60000
M.STUCK_MS = 5 * 60 * 1000

local started = false
local cycle = 0
local inflightSince: number? = nil
-- Discovery per context, kept between polls (host memory only).
local cache: Poll.Cache = {}

local function warn(what: string, err: any)
	pcall(tern.log.warn, "tern-grafana irm poll " .. what .. " failed", tostring(err))
end

local schedule: (ms: number) -> ()

local function write(value: any)
	local ok, err = pcall(function()
		tern.kv.set(Summary.KEY, value)
	end)
	if not ok then
		warn("kv.set", err)
	end
end

local function run()
	if inflightSince and tern.now() - (inflightSince :: number) < M.STUCK_MS then
		schedule(M.IDLE_MS)
		return
	end
	pcall(ConfigHost.load)
	local config = EnvHost.make(nil).config
	local ok, jobs, settings = pcall(Poll.jobs, config)
	if not ok then
		warn("plan", jobs)
		schedule(M.IDLE_MS)
		return
	end
	if #jobs == 0 then
		local okGet, existing = pcall(tern.kv.get, Summary.KEY)
		if okGet and existing ~= nil then
			write(nil)
		end
		inflightSince = nil
		schedule(M.IDLE_MS)
		return
	end
	cycle += 1
	local mine = cycle
	inflightSince = tern.now()
	local remaining = #jobs
	local function finish()
		if mine ~= cycle then
			return
		end
		inflightSince = nil
		local okPrev, prev = pcall(tern.kv.get, Summary.KEY)
		local okPayload, payload =
			pcall(Poll.payload, EnvHost.make(nil), jobs, cache, if okPrev then prev else nil, settings.poll_s)
		if okPayload then
			write(payload)
		else
			warn("summary", payload)
		end
		schedule(settings.poll_s * 1000)
	end
	local function drive(job: Poll.Job)
		local okStep, fetches = pcall(Poll.step, job, cache, EnvHost.make(nil))
		if not okStep or #fetches == 0 then
			if not okStep then
				warn("step", fetches)
			end
			remaining -= 1
			if remaining == 0 then
				finish()
			end
			return
		end
		local waiting = #fetches
		local function answered(tag: string, response: any)
			if mine ~= cycle or job.responses[tag] ~= nil then
				return
			end
			job.responses[tag] = response
			waiting -= 1
			if waiting == 0 then
				drive(job)
			end
		end
		for _, f in fetches do
			local okExec, err = pcall(TransportHost.execute :: any, f.route, f.request, function(response)
				answered(f.tag, response)
			end)
			if not okExec then
				answered(f.tag, {
					status = 0,
					headers = {},
					body = "",
					timed_out = false,
					failure = { kind = "network", message = tostring(err) },
				})
			end
		end
	end
	for _, job in jobs do
		drive(job)
	end
end

function schedule(ms: number)
	local ok, err = pcall(tern.timer, ms, function()
		local okRun, runErr = pcall(function()
			run()
		end)
		if not okRun then
			inflightSince = nil
			warn("cycle", runErr)
			schedule(M.IDLE_MS)
		end
	end)
	if not ok then
		warn("timer", err)
	end
end

-- Starts the poll loop once per host VM.
function M.start()
	if started then
		return
	end
	started = true
	schedule(M.FIRST_DELAY_MS)
end

return M
