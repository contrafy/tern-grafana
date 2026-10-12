--!strict
-- The Logs block (`tern-grafana.logs`): LogQL over one context's logs (Loki
-- direct or Grafana's Loki datasource) as a pure state machine
-- (lib/effect.luau) that plugin/logs_host.luau registers through
-- block_runner.
--
-- - Args are one canonical `tern-grafana://logs?...` link; save() keeps the
--   link of what is on screen and the volume toggle, never log lines.
-- - Every query bumps a generation; an answer (query, volume or tail poll)
--   for an older generation is dropped.
-- - Tail (`t`) polls every `logs.tail_interval` with overlapping windows and
--   merges lines by id (lib/logs/tail.luau); the range follows now.
-- - Chips (line detail fields, level chips over the lines) add or remove a
--   LogQL filter (lib/logs/logql.luau) and run the query again.
-- - Label and value suggestions are fetched lazily per context and cached
--   for TTL_MS.

local Edit = require("../query/edit")
local Effect = require("../effect")
local Env = require("../env")
local Frame = require("../frame/types")
local FrameLoki = require("../frame/loki")
local GrafanaUrl = require("../links/grafana_url")
local LogQL = require("./logql")
local Loki = require("../source/loki")
local LogsPanel = require("../panels/logs")
local Options = require("./options")
local Range = require("../time/range")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Step = require("../time/step")
local Svg = require("../render/svg_timeseries")
local Tail = require("./tail")
local TimeRange = require("../query/timerange")
local Volume = require("./volume")

type Env = Env.Env
type Effect = Effect.Effect
type Msg = Effect.Msg
type Frame = Frame.Frame
type Line = FrameLoki.Line
type Level = LogsPanel.Level
type RouteT = Route.Route

export type Status = "idle" | "loading" | "ok" | "error"
export type Failure = { kind: string, message: string, status: number? }

export type FieldKind = "label" | "metadata" | "parsed"
-- One chip in a line's detail.
export type Field = { kind: FieldKind, name: string, value: string }

-- A level chip over the lines: which label filters that level.
export type LevelChip = { level: Level, name: string, value: string, indexed: boolean, count: number }

export type Run = {
	gen: number,
	expr: string,
	metric: boolean,
	from_ms: number,
	to_ms: number,
	step_ms: number?,
	route: RouteT,
}

export type Entry = { status: "pending" | "ok" | "error", at_ms: number, values: { string }? }

export type Suggestions = { ctx: LogQL.Ctx, items: { LogQL.Item }, selected: number?, loading: boolean }

export type State = {
	options: Options.Options,
	notices: { string },
	contexts: { string },
	context: string?,
	ds: string?,
	expr: string,
	cursor: number,
	editing: boolean,
	from: string,
	to: string,
	gen: number,
	status: Status,
	inflight: Run?,
	ran: Run?,
	lines: { Line },
	-- Metric query result.
	frames: { Frame }?,
	chart: Svg.Result?,
	warnings: { string },
	failure: Failure?,
	-- Selected line (index into lines) and the line whose detail is open (id).
	sel: number?,
	detail: string?,
	-- Selected chip in the open detail.
	field_sel: number,
	show_volume: boolean,
	volume: Volume.Volume?,
	volume_loading: boolean,
	volume_at_ms: number?,
	tail: boolean,
	tail_gen: number,
	tail_inflight: boolean,
	-- Lines the last tail polls added since tailing started.
	tail_added: number,
	suggest: Suggestions?,
	cache: { [string]: { [string]: Entry } },
	pending: { [string]: { context: string, key: string, route: RouteT } },
	seq: number,
	overlay: "help"?,
}

local M = {}

M.INPUT_ID = "main.q"
M.TTL_MS = 5 * 60 * 1000
M.ERROR_TTL_MS = 30 * 1000
M.QUERY_TAG = "q:"
M.VOLUME_TAG = "v:"
M.TAIL_TAG = "t:"
M.POLL_TAG = "p:"
M.SUGGEST_TAG = "s:"
M.SUGGEST_MAX = 50
-- While tailing, the volume bars refresh at most this often.
M.VOLUME_TAIL_MS = 10000

local NO_CONFIG = "No tern-grafana config found: create ~/.config/tern-grafana/config.json "
	.. "(see docs/configuration.md) or open tern-grafana://settings"

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") or ""
end

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

-- Where logs for the block's context are read. A link's datasource uid names
-- one Grafana datasource exactly, so it wins whenever the context has Grafana.
function M.route(s: State, env: Env): (RouteT?, string?)
	local cfg = env.config
	if cfg == nil then
		return nil, NO_CONFIG
	end
	if s.context == nil then
		return nil, "No context: set default_context or add a context to the config"
	end
	local ctx = cfg.contexts[s.context :: string]
	if s.ds and ctx and ctx.grafana then
		return {
			context = s.context :: string,
			signal = "logs",
			via = "datasource",
			endpoint_name = "grafana",
			endpoint = ctx.grafana,
			datasource_uid = s.ds,
		},
			nil
	end
	local route, err = Route.route(cfg, s.context, "logs")
	if route == nil then
		return nil, if err then err.message else "logs are not routable"
	end
	return route, nil
end

local function resolve(s: State, env: Env): (Range.Range?, string?)
	return Range.resolve(s.from, s.to, { now_ms = env.now_ms })
end

local function clearResult(s: State)
	s.lines, s.frames, s.chart, s.volume = {}, nil, nil, nil
	s.sel, s.detail, s.field_sel = nil, nil, 1
	s.warnings = {}
end

local function failWith(s: State, message: string)
	s.status = "error"
	s.failure = { kind = "config", message = message }
	clearResult(s)
end

local function volumeRequest(s: State, env: Env, r: Run, effects: { Effect })
	if r.metric or not s.show_volume then
		return
	end
	local step = Volume.step(r.to_ms - r.from_ms)
	local request = Loki.rangeRequest(r.route, {
		expr = Volume.query(r.expr, step),
		from_ms = r.from_ms,
		to_ms = r.to_ms,
		step_ms = step,
		max_points = Volume.BUCKETS * 2,
	}, env)
	s.volume_loading = true
	s.volume_at_ms = env.now_ms
	table.insert(
		effects,
		{ kind = "http", tag = M.VOLUME_TAG .. r.gen .. ":" .. step, route = r.route, request = request }
	)
end

-- Starts the query for the current expression and range (and its volume).
local function run(s: State, env: Env, effects: { Effect })
	s.gen += 1
	s.inflight = nil
	s.tail_inflight = false
	s.volume_loading = false
	local expr = trim(s.expr)
	if expr == "" then
		s.status = "idle"
		s.ran, s.failure = nil, nil
		clearResult(s)
		return
	end
	local route, routeErr = M.route(s, env)
	if route == nil then
		failWith(s, routeErr or "logs are not routable")
		return
	end
	local range, rangeErr = resolve(s, env)
	if range == nil then
		failWith(s, "Time range: " .. (rangeErr or "invalid"))
		return
	end
	local metric = LogQL.isMetric(expr)
	local span = math.max(1, range.to_ms - range.from_ms)
	local step: number? = nil
	local sent = expr
	if metric then
		local points = Volume.BUCKETS * 5
		step = Step.promStep(span, points)
		local interval = Step.interval(span, points).interval_ms
		sent = Step.interpolate(expr, Step.macros(span, step :: number, interval))
	end
	local r: Run = {
		gen = s.gen,
		expr = sent,
		metric = metric,
		from_ms = range.from_ms,
		to_ms = range.to_ms,
		step_ms = step,
		route = route,
	}
	local request = Loki.rangeRequest(route, {
		expr = sent,
		from_ms = r.from_ms,
		to_ms = r.to_ms,
		limit = if metric then nil else s.options.limit,
		direction = "backward",
		step_ms = step,
		max_points = if metric then Volume.BUCKETS * 5 else nil,
	}, env)
	s.inflight = r
	s.status = "loading"
	table.insert(effects, { kind = "http", tag = M.QUERY_TAG .. s.gen, route = route, request = request })
	volumeRequest(s, env, r, effects)
end

local function selectedId(s: State): string?
	local l = if s.sel then s.lines[s.sel :: number] else nil
	return if l then l.id else nil
end

local function indexOf(lines: { Line }, id: string?): number?
	if id == nil then
		return nil
	end
	for i, l in lines do
		if l.id == id then
			return i
		end
	end
	return nil
end

local function finish(s: State, env: Env, response: any)
	local r = s.inflight :: Run
	s.inflight = nil
	local result: any = Loki.parse(r.route, response, env)
	s.ran = r
	if not result.ok then
		local e = result.error
		s.status = "error"
		s.failure = { kind = e.kind, message = e.message, status = e.status }
		s.lines, s.frames, s.chart, s.sel, s.detail = {}, nil, nil, nil, nil
		s.warnings = {}
		return
	end
	s.status = "ok"
	s.failure = nil
	s.warnings = result.warnings or {}
	local keep = selectedId(s)
	s.lines = result.lines
	if #s.lines > s.options.limit then
		for i = #s.lines, s.options.limit + 1, -1 do
			s.lines[i] = nil
		end
	end
	s.sel = indexOf(s.lines, keep)
	if indexOf(s.lines, s.detail) == nil then
		s.detail = nil
	end
	s.frames, s.chart = nil, nil
	if r.metric then
		s.frames = result.frames
		local hasNumbers = false
		for _, f in result.frames do
			if #Frame.numberFields(f) > 0 then
				hasNumbers = true
			end
		end
		if hasNumbers then
			local ok, chart = pcall(Svg.render, result.frames, { from_ms = r.from_ms, to_ms = r.to_ms })
			if ok then
				s.chart = chart
			else
				s.status = "error"
				s.failure = { kind = "render", message = tostring(chart) }
			end
		end
	end
end

local function volumeDone(s: State, env: Env, step: number, response: any)
	s.volume_loading = false
	local r = s.ran or s.inflight
	if r == nil then
		return
	end
	local result: any = Loki.parse(r.route, response, env)
	if not result.ok then
		s.volume = nil
		return
	end
	local range = resolve(s, env)
	local from = if s.tail and range then range.from_ms else r.from_ms
	local to = if s.tail and range then range.to_ms else r.to_ms
	s.volume = Volume.build(result.frames, from, to, step)
end

-- Tail -------------------------------------------------------------------------------

local function armTail(s: State, effects: { Effect })
	table.insert(effects, { kind = "timer", tag = M.TAIL_TAG .. s.tail_gen, ms = s.options.tail_ms })
end

local function poll(s: State, env: Env, effects: { Effect })
	local r = s.ran
	if r == nil or r.metric or s.inflight or s.tail_inflight or s.status ~= "ok" then
		return
	end
	local range = resolve(s, env)
	if range == nil then
		return
	end
	local from = Tail.windowStart(s.lines, range.from_ms, s.options.tail_ms)
	local request = Loki.rangeRequest(r.route, {
		expr = r.expr,
		from_ms = from,
		to_ms = range.to_ms,
		limit = s.options.limit,
		direction = "backward",
	}, env)
	s.tail_inflight = true
	table.insert(effects, { kind = "http", tag = M.POLL_TAG .. s.gen, route = r.route, request = request })
	if s.show_volume and not s.volume_loading and env.now_ms - (s.volume_at_ms or 0) >= M.VOLUME_TAIL_MS then
		local live: Run = table.clone(r)
		live.from_ms, live.to_ms = range.from_ms, range.to_ms
		volumeRequest(s, env, live, effects)
	end
end

local function pollDone(s: State, env: Env, response: any)
	s.tail_inflight = false
	local r = s.ran
	if r == nil then
		return
	end
	local result: any = Loki.parse(r.route, response, env)
	if not result.ok then
		local e = result.error
		table.insert(s.warnings, "Tail poll failed: " .. tostring(e.message))
		if #s.warnings > 5 then
			table.remove(s.warnings, 1)
		end
		return
	end
	local keep = selectedId(s)
	local merged, added = Tail.merge(s.lines, result.lines, s.options.limit)
	s.lines = merged
	s.tail_added += added
	s.sel = indexOf(s.lines, keep)
	if indexOf(s.lines, s.detail) == nil then
		s.detail = nil
	end
end

local function setTail(s: State, env: Env, on: boolean, effects: { Effect })
	s.tail_gen += 1
	s.tail = on
	s.tail_added = 0
	s.tail_inflight = false
	if not on then
		return
	end
	-- Tailing follows now: an absolute range keeps its span, ending now.
	if s.to ~= "now" then
		local range = resolve(s, env)
		local span = if range then range.to_ms - range.from_ms else 3600000
		s.from, s.to = TimeRange.liveFrom(span), "now"
		run(s, env, effects)
	elseif s.ran == nil and s.inflight == nil then
		run(s, env, effects)
	else
		poll(s, env, effects)
	end
	armTail(s, effects)
end

-- Suggestions -------------------------------------------------------------------------

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
	return now - e.at_ms < (if e.status == "ok" then M.TTL_MS else M.ERROR_TTL_MS)
end

local function fetchList(s: State, env: Env, key: string, label: string?, effects: { Effect }): Entry?
	local cache = contextCache(s)
	local route = M.route(s, env)
	if cache == nil or route == nil then
		return nil
	end
	local range = resolve(s, env)
	local opts = if range then { from_ms = range.from_ms, to_ms = range.to_ms } else nil
	local request = if label then Loki.labelValuesRequest(route, label, opts) else Loki.labelsRequest(route, opts)
	local old = cache[key]
	local e: Entry = { status = "pending", at_ms = env.now_ms, values = if old then old.values else nil }
	cache[key] = e
	s.seq += 1
	local tag = M.SUGGEST_TAG .. s.seq
	s.pending[tag] = { context = s.context :: string, key = key, route = route }
	table.insert(effects, { kind = "http", tag = tag, route = route, request = request })
	return e
end

local function suggest(s: State, env: Env, effects: { Effect })
	if not s.editing then
		s.suggest = nil
		return
	end
	local ctx = LogQL.context(s.expr, s.cursor)
	if ctx.kind == "none" then
		s.suggest = nil
		return
	end
	local list: { string }? = nil
	local loading = false
	if ctx.kind == "label" or ctx.kind == "value" then
		local label = if ctx.kind == "value" then (ctx :: any).label :: string else nil
		local key = if label then "values:" .. label else "labels"
		local cache = contextCache(s)
		local e = if cache then cache[key] else nil
		if e == nil or not fresh(e, env.now_ms) then
			e = fetchList(s, env, key, label, effects)
		end
		if e then
			list = e.values
			loading = e.status == "pending"
		end
	end
	local items = LogQL.items(ctx, list, M.SUGGEST_MAX)
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
	if cache == nil or e == nil then
		return
	end
	local r: any = Loki.parseList(p.route, response, env)
	cache[p.key] = {
		status = if r.ok then "ok" else "error",
		at_ms = env.now_ms,
		values = if r.ok then r.values else e.values,
	}
	if s.suggest and p.context == s.context then
		suggest(s, env, effects)
	end
end

local function accept(s: State, env: Env, index: number, effects: { Effect }): boolean
	local sg = s.suggest
	local item = if sg then sg.items[index] else nil
	if sg == nil or item == nil then
		return false
	end
	s.expr, s.cursor = LogQL.apply(s.expr, sg.ctx, item)
	suggest(s, env, effects)
	return true
end

-- Chips -------------------------------------------------------------------------------

local function sortedPairs(t: { [string]: string }, kind: FieldKind, out: { Field })
	local keys: { string } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in keys do
		table.insert(out, { kind = kind, name = k, value = t[k] })
	end
end

-- A line's chips: stream labels, structured metadata, parsed fields.
function M.fields(line: Line): { Field }
	local out: { Field } = {}
	sortedPairs(line.labels, "label", out)
	sortedPairs(line.metadata, "metadata", out)
	sortedPairs(line.parsed, "parsed", out)
	return out
end

-- Level chips for the lines shown: per level, the label that carries it
-- (an indexed `level` label when the lines have one, Loki's detected_level
-- otherwise) and how many lines have it.
function M.levelChips(lines: { Line }): { LevelChip }
	local byLevel: { [string]: LevelChip } = {}
	for _, l in lines do
		local chip = byLevel[l.level]
		if chip then
			chip.count += 1
			continue
		end
		local name, value, indexed
		if l.labels.level and LogsPanel.levelFromKey(l.labels.level) == l.level then
			name, value, indexed = "level", l.labels.level, true
		elseif l.labels.detected_level then
			name, value, indexed = "detected_level", l.labels.detected_level, true
		elseif l.metadata.detected_level then
			name, value, indexed = "detected_level", l.metadata.detected_level, false
		elseif l.parsed.level then
			name, value, indexed = "level", l.parsed.level, false
		end
		if name then
			byLevel[l.level] = { level = l.level, name = name, value = value, indexed = indexed, count = 1 }
		end
	end
	local out: { LevelChip } = {}
	for _, level in Volume.LEVEL_ORDER do
		if byLevel[level] then
			table.insert(out, byLevel[level])
		end
	end
	return out
end

local function applyFilter(
	s: State,
	env: Env,
	name: string,
	value: string,
	exclude: boolean,
	indexed: boolean,
	effects: { Effect }
)
	local expr, err = LogQL.filter(s.expr, name, value, exclude, indexed)
	if err then
		table.insert(effects, { kind = "toast", level = "warn", text = "Cannot filter: " .. err })
		return
	end
	s.expr, s.cursor = expr, #expr
	run(s, env, effects)
end

local function fieldFilter(s: State, env: Env, index: number, exclude: boolean, effects: { Effect }): boolean
	local i = indexOf(s.lines, s.detail)
	local line = if i then s.lines[i :: number] else nil
	local f = if line then M.fields(line)[index] else nil
	if f == nil then
		return false
	end
	-- A categorized label is indexed; without categories a stream label may
	-- still be a parsed field, which a selector cannot match, so it filters
	-- as a stage only when the source said so.
	applyFilter(s, env, f.name, f.value, exclude, f.kind == "label", effects)
	return true
end

local function levelFilter(s: State, env: Env, level: string, effects: { Effect }): boolean
	for _, chip in M.levelChips(s.lines) do
		if chip.level == level then
			applyFilter(s, env, chip.name, chip.value, false, chip.indexed, effects)
			return true
		end
	end
	return false
end

-- Links --------------------------------------------------------------------------------

local function linkParams(s: State, withExpr: boolean): { [string]: string }
	local p: { [string]: string } = { from = s.from, to = s.to }
	if s.context then
		p.context = s.context
	end
	if s.ds then
		p.ds = s.ds
	end
	if withExpr and trim(s.expr) ~= "" then
		p.expr = s.expr
	end
	return p
end

function M.link(s: State): string
	local l: Scheme.Link = { action = "logs", params = linkParams(s, true), vars = {} }
	if Scheme.validate(l) == nil then
		l.params = linkParams(s, false)
	end
	return Scheme.encode(l)
end

-- `tern-grafana://browse?url=<Grafana Explore URL>` for the query.
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
	local ds = s.ds or (if g and g.datasources then g.datasources.loki else nil)
	if ds == nil then
		return nil, "Set grafana.datasources.loki to open logs in Grafana"
	end
	local page = GrafanaUrl.build(
		{ action = "logs", params = { expr = expr, from = s.from, to = s.to, ds = ds }, vars = {} },
		base.url,
		env.encode
	)
	if page == nil then
		return nil, "Grafana has no page for this query"
	end
	local browse: Scheme.Link = { action = "browse", params = { url = page }, vars = {} }
	if Scheme.validate(browse) == nil then
		return nil, "The Explore URL is too long to open"
	end
	return Scheme.encode(browse), nil
end

-- Init ---------------------------------------------------------------------------------

local function decodeLink(raw: any): (Scheme.Link?, string?)
	if type(raw) ~= "string" or raw == "" then
		return nil, nil
	end
	local l, err = Scheme.decode(raw)
	if l == nil then
		return nil, "Ignored link: " .. (if err then err.message else "invalid")
	end
	if l.action ~= "logs" then
		return nil, string.format("Ignored link: %q is not a logs link", l.action)
	end
	return l, nil
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local cfg = env.config
	local options, problems = Options.read(if cfg then cfg.logs else nil)
	local notices: { string } = {}
	for _, p in problems do
		table.insert(notices, p.path .. ": " .. p.message)
	end
	local savedTable = if type(saved) == "table" then saved else {}
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
		gen = 0,
		status = "idle",
		inflight = nil,
		ran = nil,
		lines = {},
		frames = nil,
		chart = nil,
		warnings = {},
		failure = nil,
		sel = nil,
		detail = nil,
		field_sel = 1,
		show_volume = if type(savedTable.volume) == "boolean" then savedTable.volume else options.volume,
		volume = nil,
		volume_loading = false,
		volume_at_ms = nil,
		tail = false,
		tail_gen = 0,
		tail_inflight = false,
		tail_added = 0,
		suggest = nil,
		cache = {},
		pending = {},
		seq = 0,
		overlay = nil,
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

-- Keys ---------------------------------------------------------------------------------

-- View id of a line row (lib/logs/view.luau keys rows by line id).
function M.rowId(line: Line): string
	return "main.lines.r" .. line.id
end

local function revealSel(s: State, effects: { Effect })
	local l = if s.sel then s.lines[s.sel :: number] else nil
	if l then
		table.insert(effects, { kind = "reveal", id = M.rowId(l) })
	end
end

-- View id of the selected chip in the open detail (sections keyed by kind).
function M.fieldId(line: Line, index: number): string?
	local f = M.fields(line)[index]
	if f == nil then
		return nil
	end
	return M.rowId(line) .. ".detail." .. f.kind .. ".f" .. index
end

local function revealField(s: State, effects: { Effect })
	local i = indexOf(s.lines, s.detail)
	local id = if i then M.fieldId(s.lines[i], s.field_sel) else nil
	if id then
		table.insert(effects, { kind = "reveal", id = id })
	end
end

local function startEdit(s: State, env: Env, effects: { Effect })
	s.editing = true
	table.insert(effects, { kind = "focus", id = M.INPUT_ID })
	suggest(s, env, effects)
end

local function stopEdit(s: State, effects: { Effect })
	s.editing = false
	s.suggest = nil
	table.insert(effects, { kind = "focus", id = nil })
end

local function editKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local name = key.name
	local sg = s.suggest
	if name == "enter" or name == "return" then
		if sg and sg.selected then
			return accept(s, env, sg.selected :: number, effects)
		end
		s.suggest = nil
		stopEdit(s, effects)
		run(s, env, effects)
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
		suggest(s, env, effects)
		return true
	end
	local line = Edit.key({ text = s.expr, cursor = s.cursor }, key)
	if line == nil or (line.text == s.expr and line.cursor == s.cursor) then
		return false
	end
	local changed = line.text ~= s.expr
	s.expr, s.cursor = line.text, line.cursor
	if changed or s.suggest then
		suggest(s, env, effects)
	end
	return true
end

local function toggleVolume(s: State, env: Env, effects: { Effect })
	s.show_volume = not s.show_volume
	s.volume = nil
	local r = s.ran
	if s.show_volume and r and not r.metric then
		local range = resolve(s, env)
		local live: Run = table.clone(r)
		if range then
			live.from_ms, live.to_ms = range.from_ms, range.to_ms
		end
		volumeRequest(s, env, live, effects)
	end
end

local function moveSel(s: State, delta: number, effects: { Effect }): boolean
	local n = #s.lines
	if n == 0 then
		return false
	end
	local cur = s.sel
	local next = if cur == nil then (if delta > 0 then 1 else n) else math.clamp(cur + delta, 1, n)
	if next == cur then
		return false
	end
	s.sel = next
	revealSel(s, effects)
	return true
end

local function toggleDetail(s: State, effects: { Effect }): boolean
	local l = if s.sel then s.lines[s.sel :: number] else nil
	if l == nil then
		return false
	end
	if s.detail == l.id then
		s.detail = nil
	else
		s.detail = l.id
		s.field_sel = 1
		revealSel(s, effects)
	end
	return true
end

local function commandKey(s: State, key: Key, env: Env, effects: { Effect }): boolean
	if key.ctrl or key.meta then
		return false
	end
	local name = key.name
	local ch = key.text
	if name == "down" or ch == "j" then
		return moveSel(s, 1, effects)
	elseif name == "up" or ch == "k" then
		return moveSel(s, -1, effects)
	elseif name == "home" or ch == "g" then
		return moveSel(s, -#s.lines, effects)
	elseif name == "end" or ch == "G" then
		return moveSel(s, #s.lines, effects)
	elseif name == "pagedown" then
		return moveSel(s, 20, effects)
	elseif name == "pageup" then
		return moveSel(s, -20, effects)
	elseif name == "enter" or name == "return" or name == "space" then
		return toggleDetail(s, effects)
	elseif (name == "left" or name == "right") and s.detail then
		local i = indexOf(s.lines, s.detail)
		local n = if i then #M.fields(s.lines[i]) else 0
		if n == 0 then
			return false
		end
		s.field_sel = math.clamp(s.field_sel + (if name == "left" then -1 else 1), 1, n)
		revealField(s, effects)
		return true
	elseif (ch == "f" or ch == "x") and s.detail then
		return fieldFilter(s, env, s.field_sel, ch == "x", effects)
	elseif name == "escape" then
		if s.detail then
			s.detail = nil
			return true
		end
		table.insert(effects, { kind = "exit" })
		return true
	elseif ch == "q" then
		table.insert(effects, { kind = "exit" })
		return true
	elseif ch == nil then
		return false
	elseif ch == "/" or ch == "i" then
		s.cursor = #s.expr
		startEdit(s, env, effects)
		return true
	elseif ch == "t" then
		setTail(s, env, not s.tail, effects)
		return true
	elseif ch == "v" then
		toggleVolume(s, env, effects)
		return true
	elseif ch == "r" then
		run(s, env, effects)
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
		run(s, env, effects)
		return true
	elseif ch == "y" then
		local l = if s.sel then s.lines[s.sel :: number] else nil
		if l then
			table.insert(effects, { kind = "copy", text = l.line })
			table.insert(effects, { kind = "toast", level = "info", text = "Copied the log line" })
			return true
		end
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
	elseif ch == "?" then
		s.overlay = "help"
		return true
	end
	local from, to = TimeRange.forKey(ch, s.from, s.to, env.now_ms)
	if from == nil or to == nil then
		return false
	end
	s.from, s.to = from, to
	if s.tail and to ~= "now" then
		setTail(s, env, false, effects)
	end
	run(s, env, effects)
	return true
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
	elseif s.editing then
		changed = editKey(s, key, env, effects)
	else
		changed = commandKey(s, key, env, effects)
	end
	return s, effects, changed or #effects > 0
end

-- Messages -----------------------------------------------------------------------------

-- A click: Tern splits an action "name=value" into `act` and `value`.
local function action(s: State, name: string, arg: string?, env: Env, effects: { Effect })
	if name == "tail" then
		setTail(s, env, not s.tail, effects)
	elseif name == "volume" then
		toggleVolume(s, env, effects)
	elseif name == "row" then
		-- Rows are named by line id: a tail poll may have moved them since
		-- the click was drawn.
		local n = indexOf(s.lines, arg)
		if n == nil then
			return
		end
		if s.sel == n then
			toggleDetail(s, effects)
		else
			s.sel = n
			s.detail = arg
			s.field_sel = 1
		end
	elseif (name == "inc" or name == "exc") and tonumber(arg) then
		local n = tonumber(arg) :: number
		s.field_sel = n
		fieldFilter(s, env, n, name == "exc", effects)
	elseif name == "lvl" and arg then
		levelFilter(s, env, arg, effects)
	end
end

local function event(s: State, ev: any, env: Env, effects: { Effect })
	local id = if type(ev.id) == "string" then ev.id else ""
	if ev.ev == "focus" and id == M.INPUT_ID then
		if not s.editing then
			startEdit(s, env, effects)
		end
		return
	end
	if ev.ev == "action" and type(ev.act) == "string" then
		action(s, ev.act, if type(ev.value) == "string" then ev.value else nil, env, effects)
		return
	end
	local sugg = tonumber(string.match(id, "^main%.sugg%.s(%d+)$") or "")
	if sugg then
		if ev.ev == "activate" then
			accept(s, env, sugg, effects)
		elseif ev.ev == "select" and s.suggest then
			s.suggest.selected = sugg
		end
	end
end

local function tagGen(tag: string, prefix: string): string?
	if string.sub(tag, 1, #prefix) ~= prefix then
		return nil
	end
	return string.sub(tag, #prefix + 1)
end

function M.update(s: State, msg: Msg, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		local tag = msg.tag
		local q = tagGen(tag, M.QUERY_TAG)
		local v = tagGen(tag, M.VOLUME_TAG)
		local p = tagGen(tag, M.POLL_TAG)
		if q then
			local gen = tonumber(q)
			if gen == s.gen and s.inflight and s.inflight.gen == gen then
				finish(s, env, msg.response)
			end
		elseif v then
			local gen, step = string.match(v, "^(%d+):(%d+)$")
			if tonumber(gen) == s.gen and s.volume_loading then
				volumeDone(s, env, tonumber(step) :: number, msg.response)
			end
		elseif p then
			if tonumber(p) == s.gen and s.tail_inflight then
				pollDone(s, env, msg.response)
			end
		elseif tagGen(tag, M.SUGGEST_TAG) then
			suggestionDone(s, env, tag, msg.response, effects)
		end
	elseif msg.kind == "tick" then
		if msg.tag == M.TAIL_TAG .. s.tail_gen and s.tail then
			poll(s, env, effects)
			armTail(s, effects)
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
	local parts = { "Logs" }
	if s.context then
		table.insert(parts, s.context :: string)
	end
	if expr ~= "" then
		table.insert(parts, expr)
	end
	return table.concat(parts, " · ")
end

function M.save(s: State): any
	return { link = M.link(s), volume = s.show_volume }
end

return M
