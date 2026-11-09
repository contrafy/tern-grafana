--!strict
-- The dashboard block (`tern-grafana.dashboard`, B2) and, with `solo` set,
-- the panel block (B3, lib/dashboard/panel_state.luau): a pure state machine
-- run by plugin/block_runner.luau.
--
-- Loading: the dashboard JSON and Grafana's frontend settings (renderer,
-- datasource catalog, feature toggles) are fetched together; library panels
-- next; then the variables in dependency order, each query variable once
-- everything it references has settled; then every visible panel down its
-- ladder rung: native panels query /api/ds/query (one body per panel, over
-- the panel's own time range, lib/dashboard/panel_time) unless their module
-- needs no query, and send their module's own requests (Grafana API or
-- external GETs); PNG panels ask the image renderer, browser panels wait
-- for the user. Live panels (a module `liveMs`, e.g. the clock) share one
-- timer at the smallest period among the panels shown that redraws them
-- without querying. Every request carries a tag with a generation, and an
-- answer whose generation is stale is dropped.
-- Blob economy (docs/performance.md): a byte-identical answer to the same
-- query keeps the parsed data, so the view memo skips the redraw; native
-- panels draw a relative range snapped to their query interval
-- (M.drawRange), so a refresh inside one step draws the same bytes; the
-- auto-refresh and live timers pause while the block's tab is in the
-- background (lib/visibility.luau) and refresh as soon as it is shown; in
-- the expanded view the panels behind it are not refreshed until shown.
-- Block `init` only fetches: opening panes and other one-shot effects follow
-- user events, because Tern re-runs init on restore and plugin reloads.
--
-- The machine is split by concern: types.luau (state shape), core.luau
-- (tags, routes, scopes, instance index), png.luau (render cache),
-- advance.luau (queries and refresh), answers.luau (loading and answers),
-- links.luau, picker.luau and keys.luau. This module keeps init, update,
-- title and save, and re-exports what the view and specs read.

local Advance = require("./advance")
local Answers = require("./answers")
local Core = require("./core")
local Effect = require("../effect")
local Env = require("../env")
local Interpolate = require("./interpolate")
local Keys = require("./keys")
local Links = require("./links")
local Model = require("./model")
local Picker = require("./picker")
local Png = require("./png")
local Route = require("../config/route")
local Repeat = require("./repeat")
local Scheme = require("../links/scheme")
local Search = require("./search")
local Shared = require("../time/shared")
local Types = require("./types")
local Visibility = require("../visibility")

type Env = Env.Env
type Effect = Effect.Effect
type Msg = Effect.Msg

export type PanelStatus = Types.PanelStatus
export type Drawn = Types.Drawn
export type PanelState = Types.PanelState
export type Picker = Types.Picker
export type PickerItem = Types.PickerItem
export type PanelLink = Types.PanelLink
export type SearchState = Types.SearchState
export type Settings = Types.Settings
export type Phase = Types.Phase
export type State = Types.State

local tag = Core.tag

local M = {}

M.PNG_CACHE = Png.PNG_CACHE
M.SEARCH_LIMIT = Search.LIMIT
M.EXTERNAL_TIMEOUT_MS = Advance.EXTERNAL_TIMEOUT_MS
M.LIVE_MIN_MS = Advance.LIVE_MIN_MS
M.NO_SOURCE_PANEL = Advance.NO_SOURCE_PANEL
M.PNG_BACKOFF_MS = Answers.PNG_BACKOFF_MS
M.PNG_BACKOFF_MAX_MS = Answers.PNG_BACKOFF_MAX_MS

M.browserBase = Core.browserBase
M.panelScope = Core.panelScope
M.ladderContext = Core.ladderContext
M.instanceVars = Core.instanceVars
M.pngSpec = Core.pngSpec
M.drawRange = Core.drawRange
M.panelTime = Core.panelTime
M.find = Core.find
M.pngError = Png.err
M.link = Links.link
M.grafanaUrl = Links.grafanaUrl
M.panelLinks = Links.panelLinks
M.pickerItems = Picker.items
M.pickerItemsFor = Picker.itemsFor
M.focusedExemplars = Keys.focusedExemplars
M.selectedExemplar = Keys.selectedExemplar

-- Init --------------------------------------------------------------------------------

local function applyLink(s: State, l: Scheme.Link)
	local p = l.params
	s.context = p.context
	s.uid = p.uid
	s.org = p.org
	s.from, s.to = p.from, p.to
	if s.from == nil or s.to == nil then
		s.from, s.to = nil, nil
	end
	s.link_vars = l.vars
	s.link_panel = tonumber(p.panel or "")
end

local function routeFor(s: State, env: Env): string?
	local cfg = env.config
	if cfg == nil then
		return "no valid config: open Grafana settings (tern-grafana://settings) or see docs/configuration.md"
	end
	local route, err = Route.route(cfg, s.context, "dashboards")
	if route == nil then
		return if err then err.message else "no Grafana endpoint"
	end
	s.route = route
	s.context = s.context or route.context
	return nil
end

-- `solo`: the panel block's panel id requirement (link action `panel`).
function M.initWith(args: { string }, saved: any, env: Env, solo: boolean): (State, { Effect })
	local s = Types.new(env)
	local effects: { Effect } = {}
	if type(saved) == "table" and saved.sync == true then
		s.sync.on = true
		-- The first poll adopts what the other blocks share.
		table.insert(effects, Shared.timer(s.sync))
	end
	local raw = if type(saved) == "table" and type(saved.link) == "string" then saved.link else args[1]
	if raw and raw ~= "" then
		local l, err = Scheme.decode(raw)
		if l == nil then
			Core.setError(s, "invalid link: " .. (if err then err.message else "unknown error"))
			return s, effects
		end
		applyLink(s, l)
		if solo then
			s.solo = s.link_panel
		end
	end
	if solo and s.solo == nil then
		Core.setError(s, "a panel block needs a tern-grafana://panel link with uid and panel")
		return s, effects
	end
	local routeErr = routeFor(s, env)
	if routeErr then
		Core.setError(s, routeErr)
		return s, effects
	end
	if s.uid == nil then
		s.phase = "search"
		s.picker = { kind = "search", query = "" }
		Answers.startSearch(s, "", effects)
		return s, effects
	end
	Answers.startLoad(s, effects)
	return s, effects
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	return M.initWith(args, saved, env, false)
end

-- Keys ----------------------------------------------------------------------------------

function M.key(s: State, key: Key, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	local before = s.focus
	local changed = if s.picker then Picker.key(s, key, env, effects) else Keys.command(s, key, env, effects)
	-- Keyboard focus moved to a card that may be below the fold.
	local id = if s.focus ~= before
			and s.focus
			and not s.expanded
			and not s.solo
		then s.card_ids[s.focus :: string]
		else nil
	if id then
		table.insert(effects, { kind = "reveal", id = id, at = "start" })
	end
	return s, effects, changed or #effects > 0
end

-- Events --------------------------------------------------------------------------------

local function event(s: State, ev: UiEvent, env: Env, effects: { Effect })
	if ev.ev == "select" and type(ev.item) == "string" and s.picker then
		Picker.pick(s, ev.item, env, effects)
		return
	end
	if ev.ev ~= "action" then
		return
	end
	local act = ev.act
	local value = ev.value
	if type(act) ~= "string" or type(value) ~= "string" then
		return
	end
	if act == "focus" then
		if table.find(s.order, value) then
			s.focus = value
		end
	elseif act == "expand" then
		if table.find(s.order, value) then
			s.focus = value
			s.expanded = not s.expanded
			s.cursor = nil
			Advance.advance(s, env, false, effects)
		end
	elseif act == "row" then
		local sec: Repeat.SectionInstance? = nil
		for _, x in s.sections do
			if x.key == value then
				sec = x
			end
		end
		if sec and sec.row then
			local collapsed = s.collapsed[value]
			if collapsed == nil then
				collapsed = sec.row.collapsed
			end
			s.collapsed[value] = not collapsed
			Advance.advance(s, env, false, effects)
		end
	elseif act == "var" then
		Picker.openVar(s, value)
	elseif act == "browser" then
		Links.openPanelInBrowser(s, value, effects)
	elseif act == "plink" then
		Links.openPanelLink(s, value, env, effects)
	elseif act == "dashboard" then
		local url = Links.grafanaUrl(s, env)
		if url then
			table.insert(effects, Links.browse(url))
		end
	elseif act == "retry" then
		if s.uid then
			Answers.startLoad(s, effects)
		end
	end
end

-- Update -----------------------------------------------------------------------------------

local function split(t: string): { string }
	local out: { string } = {}
	for part in string.gmatch(t, "[^/]+") do
		table.insert(out, part)
	end
	return out
end

-- An answer (http_done): `false` when it was stale and dropped.
local function answer(s: State, msg: any, env: Env, effects: { Effect }): boolean
	local parts = split(msg.tag)
	local kind = parts[1]
	local gen = tonumber(parts[2] or "")
	if kind == "search" then
		if gen ~= s.search.gen then
			return false
		end
		local hits, err = Search.parse(msg.response, env)
		s.search.status = if hits then "ready" else "error"
		s.search.hits = hits or {}
		s.search.error = err
		return true
	end
	if gen ~= s.gen then
		return false
	end
	if kind == "dash" then
		Answers.onDashboard(s, msg.response, env, effects)
	elseif kind == "fs" then
		Answers.onSettings(s, msg.response, env, effects)
	elseif kind == "user" then
		Answers.onUser(s, msg.response, env, effects)
	elseif kind == "lib" then
		return Answers.onLibrary(s, table.concat(parts, "/", 3), msg.response, env, effects)
	elseif kind == "var" then
		if tonumber(parts[3] or "") == nil then
			return false
		end
		return Answers.onVariable(s, table.concat(parts, "/", 4), msg.response, env, effects)
	elseif kind == "q" then
		local key = table.concat(parts, "/", 4)
		local ps = s.panels[key]
		if ps == nil or tonumber(parts[3] or "") ~= ps.gen then
			return false
		end
		Answers.onQuery(s, key, msg.response, env)
	elseif kind == "x" then
		return Answers.onExtra(s, parts, msg.response, env)
	elseif kind == "png" then
		return Answers.onPng(s, msg.tag, msg.response, env, effects)
	else
		return false
	end
	return true
end

-- A timer tick: `false` when nothing the view or save reads changed.
local function tick(s: State, t: string, env: Env, effects: { Effect }): boolean
	if t == tag("pngretry", s.gen, s.png_gen) and s.png_wait then
		s.png_wait = false
		Advance.advance(s, env, false, effects)
		return true
	end
	if Shared.isTick(s.sync, t) then
		local r, cursor = Shared.poll(s.sync, env)
		local changed = if r then Advance.adoptShared(s, env, r, cursor, effects) else false
		table.insert(effects, Shared.timer(s.sync))
		return changed
	end
	if t == tag("live", s.gen, s.live_gen) and s.live_ms then
		-- Views redraw after every update; just keep ticking (no redraw
		-- while the tab is in the background).
		local hidden = Visibility.isHidden(env)
		if not hidden then
			s.live_tick += 1
		end
		local p = s.live_ms :: number
		table.insert(effects, { kind = "timer", tag = t, ms = p - env.now_ms % p })
		return not hidden
	end
	if t == tag("refresh", s.gen, s.timer_gen) and s.auto then
		if Visibility.isHidden(env) then
			-- Background tab: nothing is queried or drawn; look again
			-- shortly and refresh as soon as the block is shown.
			table.insert(effects, { kind = "timer", tag = t, ms = Visibility.POLL_MS })
			return false
		end
		Advance.refresh(s, env, effects)
		Advance.armRefresh(s, effects)
		return true
	end
	return false
end

function M.update(s: State, msg: Msg, env: Env): (State, { Effect }, boolean?)
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		return s, effects, answer(s, msg, env, effects)
	elseif msg.kind == "tick" then
		return s, effects, tick(s, msg.tag, env, effects)
	elseif msg.kind == "event" then
		event(s, msg.ev, env, effects)
	elseif msg.kind == "key" then
		local _, keyEffects = M.key(s, msg.key, env)
		effects = keyEffects
	end
	return s, effects
end

-- Title and save ---------------------------------------------------------------------------

function M.title(s: State): string?
	local d = s.dashboard
	if s.solo and d then
		local p = Model.findPanel(d, s.solo :: number)
		if p and p.title ~= "" then
			return Interpolate.replace(p.title, Core.scopeOf(s), { format = Interpolate.text })
		end
	end
	if d then
		return d.title
	end
	return if s.solo then "Grafana panel" else "Grafana dashboards"
end

function M.save(s: State): any
	local l = Links.link(s)
	if l == nil then
		return nil
	end
	local encoded = Links.encode(l)
	if encoded == nil then
		return nil
	end
	return { link = encoded, sync = if s.sync.on then true else nil }
end

return M
