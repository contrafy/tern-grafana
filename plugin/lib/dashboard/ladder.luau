--!strict
-- The rendering ladder (docs/architecture.md): per panel, native when the
-- panel registry draws its type and options and every target can be queried
-- natively; else a PNG from Grafana's image renderer when the instance has
-- one (`rendererAvailable` in /api/frontend/settings, never inferred from a
-- render's status: Grafana 11 without a renderer answers 200 with an error
-- picture); else the solo panel page in a Tern browser pane. The reason a
-- panel left the native rung is kept and shown on the panel.

local Env = require("../env")
local Interpolate = require("./interpolate")
local Model = require("./model")
local Queries = require("./queries")

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
}

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
	local _, err = Queries.resolve(panel.json, ctx.scope, ctx.datasources, env)
	return err
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
