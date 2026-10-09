--!strict
-- The `dashboard` config section (docs/configuration.md), read defensively:
-- the validator keeps feature sections as written, so a wrong type here
-- falls back to the default instead of failing.

local ConfigTypes = require("../config/types")
local Step = require("../time/step")

local M = {}

M.DEFAULT_MAX_POINTS = 600
M.DEFAULT_MIN_REFRESH_MS = 30000
M.DEFAULT_THEME = "dark"

export type Settings = {
	-- maxDataPoints for panels that set none.
	max_points: number,
	-- Auto-refresh never runs more often than this.
	min_refresh_ms: number,
	-- Theme of PNGs from Grafana's image renderer.
	render_theme: string,
}

-- A duration as a string ("30s") or a number of seconds.
local function duration(v: any): number?
	if type(v) == "number" and v > 0 then
		return v * 1000
	elseif type(v) == "string" then
		local ms = Step.parseDuration(v)
		return if ms and ms > 0 then ms else nil
	end
	return nil
end

function M.read(cfg: ConfigTypes.Config?): Settings
	local section = if cfg then (cfg :: any).dashboard else nil
	local s = if type(section) == "table" then section else {}
	local points = s.max_points
	local theme = s.render_theme
	return {
		max_points = if type(points) == "number"
				and points >= 10
				and points <= 11000
			then math.floor(points)
			else M.DEFAULT_MAX_POINTS,
		min_refresh_ms = duration(s.min_refresh) or M.DEFAULT_MIN_REFRESH_MS,
		render_theme = if theme == "light" or theme == "dark" then theme else M.DEFAULT_THEME,
	}
end

-- The auto-refresh period for a dashboard `refresh` value, never below the
-- configured minimum; nil when the dashboard does not refresh.
function M.refreshMs(refresh: string?, settings: Settings): number?
	if refresh == nil or refresh == "" then
		return nil
	end
	local ms = Step.parseDuration(refresh)
	if ms == nil or ms <= 0 then
		return nil
	end
	return math.max(ms, settings.min_refresh_ms)
end

return M
