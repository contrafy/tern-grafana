--!strict
-- Where a context's IRM lives: its Grafana endpoint (IRM is a Grafana app),
-- and once discovered, the OnCall API route derived from it.

local ConfigTypes = require("../config/types")
local Route = require("../config/route")

type Config = ConfigTypes.Config
type Route = Route.Route

local M = {}

-- The Grafana route of a context (the default one when `name` is nil), or
-- why there is none.
function M.grafana(config: Config?, name: string?, host_default: string?): (Route?, string?)
	if config == nil then
		return nil, "No valid config: open Grafana: Settings or see docs/configuration.md."
	end
	local cfg = config :: Config
	local ctxName = name or Route.defaultContext(cfg, host_default)
	if ctxName == nil then
		return nil, "No context given and default_context is not set."
	end
	local ctx = cfg.contexts[ctxName :: string]
	if ctx == nil then
		return nil, string.format("No context named %q.", ctxName)
	end
	if ctx.grafana == nil then
		return nil, string.format("Context %q has no grafana endpoint; Grafana IRM is a Grafana app.", ctxName)
	end
	return {
		context = ctxName :: string,
		signal = "dashboards",
		via = "grafana",
		endpoint_name = "grafana",
		endpoint = ctx.grafana,
	},
		nil
end

-- Contexts that have a grafana endpoint, sorted.
function M.contexts(config: Config?): { string }
	local out: { string } = {}
	if config then
		for name, ctx in config.contexts do
			if ctx.grafana then
				table.insert(out, name)
			end
		end
	end
	table.sort(out)
	return out
end

return M
