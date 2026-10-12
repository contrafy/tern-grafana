--!strict
-- Native panel rendering, rung C of the ladder (docs/architecture.md). Each
-- panel type is a Common.PanelModule (local://PANELS2.md contract, one file
-- per type); this registry maps `type` to its module and adds what every
-- panel shares:
-- - legacy angular types migrate first exactly as Grafana's auto-migration
--   does (lib/panels/migrate: graph -> timeseries, singlestat -> stat);
-- - panels that query get their frames through the panel's
--   transformations, and an unsupported transformation is the reason the
--   panel is not native;
-- - a module failure shows as an error line in the panel instead of taking
--   the dashboard down.
--
-- `panel` is the decoded panel JSON (library panels merged, repeats
-- expanded); `frames` are the panel's query results through the frame
-- converters, every refId together.

local Alertlist = require("./alertlist")
local Annolist = require("./annolist")
local Assets = require("../render/assets")
local Barchart = require("./barchart")
local Candlestick = require("./candlestick")
local Canvas = require("./canvas")
local Clock = require("./clock")
local Common = require("./common")
local Dashlist = require("./dashlist")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Flamegraph = require("./flamegraph")
local Frame = require("../frame/types")
local Gauge = require("./gauge")
local Geomap = require("./geomap")
local Heatmap = require("./heatmap")
local Histogram = require("./histogram")
local Json = require("./json")
local Logs = require("./logs")
local Migrate = require("./migrate")
local News = require("./news")
local NodeGraph = require("./nodegraph")
local Stat = require("./stat")
local Piechart = require("./piechart")
local StateTimeline = require("./statetimeline")
local Table = require("./table")
local Text = require("./text")
local Timeseries = require("./timeseries")
local Transform = require("./transform")
local Traces = require("./traces")
local TransportTypes = require("../transport/types")
local Trend = require("./trend")
local Values = require("./values")
local ui = require("../ui")
local Xychart = require("./xychart")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node
type PanelModule = Common.PanelModule

export type Options = Common.Options

local M = {}

-- Panel types with a known reason for not being native.
local REASONS: { [string]: string } = {
	row = "a row is a layout element, not a panel",
}

-- Table cell types whose text fallback would misrepresent the data.
local UNSUPPORTED_CELLS: { [string]: boolean } = { sparkline = true, image = true }

-- Without an env (no JSON null sentinel known) JSON nulls only read as empty.
local NO_ENV: Env = {
	now_ms = 0,
	decode = function(_: string): any
		return nil
	end,
	encode = function(_: any): string
		return ""
	end,
	null = newproxy(false),
}

local function cellTypes(panel: any, env: Env): { string }
	local out: { string } = {}
	local t = Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "custom", "cellOptions", "type"))
	if t then
		table.insert(out, t)
	end
	for _, o in Json.list(env, Json.path(env, panel, "fieldConfig", "overrides")) do
		for _, p in Json.list(env, Json.path(env, o, "properties")) do
			if Json.str(env, Json.path(env, p, "id")) == "custom.cellOptions" then
				local pt = Json.str(env, Json.path(env, p, "value", "type"))
				if pt then
					table.insert(out, pt)
				end
			end
		end
	end
	return out
end

-- Built-in modules ------------------------------------------------------------

local function fieldConfigWhy(panel: any, env: Env): string?
	return FieldConfig.unsupported(panel, env)
end

local function supportsWith(check: ((any, Env) -> string?)?): (any, Env) -> (boolean, string?)
	return function(panel: any, env: Env): (boolean, string?)
		local why = fieldConfigWhy(panel, env)
		if why == nil and check then
			why = check(panel, env)
		end
		return why == nil, why
	end
end

local TIMESERIES: PanelModule = {
	types = { "timeseries" },
	supports = supportsWith(Timeseries.unsupported),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return Timeseries.view(panel, frames, env, opts)
	end,
}

local STAT: PanelModule = {
	types = { "stat" },
	supports = supportsWith(Values.unsupported),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return Stat.view(panel, frames, env, opts), nil
	end,
}

local GAUGE: PanelModule = {
	types = { "gauge" },
	supports = supportsWith(Values.unsupported),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return Gauge.view(panel, frames, env, opts)
	end,
}

local BARGAUGE: PanelModule = {
	types = { "bargauge" },
	supports = supportsWith(Values.unsupported),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return Gauge.barView(panel, frames, env, opts), nil
	end,
}

local TABLE: PanelModule = {
	types = { "table" },
	supports = supportsWith(function(panel: any, env: Env): string?
		for _, t in cellTypes(panel, env) do
			if UNSUPPORTED_CELLS[t] then
				return string.format("table cell type %s is not supported", t)
			end
		end
		return nil
	end),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		-- TablePanel: no frames is PanelDataErrorView.
		if #frames == 0 then
			return Common.noData(panel, env, opts.key), nil
		end
		return Table.view(panel, frames, env, opts), nil
	end,
}

local LOGS: PanelModule = {
	types = { "logs" },
	supports = supportsWith(nil),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		if not Common.hasData(frames) then
			return Common.noData(panel, env, opts.key), nil
		end
		return Logs.view(panel, frames, env, opts), nil
	end,
}

local TEXT: PanelModule = {
	types = { "text" },
	supports = function(_: any, _: Env): (boolean, string?)
		return true, nil
	end,
	view = function(panel: any, _: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return Text.view(panel, env, opts), nil
	end,
	queries = function(_: any): boolean
		return false
	end,
}

-- Registration ------------------------------------------------------------------

local BY_TYPE: { [string]: PanelModule } = {}

M.TYPES = {} :: { string }

function M.register(m: PanelModule)
	for _, t in m.types do
		if BY_TYPE[t] == nil then
			table.insert(M.TYPES, t)
		end
		BY_TYPE[t] = m
	end
end

for _, m in { TIMESERIES, STAT, GAUGE, BARGAUGE, TABLE, LOGS, TEXT } do
	M.register(m)
end

-- Panel modules in their own files (local://PANELS2.md).
local MODULES: { any } = {
	Clock,
	Piechart,
	Barchart,
	Histogram,
	Trend,
	Xychart,
	Candlestick,
	Alertlist,
	Annolist,
	Dashlist,
	News,
	Heatmap,
	StateTimeline,
	Flamegraph,
	Traces,
	NodeGraph,
	Geomap,
	Canvas,
}
for _, m in MODULES do
	M.register(m :: PanelModule)
end

-- Migration ------------------------------------------------------------------------

-- Migrated copies by source panel table (decoded JSON is never mutated, so
-- identity is a sound key); weak so dropped dashboards are collected.
local migrated: { [any]: { panel: any?, why: string? } } = setmetatable({}, { __mode = "k" }) :: any

-- The panel as Grafana renders it: legacy types auto-migrated.
function M.effective(panel: any, envArg: Env?): (any?, string?)
	local env = envArg or NO_ENV
	local kind = Json.str(env, panel.type)
	if kind == nil or Migrate.LEGACY[kind] == nil then
		return panel, nil
	end
	local hit = migrated[panel]
	if hit == nil then
		local p, why = Migrate.migrate(panel, env)
		hit = { panel = p, why = why }
		migrated[panel] = hit
	end
	local h = hit :: { panel: any?, why: string? }
	return h.panel, h.why
end

local function moduleOf(panel: any, env: Env): (PanelModule?, any?, string?)
	if Json.tbl(env, panel) == nil then
		return nil, nil, "the panel is not an object"
	end
	local kind = Json.str(env, panel.type)
	if kind == nil then
		if Json.tbl(env, panel.libraryPanel) then
			return nil, nil, "the library panel is not resolved"
		end
		return nil, nil, "the panel has no type"
	end
	local p, why = M.effective(panel, env)
	if p == nil then
		return nil, nil, why or string.format("the legacy %s panel could not be migrated", kind)
	end
	local effKind = Json.str(env, p.type) or kind
	local m = BY_TYPE[effKind]
	if m == nil then
		return nil, p, REASONS[effKind] or string.format("panel type %s is not rendered natively", effKind)
	end
	return m, p, nil
end

-- Whether the module runs datasource queries (default yes).
local function queriesOf(m: PanelModule, p: any): boolean
	local q = m.queries
	return q == nil or q(p) ~= false
end

-- Public API ----------------------------------------------------------------------

function M.module(panel: any, envArg: Env?): PanelModule?
	local m = moduleOf(panel, envArg or NO_ENV)
	return m
end

function M.supports(panel: any, envArg: Env?): (boolean, string?)
	local env = envArg or NO_ENV
	local m, p, why = moduleOf(panel, env)
	if m == nil then
		return false, why
	end
	local mod = m :: PanelModule
	if queriesOf(mod, p) then
		local tw = Transform.unsupported(p, env)
		if tw then
			return false, tw
		end
	end
	local ok, reason = mod.supports(p, env)
	if not ok then
		return false, reason or string.format("%s panels are not drawn natively here", tostring(p.type))
	end
	return true, nil
end

-- Whether the panel needs its datasource queries run.
function M.queries(panel: any, envArg: Env?): boolean
	local m, p = moduleOf(panel, envArg or NO_ENV)
	if m == nil then
		return true
	end
	return queriesOf(m :: PanelModule, p)
end

-- The panel's non-datasource requests (none for most panels).
function M.requests(panel: any, ctx: Common.RequestContext, env: Env): { Common.PanelRequest }
	local m, p = moduleOf(panel, env)
	local fn = if m then m.requests else nil
	if fn == nil then
		return {}
	end
	local ok, list = pcall(fn, p, ctx, env)
	return if ok and type(list) == "table" then list else {}
end

-- A request's answer as the module reads it; a parser failure is the
-- answer `{ error = message }`.
function M.parse(panel: any, tag: string, response: TransportTypes.Response, env: Env): any
	local m, p = moduleOf(panel, env)
	local fn = if m then m.parse else nil
	if fn == nil then
		return response
	end
	local ok, result = pcall(fn, p, tag, response, env)
	if not ok then
		return { error = "could not read the answer: " .. tostring(result) }
	end
	return result
end

-- The live redraw period of the panel, if it has one.
function M.liveMs(panel: any, env: Env): number?
	local m, p = moduleOf(panel, env)
	local fn = if m then m.liveMs else nil
	if fn == nil then
		return nil
	end
	local ok, ms = pcall(fn, p, env)
	return if ok and type(ms) == "number" and ms > 0 then ms else nil
end

local function render(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets)
	local m, p, why = moduleOf(panel, env)
	if m == nil then
		return ui.muted(why or "Not supported", { key = opts.key }), {}
	end
	local mod = m :: PanelModule
	local data = if queriesOf(mod, p) then Transform.prepare(p, frames, env) else frames
	local node, assets = mod.view(p, data, env, opts)
	return node, assets or {}
end

-- The panel as a view plus the assets it references (SVGs keyed under
-- opts.key).
function M.view(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets)
	local ok, node, assets = pcall(render, panel, frames, env, opts)
	if not ok then
		return ui.text({ ui.span("Panel failed to render: " .. tostring(node), "error") }, { key = opts.key }), {}
	end
	return node, assets
end

return M
