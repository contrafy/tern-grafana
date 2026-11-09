--!strict
-- The dashboard machine's cache of Grafana renders (PNG rung): pictures by
-- cache key, at most PNG_CACHE of them, and why a wanted render failed.

local RenderPng = require("./render_png")
local Types = require("./types")

type State = Types.State
type PanelState = Types.PanelState

local M = {}

M.PNG_CACHE = 24

-- The render's cache key: the spec and the refresh generation.
function M.key(s: State, spec: RenderPng.Spec): string
	return RenderPng.cacheKey(spec) .. "\31" .. s.refresh_gen
end

function M.remember(s: State, key: string, bytes: string)
	if s.pngs[key] == nil then
		table.insert(s.png_order, key)
	end
	s.pngs[key] = bytes
	while #s.png_order > M.PNG_CACHE do
		local old = table.remove(s.png_order, 1) :: string
		s.pngs[old] = nil
	end
end

-- A refresh bumped `refresh_gen`: every key wanted from now on is new, so
-- the failures of older keys are never read again.
function M.forgetErrors(s: State)
	table.clear(s.png_errors)
end

-- Why the panel's wanted render failed, if it did.
function M.err(s: State, ps: PanelState): string?
	return if ps.png_want then s.png_errors[ps.png_want :: string] else nil
end

return M
