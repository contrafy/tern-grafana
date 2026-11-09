--!strict
-- String helpers shared by every layer.

local M = {}

-- `s` without leading and trailing whitespace.
function M.trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

-- The first line of an error or command output, without a "runtime error: "
-- prefix and trailing whitespace: Tern's errors may carry a Lua stack
-- traceback, which belongs in the log, not in a block. nil and empty text
-- read "unknown error"; non-strings go through tostring.
function M.firstLine(err: any): string
	local text = if err == nil then "" elseif type(err) == "string" then err else tostring(err)
	local line = string.match(text, "^%s*([^\r\n]*)") or ""
	line = string.gsub(line, "^runtime error: ", "")
	line = string.gsub(line, "%s+$", "")
	return if line == "" then "unknown error" else line
end

return M
