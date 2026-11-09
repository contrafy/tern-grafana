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
local Scheme = require("../links/scheme")
local Tbl = require("../tbl")
local Types = require("./types")
local Variables = require("./variables")

type Env = Env.Env
type Effect = Effect.Effect
type State = Types.State
type PanelLink = Types.PanelLink

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
-- `${__url_time_range}` interpolated; a path-only URL is on Grafana.
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
		local u = Interpolate.replace(url :: string, scope, { format = Interpolate.text })
		if string.sub(u, 1, 1) == "/" and base then
			u = base .. u
		end
		local t = if type(l.title) == "string" and l.title ~= "" then l.title else u
		table.insert(out, { title = Interpolate.replace(t, scope, { format = Interpolate.text }), url = u })
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

return M
