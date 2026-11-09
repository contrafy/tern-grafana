--!strict
-- Background IRM poll for the status segment: every `irm.poll_s` seconds
-- runs lib/irm/poll.luau for each context in `irm.contexts` through
-- transport_host and writes the summary to kv `tern-grafana.irm.summary`
-- (counts and on-call usernames only; see lib/irm/summary.luau). Decisions
-- live in lib/irm/poll.luau; this file only runs the timer and the requests.

local ConfigHost = require("./config_host")
local EnvHost = require("./env_host")
local Poll = require("./lib/irm/poll")
local Poller = require("./poller_host")
local Summary = require("./lib/irm/summary")

local M = {}

-- First poll after the alerts poller's, so the two do not start together.
M.FIRST_DELAY_MS = 8000
M.IDLE_MS = 60000
M.STUCK_MS = 5 * 60 * 1000

local P: Poller.Poller
-- Discovery per context, kept between polls (host memory only).
local cache: Poll.Cache = {}

local function run()
	if Poller.busy(P, M.STUCK_MS) then
		Poller.schedule(P, M.IDLE_MS)
		return
	end
	pcall(ConfigHost.load)
	local config = EnvHost.make(nil).config
	local ok, jobs, settings = pcall(Poll.jobs, config)
	if not ok then
		Poller.warn(P, "plan", jobs)
		Poller.schedule(P, M.IDLE_MS)
		return
	end
	if #jobs == 0 then
		Poller.clear(P)
		P.inflightSince = nil
		Poller.schedule(P, M.IDLE_MS)
		return
	end
	local mine = Poller.begin(P)
	local remaining = #jobs
	local function finish()
		if mine ~= P.cycle then
			return
		end
		P.inflightSince = nil
		local okPayload, payload = pcall(Poll.payload, EnvHost.make(nil), jobs, cache, Poller.read(P), settings.poll_s)
		if okPayload then
			Poller.write(P, payload)
		else
			Poller.warn(P, "summary", payload)
		end
		Poller.schedule(P, settings.poll_s * 1000)
	end
	local function drive(job: Poll.Job)
		local okStep, fetches = pcall(Poll.step, job, cache, EnvHost.make(nil))
		if not okStep or #fetches == 0 then
			if not okStep then
				Poller.warn(P, "step", fetches)
			end
			remaining -= 1
			if remaining == 0 then
				finish()
			end
			return
		end
		local waiting = #fetches
		local function answered(tag: string, response: any)
			if mine ~= P.cycle or job.responses[tag] ~= nil then
				return
			end
			job.responses[tag] = response
			waiting -= 1
			if waiting == 0 then
				drive(job)
			end
		end
		for _, f in fetches do
			Poller.execute(f.route, f.request, function(response)
				answered(f.tag, response)
			end)
		end
	end
	for _, job in jobs do
		drive(job)
	end
end

P = Poller.new("tern-grafana irm poll", Summary.KEY, M.IDLE_MS, run)

-- Starts the poll loop once per host VM.
function M.start()
	Poller.start(P, M.FIRST_DELAY_MS)
end

return M
