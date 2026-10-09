--!strict
-- Where a command-line query belongs in the config, and the Query block link
-- that reopens it: shared by the lenses that show a server's PromQL results
-- (promtool query, curl).

local ConfigTypes = require("../config/types")
local GrafanaUrl = require("../links/grafana_url")
local Range = require("../time/range")
local Scheme = require("../links/scheme")

type Config = ConfigTypes.Config

local M = {}

-- The window an instant query at a known time opens with in the Query block.
M.INSTANT_WINDOW_MS = 60 * 60 * 1000

export type Target = { context: string, ds: string? }

local function samePlace(a: GrafanaUrl.ParsedUrl, b: GrafanaUrl.ParsedUrl): boolean
	return a.scheme == b.scheme and a.authority == b.authority
end

local function sortedContexts(cfg: Config): { string }
	local names: { string } = {}
	for name in cfg.contexts do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- The configured context a Prometheus API base URL belongs to: a context whose
-- prometheus endpoint is that URL, else a Grafana datasource proxy URL
-- (`<grafana>/api/datasources/proxy/uid/<uid>`) of a configured Grafana.
function M.targetFor(server: string?, cfg: Config?): Target?
	if server == nil or cfg == nil then
		return nil
	end
	local url = GrafanaUrl.parse(server)
	if url == nil then
		return nil
	end
	for _, name in sortedContexts(cfg) do
		local prom = cfg.contexts[name].prometheus
		local base = if prom then GrafanaUrl.parse(prom.url .. prom.path_prefix) else nil
		if base and samePlace(base, url) and base.path == url.path then
			return { context = name }
		end
	end
	for _, base in GrafanaUrl.bases(cfg) do
		if base.scheme == url.scheme and base.authority == url.authority then
			local prefix = string.gsub(base.path, "%p", "%%%0")
			local uid = string.match(url.path, "^" .. prefix .. "/api/datasources/proxy/uid/([^/]+)$")
			if uid then
				return { context = base.context, ds = uid }
			end
		end
	end
	return nil
end

-- The configured Grafana context serving `url` (its scheme, host and base
-- path, which `path` continues), or nil.
function M.grafanaFor(url: GrafanaUrl.ParsedUrl, path: string, cfg: Config?): string?
	for _, base in GrafanaUrl.bases(cfg) do
		if base.scheme == url.scheme and base.authority == url.authority and base.path .. path == url.path then
			return base.context
		end
	end
	return nil
end

-- An absolute time as Prometheus and promtool take it (RFC3339 or Unix
-- seconds) in epoch ms; nil for relative or unreadable text.
function M.timeMs(text: string?): number?
	if text == nil or Range.isRelative(text) then
		return nil
	end
	return (Range.parse(text, false, { now_ms = 0 }))
end

-- Link times are epoch ms; smaller numbers would read back as seconds.
function M.msParam(ms: number?): string?
	if ms == nil or ms < 1e11 then
		return nil
	end
	return string.format("%d", ms)
end

-- `tern-grafana://query?...` for `params`, or nil and why not.
function M.queryLink(params: { [string]: string }): (string?, string?)
	local link: Scheme.Link = { action = "query", params = params, vars = {} }
	local ok, err = Scheme.validate(link)
	if not ok then
		return nil, if err then err.message else "invalid link"
	end
	return Scheme.encode(link), nil
end

return M
