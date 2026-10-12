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
local Settings = require("./lib/watches/settings")
local TransportHost = require("./transport_host")
local Validate = require("./lib/config/validate")

type State = Evaluate.State

local M = {}

-- First poll shortly after the host starts (config, hostname and transports settle).
M.FIRST_DELAY_MS = 3000
-- A cycle whose answers never all arrived is abandoned after this long.
M.STUCK_MS = 2 * 60 * 1000

local started = false
local cycle = 0
local inflightSince: number? = nil
local states: { [string]: State }? = nil
local warnedFor: any = nil

local function warn(what: string, err: any)
	pcall(tern.log.warn, "tern-grafana watches " .. what .. " failed", tostring(err))
end

local schedule: (ms: number) -> ()

local function write(value: any)
	local ok, err = pcall(function()
		tern.kv.set(Poll.KEY, value)
	end)
	if not ok then
		warn("kv.set", err)
	end
end

local function run()
	if inflightSince and tern.now() - (inflightSince :: number) < M.STUCK_MS then
		schedule(Poll.MIN_DELAY_MS * 5)
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
		local okPrev, prev = pcall(tern.kv.get, Poll.KEY)
		states = Poll.restore(if okPrev then prev else nil, watches, env.now_ms)
	end
	local current = states :: { [string]: State }
	if #watches == 0 then
		local okGet, existing = pcall(tern.kv.get, Poll.KEY)
		if okGet and existing ~= nil then
			write(nil)
		end
		table.clear(current)
		inflightSince = nil
		schedule(Poll.IDLE_MS)
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
		schedule(Poll.nextDelay(watches, current, env.now_ms))
		return
	end
	cycle += 1
	local mine = cycle
	inflightSince = tern.now()
	local pending = #due
	local function finish()
		if mine ~= cycle or pending > 0 then
			return
		end
		inflightSince = nil
		local now = EnvHost.nowMs()
		local okPayload, payload = pcall(Poll.payload, watches, current, config, now)
		if okPayload then
			write(payload)
		else
			warn("summary", payload)
		end
		schedule(Poll.nextDelay(watches, current, now))
	end
	for _, w in due do
		local job = Poll.job(config :: any, w, env.now_ms)
		local function settle(response: any)
			if mine ~= cycle then
				return
			end
			local ok, state = pcall(Poll.finish, EnvHost.make(nil), current[w.name], job, response, env.now_ms)
			if ok then
				current[w.name] = state
			else
				warn("evaluate " .. w.name, state)
			end
			pending -= 1
			finish()
		end
		if job.request == nil then
			local prev = current[w.name]
			if prev == nil or prev.error ~= "config" then
				warn("route " .. w.name, job.error)
			end
			settle(nil)
		else
			local okExec, err = pcall(function()
				TransportHost.execute(job.route :: any, job.request :: any, settle)
			end)
			if not okExec then
				settle({
					status = 0,
					headers = {},
					body = "",
					timed_out = false,
					failure = { kind = "network", message = tostring(err) },
				})
			end
		end
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
			schedule(Poll.IDLE_MS)
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
