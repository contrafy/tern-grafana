--!strict
-- The scaffolding the background pollers (alerts_poll_host, irm_poll_host,
-- watches_poll_host) share: one timer loop per poller that starts once per
-- host VM, re-arms after a raised cycle, a stuck-cycle guard, the kv summary
-- write and the network failure for a request that could not be sent. Each
-- poller keeps its own cycle logic and timings.

local TransportHost = require("./transport_host")

local M = {}

export type Poller = {
	-- Log prefix, e.g. "tern-grafana alerts poll".
	prefix: string,
	key: string,
	-- Re-arm delay after a cycle raised.
	retry_ms: number,
	-- Bumped by `begin`; callbacks of an older cycle compare against it.
	cycle: number,
	-- When the running cycle started; nil when none is in flight.
	inflightSince: number?,
	started: boolean,
	run: () -> (),
}

function M.new(prefix: string, key: string, retry_ms: number, run: () -> ()): Poller
	return {
		prefix = prefix,
		key = key,
		retry_ms = retry_ms,
		cycle = 0,
		inflightSince = nil,
		started = false,
		run = run,
	}
end

function M.warn(p: Poller, what: string, err: any)
	pcall(tern.log.warn, p.prefix .. " " .. what .. " failed", tostring(err))
end

function M.write(p: Poller, value: any)
	local ok, err = pcall(function()
		tern.kv.set(p.key, value)
	end)
	if not ok then
		M.warn(p, "kv.set", err)
	end
end

-- The current kv summary, nil when unreadable.
function M.read(p: Poller): any
	local ok, value = pcall(tern.kv.get, p.key)
	return if ok then value else nil
end

-- Drops the summary (when present) so the segment goes away.
function M.clear(p: Poller)
	local ok, existing = pcall(tern.kv.get, p.key)
	if ok and existing ~= nil then
		M.write(p, nil)
	end
end

-- True while an earlier cycle is in flight and not yet `stuck_ms` old.
function M.busy(p: Poller, stuck_ms: number): boolean
	local since = p.inflightSince
	return since ~= nil and tern.now() - since < stuck_ms
end

-- Starts a cycle; returns its number.
function M.begin(p: Poller): number
	p.cycle += 1
	p.inflightSince = tern.now()
	return p.cycle
end

function M.schedule(p: Poller, ms: number)
	local ok, err = pcall(tern.timer, ms, function()
		local okRun, runErr = pcall(function()
			p.run()
		end)
		if not okRun then
			p.inflightSince = nil
			M.warn(p, "cycle", runErr)
			M.schedule(p, p.retry_ms)
		end
	end)
	if not ok then
		M.warn(p, "timer", err)
	end
end

-- Starts the loop once per host VM.
function M.start(p: Poller, first_ms: number)
	if p.started then
		return
	end
	p.started = true
	M.schedule(p, first_ms)
end

-- Sends through transport_host; a request that raises answers `cb` with a
-- network failure instead.
function M.execute(route: any, request: any, cb: (response: any) -> ())
	local ok, err = pcall(TransportHost.execute :: any, route, request, cb)
	if not ok then
		cb({
			status = 0,
			headers = {},
			body = "",
			timed_out = false,
			failure = { kind = "network", message = tostring(err) },
		})
	end
end

return M
