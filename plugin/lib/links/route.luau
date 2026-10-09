--!strict
-- Decides the window's `route.link` answer. tern-grafana:// links are always
-- claimed (an unclaimed private link would fall through to the OS); Grafana
-- URLs open natively when the matching block exists and in the browser pane
-- otherwise; every other URL is left to Tern (nil).
--
-- Block args are a single canonical tern-grafana:// link, so the block reuses
-- `Scheme.decode` and its validation; links never carry secrets.

local GrafanaUrl = require("./grafana_url")
local Scheme = require("./scheme")
local Types = require("../config/types")

type Config = Types.Config
type Link = Scheme.Link

local M = {}

M.PLUGIN = "tern-grafana"

-- Which actions have a native block. Later milestones flip entries.
M.CAPABILITIES = table.freeze({
	query = true,
	dashboard = true,
	panel = true,
	alerts = true,
	silence = false,
	logs = false,
	trace = false,
	ops = false,
	settings = false,
})

export type Capabilities = { [string]: boolean }

export type Decision = { block: string, args: { string } } | { url: string } | { handled: boolean }

export type Codec = { decode: (string) -> any, encode: (any) -> string }

local function blockFor(l: Link): Decision
	return { block = M.PLUGIN .. "." .. l.action, args = { Scheme.encode(l) } }
end

local function contextBase(bases: { GrafanaUrl.Base }, cfg: Config?, name: string?): string?
	local wanted = name or (cfg and cfg.default_context)
	for _, b in bases do
		if b.context == wanted then
			return b.url
		end
	end
	return nil
end

-- Returns the decision and, when the user should be told something (bad
-- link, unknown context, no native view yet), a short message.
function M.decide(url: string, cfg: Config?, caps: Capabilities, codec: Codec): (Decision?, string?)
	local bases = GrafanaUrl.bases(cfg)
	if Scheme.isLink(url) then
		local l, err = Scheme.decode(url)
		if not l then
			return { handled = true }, "Invalid tern-grafana link: " .. (if err then err.message else "unknown error")
		end
		if l.action == "browse" then
			return { url = l.params.url }
		end
		local ctx = l.params.context
		if ctx and not (cfg and cfg.contexts[ctx]) then
			return { handled = true }, string.format("Unknown context %q", ctx)
		end
		if caps[l.action] then
			return blockFor(l)
		end
		local base = contextBase(bases, cfg, ctx)
		local page = if base then GrafanaUrl.build(l, base, codec.encode) else nil
		if page then
			return { url = page }
		end
		return { handled = true }, string.format("No native %s view yet", l.action)
	end
	local r = GrafanaUrl.recognize(url, bases, codec.decode)
	if not r then
		return nil
	end
	local l = (r :: any).link :: Link?
	if l and caps[l.action] then
		return blockFor(l)
	end
	return { url = url }
end

-- The answer when deciding raised: never let a link fall through to the OS.
function M.fallback(url: string): Decision?
	if Scheme.isLink(url) then
		return { handled = true }
	end
	return if GrafanaUrl.parse(url) then { url = url } else nil
end

return M
