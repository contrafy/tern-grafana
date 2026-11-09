--!strict
-- The audit line a write decision logs (silences, IRM, deploy annotations):
-- `name=value` pairs joined by spaces. `always` fields are written even when
-- nil ("name=nil"); `optional` ones only when set. Callers pass whitelisted
-- names only: never free text, matcher values or credentials.

local M = {}

function M.line(e: { [string]: any }, always: { string }, optional: { string }?): string
	local parts = table.create(#always + if optional then #optional else 0)
	for _, name in always do
		table.insert(parts, name .. "=" .. tostring(e[name]))
	end
	if optional then
		for _, name in optional do
			local v = e[name]
			if v then
				table.insert(parts, name .. "=" .. tostring(v))
			end
		end
	end
	return table.concat(parts, " ")
end

return M
