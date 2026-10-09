--!strict
-- Recognizes Grafana URLs under the configured Grafana base URLs and maps them
-- to tern-grafana links. Only URLs under a configured base are ours: anything
-- else must stay untouched so other links keep their normal behavior. URL
-- shapes follow Grafana 11/12 (public/app/core/utils/explore.ts, the explore
-- `panes` state with schemaVersion=1, and the legacy `left` state that Grafana
-- still migrates).

local Scheme = require("./scheme")
local Types = require("../config/types")

type Config = Types.Config
type Link = Scheme.Link

local M = {}

export type Base = {
	context: string,
	scheme: string,
	-- Lowercased host with the default port removed (`host` or `host:8443`).
	authority: string,
	-- "" or "/sub/path", no trailing slash.
	path: string,
	-- Datasource uids from the context, used to tell metrics from logs.
	prometheus_ds: string?,
	loki_ds: string?,
	-- Public base URL to build browser links with.
	url: string,
}

export type Recognized = { link: Link } | { browser: string }

export type ParsedUrl = { scheme: string, authority: string, path: string, query: string }

local DEFAULT_PORTS: { [string]: string } = { http = "80", https = "443" }

-- Splits an http(s) URL; nil for anything else or for URLs with userinfo.
function M.parse(url: string): ParsedUrl?
	local scheme, rest = string.match(url, "^(%a[%w+.-]*)://(.*)$")
	if not scheme or not rest then
		return nil
	end
	scheme = string.lower(scheme) :: string
	if scheme ~= "http" and scheme ~= "https" then
		return nil
	end
	local authority = string.match(rest, "^[^/?#]*") :: string
	if authority == "" or string.find(authority, "@", 1, true) then
		return nil
	end
	local afterAuthority = string.sub(rest, #authority + 1)
	afterAuthority = string.match(afterAuthority, "^[^#]*") :: string
	local path, query = string.match(afterAuthority, "^([^?]*)%??(.*)$")
	authority = string.lower(authority)
	local host, port = string.match(authority, "^(.*):(%d*)$")
	if host and (port == "" or port == DEFAULT_PORTS[scheme]) then
		authority = host
	end
	local parsed: ParsedUrl = {
		scheme = scheme :: string,
		authority = authority,
		path = string.gsub(path or "", "/+$", "") :: string,
		query = query or "",
	}
	return parsed
end

local function sortedNames(t: { [string]: any }): { string }
	local names = {}
	for k in t do
		table.insert(names, k)
	end
	table.sort(names)
	return names
end

-- Every Grafana base URL in the config (`url` + `path_prefix`, and
-- `browser_url`), longest path first so sub-path installs win.
function M.bases(cfg: Config?): { Base }
	local out: { Base } = {}
	if not cfg then
		return out
	end
	for _, name in sortedNames(cfg.contexts) do
		local g = cfg.contexts[name].grafana
		if not g then
			continue
		end
		local ds = g.datasources
		local browser = g.browser_url or (g.url .. g.path_prefix)
		local candidates = { g.url .. g.path_prefix }
		if g.browser_url then
			table.insert(candidates, g.browser_url)
		end
		for _, candidate in candidates do
			local p = M.parse(candidate)
			if p then
				table.insert(out, {
					context = name,
					scheme = p.scheme,
					authority = p.authority,
					path = p.path,
					prometheus_ds = ds and ds.prometheus,
					loki_ds = ds and ds.loki,
					url = (string.gsub(browser, "/+$", "")),
				})
			end
		end
	end
	table.sort(out, function(a, b)
		if #a.path ~= #b.path then
			return #a.path > #b.path
		end
		return a.context < b.context
	end)
	return out
end

function M.match(url: string, bases: { Base }): (Base?, string?, string?)
	local p = M.parse(url)
	if not p then
		return nil
	end
	for _, b in bases do
		if b.scheme ~= p.scheme or b.authority ~= p.authority then
			continue
		end
		if p.path == b.path then
			return b, "", p.query
		end
		if string.sub(p.path, 1, #b.path + 1) == b.path .. "/" then
			return b, string.sub(p.path, #b.path + 1), p.query
		end
	end
	return nil
end

local function timeString(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	elseif type(v) == "number" and v == math.floor(v) then
		return string.format("%d", v)
	end
	return nil
end

-- `viewPanel=3` (classic) or `viewPanel=panel-3` (Scenes, Grafana 11+).
local function panelId(v: string?): string?
	if not v then
		return nil
	end
	return string.match(v, "^%d+$") or string.match(v, "^panel%-(%d+)$")
end

local function dsUid(v: any): string?
	if type(v) == "string" then
		return v
	elseif type(v) == "table" and type(v.uid) == "string" then
		return v.uid
	end
	return nil
end

local function dsType(v: any): string?
	if type(v) == "table" and type(v.type) == "string" then
		return v.type
	end
	return nil
end

type PaneQuery = { expr: string, ds: string?, kind: string?, from: string?, to: string? }

-- One explore pane state: `{datasource, queries = {{expr, datasource}}, range = {from, to}}`.
local function paneState(state: any): PaneQuery?
	if type(state) ~= "table" then
		return nil
	end
	local q = type(state.queries) == "table" and state.queries[1]
	if type(q) ~= "table" or type(q.expr) ~= "string" or q.expr == "" then
		return nil
	end
	local range = if type(state.range) == "table" then state.range else {}
	return {
		expr = q.expr,
		ds = dsUid(q.datasource) or dsUid(state.datasource),
		kind = dsType(q.datasource) or dsType(state.datasource),
		from = timeString(range.from),
		to = timeString(range.to),
	}
end

-- Legacy `left=["now-1h","now","<datasource name>",{"expr":"up"}]`.
local function legacyState(state: any): PaneQuery?
	if type(state) ~= "table" or state[1] == nil then
		return paneState(state)
	end
	for i = 4, #state do
		local q = state[i]
		if type(q) == "table" and type(q.expr) == "string" and q.expr ~= "" then
			return { expr = q.expr, from = timeString(state[1]), to = timeString(state[2]) }
		end
	end
	return nil
end

local function explore(query: { [string]: string }, decode: (string) -> any): PaneQuery?
	local raw = query.panes or query.left
	if not raw then
		return nil
	end
	local ok, state = pcall(decode, raw)
	if not ok or type(state) ~= "table" then
		return nil
	end
	if query.panes then
		-- Pane ids are random; the left pane is the first in the URL, but
		-- decoded objects lose order, so prefer the lowest id deterministically.
		local ids = sortedNames(state)
		return if ids[1] then paneState(state[ids[1]]) else nil
	end
	return legacyState(state)
end

local function exploreAction(q: PaneQuery, base: Base): string?
	if q.kind == "prometheus" or (q.ds ~= nil and q.ds == base.prometheus_ds) then
		return "query"
	elseif q.kind == "loki" or (q.ds ~= nil and q.ds == base.loki_ds) then
		return "logs"
	end
	return nil
end

local function link(action: string, params: { [string]: string }, vars: { [string]: { string } }?): Recognized?
	local candidate: Link = { action = action, params = params, vars = vars or {} }
	local ok = Scheme.validate(candidate)
	return if ok then { link = ok } else nil
end

local function put(params: { [string]: string }, key: string, value: string?)
	if value and value ~= "" then
		params[key] = value
	end
end

-- Maps a URL to a link or a browser answer; nil when it is not under a
-- configured Grafana base URL. `decode` parses the explore JSON state.
function M.recognize(url: string, bases: { Base }, decode: (string) -> any): Recognized?
	local base, rest, rawQuery = M.match(url, bases)
	if not base or not rest or not rawQuery then
		return nil
	end
	local browser: Recognized = { browser = url }
	local pairs_ = Scheme.parseQuery(rawQuery)
	if not pairs_ then
		return browser
	end
	local query: { [string]: string } = {}
	local vars: { [string]: { string } } = {}
	for _, p in pairs_ do
		local varName = string.match(p.name, "^var%-(.+)$")
		if varName then
			vars[varName] = vars[varName] or {}
			table.insert(vars[varName], p.value)
		elseif query[p.name] == nil then
			query[p.name] = p.value
		end
	end
	local segments = {}
	for seg in string.gmatch(rest, "[^/]+") do
		table.insert(segments, Scheme.percentDecode(seg, false) or "")
	end
	local params: { [string]: string } = { context = base.context }
	local head = segments[1]
	local result: Recognized? = nil
	if (head == "d" or head == "d-solo") and segments[2] then
		params.uid = segments[2]
		put(params, "from", query.from)
		put(params, "to", query.to)
		put(params, "org", query.orgId)
		if head == "d-solo" then
			put(params, "panel", panelId(query.panelId))
			result = link("panel", params, vars)
		else
			put(params, "panel", panelId(query.viewPanel))
			result = link("dashboard", params, vars)
		end
	elseif head == "explore" and segments[2] == nil then
		local q = explore(query, decode)
		local action = if q then exploreAction(q, base) else nil
		if q and action then
			params.expr = q.expr
			put(params, "ds", q.ds)
			put(params, "from", q.from)
			put(params, "to", q.to)
			result = link(action, params)
		end
	elseif head == "alerting" then
		if segments[2] == "list" and segments[3] == nil then
			result = link("alerts", params)
		elseif segments[2] == "grafana" and segments[3] and segments[4] == "view" and segments[5] == nil then
			params.rule = segments[3]
			result = link("alerts", params)
		end
	end
	-- `/goto/<id>` short links and every other page open in the browser.
	return result or browser
end

local function addQuery(parts: { string }, name: string, value: string?)
	if value then
		table.insert(parts, name .. "=" .. Scheme.percentEncode(value))
	end
end

local function withQuery(url: string, parts: { string }): string
	return if #parts > 0 then url .. "?" .. table.concat(parts, "&") else url
end

-- The Grafana page for a link, for browser fallback; nil when Grafana has no
-- page for it. `encode` writes the explore JSON state.
function M.build(l: Link, baseUrl: string, encode: (any) -> string): string?
	local p = l.params
	local parts: { string } = {}
	if l.action == "dashboard" or l.action == "panel" then
		addQuery(parts, "orgId", p.org)
		addQuery(parts, "from", p.from)
		addQuery(parts, "to", p.to)
		addQuery(parts, "viewPanel", p.panel)
		for _, name in sortedNames(l.vars) do
			for _, v in l.vars[name] do
				addQuery(parts, "var-" .. Scheme.percentEncode(name), v)
			end
		end
		return withQuery(baseUrl .. "/d/" .. Scheme.percentEncode(p.uid), parts)
	elseif l.action == "alerts" then
		if p.rule then
			return baseUrl .. "/alerting/grafana/" .. Scheme.percentEncode(p.rule) .. "/view"
		end
		return baseUrl .. "/alerting/list"
	elseif (l.action == "query" or l.action == "logs") and p.expr then
		local ds = if p.ds then { uid = p.ds } else nil
		local state = {
			a = {
				datasource = p.ds,
				queries = { { refId = "A", expr = p.expr, datasource = ds } },
				range = { from = p.from or "now-1h", to = p.to or "now" },
			},
		}
		addQuery(parts, "schemaVersion", "1")
		addQuery(parts, "panes", encode(state))
		return withQuery(baseUrl .. "/explore", parts)
	end
	return nil
end

return M
