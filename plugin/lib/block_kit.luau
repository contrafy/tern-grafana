--!strict
-- Context, link and one-line edit helpers the block machines share. Each
-- block keeps its own guards (when a switch is allowed, what it resets).

local ConfigTypes = require("./config/types")
local Route = require("./config/route")
local Scheme = require("./links/scheme")

local M = {}

-- Every configured context name, sorted; none without a config.
function M.contexts(config: ConfigTypes.Config?): { string }
	return if config then Route.contextNames(config) else {}
end

-- The params of a `tern-grafana://<action>` link in `args[1]`, or nil when
-- there is no such link.
function M.linkParams(args: { string }, action: string): { [string]: string }?
	local first = args[1]
	if first == nil or first == "" then
		return nil
	end
	local link = Scheme.decode(first)
	if link == nil or link.action ~= action then
		return nil
	end
	return link.params
end

-- The context `step` places after `current` in `contexts` (wrapping), or nil
-- with fewer than two contexts.
function M.cycle(contexts: { string }, current: string?, step: number): string?
	local n = #contexts
	if n < 2 then
		return nil
	end
	local i = table.find(contexts, current or "") or 0
	return contexts[(i - 1 + step) % n + 1]
end

-- Edits a one-line text field from a key (not escape/enter); true when the
-- key was used. `utf8Back`: backspace removes a whole UTF-8 character rather
-- than one byte.
function M.editText(text: string, key: any, utf8Back: boolean): (string, boolean)
	local name = key.name
	if name == "backspace" then
		if utf8Back then
			return string.sub(text, 1, (utf8.offset(text, -1) or (#text + 1)) - 1), true
		end
		return string.sub(text, 1, -2), true
	elseif name == "paste" and type(key.text) == "string" then
		return text .. string.gsub(key.text, "%c", " "), true
	elseif key.ctrl and name == "u" then
		return "", true
	elseif key.text and key.text ~= "" and not key.ctrl and not key.meta then
		return text .. key.text, true
	end
	return text, false
end

return M
