--!strict
-- The rendering ladder (docs/architecture.md): per panel, native when the
-- panel registry draws its type and options and every target can be queried
-- natively; else a PNG from Grafana's image renderer when the instance has
-- one (`rendererAvailable` in /api/frontend/settings, never inferred from a
-- render's status: Grafana 11 without a renderer answers 200 with an error
-- picture); else the solo panel page in a Tern browser pane. The reason a
-- panel left the native rung is kept and shown on the panel.
--
-- A `-- Dashboard --` panel is native when its source panel's queries are
-- (whatever the source's own rung: Grafana runs the source's queries for it)
-- and, with `withTransforms`, Tern applies the source's transformations. A
-- missing source panel is Grafana's own error, shown natively.

local Env = require("../env")
local Interpolate = require("./interpolate")
local Model = require("./model")
local Queries = require("./queries")
local Transform = require("../panels/transform")

type Env = Env.Env

local M = {}

export type Mode = "native" | "png" | "browser"

export type Decision = { mode: Mode, reason: string? }

export type Context = {
	-- The panel registry's verdict on the panel JSON.
	supports: (panel: { [string]: any }, env: Env) -> (boolean, string?),
	-- nil while unknown (treated as no renderer).
	renderer_available: boolean?,
	scope: Interpolate.Scope,
	datasources: { Queries.Datasource },
	-- The dashboard's panel with this id (the source of a `-- Dashboard --`
	-- query), nil when there is none.
	source: ((panel_id: number) -> Model.Panel?)?,
}

-- Chained `-- Dashboard --` queries followed at most this deep.
local MAX_CHAIN = 8

-- Why the data of a panel cannot be produced natively; nil when it can.
local function queryBlocker(panel: Model.Panel, ctx: Context, env: Env, depth: number): string?
	local _, err = Queries.resolve(panel.json, ctx.scope, ctx.datasources, env)
	if err then
		return err
	end
	local dq, derr = Queries.dashboardQuery(panel.json, env)
	if derr then
		return derr
	end
	if dq == nil then
		return nil
	end
	local src = if ctx.source then ctx.source(dq.panel_id) else nil
	if src == nil then
		return nil
	end
	if depth >= MAX_CHAIN or src.id == panel.id then
		return "-- Dashboard -- queries reference each other in a loop"
	end
	if src.library_uid then
		return "library panel is still loading"
	end
	local why = queryBlocker(src, ctx, env, depth + 1)
	if why then
		return string.format("reuses panel %d, whose queries are not run natively: %s", src.id, why)
	end
	if dq.with_transforms then
		local tw = Transform.unsupported(src.json, env)
		if tw then
			return string.format("reuses panel %d with its transformations: %s", src.id, tw)
		end
	end
	return nil
end

-- Why a panel cannot be drawn natively; nil when it can.
function M.nativeBlocker(panel: Model.Panel, ctx: Context, env: Env): string?
	if panel.library_uid then
		return "library panel is still loading"
	end
	if panel.type == "library" then
		return "library panel could not be loaded"
	end
	local ok, reason = ctx.supports(panel.json, env)
	if not ok then
		return reason or string.format("%s panels are not drawn natively", panel.type)
	end
	return queryBlocker(panel, ctx, env, 0)
end

function M.decide(panel: Model.Panel, ctx: Context, env: Env): Decision
	local blocker = M.nativeBlocker(panel, ctx, env)
	if blocker == nil then
		return { mode = "native" }
	end
	if ctx.renderer_available == true then
		return { mode = "png", reason = blocker }
	end
	local why = if ctx.renderer_available == nil
		then "Grafana's image renderer status is unknown"
		else "Grafana has no image renderer"
	return { mode = "browser", reason = blocker .. "; " .. why }
end

return M
