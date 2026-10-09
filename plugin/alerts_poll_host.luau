--!strict
-- Background alert poll for the status segment: every `alerts.poll_s`
-- seconds reads the alerts of each context in `alerts.contexts` through
-- transport_host and writes the summary to kv `tern-grafana.alerts.summary`
-- (counts and fingerprints only; see lib/alerts/summary.luau). Decisions live
-- in lib/alerts/poll.luau; this file only runs the timer and the requests.

local ConfigHost = require("./config_host")
local EnvHost = require("./env_host")
local Poll = require("./lib/alerts/poll")
local Summary = require("./lib/alerts/summary")
local TransportHost = require("./transport_host")

local M = {}

-- First poll shortly after the host starts (config and transports settle).
M.FIRST_DELAY_MS = 3000
-- How often a disabled or unconfigured poller looks at the config again.
M.IDLE_MS = 60000
-- A cycle whose answers never all arrived is abandoned after this long.
M.STUCK_MS = 5 * 60 * 1000

local started = false
local cycle = 0
local inflightSince: number? = nil

local function warn(what: string, err: any)
	pcall(tern.log.warn, "tern-grafana alerts poll " .. what .. " failed", tostring(err))
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
	local config = ConfigHost.current()
	local ok, jobs, poll_s = pcall(Poll.jobs, config)
	if not ok then
		warn("plan", jobs)
		schedule(M.IDLE_MS)
		return
	end
	if #jobs == 0 then
		-- Polling off or nothing to poll: drop the summary so the segment goes away.
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
	local done = false
	local function finish()
		if mine ~= cycle or done then
			return
		end
		for _, job in jobs do
			if not Poll.complete(job) then
				return
			end
		end
		done = true
		inflightSince = nil
		local okPrev, prev = pcall(tern.kv.get, Summary.KEY)
		local okPayload, payload = pcall(Poll.payload, EnvHost.make(nil), jobs, if okPrev then prev else nil, poll_s)
		if okPayload then
			write(payload)
		else
			warn("summary", payload)
		end
		schedule(poll_s * 1000)
	end
	for _, job in jobs do
		if job.plan then
			for _, f in job.plan.fetches do
				local okExec, err = pcall(function()
					TransportHost.execute(f.route, f.request, function(response)
						job.responses[f.tag] = response
						finish()
					end)
				end)
				if not okExec then
					job.responses[f.tag] = {
						status = 0,
						headers = {},
						body = "",
						timed_out = false,
						failure = { kind = "network", message = tostring(err) },
					}
				end
			end
		end
	end
	finish()
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
