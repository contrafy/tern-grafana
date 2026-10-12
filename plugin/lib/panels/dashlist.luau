--!strict
-- The dashboard list panel (public/app/plugins/panel/dashlist at v12.4.0:
-- DashList.tsx fetchDashboards and the grouping, DashListItem.tsx,
-- utils.ts useDashListUrlParams, panelcfg.cue defaults;
-- app/features/search/service/sql.ts for how the searches become
-- `/api/search` requests and folder names).
--
-- Starred (`starred=true`), recently viewed and search (query, tags,
-- folderUID, type=dash-db) each read `/api/search` with maxItems. Grafana's
-- recently viewed list is the browser's own view history (impressionSrv,
-- local storage), which Tern does not have: the list holds the dashboard
-- the panel is on, which Grafana records as viewed when it opens it, and
-- says so. Starred and search results are sorted by name, recent keeps its
-- order; a dashboard is marked starred from Grafana's isStarred. Each title
-- opens the native dashboard block, keepTime with the panel's time range.
--
-- Not native: query or tags written with dashboard variables (a panel
-- request cannot interpolate them). includeVars is not carried into the
-- link (the panel view does not see the variable values).

local Assets = require("../render/assets")
local Common = require("./common")
local Env = require("../env")
local Frame = require("../frame/types")
local Json = require("./json")
local Response = require("../source/response")
local Scheme = require("../links/scheme")
local TransportTypes = require("../transport/types")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node

local M = {}

M.types = { "dashlist" }

export type Options = {
	keepTime: boolean,
	includeVars: boolean,
	showStarred: boolean,
	showRecentlyViewed: boolean,
	showSearch: boolean,
	showHeadings: boolean,
	showFolderNames: boolean,
	maxItems: number,
	query: string,
	tags: { string },
	folderUID: string?,
}

export type Hit = {
	uid: string,
	title: string,
	folder_uid: string?,
	folder_title: string?,
	starred: boolean,
}

-- panelcfg.cue defaults.
function M.options(panel: any, env: Env): Options
	local o = Json.obj(env, Json.path(env, panel, "options"))
	local function flag(name: string, default: boolean): boolean
		local v = Json.bool(env, o[name])
		if v == nil then
			return default
		end
		return v
	end
	local tags: { string } = {}
	for _, t in Json.list(env, o.tags) do
		local s = Json.str(env, t)
		if s then
			table.insert(tags, s)
		end
	end
	return {
		keepTime = flag("keepTime", false),
		includeVars = flag("includeVars", false),
		showStarred = flag("showStarred", true),
		showRecentlyViewed = flag("showRecentlyViewed", false),
		showSearch = flag("showSearch", false),
		showHeadings = flag("showHeadings", true),
		showFolderNames = flag("showFolderNames", true),
		maxItems = Json.num(env, o.maxItems) or 10,
		query = Json.str(env, o.query) or "",
		tags = tags,
		folderUID = Json.str(env, o.folderUID),
	}
end

function M.supports(panel: any, env: Env): (boolean, string?)
	local o = M.options(panel, env)
	if o.showSearch then
		local texts = table.clone(o.tags)
		table.insert(texts, o.query)
		for _, t in texts do
			if string.find(t, "$", 1, true) then
				return false, "dashboard list searches with dashboard variables are not interpolated natively"
			end
		end
	end
	return true, nil
end

function M.queries(_: any): boolean
	return false
end

local function limit(o: Options): string
	return tostring(math.floor(o.maxItems))
end

-- fetchDashboards through SQLSearcher.starred/search.
function M.requests(panel: any, ctx: Common.RequestContext, env: Env): { Common.PanelRequest }
	local o = M.options(panel, env)
	local out: { Common.PanelRequest } = {}
	if o.showStarred then
		table.insert(out, {
			tag = "starred",
			signal = "dashboards",
			request = { method = "GET", path = "/api/search", query = { { "limit", limit(o) }, { "starred", "true" } } },
		})
	end
	if o.showRecentlyViewed and ctx.dashboard_uid then
		table.insert(out, {
			tag = "recent",
			signal = "dashboards",
			request = {
				method = "GET",
				path = "/api/search",
				query = {
					{ "limit", limit(o) },
					{ "type", "dash-db" },
					{ "dashboardUIDs", ctx.dashboard_uid :: string },
				},
			},
		})
	end
	if o.showSearch then
		local q: { { string } } = { { "limit", limit(o) } }
		for _, t in o.tags do
			table.insert(q, { "tag", t })
		end
		if o.query ~= "" and o.query ~= "*" then
			table.insert(q, { "query", o.query })
		end
		table.insert(q, { "type", "dash-db" })
		-- DashList: an empty folderUID is the General folder.
		if o.folderUID ~= nil then
			table.insert(q, { "folderUIDs", if o.folderUID == "" then "general" else o.folderUID :: string })
		end
		table.insert(out, {
			tag = "search",
			signal = "dashboards",
			request = { method = "GET", path = "/api/search", query = q },
		})
	end
	return out
end

function M.parse(_: any, _tag: string, response: TransportTypes.Response, env: Env): any
	local doc, err = Response.json(response, env, "dashboard search")
	if err then
		return { error = err.message }
	end
	local hits: { Hit } = {}
	for _, h in Json.list(env, doc) do
		local uid = Json.str(env, Json.path(env, h, "uid"))
		if uid == nil or uid == "" or Json.str(env, h.type) == "dash-folder" then
			continue
		end
		table.insert(hits, {
			uid = uid,
			title = Json.str(env, h.title) or uid,
			folder_uid = Json.str(env, h.folderUid),
			folder_title = Json.str(env, h.folderTitle),
			starred = Json.bool(env, h.isStarred) == true,
		})
	end
	return { hits = hits }
end

-- View ----------------------------------------------------------------------------------

function M.link(uid: string, o: Options, opts: Common.Options): string?
	local params: { [string]: string } = { uid = uid }
	if o.keepTime and opts.time then
		local t = opts.time :: { from_ms: number, to_ms: number }
		params.from = string.format("%d", t.from_ms)
		params.to = string.format("%d", t.to_ms)
	end
	local ok, link = pcall(Scheme.encode, { action = "dashboard", params = params, vars = {} })
	return if ok then link else nil
end

local function el(class: string, key: string, children: { Node }, props: { [string]: any }?): Node
	local p: { [string]: any } = { tag = "div", class = class, key = key }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "el", p = p, c = children }
end

local function byName(list: { Hit }): { Hit }
	local out = table.clone(list)
	table.sort(out, function(a: Hit, b: Hit): boolean
		local la, lb = string.lower(a.title), string.lower(b.title)
		if la ~= lb then
			return la < lb
		end
		return a.title < b.title
	end)
	return out
end

local function hitsOf(extra: { [string]: any }?, tag: string): ({ Hit }?, string?)
	local a = if extra then extra[tag] else nil
	if a == nil then
		return nil, nil
	end
	if a.error then
		return nil, tostring(a.error)
	end
	return a.hits, nil
end

local function itemNode(h: Hit, starred: boolean, o: Options, opts: Common.Options, i: number): Node
	local link = M.link(h.uid, o, opts)
	local main: { Node } = { ui.text({ { t = h.title, href = link } }, { key = "t" }) }
	if o.showFolderNames then
		-- sql.ts: a dashboard without a folder is in "Dashboards" (general).
		local folder = if h.folder_uid and h.folder_uid ~= "" then h.folder_title else "Dashboards"
		if folder then
			table.insert(main, ui.text({ ui.span(folder :: string, "muted") }, { key = "f" }))
		end
	end
	return el("tgl-item tgl-dash", "d" .. i, {
		el("tgl-col tgl-grow", "m", main),
		ui.text({ ui.span(if starred then "★" else "☆", if starred then "warning" else "muted") }, {
			key = "s",
			title = if starred then "Starred" else "Not starred",
		}),
	})
end

function M.view(panel: any, _: { Frame.Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local o = M.options(panel, env)
	local children: { Node } = {}
	if not (o.showStarred or o.showRecentlyViewed or o.showSearch) then
		return el("tgl-list", opts.key, { ui.muted("No dashboard groups configured", { key = "none" }) }), nil
	end
	local starredHits, starredErr = hitsOf(opts.extra, "starred")
	local starredSet: { [string]: boolean } = {}
	for _, h in starredHits or {} :: { Hit } do
		starredSet[h.uid] = true
	end
	local function isStarred(h: Hit): boolean
		return h.starred or starredSet[h.uid] == true
	end
	local groups: { { show: boolean, header: string, tag: string, sort: boolean, note: string? } } = {
		{ show = o.showStarred, header = "Starred dashboards", tag = "starred", sort = true },
		{
			show = o.showRecentlyViewed,
			header = "Recently viewed dashboards",
			tag = "recent",
			sort = false,
			note = "Tern has no Grafana view history: this dashboard",
		},
		{ show = o.showSearch, header = "Search", tag = "search", sort = true },
	}
	for gi, g in groups do
		if not g.show then
			continue
		end
		local items: { Node } = {}
		if o.showHeadings then
			table.insert(items, ui.text({ ui.span(g.header, "strong") }, { key = "h" }))
		end
		local hits, err
		if g.tag == "starred" then
			hits, err = starredHits, starredErr
		else
			hits, err = hitsOf(opts.extra, g.tag)
		end
		if err then
			table.insert(items, ui.text({ ui.span(err :: string, "error") }, { key = "e" }))
		elseif hits == nil then
			table.insert(items, ui.muted("Loading...", { key = "l" }))
		else
			if g.note then
				table.insert(items, ui.muted(g.note :: string, { key = "n" }))
			end
			local list = if g.sort then byName(hits :: { Hit }) else hits :: { Hit }
			for i = 1, math.min(#list, math.max(math.floor(o.maxItems), 0)) do
				table.insert(items, itemNode(list[i], isStarred(list[i]), o, opts, i))
			end
		end
		table.insert(children, el("tgl-group", "g" .. gi, items))
	end
	return el("tgl-list", opts.key, children, { role = "tern-grafana.dashlist" }), nil
end

return M
