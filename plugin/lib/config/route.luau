--!strict
-- Picks the endpoint that serves a signal for a context. A direct endpoint
-- wins; otherwise Grafana serves it through the datasource the user named for
-- that signal. Alerts fall back to Grafana-managed alerting, and dashboards
-- and annotations exist only in Grafana.

local Types = require("./types")

type Config = Types.Config
type Context = Types.Context
type Endpoint = Types.Endpoint
type EndpointName = Types.EndpointName
type Signal = Types.Signal

-- direct: the signal's own server. datasource: Grafana's datasource proxy or
-- /api/ds/query with `datasource_uid`. grafana: Grafana's own API.
export type Via = "direct" | "datasource" | "grafana"

export type Route = {
	context: string,
	signal: Signal,
	via: Via,
	endpoint_name: EndpointName,
	endpoint: Endpoint,
	datasource_uid: string?,
}

export type RouteError = {
	kind: "no_context" | "unknown_context" | "unroutable",
	message: string,
}

local M = {}

-- The direct endpoint (and Grafana datasource key) serving each data signal.
local BACKEND: { [Signal]: "prometheus" | "loki" | "tempo" | "alertmanager" } = {
	metrics = "prometheus",
	logs = "loki",
	traces = "tempo",
	alerts = "alertmanager",
}

local function contextNames(config: Config): string
	local names: { string } = {}
	for name in config.contexts do
		table.insert(names, name)
	end
	table.sort(names)
	return table.concat(names, ", ")
end

local function unroutable(message: string): (Route?, RouteError?)
	return nil, { kind = "unroutable", message = message }
end

function M.route(config: Config, context_name: string?, signal: Signal): (Route?, RouteError?)
	local name = context_name or config.default_context
	if name == nil then
		return nil,
			{
				kind = "no_context",
				message = string.format(
					"no context given and default_context is not set (contexts: %s)",
					contextNames(config)
				),
			}
	end
	local ctx: Context? = config.contexts[name]
	if ctx == nil then
		return nil,
			{
				kind = "unknown_context",
				message = string.format("no context named %q (contexts: %s)", name, contextNames(config)),
			}
	end

	local grafana = ctx.grafana
	local backend = BACKEND[signal]
	if backend == nil then
		if signal ~= "dashboards" and signal ~= "annotations" then
			error("route: unknown signal " .. tostring(signal), 2)
		end
		if grafana == nil then
			return unroutable(string.format("context %q has no grafana endpoint, which %s require", name, signal))
		end
		return { context = name, signal = signal, via = "grafana", endpoint_name = "grafana", endpoint = grafana }
	end

	local direct: Endpoint? = (ctx :: any)[backend]
	if direct then
		return {
			context = name,
			signal = signal,
			via = "direct",
			endpoint_name = backend :: EndpointName,
			endpoint = direct,
		}
	end
	if grafana == nil then
		return unroutable(string.format("context %q has no %s or grafana endpoint", name, backend))
	end
	local uid = if grafana.datasources then (grafana.datasources :: any)[backend] else nil
	if uid then
		return {
			context = name,
			signal = signal,
			via = "datasource",
			endpoint_name = "grafana",
			endpoint = grafana,
			datasource_uid = uid,
		}
	end
	if signal == "alerts" then
		return { context = name, signal = signal, via = "grafana", endpoint_name = "grafana", endpoint = grafana }
	end
	return unroutable(
		string.format("context %q has no %s endpoint and grafana.datasources.%s is not set", name, backend, backend)
	)
end

return M
