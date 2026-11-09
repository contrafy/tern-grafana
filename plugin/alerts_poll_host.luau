--!strict
-- Background alert poll for the status segment: every `alerts.poll_s`
-- seconds reads the alerts of each context in `alerts.contexts` through
-- transport_host and writes the summary to kv `tern-grafana.alerts.summary`
-- (counts and fingerprints only; see lib/alerts/summary.luau). Decisions live
-- in lib/alerts/poll.luau; this file only runs the timer and the requests.

local ConfigHost = require("./config_host")
local EnvHost = require("./env_host")
local Poll = require("./lib/alerts/poll")
local Poller = require("./poller_host")
local Summary = require("./lib/alerts/summary")

local M = {}

-- First poll shortly after the host starts (config and transports settle).
M.FIRST_DELAY_MS = 3000
-- How often a disabled or unconfigured poller looks at the config again.
M.IDLE_MS = 60000
-- A cycle whose answers never all arrived is abandoned after this long.
M.STUCK_MS = 5 * 60 * 1000

local P: Poller.Poller

local function run()
	if Poller.busy(P, M.STUCK_MS) then
		Poller.schedule(P, M.IDLE_MS)
		return
	end
	pcall(ConfigHost.load)
	local config = EnvHost.make(nil).config
	local ok, jobs, poll_s, toastSeverities = pcall(Poll.jobs, config)
	if not ok then
		Poller.warn(P, "plan", jobs)
		Poller.schedule(P, M.IDLE_MS)
		return
	end
	if #jobs == 0 then
		-- Polling off or nothing to poll: drop the summary so the segment goes away.
		Poller.clear(P)
		P.inflightSince = nil
		Poller.schedule(P, M.IDLE_MS)
		return
	end
	local mine = Poller.begin(P)
	local done = false
	local function finish()
		if mine ~= P.cycle or done then
			return
		end
		for _, job in jobs do
			if not Poll.complete(job) then
				return
			end
		end
		done = true
		P.inflightSince = nil
		local okPayload, payload = pcall(Poll.payload, EnvHost.make(nil), jobs, Poller.read(P), poll_s, toastSeverities)
		if okPayload then
			Poller.write(P, payload)
		else
			Poller.warn(P, "summary", payload)
		end
		Poller.schedule(P, poll_s * 1000)
	end
	for _, job in jobs do
		if job.plan then
			for _, f in job.plan.fetches do
				Poller.execute(f.route, f.request, function(response)
					job.responses[f.tag] = response
					finish()
				end)
			end
		end
	end
	finish()
end

P = Poller.new("tern-grafana alerts poll", Summary.KEY, M.IDLE_MS, run)

-- Starts the poll loop once per host VM.
function M.start()
	Poller.start(P, M.FIRST_DELAY_MS)
end

return M
