--!strict
-- The dashboard machine's links: the block's own `tern-grafana://` link
-- (what `save` keeps), Grafana's pages for it and its panels, panel links,
-- and pinning a panel as its own block.

local Core = require("./core")
local Effect = require("../effect")
local Env = require("../env")
local GrafanaUrl = require("../links/grafana_url")
local Http = require("../transport/http")
local Interpolate = require("./interpolate")
local RenderPng = require("./render_png")
local Repeat = require("./repeat")
local Search = require("./search")
local Scheme = require("../links/scheme")
local Tbl = require("../tbl")
local Types = require("./types")
local Variables = require("./variables")

type Env = Env.Env
type Effect = Effect.Effect
type State = Types.State
type PanelLink = Types.PanelLink

-- A dashboard link (dashboard.links, DashboardLinks): a "link" button
-- opening `url`, or a "dashboards" link listing the dashboards tagged
-- `tags` (as one dropdown, or a button per dashboard).
export type DashLink = {
	kind: "link" | "dashboards",
	title: string,
	tooltip: string?,
	url: string,
	dropdown: boolean,
	tags: { string },
	keep_time: boolean,
	include_vars: boolean,
}

local M = {}

-- The link this block shows now: canonical, secret-free, and what `save` keeps.
function M.link(s: State): Scheme.Link?
	if s.uid == nil then
		return nil
	end
	local params: { [string]: string } = { uid = s.uid :: string }
	if s.context then
		params.context = s.context :: string
	end
	if s.org then
		params.org = s.org :: string
	end
	if s.from and s.to then
		params.from, params.to = s.from :: string, s.to :: string
	end
	local vars = if s.dashboard then Variables.urlValues(s.vars) else s.link_vars
	if s.solo then
		params.panel = tostring(s.solo)
		return { action = "panel", params = params, vars = vars }
	end
	local inst = if s.expanded and s.focus then Core.find(s, s.focus :: string) else nil
	if inst then
		params.panel = tostring(inst.panel.id)
	end
	return { action = "dashboard", params = params, vars = vars }
end

-- The encoded link, or nil when it does not validate.
function M.encode(l: Scheme.Link): string?
	local ok = Scheme.validate(l)
	return if ok then Scheme.encodeValid(ok) else nil
end

-- Grafana's page for the dashboard (or the expanded panel) under the browser URL.
function M.grafanaUrl(s: State, env: Env): string?
	local base = Core.browserBase(s)
	local l = M.link(s)
	if base == nil or l == nil then
		return nil
	end
	local page = Tbl.copy(l)
	page.action = "dashboard"
	return GrafanaUrl.build(page, base, env.encode)
end

function M.browse(url: string): Effect
	return {
		kind = "open",
		target = Scheme.encode({ action = "browse", params = { url = url }, vars = {} }),
	}
end

-- The focused panel's solo page in the browser pane.
function M.openPanelInBrowser(s: State, key: string?, effects: { Effect })
	local base = Core.browserBase(s)
	local inst = if key then Core.find(s, key) else nil
	if base == nil or inst == nil then
		return
	end
	local spec = Core.pngSpec(s, inst)
	if spec == nil then
		return
	end
	spec.width, spec.height, spec.theme = nil, nil, nil
	table.insert(effects, M.browse(RenderPng.soloUrl(base, spec)))
end

-- The panel's links (panel.links) with variables, the time builtins and
-- `${__url_time_range}` interpolated as linkSrv.getDataLinkUIModel does (the
-- URL `uriencode`, the title in the default format); a path-only URL is on
-- Grafana.
function M.panelLinks(s: State, inst: Repeat.Instance, env: Env): { PanelLink }
	local out: { PanelLink } = {}
	local links = Env.value(env, inst.panel.json.links)
	if type(links) ~= "table" then
		return out
	end
	local scope = Interpolate.merge(Core.builtinScope(s), Core.panelScope(s, inst))
	scope = Interpolate.merge(scope, {
		__url_time_range = Interpolate.value(
			"from=" .. Http.escape(s.from or "now-6h") .. "&to=" .. Http.escape(s.to or "now")
		),
	})
	local base = Core.browserBase(s)
	for _, l in links do
		local url = if type(l) == "table" and type(l.url) == "string" then l.url else nil
		if url == nil or url == "" then
			continue
		end
		local u = Interpolate.replace(url :: string, scope, { format = Interpolate.named("uriencode") })
		if string.sub(u, 1, 1) == "/" and base then
			u = base .. u
		end
		local t = if type(l.title) == "string" and l.title ~= "" then l.title else u
		table.insert(out, { title = Interpolate.replace(t, scope), url = u })
	end
	return out
end

-- Opens panel link `<index>:<panel key>` in the browser pane.
function M.openPanelLink(s: State, value: string, env: Env, effects: { Effect })
	local idx, key = string.match(value, "^(%d+):(.+)$")
	local inst = if key then Core.find(s, key) else nil
	if inst == nil then
		return
	end
	local link = M.panelLinks(s, inst, env)[tonumber(idx) :: number]
	if link and string.match(link.url, "^https?://") then
		table.insert(effects, M.browse(link.url))
	end
end

-- Opens a panel's data link (`dlink=<percent-encoded URL>`, the treemap's
-- tiles) in the browser pane.
function M.openDataLink(value: string, effects: { Effect })
	local url = Scheme.percentDecode(value, false)
	if url and string.match(url, "^https?://") then
		table.insert(effects, M.browse(url))
	end
end

-- Opens the focused panel as its own panel block.
function M.pin(s: State, effects: { Effect })
	local inst = if s.focus then Core.find(s, s.focus :: string) else nil
	if inst == nil or s.uid == nil then
		return
	end
	local params: { [string]: string } = { uid = s.uid :: string, panel = tostring(inst.panel.id) }
	if s.context then
		params.context = s.context :: string
	end
	if s.org then
		params.org = s.org :: string
	end
	if s.from and s.to then
		params.from, params.to = s.from :: string, s.to :: string
	end
	local target = M.encode({ action = "panel", params = params, vars = Core.instanceVars(s, inst) })
	if target then
		table.insert(effects, { kind = "open", target = target })
	end
end

local function flag(v: any): boolean
	return v == true
end

-- The query getLinkSrv().getLinkUrl appends for keepTime and includeVars:
-- the range as written and `var-<name>` per selected value.
local function linkQuery(s: State, l: DashLink): string
	local parts: { string } = {}
	if l.keep_time then
		table.insert(parts, "from=" .. Http.escape(s.from or "now-6h"))
		table.insert(parts, "to=" .. Http.escape(s.to or "now"))
	end
	if l.include_vars then
		local values = Variables.urlValues(s.vars)
		local names: { string } = {}
		for name in values do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			for _, v in values[name] do
				table.insert(parts, "var-" .. Http.escape(name) .. "=" .. Http.escape(v))
			end
		end
	end
	return table.concat(parts, "&")
end

-- urlUtil.appendQueryToUrl.
local function appendQuery(url: string, query: string): string
	if query == "" then
		return url
	end
	local sep = if string.find(url, "?", 1, true) then "&" else "?"
	return url .. sep .. query
end

-- The dashboard's links with variables interpolated (templateSrv.replace on
-- the title, tooltip and URL) and a "link" URL completed as getLinkUrl does;
-- a path-only URL is on Grafana.
function M.dashboardLinks(s: State, env: Env): { DashLink }
	local out: { DashLink } = {}
	local d = s.dashboard
	if d == nil then
		return out
	end
	local scope = Interpolate.merge(Core.builtinScope(s), Core.scopeOf(s))
	local base = Core.browserBase(s)
	for _, raw in d.links do
		local l = Env.value(env, raw)
		if type(l) ~= "table" then
			continue
		end
		local kind: "link" | "dashboards" = if l.type == "dashboards" then "dashboards" else "link"
		local tags: { string } = {}
		if type(l.tags) == "table" then
			for _, t in l.tags do
				if type(t) == "string" then
					table.insert(tags, t)
				end
			end
		end
		local title = if type(l.title) == "string" then Interpolate.replace(l.title, scope) else ""
		local tooltip = if type(l.tooltip) == "string" and l.tooltip ~= ""
			then Interpolate.replace(l.tooltip, scope)
			else nil
		local link: DashLink = {
			kind = kind,
			title = title,
			tooltip = tooltip,
			url = "",
			dropdown = flag(l.asDropdown),
			tags = tags,
			keep_time = flag(l.keepTime),
			include_vars = flag(l.includeVars),
		}
		if kind == "link" then
			local u = if type(l.url) == "string" then Interpolate.replace(l.url, scope) else ""
			if string.sub(u, 1, 1) == "/" and base then
				u = base .. u
			end
			link.url = appendQuery(u, linkQuery(s, link))
		end
		table.insert(out, link)
	end
	return out
end

-- DashboardLinksDashboard's search: the dashboards tagged with every tag of
-- each "dashboards" link (all dashboards without tags).
function M.requestDashboardLinks(s: State, env: Env, effects: { Effect })
	local route = s.route
	s.dash_hits = {}
	if route == nil then
		return
	end
	for i, l in M.dashboardLinks(s, env) do
		if l.kind == "dashboards" then
			table.insert(effects, Core.http(Core.tag("dlinks", s.gen, i), route, Search.request("", l.tags)))
		end
	end
end

-- The answer of link `index`'s search, the current dashboard left out.
function M.onDashboardLinks(s: State, index: string, response: any, env: Env): boolean
	local i = tonumber(index)
	if i == nil then
		return false
	end
	local hits: { Search.Hit } = Search.parse(response, env) or {}
	local out: { Search.Hit } = {}
	for _, h in hits do
		if h.uid ~= s.uid then
			table.insert(out, h)
		end
	end
	s.dash_hits[i] = out
	return true
end

-- The dashboards a "dashboards" link lists, as picker links.
function M.dashboardHits(s: State, index: number): { PanelLink }
	local out: { PanelLink } = {}
	local hits: { Search.Hit } = s.dash_hits[index] or {}
	for _, h in hits do
		table.insert(out, { title = h.title, url = h.folder or "", uid = h.uid })
	end
	return out
end

-- Opens dashboard `uid` as a dashboard block, with the range and the
-- variables when link `l` keeps them.
local function openDashboard(s: State, uid: string, l: DashLink?, effects: { Effect })
	local params: { [string]: string } = { uid = uid }
	if s.context then
		params.context = s.context :: string
	end
	if s.org then
		params.org = s.org :: string
	end
	if l and l.keep_time and s.from and s.to then
		params.from, params.to = s.from :: string, s.to :: string
	end
	local vars = if l and l.include_vars then Variables.urlValues(s.vars) else {}
	local target = M.encode({ action = "dashboard", params = params, vars = vars })
	if target then
		table.insert(effects, { kind = "open", target = target })
	end
end

-- Link `<index>` (a "link" button) in the browser pane, or `<index>:<n>`
-- (dashboard n of a "dashboards" link) as its own dashboard block.
function M.openDashboardLink(s: State, value: string, env: Env, effects: { Effect })
	local idx, n = string.match(value, "^(%d+):?(%d*)$")
	local l = if idx then M.dashboardLinks(s, env)[tonumber(idx) :: number] else nil
	if l == nil then
		return
	end
	if l.kind == "link" then
		if string.match(l.url, "^https?://") then
			table.insert(effects, M.browse(l.url))
		end
		return
	end
	local hits: { Search.Hit } = s.dash_hits[tonumber(idx) :: number] or {}
	local hit = hits[tonumber(n) or 0]
	if hit then
		openDashboard(s, hit.uid, l, effects)
	end
end

return M
