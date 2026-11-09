--!strict
-- Background poll for personal threshold watches (config `watches`,
-- docs/watches.md): wakes when the next watch falls due, sends the due
-- watches' instant queries through transport_host, steps their state and
-- writes the summary to kv `tern-grafana.watches.summary`, which the window
-- turns into a status segment and toasts. Decisions live in
-- lib/watches/{poll,evaluate}.luau; this file runs the timer and requests.

local ConfigHost = require("./config_host")
local EnvHost = require("./env_host")
local Evaluate = require("./lib/watches/evaluate")
local Poll = require("./lib/watches/poll")
local Poller = require("./poller_host")
local Settings = require("./lib/watches/settings")
local Validate = require("./lib/config/validate")

type State = Evaluate.State

local M = {}

-- First poll shortly after the host starts (config, hostname and transports settle).
M.FIRST_DELAY_MS = 3000
-- A cycle whose answers never all arrived is abandoned after this long.
M.STUCK_MS = 2 * 60 * 1000

local P: Poller.Poller
local states: { [string]: State }? = nil
local warnedFor: any = nil

local function run()
	if Poller.busy(P, M.STUCK_MS) then
		Poller.schedule(P, Poll.MIN_DELAY_MS * 5)
		return
	end
	pcall(ConfigHost.load)
	local env = EnvHost.make(nil)
	local config = env.config
	local watches, problems = Settings.read(config)
	if config ~= warnedFor then
		warnedFor = config
		for _, p in problems do
			pcall(tern.log.warn, "tern-grafana config: " .. Validate.format(p))
		end
	end
	if states == nil then
		states = Poll.restore(Poller.read(P), watches, env.now_ms)
	end
	local current = states :: { [string]: State }
	if #watches == 0 then
		Poller.clear(P)
		table.clear(current)
		P.inflightSince = nil
		Poller.schedule(P, Poll.IDLE_MS)
		return
	end
	-- Forget watches that were removed from the config.
	local names: { [string]: boolean } = {}
	for _, w in watches do
		names[w.name] = true
	end
	for name in current do
		if not names[name] then
			current[name] = nil
		end
	end

	local due = Poll.due(watches, current, env.now_ms)
	if #due == 0 then
		Poller.schedule(P, Poll.nextDelay(watches, current, env.now_ms))
		return
	end
	local mine = Poller.begin(P)
	local pending = #due
	local function finish()
		if mine ~= P.cycle or pending > 0 then
			return
		end
		P.inflightSince = nil
		local now = EnvHost.nowMs()
		local okPayload, payload = pcall(Poll.payload, watches, current, config, now)
		if okPayload then
			Poller.write(P, payload)
		else
			Poller.warn(P, "summary", payload)
		end
		Poller.schedule(P, Poll.nextDelay(watches, current, now))
	end
	for _, w in due do
		local job = Poll.job(config :: any, w, env.now_ms)
		local function settle(response: any)
			if mine ~= P.cycle then
				return
			end
			local ok, state = pcall(Poll.finish, EnvHost.make(nil), current[w.name], job, response, env.now_ms)
			if ok then
				current[w.name] = state
			else
				Poller.warn(P, "evaluate " .. w.name, state)
			end
			pending -= 1
			finish()
		end
		if job.request == nil then
			local prev = current[w.name]
			if prev == nil or prev.error ~= "config" then
				Poller.warn(P, "route " .. w.name, job.error)
			end
			settle(nil)
		else
			Poller.execute(job.route, job.request, settle)
		end
	end
end

P = Poller.new("tern-grafana watches", Poll.KEY, Poll.IDLE_MS, run)

-- Starts the poll loop once per host VM.
function M.start()
	Poller.start(P, M.FIRST_DELAY_MS)
end

return M
