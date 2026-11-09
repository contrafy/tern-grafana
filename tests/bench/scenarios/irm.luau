--!strict
-- The IRM status poll (host half, every irm.poll_s): one context, every
-- fetch answered from the scrubbed IRM 0.128.0 captures, then the kv
-- payload the status segment reads. `cold` starts with an empty cache
-- (plugin discovery included), `warm` reuses it as every later poll does.

local Bench = require("../lib/bench")
local Poll = require("../../../plugin/lib/irm/poll")
local Probes = require("../lib/probes")
local S = require("../../unit/irm/support")
local json = require("../../lib/json")

local CAPTURED: { [string]: string } = {
	settings = "settings.json",
	["g:firing"] = "oncall_alert_groups_new_count.json",
	["g:acknowledged"] = "oncall_alert_groups_acknowledged_count.json",
	["g:silenced"] = "oncall_alert_groups_silenced_count.json",
	schedules = "oncall_schedules.json",
	users = "oncall_users.json",
	incidents = "incident_previews_open.json",
}

local function respond(tag: string): any
	if string.match(tag, "^now:") then
		return S.ok(S.V .. "oncall_current_oncall.json")
	end
	return S.ok(S.V .. assert(CAPTURED[tag], tag))
end

local function pollOnce(env: any, cache: any): (any, number)
	local jobs = Poll.jobs(env.config)
	local fetches = 0
	for _, job in jobs do
		local list = Poll.step(job, cache, env)
		while #list > 0 do
			for _, f in list do
				fetches += 1
				job.responses[f.tag] = respond(f.tag)
			end
			list = Poll.step(job, cache, env)
		end
	end
	return Poll.payload(env, jobs, cache, nil, 60), fetches
end

local M = {}

function M.run(opts: any): { any }
	local name = "irm/poll"
	if not opts.match(name) then
		return {}
	end
	local env = S.env()
	env.decode = Probes.decoder(env.decode)
	local payload, coldFetches = pollOnce(env, {})
	local cold = Bench.sample(opts.warmup, opts.iters, function()
		return {}
	end, function(cache: any)
		pollOnce(env, cache)
	end)
	local warmCache = {}
	pollOnce(env, warmCache)
	local warmFetches = 0
	local warm = Bench.sample(opts.warmup, opts.iters, function()
		return warmCache
	end, function(cache: any)
		local _, n = pollOnce(env, cache)
		warmFetches = n
	end)
	local base = Bench.liveKb()
	local cache = {}
	for _ = 1, 100 do
		pollOnce(env, cache)
	end
	local retained = Bench.liveKb() - base
	local phases = Bench.attribute(function()
		pollOnce(env, warmCache)
	end)
	local metrics: { [string]: any } = {
		fetches_cold = coldFetches,
		fetches_warm = warmFetches,
		payload_bytes = #json.encode(payload),
		retained_kb_after_100_polls = retained,
	}
	Bench.put(metrics, "poll_cold", cold)
	Bench.put(metrics, "poll_warm", warm)
	return { { name = name, metrics = metrics, phases = { warm = phases } } }
end

return M
