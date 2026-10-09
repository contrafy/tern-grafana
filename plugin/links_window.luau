--!strict
-- Window glue for links: installs `route.link` and executes its decisions.
-- The config is read on the window's machine to learn Grafana base URLs and
-- contexts; Tern has no stat, so the parsed config is cached by file content.

local Route = require("./lib/links/route")
local Validate = require("./lib/config/validate")
local Types = require("./lib/config/types")

type Config = Types.Config

local M = {}

local MAX_CONFIG_BYTES = 1024 * 1024

local cachedText: string? = nil
local cachedConfig: Config? = nil

local function loadConfig(t: any): Config?
	local path = Validate.path({ XDG_CONFIG_HOME = t.getenv("XDG_CONFIG_HOME"), HOME = t.getenv("HOME") })
	if not path then
		return nil
	end
	local ok, text = pcall(t.fs.read, path, MAX_CONFIG_BYTES)
	if not ok or type(text) ~= "string" then
		cachedText, cachedConfig = nil, nil
		return nil
	end
	if text ~= cachedText then
		cachedText = text
		cachedConfig = (Validate.parseFile(text, t.json.decode))
	end
	return cachedConfig
end

-- Opens `url` in a browser pane; the window's own `cx:open` skips routes.
function M.openBrowser(cx: any, url: string)
	cx:open(url)
end

function M.register(t: any)
	local codec = {
		decode = t.json.decode,
		encode = function(v: any): string
			return t.json.encode(v)
		end,
	}
	t.route.link(function(link: any, cx: any): any
		local ok, decision, message = pcall(function()
			return Route.decide(link.url, loadConfig(t), Route.CAPABILITIES, codec)
		end)
		if not ok then
			cx:toast("error", "Tern Grafana could not open the link", tostring(decision))
			return Route.fallback(link.url)
		end
		if message then
			cx:toast("info", message)
		end
		return decision
	end)
end

return M
