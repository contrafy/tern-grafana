--!strict
-- The Query block (`tern-grafana.query`): a PromQL scratchpad over one
-- context's metrics, as a pure state machine (lib/effect.luau) that
-- plugin/query_host.luau registers through block_runner.
--
-- - Args are one canonical `tern-grafana://query?...` link; save() keeps the
--   link of what is on screen plus the mode and chart cursor, never results.
-- - Every query bumps a generation; an answer for an older generation is
--   dropped, so a slow query never overwrites a newer one.
-- - Suggestions are fetched lazily, the first time a context needs a list,
--   and cached per context for TTL_MS.
-- - The chart SVG is rendered once per result; the keyboard cursor only moves
--   an overlay, so stepping through samples mints no new blob.

local Effect = require("../effect")
local Env = require("../env")
local Frame = require("../frame/types")
local GrafanaUrl = require("../links/grafana_url")
local History = require("./history")
local Metrics = require("../source/metrics")
local Options = require("./options")
local Promql = require("./promql")
local Range = require("../time/range")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Step = require("../time/step")
local Suggest = require("./suggest")
local Svg = require("../render/svg_timeseries")
local TimeRange = require("./timerange")
local Cursor = require("../render/cursor")
local Edit = require("./edit")

type Env = Env.Env
type Effect = Effect.Effect
type Msg = Effect.Msg
type Frame = Frame.Frame
type RouteT = Route.Route

export type Mode = "graph" | "table"
export type Status = "idle" | "loading" | "ok" | "error"

-- A query failure, or "config" when the query could not even be sent.
export type Failure = { kind: string, message: string, status: number? }

export type Run = {
	gen: number,
	expr: string,
	kind: "range" | "instant",
	from_ms: number,
	to_ms: number,
	step_ms: number,
	interval_ms: number,
	route: RouteT,
}

export type Entry = {
	status: "pending" | "ok" | "error",
	at_ms: number,
	values: { string }?,
	metadata: { [string]: Suggest.Meta }?,
}

type Pending = { context: string, key: string, kind: "values" | "labels" | "metadata", route: RouteT }

export type Suggestions = {
	ctx: Promql.Context,
	items: { Suggest.Item },
	-- Set once the user moves through the list; Enter then accepts.
	selected: number?,
	loading: boolean,
}

export type HistoryPicker = { all: { string }, filter: string, selected: number }

export type State = {
	options: Options.Options,
	-- Config and link problems, shown as warnings.
	notices: { string },
	contexts: { string },
	context: string?,
	-- Grafana datasource uid named by the link.
	ds: string?,
	expr: string,
	-- Caret, 0-based byte offset into expr.
	cursor: number,
	editing: boolean,
	from: string,
	to: string,
	mode: Mode,
	gen: number,
	status: Status,
	inflight: Run?,
	-- The query the result on screen answers.
	ran: Run?,
	frames: { Frame }?,
	warnings: { string },
	failure: Failure?,
	chart: Svg.Result?,
	-- Chart cursor time (epoch ms).
	cursor_t: number?,
	-- Saved cursor, applied to the first chart it falls in.
	restore_cursor: number?,
	-- Auto-refresh interval while on.
	refresh_ms: number?,
	timer_gen: number,
	suggest: Suggestions?,
	cache: { [string]: { [string]: Entry } },
	pending: { [string]: Pending },
	seq: number,
	overlay: ("help" | "history")?,
	history: HistoryPicker?,
}

local M = {}

M.INPUT_ID = "main.q"
M.TTL_MS = 5 * 60 * 1000
M.ERROR_TTL_MS = 30 * 1000
M.QUERY_TAG = "q:"
M.SUGGEST_TAG = "s:"
M.REFRESH_TAG = "refresh:"
-- shift+left/right steps this many samples.
M.FAST_STEP = 10

local NO_CONFIG = "No tern-grafana config found: create ~/.config/tern-grafana/config.json "
	.. "(see docs/configuration.md) or open tern-grafana://settings"

local function sortedContexts(env: Env): { string }
	local names: { string } = {}
	local cfg = env.config
	if cfg then
		for name in cfg.contexts do
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

-- Where metrics for the block's context are read. A link's datasource uid
-- names one Grafana datasource exactly, so it wins over the configured route
-- whenever the context has Grafana.
function M.route(s: State, env: Env): (RouteT?, string?)
	local cfg = env.config
	if cfg == nil then
		return nil, NO_CONFIG
	end
	if s.context == nil then
		return nil, "No context: set default_context or add a context to the config"
	end
	local route, err = Route.route(cfg, s.context, "metrics")
	local ctx = cfg.contexts[s.context :: string]
	if s.ds and ctx and ctx.grafana then
		return {
			context = s.context :: string,
			signal = "metrics",
			via = "datasource",
			endpoint_name = "grafana",
			endpoint = ctx.grafana,
			datasource_uid = s.ds,
		},
			nil
	end
	if route == nil then
		return nil, if err then err.message else "metrics are not routable"
	end
	return route, nil
end

local function resolve(s: State, env: Env): (Range.Range?, string?)
	return Range.resolve(s.from, s.to, { now_ms = env.now_ms })
end

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

-- Starts the query for the current expression, range and mode.
local function run(s: State, env: Env, effects: { Effect })
	s.gen += 1
	s.inflight = nil
	local expr = trim(s.expr)
	if expr == "" then
		s.status = "idle"
		s.ran, s.frames, s.chart, s.failure, s.cursor_t = nil, nil, nil, nil, nil
		s.warnings = {}
		return
	end
	local function fail(message: string)
		s.status = "error"
		s.failure = { kind = "config", message = message }
		s.frames, s.chart, s.cursor_t = nil, nil, nil
		s.warnings = {}
	end
	local route, routeErr = M.route(s, env)
	if route == nil then
		fail(routeErr or "metrics are not routable")
		return
	end
	local range, rangeErr = resolve(s, env)
	if range == nil then
		fail("Time range: " .. (rangeErr or "invalid"))
		return
	end
	local span = math.max(1, range.to_ms - range.from_ms)
	local points = s.options.max_points
	local step = Step.promStep(span, points)
	local interval = Step.interval(span, points).interval_ms
	local sent = Step.interpolate(expr, Step.macros(span, step, interval))
	local kind: "range" | "instant" = if s.mode == "graph" then "range" else "instant"
	local request = if kind == "range"
		then Metrics.rangeRequest(route, {
			expr = sent,
			from_ms = range.from_ms,
			to_ms = range.to_ms,
			step_ms = step,
			max_points = points,
			ref_id = "A",
		})
		else Metrics.instantRequest(route, { expr = sent, time_ms = range.to_ms, ref_id = "A" })
	s.inflight = {
		gen = s.gen,
		expr = expr,
		kind = kind,
		from_ms = range.from_ms,
		to_ms = range.to_ms,
		step_ms = step,
		interval_ms = interval,
		route = route,
	}
	s.status = "loading"
	table.insert(effects, { kind = "http", tag = M.QUERY_TAG .. s.gen, route = route, request = request })
end

local function hasNumbers(frames: { Frame }): boolean
	for _, f in frames do
		if #Frame.numberFields(f) > 0 then
			return true
		end
	end
	return false
end

local function inChart(chart: Svg.Result, t: number?): boolean
	return t ~= nil and t >= chart.layout.t_from and t <= chart.layout.t_to
end

local function finish(s: State, env: Env, response: any)
	local r = s.inflight :: Run
	s.inflight = nil
	local result: any = Metrics.parse(r.route, response, env, r.kind)
	if not result.ok then
		local e = result.error
		s.status = "error"
		s.failure = { kind = e.kind, message = e.message, status = e.status }
		s.ran, s.frames, s.chart, s.cursor_t = r, nil, nil, nil
		s.warnings = {}
		return
	end
	local frames: { Frame } = result.frames
	s.status = "ok"
	s.failure = nil
	s.ran = r
	s.frames = frames
	s.warnings = result.warnings or {}
	s.chart = nil
	if r.kind == "range" and hasNumbers(frames) then
		local ok, chart = pcall(Svg.render, frames, { from_ms = r.from_ms, to_ms = r.to_ms })
		if not ok then
			s.status = "error"
			s.failure = { kind = "render", message = tostring(chart) }
			s.cursor_t = nil
			return
		end
		s.chart = chart
		if inChart(chart, s.restore_cursor) then
			s.cursor_t = s.restore_cursor
		elseif not inChart(chart, s.cursor_t) then
			s.cursor_t = nil
		end
		s.restore_cursor = nil
	else
		s.cursor_t = nil
	end
end

-- Suggestions --------------------------------------------------------------

local function contextCache(s: State): { [string]: Entry }?
	local name = s.context
	if name == nil then
		return nil
	end
	local c = s.cache[name]
	if c == nil then
		c = {}
		s.cache[name] = c
	end
	return c
end

local function fresh(e: Entry, now: number): boolean
	if e.status == "pending" then
		return true
	end
	local ttl = if e.status == "ok" then M.TTL_MS else M.ERROR_TTL_MS
	return now - e.at_ms < ttl
end

local function fetch(s: State, env: Env, need: Suggest.Need, effects: { Effect }): Entry?
	local cache = contextCache(s)
	local route = M.route(s, env)
	if cache == nil or route == nil then
		return nil
	end
	local range = resolve(s, env)
	local opts = {
		match = if need.match then { need.match } else nil,
		from_ms = if range then range.from_ms else nil,
		to_ms = if range then range.to_ms else nil,
	}
	local request
	if need.kind == "values" then
		request = Metrics.labelValuesRequest(route, need.label :: string, opts)
	elseif need.kind == "labels" then
		request = Metrics.labelsRequest(route, opts)
	else
		request = Metrics.metadataRequest(route)
	end
	local old = cache[need.key]
	local e: Entry = {
		status = "pending",
		at_ms = env.now_ms,
		values = if old then old.values else nil,
		metadata = if old then old.metadata else nil,
	}
	cache[need.key] = e
	s.seq += 1
	local tag = M.SUGGEST_TAG .. s.seq
	s.pending[tag] = { context = s.context :: string, key = need.key, kind = need.kind, route = route }
	table.insert(effects, { kind = "http", tag = tag, route = route, request = request })
	return e
end

-- Recomputes the suggestion list for the text at the caret. `force` shows
-- every metric and function at an empty expression position (ctrl+space).
local function suggest(s: State, env: Env, effects: { Effect }, force: boolean)
	if not s.editing then
		s.suggest = nil
		return
	end
	local ctx = Promql.context(s.expr, s.cursor)
	if ctx.kind == "none" or (ctx.kind == "expr" and ctx.prefix == "" and not force) then
		s.suggest = nil
		return
	end
	local cache = contextCache(s)
	local data: Suggest.Data = { lists = {} }
	local loading = false
	for _, need in Suggest.needs(ctx) do
		local e = if cache then cache[need.key] else nil
		if e == nil or not fresh(e, env.now_ms) then
			e = fetch(s, env, need, effects)
		end
		if e then
			loading = loading or e.status == "pending"
			if e.values then
				data.lists[need.key] = e.values
			end
			if e.metadata then
				data.metadata = e.metadata
			end
		end
	end
	local items = Suggest.items(ctx, data)
	if #items == 0 and not loading then
		s.suggest = nil
		return
	end
	s.suggest = { ctx = ctx, items = items, selected = nil, loading = loading and #items == 0 }
end

local function suggestionDone(s: State, env: Env, tag: string, response: any, effects: { Effect })
	local p = s.pending[tag]
	if p == nil then
		return
	end
	s.pending[tag] = nil
	local cache = s.cache[p.context]
	local e = if cache then cache[p.key] else nil
	if e == nil then
		return
	end
	local next: Entry = { status = "ok", at_ms = env.now_ms, values = e.values, metadata = e.metadata }
	if p.kind == "metadata" then
		local r: any = Metrics.parseMetadata(p.route, response, env)
		if r.ok then
			next.metadata = r.metadata
		else
			next.status = "error"
		end
	else
		local r: any = Metrics.parseList(p.route, response, env)
		if r.ok then
			next.values = r.values
		else
			next.status = "error"
		end
	end
	(cache :: { [string]: Entry })[p.key] = next
	if s.suggest and p.context == s.context then
		suggest(s, env, effects, true)
	end
end

local function accept(s: State, env: Env, index: number, effects: { Effect }): boolean
	local sg = s.suggest
	local item = if sg then sg.items[index] else nil
	if sg == nil or item == nil then
		return false
	end
	s.expr, s.cursor = Suggest.apply(s.expr, s.cursor, sg.ctx, item)
	suggest(s, env, effects, false)
	return true
end

-- Links ----------------------------------------------------------------------

local function linkParams(s: State, withExpr: boolean): { [string]: string }
	local p: { [string]: string } = { from = s.from, to = s.to, mode = s.mode }
	if s.context then
		p.context = s.context
	end
	if s.ds then
		p.ds = s.ds
	end
	if withExpr and s.expr ~= "" then
		p.expr = s.expr
	end
	return p
end

-- The canonical tern-grafana://query link for what the block shows. An
-- expression a link cannot carry (too long, control characters) is left out.
function M.link(s: State): string
	local l: Scheme.Link = { action = "query", params = linkParams(s, true), vars = {} }
	if Scheme.validate(l) == nil then
		l.params = linkParams(s, false)
	end
	return Scheme.encode(l)
end

-- `tern-grafana://browse?url=<Grafana Explore URL>`: the browse indirection
-- keeps our own route.link from claiming the Explore URL back.
function M.exploreLink(s: State, env: Env): (string?, string?)
	local cfg = env.config
	if cfg == nil or s.context == nil then
		return nil, "No context"
	end
	local expr = trim(s.expr)
	if expr == "" then
		return nil, "No query to open"
	end
	local base: GrafanaUrl.Base? = nil
	for _, b in GrafanaUrl.bases(cfg) do
		if b.context == s.context then
			base = b
			break
		end
	end
	if base == nil then
		return nil, string.format("Context %q has no Grafana endpoint", s.context :: string)
	end
	local g = cfg.contexts[s.context :: string].grafana
	local ds = s.ds or (if g and g.datasources then g.datasources.prometheus else nil)
	local params: { [string]: string } = { expr = expr, from = s.from, to = s.to }
	if ds then
		params.ds = ds
	end
	local page = GrafanaUrl.build({ action = "query", params = params, vars = {} }, base.url, env.encode)
	if page == nil then
		return nil, "Grafana has no page for this query"
	end
	local browse: Scheme.Link = { action = "browse", params = { url = page }, vars = {} }
	if Scheme.validate(browse) == nil then
		return nil, "The Explore URL is too long to open"
	end
	return Scheme.encode(browse), nil
end

-- Init -------------------------------------------------------------------------

local function decodeLink(raw: any): (Scheme.Link?, string?)
	if type(raw) ~= "string" or raw == "" then
		return nil, nil
	end
	local l, err = Scheme.decode(raw)
	if l == nil then
		return nil, "Ignored link: " .. (if err then err.message else "invalid")
	end
	if l.action ~= "query" then
		return nil, string.format("Ignored link: %q is not a query link", l.action)
	end
	return l, nil
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local cfg = env.config
	local options, problems = Options.read(if cfg then cfg.query else nil)
	local notices: { string } = {}
	for _, p in problems do
		table.insert(notices, p.path .. ": " .. p.message)
	end
	local savedTable = if type(saved) == "table" then saved else {}
	-- The saved link reflects edits made after the block opened.
	local link, linkErr = decodeLink(savedTable.link)
	if link == nil then
		link, linkErr = decodeLink(args[1])
	end
	if linkErr then
		table.insert(notices, linkErr)
	end
	local params: { [string]: string } = if link then link.params else {}
	local contexts = sortedContexts(env)
	local context = params.context or (if cfg then cfg.default_context else nil) or contexts[1]
	local savedMode = savedTable.mode
	local mode: Mode = if savedMode == "graph" or savedMode == "table"
		then savedMode
		elseif params.mode == "table" then "table"
		else "graph"
	local expr = params.expr or ""
	local s: State = {
		options = options,
		notices = notices,
		contexts = contexts,
		context = context,
		ds = params.ds,
		expr = expr,
		cursor = #expr,
		editing = false,
		from = params.from or options.default_range,
		to = params.to or "now",
		mode = mode,
		gen = 0,
		status = "idle",
		inflight = nil,
		ran = nil,
		frames = nil,
		warnings = {},
		failure = nil,
		chart = nil,
		cursor_t = nil,
		restore_cursor = if type(savedTable.cursor) == "number" then savedTable.cursor else nil,
		refresh_ms = nil,
		timer_gen = 0,
		suggest = nil,
		cache = {},
		pending = {},
		seq = 0,
		overlay = nil,
		history = nil,
	}
	local effects: { Effect } = {}
	if cfg and context and cfg.contexts[context] == nil then
		s.status = "error"
		s.failure = { kind = "config", message = string.format("Unknown context %q", context) }
	elseif trim(expr) ~= "" then
		run(s, env, effects)
	else
		s.editing = true
		table.insert(effects, { kind = "focus", id = M.INPUT_ID })
		if cfg == nil then
			s.status = "error"
			s.failure = { kind = "config", message = NO_CONFIG }
		end
	end
	return s, effects
end

-- Keys -------------------------------------------------------------------------

local function startEdit(s: State, env: Env, effects: { Effect })
	s.editing = true
	table.insert(effects, { kind = "focus", id = M.INPUT_ID })
	suggest(s, env, effects, false)
end

local function stopEdit(s: State, effects: { Effect })
	s.editing = false
	s.suggest = nil
	table.insert(effects, { kind = "focus", id = nil })
end

local function recordHistory(s: State, env: Env, effects: { Effect })
	local expr = trim(s.expr)
	if expr == "" or s.context == nil then
		return
	end
	local stored = if env.kv_get then env.kv_get(History.KEY) else nil
	table.insert(
		effects,
		{ kind = "kv_set", key = History.KEY, value = History.add(stored, s.context :: string, expr) }
	)
end

-- Enter in the input, or a history pick: run and remember the expression.
local function submit(s: State, env: Env, effects: { Effect })
	s.suggest = nil
	recordHistory(s, env, effects)
	run(s, env, effects)
end

local function editKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local name = key.name
	local sg = s.suggest
	if name == "enter" or name == "return" then
		if sg and sg.selected then
			return accept(s, env, sg.selected, effects)
		end
		submit(s, env, effects)
		return true
	elseif name == "escape" then
		stopEdit(s, effects)
		return true
	elseif name == "tab" then
		if sg and #sg.items > 0 then
			return accept(s, env, sg.selected or 1, effects)
		end
		return false
	elseif (name == "up" or name == "down") and sg and #sg.items > 0 then
		local n = #sg.items
		local cur = sg.selected
		if name == "down" then
			sg.selected = if cur == nil then 1 else cur % n + 1
		else
			sg.selected = if cur == nil then n else (cur - 2) % n + 1
		end
		return true
	elseif name == "space" and key.ctrl then
		suggest(s, env, effects, true)
		return true
	end
	local line = Edit.key({ text = s.expr, cursor = s.cursor }, key)
	if line == nil then
		return false
	end
	if line.text == s.expr and line.cursor == s.cursor then
		return false
	end
	local textChanged = line.text ~= s.expr
	s.expr, s.cursor = line.text, line.cursor
	if textChanged or s.suggest then
		suggest(s, env, effects, false)
	end
	return true
end

local function historyVisible(h: HistoryPicker): { string }
	return History.filter(h.all, h.filter)
end

M.historyVisible = historyVisible

local function pickHistory(s: State, env: Env, index: number, effects: { Effect }): boolean
	local h = s.history
	local expr = if h then historyVisible(h)[index] else nil
	if expr == nil then
		return false
	end
	s.overlay, s.history = nil, nil
	s.expr, s.cursor = expr, #expr
	submit(s, env, effects)
	return true
end

local function historyKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local h = s.history :: HistoryPicker
	local name = key.name
	local n = #historyVisible(h)
	if name == "escape" then
		s.overlay, s.history = nil, nil
		return true
	elseif name == "enter" or name == "return" then
		return pickHistory(s, env, h.selected, effects)
	elseif name == "down" or (key.ctrl and name == "n") then
		if n > 0 then
			h.selected = h.selected % n + 1
		end
		return n > 0
	elseif name == "up" or (key.ctrl and name == "p") then
		if n > 0 then
			h.selected = (h.selected - 2) % n + 1
		end
		return n > 0
	elseif name == "backspace" then
		if h.filter == "" then
			return false
		end
		h.filter = string.sub(h.filter, 1, Edit.prevChar(h.filter, #h.filter))
		h.selected = 1
		return true
	end
	local t = key.text
	if t and t ~= "" and not key.ctrl and not key.meta and not string.find(t, "%c") then
		h.filter ..= t
		h.selected = 1
		return true
	end
	return false
end

local function setRange(s: State, env: Env, from: string?, to: string?, effects: { Effect }): boolean
	if from == nil or to == nil then
		return false
	end
	s.from, s.to = from, to
	run(s, env, effects)
	return true
end

local function armTimer(s: State, effects: { Effect })
	table.insert(effects, { kind = "timer", tag = M.REFRESH_TAG .. s.timer_gen, ms = s.refresh_ms :: number })
end

local function commandKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local name = key.name
	local ch = if key.ctrl or key.meta then nil else key.text
	if name == "left" or name == "right" then
		local chart = s.chart
		if s.mode ~= "graph" or chart == nil then
			return false
		end
		local t = Cursor.step(
			chart.layout,
			s.cursor_t,
			if name == "left" then -1 else 1,
			if key.shift then M.FAST_STEP else 1
		)
		if t == nil or t == s.cursor_t then
			return false
		end
		s.cursor_t = t
		return true
	elseif name == "escape" or ch == "q" then
		table.insert(effects, { kind = "exit" })
		return true
	elseif ch == nil then
		return false
	elseif ch == "/" or ch == "i" then
		s.cursor = #s.expr
		startEdit(s, env, effects)
		return true
	elseif ch == "g" or ch == "t" then
		local mode: Mode = if ch == "g" then "graph" else "table"
		if s.mode == mode then
			return false
		end
		s.mode = mode
		s.cursor_t = nil
		run(s, env, effects)
		return true
	elseif ch == "r" then
		run(s, env, effects)
		return true
	elseif ch == "a" then
		s.timer_gen += 1
		if s.refresh_ms then
			s.refresh_ms = nil
		else
			s.refresh_ms = s.options.refresh_ms
			armTimer(s, effects)
		end
		return true
	elseif ch == "c" then
		local n = #s.contexts
		if n < 2 then
			table.insert(effects, { kind = "toast", level = "info", text = "Only one context is configured" })
			return true
		end
		local at = table.find(s.contexts, s.context or "") or 0
		s.context = s.contexts[at % n + 1]
		s.ds = nil
		s.cursor_t = nil
		run(s, env, effects)
		return true
	elseif ch == "y" then
		if trim(s.expr) == "" then
			return false
		end
		table.insert(effects, { kind = "copy", text = s.expr })
		table.insert(effects, { kind = "toast", level = "info", text = "Copied the query" })
		return true
	elseif ch == "o" then
		local target, err = M.exploreLink(s, env)
		if target then
			table.insert(effects, { kind = "open", target = target })
		else
			table.insert(effects, { kind = "toast", level = "warn", text = err or "Cannot open in Grafana" })
		end
		return true
	elseif ch == "h" then
		if s.context == nil then
			return false
		end
		local stored = if env.kv_get then env.kv_get(History.KEY) else nil
		local all = History.list(stored, s.context :: string)
		if #all == 0 then
			table.insert(
				effects,
				{ kind = "toast", level = "info", text = "No query history for " .. (s.context :: string) }
			)
			return true
		end
		s.overlay = "history"
		s.history = { all = all, filter = "", selected = 1 }
		return true
	elseif ch == "?" then
		s.overlay = "help"
		return true
	end
	local from, to = TimeRange.forKey(ch, s.from, s.to, env.now_ms)
	return setRange(s, env, from, to, effects)
end

function M.key(s: State, key: Key, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	local changed: boolean
	if s.overlay == "help" then
		local ch = key.text
		changed = key.name == "escape" or ch == "?" or ch == "q"
		if changed then
			s.overlay = nil
		end
	elseif s.overlay == "history" then
		changed = historyKey(s, key, env, effects)
	elseif s.editing then
		changed = editKey(s, key, env, effects)
	else
		changed = commandKey(s, key, env, effects)
	end
	return s, effects, changed or #effects > 0
end

-- Messages -----------------------------------------------------------------------

local function event(s: State, ev: UiEvent, env: Env, effects: { Effect })
	local id = ev.id or ""
	if ev.ev == "focus" and id == M.INPUT_ID then
		if not s.editing then
			startEdit(s, env, effects)
		end
		return
	end
	local sugg = tonumber(string.match(id, "^main%.sugg%.s(%d+)$") or "")
	if sugg then
		if ev.ev == "activate" then
			accept(s, env, sugg, effects)
		elseif ev.ev == "select" and s.suggest then
			s.suggest.selected = sugg
		end
		return
	end
	local hist = tonumber(string.match(id, "^layer%.hist%.h(%d+)$") or "")
	if hist and s.history then
		if ev.ev == "activate" then
			pickHistory(s, env, hist, effects)
		elseif ev.ev == "select" then
			s.history.selected = hist
		end
	end
end

function M.update(s: State, msg: Msg, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		local tag = msg.tag
		if string.sub(tag, 1, #M.QUERY_TAG) == M.QUERY_TAG then
			local gen = tonumber(string.sub(tag, #M.QUERY_TAG + 1))
			if gen == s.gen and s.inflight and s.inflight.gen == gen then
				finish(s, env, msg.response)
			end
		elseif string.sub(tag, 1, #M.SUGGEST_TAG) == M.SUGGEST_TAG then
			suggestionDone(s, env, tag, msg.response, effects)
		end
	elseif msg.kind == "tick" then
		if msg.tag == M.REFRESH_TAG .. s.timer_gen and s.refresh_ms then
			if s.status ~= "loading" then
				run(s, env, effects)
			end
			armTimer(s, effects)
		end
	elseif msg.kind == "event" then
		event(s, msg.ev, env, effects)
	elseif msg.kind == "key" then
		local _, keyEffects = M.key(s, msg.key, env)
		effects = keyEffects
	end
	return s, effects
end

function M.title(s: State): string?
	local expr = trim(s.expr)
	if #expr > 40 then
		expr = string.sub(expr, 1, 37) .. "..."
	end
	local parts = { "PromQL" }
	if s.context then
		table.insert(parts, s.context :: string)
	end
	if expr ~= "" then
		table.insert(parts, expr)
	end
	return table.concat(parts, " · ")
end

function M.save(s: State): any
	return { link = M.link(s), mode = s.mode, cursor = s.cursor_t }
end

return M
