--!strict
-- Table helpers that work on every table Tern hands to plugins. Arrays from
-- tern.json.decode carry a protected metatable (the JSON array tag), so
-- table.clone, table.freeze and setmetatable raise on them; copy instead.

local M = {}

-- A shallow copy. Like table.clone it keeps every key, but it never touches the
-- metatable, so it accepts tagged arrays (the copy is untagged).
function M.copy<T>(t: T): T
	-- selene: allow(manual_table_clone)
	local out = {}
	for k, v in t :: any do
		out[k] = v
	end
	return out :: any
end

return M
