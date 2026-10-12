--!strict
-- What a finished command triggers: a deploy annotation (posted now when the
-- context is approved "always", else the approve block asks) and/or an
-- impact watch block. Both are off until configured, and both use the
-- annotation patterns. The host hook executes the plan and decides nothing.

local Approval = require("./approval")
local Command = require("./command")
local ImpactSettings = require("../impact/settings")
local Pairing = require("./pairing")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Settings = require("./settings")
local Types = require("../config/types")

type Config = Types.Config

export type Annotate = {
	context: string,
	decision: "post" | "ask",
	settings: Settings.Settings,
}

export type Plan = {
	match: Command.Match,
	annotate: Annotate?,
	-- tern-grafana://impact link.
	impact: string?,
	-- Why a wanted action could not happen (shown as a toast, once per cause).
	problems: { string },
}

local M = {}

local function routable(config: Config, context: string?, signal: Types.Signal): (string?, string?)
	local r, err = Route.route(config, context, signal)
	if r == nil then
		return nil, if err then err.message else "no route"
	end
	return r.context, nil
end

-- Parameters an impact link carries: context, times and what the command named.
function M.impactLink(context: string, run: Pairing.Run, match: Command.Match): string
	local params: { [string]: string } = {
		context = context,
		start = string.format("%d", math.floor(run.started_ms)),
		finish = string.format("%d", math.floor(math.max(run.finished_ms, run.started_ms))),
		kind = match.kind,
	}
	if match.namespace then
		params.ns = match.namespace
	end
	if match.service then
		params.svc = match.service
	end
	if run.cwd then
		local base = Command.basename(run.cwd :: string)
		if base ~= "/" and #base <= 255 and not string.find(base, "%c") then
			params.dir = base
		end
	end
	return Scheme.encode({ action = "impact", params = params, vars = {} })
end

-- nil when nothing is enabled or the command is not a deploy.
function M.plan(config: Config?, run: Pairing.Run, approvalsRaw: any): Plan?
	if config == nil then
		return nil
	end
	local ann = Settings.read(config)
	local imp = ImpactSettings.read(config)
	if not ann.enabled and not imp.enabled then
		return nil
	end
	local match = Command.match(run.line, ann.compiled)
	if match == nil then
		return nil
	end
	local plan: Plan = { match = match, annotate = nil, impact = nil, problems = {} }
	if ann.enabled and Settings.gate(ann.on, run.status) then
		local ctx, err = routable(config, ann.context, "annotations")
		if ctx == nil then
			table.insert(plan.problems, "Deploy annotation skipped: " .. tostring(err))
		else
			local decision = Approval.decide(Approval.read(approvalsRaw), ctx)
			if decision ~= "skip" then
				plan.annotate = { context = ctx, decision = decision :: any, settings = ann }
			end
		end
	end
	if imp.enabled and Settings.gate(imp.on, run.status) then
		local ctx, err = routable(config, imp.context, "metrics")
		if ctx == nil then
			table.insert(plan.problems, "Impact watch skipped: " .. tostring(err))
		else
			plan.impact = M.impactLink(ctx, run, match)
		end
	end
	if plan.annotate == nil and plan.impact == nil and #plan.problems == 0 then
		return nil
	end
	return plan
end

return M
