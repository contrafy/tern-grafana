--!strict
-- Query history in tern.kv: the last CAP distinct expressions per context,
-- newest first. Only expressions are kept (kv is a 0644 file), never results.
-- Stored as `{ [context] = { expr, ... } }`; every block re-reads it before
-- adding so concurrent Query blocks do not drop each other's entries.

local M = {}

M.KEY = "tern-grafana.query.history"
M.CAP = 100

local function entries(stored: any, context: string): { string }
	if type(stored) ~= "table" then
		return {}
	end
	local list = stored[context]
	local out: { string } = {}
	if type(list) == "table" then
		for _, v in list do
			if type(v) == "string" and v ~= "" then
				table.insert(out, v)
			end
		end
	end
	return out
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

-- Newest first.
function M.list(stored: any, context: string): { string }
	return entries(stored, context)
end

-- The stored value with `expr` moved to the front of `context`'s list.
function M.add(stored: any, context: string, expr: string): { [string]: { string } }
	local out: { [string]: { string } } = {}
	if type(stored) == "table" then
		for name in stored do
			if type(name) == "string" then
				out[name] = entries(stored, name)
			end
		end
	end
	local e = trim(expr)
	if e == "" then
		return out
	end
	local list: { string } = { e }
	for _, v in entries(stored, context) do
		if v ~= e and #list < M.CAP then
			table.insert(list, v)
		end
	end
	out[context] = list
	return out
end

-- Entries containing `filter` (case-insensitive), in order.
function M.filter(list: { string }, filter: string): { string }
	if filter == "" then
		return list
	end
	local needle = string.lower(filter)
	local out: { string } = {}
	for _, v in list do
		if string.find(string.lower(v), needle, 1, true) then
			table.insert(out, v)
		end
	end
	return out
end

return M
