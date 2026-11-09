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
-- - field config displayName strings get the dashboard variables
--   (opts.replace); field macros resolve per field in lib/panels/fieldconfig;
-- - a module failure shows as an error line in the panel instead of taking
--   the dashboard down.
--
-- `panel` is the decoded panel JSON (library panels merged, repeats
-- expanded); `frames` are the panel's query results through the frame
-- converters, every refId together.

-- Panel modules load on first use of their type (see LAZY below), so a
-- block that never draws a clock or a geomap never compiles them.
local Assets = require("../render/assets")
local Common = require("./common")
local Env = require("../env")
local FieldConfig = require("./fieldconfig")
local Frame = require("../frame/types")
local Json = require("./json")
local Migrate = require("./migrate")
local Transform = require("./transform")
local TransportTypes = require("../transport/types")
local ui = require("../ui")
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

-- The module `load` requires, required on the first call only (a require
-- per supports()/view() call is not free).
local function once(load: () -> any): () -> any
	local m: any = nil
	return function(): any
		if m == nil then
			m = load()
		end
		return m
	end
end

local timeseries = once(function(): any
	return require("./timeseries")
end)
local values = once(function(): any
	return require("./values")
end)
local stat = once(function(): any
	return require("./stat")
end)
local gauge = once(function(): any
	return require("./gauge")
end)
local tablePanel = once(function(): any
	return require("./table")
end)
local logs = once(function(): any
	return require("./logs")
end)
local text = once(function(): any
	return require("./text")
end)

local TIMESERIES: PanelModule = {
	types = { "timeseries" },
	supports = supportsWith(function(panel: any, env: Env): string?
		return timeseries().unsupported(panel, env)
	end),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return timeseries().view(panel, frames, env, opts)
	end,
}

local function valuesWhy(panel: any, env: Env): string?
	return values().unsupported(panel, env)
end

local STAT: PanelModule = {
	types = { "stat" },
	supports = supportsWith(valuesWhy),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return stat().view(panel, frames, env, opts)
	end,
}

local GAUGE: PanelModule = {
	types = { "gauge" },
	supports = supportsWith(valuesWhy),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return gauge().view(panel, frames, env, opts)
	end,
}

local BARGAUGE: PanelModule = {
	types = { "bargauge" },
	supports = supportsWith(valuesWhy),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return gauge().barView(panel, frames, env, opts), nil
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
		return tablePanel().view(panel, frames, env, opts), nil
	end,
}

local LOGS: PanelModule = {
	types = { "logs" },
	supports = supportsWith(nil),
	view = function(panel: any, frames: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		if not Common.hasData(frames) then
			return Common.noData(panel, env, opts.key), nil
		end
		return logs().view(panel, frames, env, opts), nil
	end,
}

local TEXT: PanelModule = {
	types = { "text" },
	supports = function(_: any, _: Env): (boolean, string?)
		return true, nil
	end,
	view = function(panel: any, _: { Frame }, env: Env, opts: Options): (Node, Assets.Assets?)
		return text().view(panel, env, opts), nil
	end,
	queries = function(_: any): boolean
		return false
	end,
}

-- Registration ------------------------------------------------------------------

local BY_TYPE: { [string]: PanelModule } = {}

M.TYPES = {} :: { string }

-- Types whose module file is not loaded yet -> its loader (cleared once the
-- module is loaded or the type is registered again).
local PENDING: { [string]: () -> PanelModule } = {}

function M.register(m: PanelModule)
	for _, t in m.types do
		if BY_TYPE[t] == nil and PENDING[t] == nil then
			table.insert(M.TYPES, t)
		end
		BY_TYPE[t] = m
		PENDING[t] = nil
	end
end

for _, m in { TIMESERIES, STAT, GAUGE, BARGAUGE, TABLE, LOGS, TEXT } do
	M.register(m)
end

-- Panel modules in their own files (local://PANELS2.md), in registration
-- order; `types` repeats each module's M.types (tests/unit/panels/
-- registry.spec checks they agree).
local LAZY: { { types: { string }, load: () -> any } } = {
	{
		types = { "grafana-clock-panel" },
		load = function(): any
			return require("./clock")
		end,
	},
	{
		types = { "piechart" },
		load = function(): any
			return require("./piechart")
		end,
	},
	{
		types = { "barchart" },
		load = function(): any
			return require("./barchart")
		end,
	},
	{
		types = { "histogram" },
		load = function(): any
			return require("./histogram")
		end,
	},
	{
		types = { "trend" },
		load = function(): any
			return require("./trend")
		end,
	},
	{
		types = { "xychart" },
		load = function(): any
			return require("./xychart")
		end,
	},
	{
		types = { "candlestick" },
		load = function(): any
			return require("./candlestick")
		end,
	},
	{
		types = { "alertlist" },
		load = function(): any
			return require("./alertlist")
		end,
	},
	{
		types = { "annolist" },
		load = function(): any
			return require("./annolist")
		end,
	},
	{
		types = { "dashlist" },
		load = function(): any
			return require("./dashlist")
		end,
	},
	{
		types = { "news" },
		load = function(): any
			return require("./news")
		end,
	},
	{
		types = { "heatmap" },
		load = function(): any
			return require("./heatmap")
		end,
	},
	{
		types = { "state-timeline", "status-history" },
		load = function(): any
			return require("./statetimeline")
		end,
	},
	{
		types = { "flamegraph" },
		load = function(): any
			return require("./flamegraph")
		end,
	},
	{
		types = { "traces" },
		load = function(): any
			return require("./traces")
		end,
	},
	{
		types = { "nodeGraph" },
		load = function(): any
			return require("./nodegraph")
		end,
	},
	{
		types = { "geomap" },
		load = function(): any
			return require("./geomap")
		end,
	},
	{
		types = { "canvas" },
		load = function(): any
			return require("./canvas")
		end,
	},
}
M.LAZY = LAZY

for _, entry in LAZY do
	local load = entry.load
	local function loader(): PanelModule
		local m = load() :: PanelModule
		for _, t in entry.types do
			if PENDING[t] == loader then
				BY_TYPE[t] = m
				PENDING[t] = nil
			end
		end
		return m
	end
	for _, t in entry.types do
		if BY_TYPE[t] == nil and PENDING[t] == nil then
			table.insert(M.TYPES, t)
		end
		PENDING[t] = loader
	end
end

local function byType(t: string): PanelModule?
	local m = BY_TYPE[t]
	if m == nil then
		local load = PENDING[t]
		if load then
			load()
			m = BY_TYPE[t]
		end
	end
	return m
end

-- Migration ------------------------------------------------------------------------

-- Migrated copies by source panel table (decoded JSON is never mutated, so
-- identity is a sound key); weak so dropped dashboards are collected.
-- `title` is the title of the panel migrated: callers may pass a copy of
-- `source` whose title differs (variables), which must re-migrate.
local migrated: { [any]: { panel: any?, why: string?, title: any } } = setmetatable({}, { __mode = "k" }) :: any

-- The panel as Grafana renders it: legacy types auto-migrated. `source` is
-- the decoded panel `panel` was copied from (only the title may differ); it
-- keys the cache so fresh copies migrate once.
function M.effective(panel: any, envArg: Env?, source: any?): (any?, string?)
	local env = envArg or NO_ENV
	local kind = Json.str(env, panel.type)
	if kind == nil or Migrate.LEGACY[kind] == nil then
		return panel, nil
	end
	local key = source or panel
	local hit = migrated[key]
	if hit == nil or hit.title ~= panel.title then
		local p, why = Migrate.migrate(panel, env)
		hit = { panel = p, why = why, title = panel.title }
		migrated[key] = hit
	end
	local h = hit :: { panel: any?, why: string?, title: any }
	return h.panel, h.why
end

local function moduleOf(panel: any, env: Env, source: any?): (PanelModule?, any?, string?)
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
	local p, why = M.effective(panel, env, source)
	if p == nil then
		return nil, nil, why or string.format("the legacy %s panel could not be migrated", kind)
	end
	local effKind = Json.str(env, p.type) or kind
	local m = byType(effKind)
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
	local m, p, why = moduleOf(panel, env, opts.source)
	if m == nil then
		return ui.muted(why or "Not supported", { key = opts.key }), {}
	end
	local mod = m :: PanelModule
	if opts.replace then
		p = FieldConfig.withVariables(p, env, opts.replace)
	end
	local data = if queriesOf(mod, p) then Transform.prepare(p, frames, env, opts.interpolate) else frames
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
