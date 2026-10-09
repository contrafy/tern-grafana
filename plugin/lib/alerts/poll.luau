--!strict
-- One background poll: which contexts to read and how their answers become
-- the kv payload. plugin/alerts_poll_host.luau runs it on a timer.

local ConfigTypes = require("../config/types")
local Env = require("../env")
local Settings = require("./settings")
local Sources = require("./sources")
local Summary = require("./summary")
local TransportTypes = require("../transport/types")

type Config = ConfigTypes.Config
type Env = Env.Env
type Plan = Sources.Plan
type Response = TransportTypes.Response

export type Job = {
	context: string,
	-- nil when the context cannot be routed (it still gets a "config" summary).
	plan: Plan?,
	responses: { [string]: Response },
}

local M = {}

-- (jobs, poll_s); no jobs when polling is off or nothing is configured.
function M.jobs(config: Config?): ({ Job }, number)
	local settings = Settings.read(config)
	if config == nil or settings.poll_s == 0 then
		return {}, settings.poll_s
	end
	local jobs: { Job } = {}
	for _, name in settings.contexts do
		local plan = Sources.plan(config, name)
		table.insert(jobs, { context = name, plan = plan, responses = {} })
	end
	return jobs, settings.poll_s
end

function M.complete(job: Job): boolean
	if job.plan == nil then
		return true
	end
	for _, f in (job.plan :: Plan).fetches do
		if job.responses[f.tag] == nil then
			return false
		end
	end
	return true
end

-- The kv payload after a poll; a context that failed keeps its previous
-- counts with the error kind set.
function M.payload(env: Env, jobs: { Job }, prevRaw: any, poll_s: number): Summary.Payload
	local prev = Summary.readPayload(prevRaw)
	local contexts: { [string]: Summary.Summary } = {}
	for _, job in jobs do
		local before = if prev then prev.contexts[job.context] else nil
		if job.plan == nil then
			contexts[job.context] = Summary.failed(before, "config", env.now_ms)
		else
			local result = Sources.combine(env, job.plan :: Plan, job.responses)
			contexts[job.context] = if result.ok
				then Summary.summarize(result.alerts, env.now_ms)
				else Summary.failed(before, result.error_kind or "http", env.now_ms)
		end
	end
	return Summary.payload(contexts, env.now_ms, poll_s)
end

return M
