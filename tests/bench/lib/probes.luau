--!strict
-- Wraps the pipeline's phase functions with Bench.timed so a scenario's
-- attribution pass can say where a refresh spends its time. Must be required
-- before any block state module (tests/bench/run.luau does), so modules that
-- copy a function into a local at load copy the wrapper.

local Bench = require("./bench")

local P = "../../../plugin/lib/"

-- { module under plugin/lib, function names, phase label }
local PROBES: { { any } } = {
	{ "frame/grafana", { "frames", "parseResults" }, "frame: grafana frames" },
	{ "frame/prom", { "matrix", "vector", "result" }, "frame: prometheus" },
	{ "frame/loki", {}, "frame: loki" },
	{ "source/loki", { "parse" }, "source: loki parse" },
	{ "dashboard/queries", { "build", "parse" }, "dashboard: queries build/parse" },
	{ "dashboard/interpolate", { "replace", "text" }, "dashboard: interpolate" },
	{ "dashboard/repeat", { "expand", "find" }, "dashboard: repeat expand/find" },
	{ "dashboard/layout", { "arrange" }, "dashboard: layout arrange" },
	{ "dashboard/view", { "view" }, "dashboard: view" },
	{ "panels/transform", { "prepare" }, "panels: transform prepare" },
	{ "panels/fieldconfig", { "resolve", "bake", "display", "displayName" }, "panels: fieldconfig" },
	{ "panels/registry", { "view", "parse" }, "panels: registry view/parse" },
	{ "panels/reduce", { "reduce", "calcs" }, "panels: reduce" },
	{ "render/svg_timeseries", { "render" }, "render: svg timeseries" },
	{ "render/series", { "extract", "calcs", "join", "stack" }, "render: series" },
	{ "render/legend", { "rows", "view" }, "render: legend" },
	{ "render/axis", { "timeTicks", "niceScale", "formatTime" }, "render: axis" },
	{ "render/chart_view", { "view", "overlay" }, "render: chart view" },
	{ "render/assets", { "materialize" }, "host: assets materialize" },
	{ "render/blob_cache", { "digest" }, "host: blob hash (digest)" },
	{ "time/lttb", { "downsample" }, "time: lttb" },
	{ "units/format", { "format" }, "units: format" },
	{ "query/view", { "view" }, "query: view" },
	{ "logs/view", { "view" }, "logs: view" },
	{ "logs/tail", { "merge" }, "logs: tail merge" },
	{ "compat/analyze", { "panels" }, "compat: analyze panels" },
	{ "dashboard/model", { "parseResponse" }, "dashboard: model parse" },
	{ "irm/poll", { "step", "payload" }, "irm: poll step/payload" },
}

local M = {}

-- The JSON decoder handed to machines through Env, timed as its own phase.
function M.decoder(decode: (string) -> any): (string) -> any
	return Bench.timed("json: decode", Bench.countDecode(decode))
end

-- Installs every probe once.
function M.install()
	for _, spec in PROBES do
		local module = (require :: any)(P .. spec[1])
		for _, name in spec[2] do
			if type(module[name]) == "function" then
				Bench.probe(module, name, spec[3])
			end
		end
	end
end

return M
