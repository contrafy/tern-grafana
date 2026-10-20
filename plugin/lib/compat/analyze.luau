--!strict
-- The compatibility report's decisions: for one dashboard (library panels
-- merged) and Grafana's frontend settings, the rung every panel takes and
-- why, decided by the Dashboard block's own functions (Repeat.expand for
-- the panel instances, Ladder.decide with the registry's verdict), plus
-- the counts grouped by reason across dashboards.
--
-- Differences from an open Dashboard block, all on purpose:
-- - collapsed rows are analyzed too (the block decides their panels when the
--   row is expanded);
-- - a repeated panel or row counts once (its first copy, with the first
--   repeat value in scope, as the block's first copy) and records the repeat
--   variable;
-- - query variables are not fetched: their saved selection is in scope.
--   Datasource variables are resolved from the frontend settings as the
--   block resolves them.

local Env = require("../env")
local GrafanaSource = require("../source/grafana")
local Interpolate = require("../dashboard/interpolate")
local Ladder = require("../dashboard/ladder")
local Model = require("../dashboard/model")
local Queries = require("../dashboard/queries")
local Registry = require("../panels/registry")
local Repeat = require("../dashboard/repeat")
local Route = require("../config/route")
local TransportTypes = require("../transport/types")
local Variables = require("../dashboard/variables")

type Env = Env.Env

local M = {}

export type Settings = {
	renderer: boolean,
	version: string?,
	datasources: { Queries.Datasource },
}

export type PanelResult = {
	id: number,
	title: string,
	-- The panel JSON's own type ("graph" for a legacy graph).
	type: string,
	mode: Ladder.Mode,
	-- The reason shown on the panel (nil when native).
	reason: string?,
	-- Why the panel is not native, without the rung suffix (nil when native).
	blocker: string?,
	-- The blocker with names and uids generalized, the grouping key.
	group: string?,
	row: string?,
	collapsed: boolean,
	-- Repeat variable of the panel, or of its row.
	repeat_var: string?,
	row_repeat_var: string?,
	library: boolean,
}

export type DashResult = {
	uid: string,
	title: string,
	folder: string?,
	panels: { PanelResult },
	-- Why the dashboard could not be analyzed.
	error: string?,
	native: number,
	png: number,
	browser: number,
}

export type TypeCount = { type: string, count: number }

export type ReasonRow = {
	reason: string,
	mode: Ladder.Mode,
	panels: number,
	dashboards: number,
	types: { TypeCount },
}

export type Summary = {
	dashboards: number,
	failed: number,
	panels: number,
	native: number,
	png: number,
	browser: number,
	reasons: { ReasonRow },
	native_types: { TypeCount },
}

-- Grafana's frontend settings as the Dashboard block reads them.
function M.settings(route: Route.Route, response: TransportTypes.Response, env: Env): (Settings?, string?)
	local r = GrafanaSource.parseFrontendSettings(route, response, env)
	if not r.ok then
		return nil, (r :: any).error.message
	end
	local fs = (r :: any).settings :: GrafanaSource.FrontendSettings
	return {
		renderer = fs.renderer_available == true,
		version = fs.version,
		datasources = Queries.frontendDatasources(response, env),
	},
		nil
end

-- Resolves datasource variables from Grafana's datasource list in dependency
-- order, as the Dashboard block does once the frontend settings are in.
local function resolveDatasourceVariables(vars: { Variables.Variable }, datasources: { Queries.Datasource })
	for _, v in vars do
		if v.kind ~= "datasource" then
			continue
		end
		local options, err = Variables.datasourceOptions(v, datasources, Variables.scope(vars, nil))
		if err then
			Variables.setError(v, err)
		else
			Variables.setOptions(v, options)
			Variables.normalizeDatasource(v)
		end
	end
end

-- Names, uids and variable references replaced, so one cause groups once:
-- `unknown datasource "abc"` and `datasource ${ds} is not resolved` apply
-- to many datasources and variables.
function M.group(blocker: string): string
	local g = string.gsub(blocker, '%b""', '"..."')
	g = string.gsub(g, "%$%b{}", "$var")
	g = string.gsub(g, "%[%[[^%]]*%]%]", "$var")
	g = string.gsub(g, "%$[%a_][%w_]*", "$var")
	return g
end

-- Every panel of `d` (library panels already applied) on its rung.
function M.panels(d: Model.Dashboard, settings: Settings, env: Env): { PanelResult }
	local vars = Variables.fromModel(d.templating, env)
	resolveDatasourceVariables(vars, settings.datasources)
	local base = Variables.scope(vars, nil)
	local out: { PanelResult } = {}
	local function source(id: number): Model.Panel?
		return Model.findPanel(d, id)
	end
	for _, sec in Repeat.expand(d, vars) do
		-- Copies of a repeated row ("r5.1") repeat the first one.
		if string.find(sec.key, ".", 1, true) then
			continue
		end
		local row = sec.row
		for _, inst in sec.panels do
			if inst.clone > 0 then
				continue
			end
			local p = inst.panel
			local scope = base
			if next(inst.scoped) ~= nil then
				scope = Interpolate.merge(base, inst.scoped)
			end
			local ctx: Ladder.Context = {
				supports = Registry.supports,
				renderer_available = settings.renderer,
				scope = scope,
				datasources = settings.datasources,
				source = source,
			}
			local decision = Ladder.decide(p, ctx, env)
			local blocker = if decision.mode == "native" then nil else Ladder.nativeBlocker(p, ctx, env)
			table.insert(out, {
				id = p.id,
				title = p.title,
				type = p.type,
				mode = decision.mode,
				reason = decision.reason,
				blocker = blocker,
				group = if blocker then M.group(blocker) else nil,
				row = if row then row.title else nil,
				collapsed = row ~= nil and row.collapsed,
				repeat_var = if p.repeat_by then p.repeat_by.var else nil,
				row_repeat_var = if row and row.repeat_by then row.repeat_by.var else nil,
				library = Env.value(env, p.json.libraryPanel) ~= nil,
			})
		end
	end
	return out
end

type Counts = { native: number, png: number, browser: number }

local function count(c: Counts, mode: Ladder.Mode)
	if mode == "native" then
		c.native += 1
	elseif mode == "png" then
		c.png += 1
	else
		c.browser += 1
	end
end

type Acc = { row: ReasonRow, types: { [string]: number }, seen: { [string]: boolean } }

function M.result(uid: string, title: string, folder: string?, panels: { PanelResult }, err: string?): DashResult
	local r: DashResult =
		{ uid = uid, title = title, folder = folder, panels = panels, error = err, native = 0, png = 0, browser = 0 }
	for _, p in panels do
		count(r, p.mode)
	end
	return r
end

local function sortedTypes(counts: { [string]: number }): { TypeCount }
	local out: { TypeCount } = {}
	for t, n in counts do
		table.insert(out, { type = t, count = n })
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.type < b.type
	end)
	return out
end

-- Totals and the non-native causes, most panels first.
function M.summarize(results: { DashResult }): Summary
	local s: Summary = {
		dashboards = 0,
		failed = 0,
		panels = 0,
		native = 0,
		png = 0,
		browser = 0,
		reasons = {},
		native_types = {},
	}
	local byGroup: { [string]: Acc } = {}
	local order: { Acc } = {}
	local nativeTypes: { [string]: number } = {}
	for _, r in results do
		s.dashboards += 1
		if r.error then
			s.failed += 1
		end
		for _, p in r.panels do
			s.panels += 1
			count(s, p.mode)
			if p.mode == "native" then
				nativeTypes[p.type] = (nativeTypes[p.type] or 0) + 1
				continue
			end
			local key = p.group or "unknown"
			local acc = byGroup[key]
			if acc == nil then
				acc = {
					row = { reason = key, mode = p.mode, panels = 0, dashboards = 0, types = {} },
					types = {},
					seen = {},
				}
				byGroup[key] = acc
				table.insert(order, acc)
			end
			local a = acc :: Acc
			a.row.panels += 1
			a.types[p.type] = (a.types[p.type] or 0) + 1
			if not a.seen[r.uid] then
				a.seen[r.uid] = true
				a.row.dashboards += 1
			end
		end
	end
	for _, a in order do
		a.row.types = sortedTypes(a.types)
		table.insert(s.reasons, a.row)
	end
	table.sort(s.reasons, function(a, b)
		if a.panels ~= b.panels then
			return a.panels > b.panels
		end
		if a.dashboards ~= b.dashboards then
			return a.dashboards > b.dashboards
		end
		return a.reason < b.reason
	end)
	s.native_types = sortedTypes(nativeTypes)
	return s
end

function M.typesText(types: { TypeCount }): string
	local parts: { string } = table.create(#types)
	for i, t in types do
		parts[i] = string.format("%s (%d)", t.type, t.count)
	end
	return table.concat(parts, ", ")
end

return M
