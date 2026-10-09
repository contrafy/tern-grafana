--!strict
-- Tolerant readers for decoded dashboard JSON. Panels come from users'
-- dashboards, written by any Grafana version or by hand, so a reader never
-- raises: a value of the wrong type (or the JSON null sentinel) reads as
-- absent and the caller's default applies.

local Env = require("../env")

type Env = Env.Env

local M = {}

function M.tbl(env: Env, v: any): { [any]: any }?
	if type(v) == "table" and v ~= env.null then
		return v
	end
	return nil
end

-- `v` as a table, or an empty one when it is absent or not a table.
function M.obj(env: Env, v: any): { [any]: any }
	local t = M.tbl(env, v)
	if t then
		return t
	end
	local empty: { [any]: any } = {}
	return empty
end

function M.list(env: Env, v: any): { any }
	local t = M.tbl(env, v)
	if t then
		return t :: { any }
	end
	local empty: { any } = {}
	return empty
end

function M.str(_env: Env, v: any): string?
	return if type(v) == "string" then v else nil
end

-- A finite or infinite number (NaN reads as absent); numeric strings too,
-- since hand-written dashboards store "80" as often as 80.
function M.num(_env: Env, v: any): number?
	if type(v) == "number" then
		return if v == v then v else nil
	elseif type(v) == "string" then
		local n = tonumber(v)
		return if n and n == n then n else nil
	end
	return nil
end

function M.bool(_env: Env, v: any): boolean?
	return if type(v) == "boolean" then v else nil
end

-- t[k1][k2]... with absent links reading as nil.
function M.path(env: Env, v: any, ...: string): any
	local cur = v
	for _, k in { ... } do
		local t = M.tbl(env, cur)
		if t == nil then
			return nil
		end
		cur = t[k]
	end
	return if cur == env.null then nil else cur
end

return M
