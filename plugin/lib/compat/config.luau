--!strict
-- The `compat` config section (docs/compat.md), read defensively like the
-- other feature sections: a wrong value falls back to the default.

local ConfigTypes = require("../config/types")

local M = {}

M.DEFAULT_MAX_DASHBOARDS = 500
M.MAX_DASHBOARDS_LIMIT = 10000

export type Settings = {
	-- At most this many dashboards are scanned (search order).
	max_dashboards: number,
}

function M.read(cfg: ConfigTypes.Config?): Settings
	local section = if cfg then (cfg :: any).compat else nil
	local s = if type(section) == "table" then section else {}
	local max = s.max_dashboards
	return {
		max_dashboards = if type(max) == "number"
				and max >= 1
				and max <= M.MAX_DASHBOARDS_LIMIT
			then math.floor(max)
			else M.DEFAULT_MAX_DASHBOARDS,
	}
end

return M
