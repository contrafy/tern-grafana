--!strict
-- The `trace` block: one trace as a waterfall (Tempo direct or Grafana's
-- Tempo datasource) and a TraceQL search tab. Args are a tern-grafana://trace
-- link: `id` opens that trace, otherwise the search tab runs `q` (default
-- `{}`) over `from`/`to`; `span` selects a span once the trace loads.
-- Rendering lives in ./view.

local Edit = require("../query/edit")
local Effect = require("../effect")
local Env = require("../env")
local Ids = require("./ids")
local Model = require("./model")
local Range = require("../time/range")
local Route = require("../config/route")
local Scheme = require("../links/scheme")
local Settings = require("./settings")
local Tempo = require("../source/tempo")
local Timerange = require("../query/timerange")
local TraceTypes = require("./types")
local TransportTypes = require("../transport/types")

type Effect = Effect.Effect
type Msg = Effect.Msg
type Env = Env.Env
type Route = Route.Route
type QueryError = TransportTypes.QueryError
type Trace = TraceTypes.Trace
type Span = TraceTypes.Span

export type Tab = "trace" | "search"
export type Kind = "trace" | "search" | "tags" | "values"

export type State = {
	contexts: { string },
	context: string?,
	route: Route?,
	-- How trace and search requests reach Tempo; "proxy" after Grafana's
	-- /api/ds/query failed for that kind.
	modes: { trace: Tempo.Mode, search: Tempo.Mode },
	problem: string?,
	config_problems: { string },
	tab: Tab,
	-- Sequence number of the request each kind waits for.
	seq: number,
	pending: { [string]: number? },
	-- Trace tab.
	trace_id: string?,
	trace: Trace?,
	trace_error: QueryError?,
	collapsed: { [string]: boolean },
	-- Visible span indices in display order (collapsed subtrees left out).
	rows: { number },
	-- Visible spans beyond MAX_ROWS that are not drawn.
	hidden_rows: number,
	sel: number,
	detail: boolean,
	-- Span id to select once the trace loads (link `span`).
	want_span: string?,
	-- Search tab.
	q: string,
	from: string,
	to: string,
	limit: number,
	hits: { Tempo.SearchHit }?,
	search_error: QueryError?,
	search_sel: number,
	searched_ms: number?,
	tags: { Tempo.Tag }?,
	tag: string?,
	values: { string }?,
	-- The field being edited: the trace id or the TraceQL query.
	editing: ("id" | "q")?,
	line: Edit.Line,
	note: string?,
}

local M = {}

M.TABS = table.freeze({ "trace", "search" } :: { Tab })
M.MAX_ROWS = 1000
M.DEFAULT_QUERY = "{}"
M.INPUT_ID = "main.input"
M.PAGE = 10

local function sortedContexts(env: Env): { string }
	local out: { string } = {}
	local cfg = env.config
	if cfg then
		for name in cfg.contexts do
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

function M.loading(s: State, kind: Kind): boolean
	return s.pending[kind] ~= nil
end

local function request(s: State, kind: Kind, req: TransportTypes.Request, effects: { Effect })
	local route = s.route
	if route == nil then
		return
	end
	s.seq += 1
	s.pending[kind] = s.seq
	table.insert(effects, { kind = "http", tag = string.format("%s:%d", kind, s.seq), route = route, request = req })
end

-- Recomputes the visible rows after a load or a collapse, keeping the
-- selected span selected when it is still visible.
function M.derive(s: State)
	local t = s.trace
	local prev = if t and s.rows[s.sel] then s.rows[s.sel] else nil
	local rows: { number } = {}
	local hidden = 0
	if t then
		local skipBelow: number? = nil
		for i, span in t.spans do
			if skipBelow and span.depth > skipBelow then
				continue
			end
			skipBelow = nil
			if #rows < M.MAX_ROWS then
				table.insert(rows, i)
			else
				hidden += 1
			end
			if s.collapsed[span.raw.span_id] and #span.children > 0 then
				skipBelow = span.depth
			end
		end
	end
	s.rows = rows
	s.hidden_rows = hidden
	local found = if prev then table.find(rows, prev) else nil
	s.sel = found or math.clamp(s.sel, math.min(1, #rows), #rows)
end

function M.selected(s: State): Span?
	local t = s.trace
	local i = s.rows[s.sel]
	return if t and i then t.spans[i] else nil
end

local function loadTrace(s: State, env: Env, effects: { Effect })
	local route, id = s.route, s.trace_id
	if route == nil or id == nil then
		return
	end
	s.trace_error = nil
	-- The short form, as Tempo and Grafana print and record trace ids.
	request(s, "trace", Tempo.traceRequest(route, s.modes.trace, Ids.short(id), env), effects)
end

local function searchRange(s: State, env: Env): (Range.Range?, string?)
	return Range.resolve(s.from, s.to, { now_ms = env.now_ms })
end

local function runSearch(s: State, env: Env, effects: { Effect })
	local route = s.route
	if route == nil then
		return
	end
	local r, err = searchRange(s, env)
	if r == nil then
		s.search_error = { kind = "query", message = "range: " .. tostring(err) }
		return
	end
	s.search_error = nil
	local q = if s.q == "" then M.DEFAULT_QUERY else s.q
	request(
		s,
		"search",
		Tempo.searchRequest(
			route,
			s.modes.search,
			{ q = q, limit = s.limit, from_ms = r.from_ms, to_ms = r.to_ms },
			env
		),
		effects
	)
end

local function loadTags(s: State, effects: { Effect })
	local route = s.route
	if route == nil or s.tags ~= nil or s.pending.tags then
		return
	end
	request(s, "tags", Tempo.tagsRequest(route, Tempo.mode(route)), effects)
end

-- Resolves the context's traces route and reloads what the tab shows.
local function connect(s: State, env: Env, effects: { Effect })
	s.pending = {}
	s.route = nil
	s.trace, s.trace_error, s.hits, s.search_error = nil, nil, nil, nil
	s.tags, s.tag, s.values = nil, nil, nil
	s.note = nil
	local cfg = env.config
	if cfg == nil then
		s.problem = "No valid config: open Grafana: Settings or see docs/configuration.md."
	else
		local route, err = Route.route(cfg, s.context, "traces")
		if route == nil then
			s.problem = (err :: Route.RouteError).message
		else
			s.problem = nil
			s.route = route
			s.context = route.context
			local mode: Tempo.Mode = Tempo.mode(route)
			s.modes = { trace = mode, search = mode }
		end
	end
	M.derive(s)
	if s.route == nil then
		return
	end
	if s.trace_id then
		loadTrace(s, env, effects)
	end
	if s.tab == "search" then
		runSearch(s, env, effects)
		loadTags(s, effects)
	end
end

local function linkParams(args: { string }): { [string]: string }
	local first = args[1]
	if first == nil or first == "" then
		return {}
	end
	local link = Scheme.decode(first)
	if link == nil or link.action ~= "trace" then
		return {}
	end
	return link.params
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local params = linkParams(args)
	local savedT = if type(saved) == "table" then saved else {}
	local settings, problems = Settings.read(env.config)
	local configProblems: { string } = {}
	for _, p in problems do
		table.insert(configProblems, p.path .. ": " .. p.message)
	end
	local s: State = {
		contexts = sortedContexts(env),
		context = nil,
		route = nil,
		modes = { trace = "direct", search = "direct" },
		problem = nil,
		config_problems = configProblems,
		tab = "search",
		seq = 0,
		pending = {},
		trace_id = nil,
		trace = nil,
		trace_error = nil,
		collapsed = {},
		rows = {},
		hidden_rows = 0,
		sel = 1,
		detail = false,
		want_span = nil,
		q = M.DEFAULT_QUERY,
		from = settings.range,
		to = "now",
		limit = settings.search_limit,
		hits = nil,
		search_error = nil,
		search_sel = 1,
		searched_ms = nil,
		tags = nil,
		tag = nil,
		values = nil,
		editing = nil,
		line = { text = "", cursor = 0 },
		note = nil,
	}
	-- Tern restores a block by re-running init with its first args and the
	-- last saved state, so what the user moved on to (saved) wins over the
	-- link that opened the block.
	local restored = type(saved) == "table"
	s.context = str(savedT.context) or params.context
	if s.context and env.config and env.config.contexts[s.context :: string] == nil then
		s.context = nil
	end
	local id = Ids.trace(if restored then str(savedT.trace_id) else params.id)
	s.trace_id = id
	s.q = (if restored then str(savedT.q) else params.q) or M.DEFAULT_QUERY
	local from = if restored then str(savedT.from) else params.from
	local to = if restored then str(savedT.to) else params.to
	if from and to and Range.resolve(from, to, { now_ms = env.now_ms }) then
		s.from, s.to = from, to
	end
	if not restored and params.span then
		s.want_span = Ids.span(params.span)
	end
	if id then
		s.tab = if restored and savedT.tab == "search" then "search" else "trace"
	elseif restored and savedT.tab == "trace" then
		s.tab = "trace"
	end
	local effects: { Effect } = {}
	connect(s, env, effects)
	return s, effects
end

-- Response handling ---------------------------------------------------------

local function selectSpan(s: State, spanId: string): boolean
	local t = s.trace
	local index = if t then t.by_id[spanId] else nil
	if t == nil or index == nil then
		return false
	end
	for _, a in Model.ancestors(t, index) do
		s.collapsed[t.spans[a].raw.span_id] = nil
	end
	M.derive(s)
	local row = table.find(s.rows, index)
	if row then
		s.sel = row
		return true
	end
	return false
end

local function fellBack(s: State, kind: "trace" | "search", err: QueryError, env: Env, effects: { Effect }): boolean
	local mode: Tempo.Mode = if kind == "trace" then s.modes.trace else s.modes.search
	if not Tempo.fallback(mode, err) then
		return false
	end
	if kind == "trace" then
		s.modes.trace = "proxy"
	else
		s.modes.search = "proxy"
	end
	s.note = string.format(
		"Grafana's /api/ds/query failed for the Tempo %s (%s); using the datasource proxy instead.",
		if kind == "trace" then "trace lookup" else "search",
		err.message
	)
	if kind == "trace" then
		loadTrace(s, env, effects)
	else
		runSearch(s, env, effects)
	end
	return true
end

local function revealSelection(s: State, effects: { Effect })
	local id = M.selectionId(s)
	if id then
		table.insert(effects, { kind = "reveal", id = id })
	end
end

local function answered(s: State, kind: Kind, response: TransportTypes.Response, env: Env, effects: { Effect })
	if kind == "trace" then
		local mode: Tempo.Mode = s.modes.trace
		local r = Tempo.parseTrace(mode, response, env)
		if not r.ok then
			local err = (r :: any).error :: QueryError
			if not fellBack(s, "trace", err, env, effects) then
				s.trace_error = err
				s.trace = nil
				M.derive(s)
			end
			return
		end
		local t = Model.build((r :: any).spans, s.trace_id)
		s.trace = t
		s.trace_error = if t then nil else { kind = "query", message = "trace not found" }
		s.collapsed = {}
		s.sel = 1
		M.derive(s)
		local want = s.want_span
		if want and selectSpan(s, want) then
			s.want_span = nil
			s.detail = true
			revealSelection(s, effects)
		end
	elseif kind == "search" then
		local r = Tempo.parseSearch(s.modes.search, response, env)
		if not r.ok then
			local err = (r :: any).error :: QueryError
			if not fellBack(s, "search", err, env, effects) then
				s.search_error = err
			end
			return
		end
		s.hits = (r :: any).hits
		s.search_error = nil
		s.searched_ms = env.now_ms
		s.search_sel = math.clamp(s.search_sel, 1, math.max(1, #(s.hits :: { Tempo.SearchHit })))
	elseif kind == "tags" then
		local r = Tempo.parseTags(response, env)
		-- Suggestions are optional: a server without the v2 tags API shows none.
		s.tags = if r.ok then (r :: any).tags else {}
	elseif kind == "values" then
		local r = Tempo.parseTagValues(response, env)
		s.values = if r.ok then (r :: any).values else {}
	end
end

-- Selection and navigation ---------------------------------------------------

-- View ids (lib/trace/view): waterfall rows `r<span index>` under `wf`,
-- search hits `h<i>` under `hits`.
function M.selectionId(s: State): string?
	if s.tab == "trace" then
		local i = s.rows[s.sel]
		return if i then string.format("main.wf.r%d", i) else nil
	end
	if s.hits and s.hits[s.search_sel] then
		return string.format("main.hits.h%d", s.search_sel)
	end
	return nil
end

local function move(s: State, delta: number, effects: { Effect })
	if s.tab == "trace" then
		if #s.rows == 0 then
			return
		end
		s.sel = math.clamp(s.sel + delta, 1, #s.rows)
	else
		local n = if s.hits then #(s.hits :: { Tempo.SearchHit }) else 0
		if n == 0 then
			return
		end
		s.search_sel = math.clamp(s.search_sel + delta, 1, n)
	end
	revealSelection(s, effects)
end

local function selectIndex(s: State, index: number, effects: { Effect })
	local row = table.find(s.rows, index)
	if row then
		s.sel = row
		revealSelection(s, effects)
	end
end

local function setCollapsed(s: State, span: Span, collapsed: boolean): boolean
	if #span.children == 0 then
		return false
	end
	local id = span.raw.span_id
	if (s.collapsed[id] == true) == collapsed then
		return false
	end
	if collapsed then
		s.collapsed[id] = true
	else
		s.collapsed[id] = nil
	end
	M.derive(s)
	return true
end

-- left: fold the selected span, or go to its parent.
local function left(s: State, effects: { Effect })
	local span = M.selected(s)
	if span == nil then
		return
	end
	if not setCollapsed(s, span, true) and span.parent then
		selectIndex(s, span.parent :: number, effects)
	end
end

-- right: unfold the selected span, or go to its first child.
local function right(s: State, effects: { Effect })
	local span = M.selected(s)
	if span == nil then
		return
	end
	if not setCollapsed(s, span, false) and span.children[1] then
		selectIndex(s, span.children[1], effects)
	end
end

local function toggle(s: State, index: number?)
	local t = s.trace
	local span = if t and index then t.spans[index] else nil
	if span then
		setCollapsed(s, span, not s.collapsed[span.raw.span_id])
	end
end

-- The next (dir 1) or previous error span in display order, unfolding its
-- ancestors.
local function nextError(s: State, dir: number, effects: { Effect })
	local t = s.trace
	if t == nil or t.errors == 0 then
		s.note = "This trace has no error spans."
		return
	end
	local n = #t.spans
	local cur = s.rows[s.sel] or 0
	for step = 1, n do
		local i = (cur - 1 + dir * step) % n + 1
		if t.spans[i].error then
			if selectSpan(s, t.spans[i].raw.span_id) then
				revealSelection(s, effects)
			end
			return
		end
	end
end

local function openHit(s: State, i: number, env: Env, effects: { Effect })
	local hit = if s.hits then (s.hits :: { Tempo.SearchHit })[i] else nil
	if hit == nil then
		return
	end
	s.search_sel = i
	s.tab = "trace"
	s.detail = false
	s.note = nil
	if s.trace_id == hit.trace_id and (s.trace or M.loading(s, "trace")) then
		return
	end
	s.trace_id = hit.trace_id
	s.trace = nil
	s.collapsed = {}
	s.sel = 1
	M.derive(s)
	loadTrace(s, env, effects)
end

function M.traceLink(s: State, id: string, span: string?): string?
	if s.context == nil then
		return nil
	end
	local params: { [string]: string } = { context = s.context :: string, id = Ids.short(id) }
	if span then
		params.span = span
	end
	return Scheme.encode({ action = "trace", params = params, vars = {} })
end

local function openHitBlock(s: State, i: number, effects: { Effect })
	local hit = if s.hits then (s.hits :: { Tempo.SearchHit })[i] else nil
	local target = if hit then M.traceLink(s, hit.trace_id) else nil
	if target then
		table.insert(effects, { kind = "open", target = target })
	end
end

local function switchTab(s: State, tab: Tab, env: Env, effects: { Effect })
	if s.tab == tab then
		return
	end
	s.tab = tab
	s.note = nil
	if tab == "search" then
		if s.hits == nil and not M.loading(s, "search") then
			runSearch(s, env, effects)
		end
		loadTags(s, effects)
	end
end

local function switchContext(s: State, env: Env, name: string, effects: { Effect })
	if name == s.context and s.route then
		return
	end
	s.context = name
	s.collapsed = {}
	s.sel, s.search_sel = 1, 1
	connect(s, env, effects)
end

local function cycleContext(s: State, env: Env, step: number, effects: { Effect })
	local n = #s.contexts
	if n < 2 then
		return
	end
	local i = table.find(s.contexts, s.context or "") or 0
	switchContext(s, env, s.contexts[(i - 1 + step) % n + 1], effects)
end

local function copy(s: State, what: "span" | "trace", effects: { Effect })
	local span = M.selected(s)
	local text: string? = if what == "span" and span then span.raw.span_id else s.trace_id
	if text then
		table.insert(effects, { kind = "copy", text = text :: string })
		s.note = "Copied " .. what .. " id " .. (text :: string) .. "."
	end
end

-- Editing ----------------------------------------------------------------------

local function startEdit(s: State, field: "id" | "q", effects: { Effect })
	local text = if field == "id" then (if s.trace_id then Ids.short(s.trace_id :: string) else "") else s.q
	s.editing = field
	s.line = { text = text, cursor = #text }
	table.insert(effects, { kind = "focus", id = M.INPUT_ID })
end

local function stopEdit(s: State, effects: { Effect })
	s.editing = nil
	table.insert(effects, { kind = "focus", id = nil })
end

local function submit(s: State, env: Env, effects: { Effect })
	local text = string.match(s.line.text, "^%s*(.-)%s*$") or ""
	if s.editing == "id" then
		local id = Ids.trace(text)
		if id == nil or not string.match(text, "^%x+$") then
			s.note = "A trace id is up to 32 hex digits."
			return
		end
		stopEdit(s, effects)
		s.trace_id = id
		s.trace = nil
		s.collapsed = {}
		s.sel = 1
		s.detail = false
		M.derive(s)
		loadTrace(s, env, effects)
	else
		stopEdit(s, effects)
		s.q = if text == "" then M.DEFAULT_QUERY else text
		s.search_sel = 1
		runSearch(s, env, effects)
	end
end

local function editKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	local name = key.name
	if name == "enter" or name == "return" then
		submit(s, env, effects)
		return true
	elseif name == "escape" then
		stopEdit(s, effects)
		return true
	end
	local line = Edit.key(s.line, key)
	if line == nil or (line.text == s.line.text and line.cursor == s.line.cursor) then
		return false
	end
	s.line = line
	return true
end

-- TraceQL with `<tag> = "<value>"` added: a new selector for an empty query,
-- otherwise one more condition in the last selector.
function M.addMatcher(q: string, tag: string, value: string): string
	local cond = string.format("%s = %q", tag, value)
	local trimmed = string.match(q, "^%s*(.-)%s*$") or ""
	local inner = string.match(trimmed, "^{%s*(.-)%s*}$")
	if trimmed == "" or (inner ~= nil and inner == "") then
		return "{ " .. cond .. " }"
	end
	local head = string.match(trimmed, "^(.*)}$")
	if head == nil then
		return trimmed .. " && { " .. cond .. " }"
	end
	return (string.gsub(head, "%s*$", "")) .. " && " .. cond .. " }"
end

-- `scope.name` as TraceQL writes it; intrinsics stay bare.
function M.tagName(t: Tempo.Tag): string
	if t.scope == "" or t.scope == "intrinsic" then
		return t.name
	end
	return t.scope .. "." .. t.name
end

local function pickTag(s: State, name: string, effects: { Effect })
	if s.tag == name then
		s.tag, s.values = nil, nil
		s.pending.values = nil
		return
	end
	local route = s.route
	if route == nil then
		return
	end
	s.tag, s.values = name, nil
	request(s, "values", Tempo.tagValuesRequest(route, Tempo.mode(route), name), effects)
end

local function pickValue(s: State, i: number, env: Env, effects: { Effect })
	local v = if s.values then (s.values :: { string })[i] else nil
	if v == nil or s.tag == nil then
		return
	end
	s.q = M.addMatcher(s.q, s.tag :: string, v)
	s.tag, s.values = nil, nil
	s.search_sel = 1
	runSearch(s, env, effects)
end

local function setRange(s: State, from: string?, to: string?, env: Env, effects: { Effect }): boolean
	if from == nil or to == nil then
		return false
	end
	s.from, s.to = from, to
	runSearch(s, env, effects)
	return true
end

local function reload(s: State, env: Env, effects: { Effect })
	if s.tab == "trace" then
		loadTrace(s, env, effects)
	else
		runSearch(s, env, effects)
	end
end

local function traceKey(s: State, key: any, effects: { Effect }): boolean
	local name, text = key.name, key.text
	if name == "down" or text == "j" then
		move(s, 1, effects)
	elseif name == "up" or text == "k" then
		move(s, -1, effects)
	elseif name == "pagedown" then
		move(s, M.PAGE, effects)
	elseif name == "pageup" then
		move(s, -M.PAGE, effects)
	elseif name == "home" or text == "g" then
		move(s, -math.huge, effects)
	elseif name == "end" or text == "G" then
		move(s, math.huge, effects)
	elseif name == "left" or text == "h" then
		left(s, effects)
	elseif name == "right" or text == "l" then
		right(s, effects)
	elseif name == "enter" or name == "return" then
		if M.selected(s) == nil then
			return false
		end
		s.detail = not s.detail
	elseif name == "space" then
		toggle(s, s.rows[s.sel])
	elseif text == "e" then
		nextError(s, 1, effects)
	elseif text == "E" then
		nextError(s, -1, effects)
	elseif text == "p" then
		local span = M.selected(s)
		if span and span.parent then
			selectIndex(s, span.parent :: number, effects)
		end
	elseif text == "/" or text == "i" then
		startEdit(s, "id", effects)
	elseif text == "y" then
		copy(s, "span", effects)
	elseif text == "Y" then
		copy(s, "trace", effects)
	elseif name == "escape" then
		if not s.detail then
			return false
		end
		s.detail = false
	else
		return false
	end
	return true
end

local function searchKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	local name, text = key.name, key.text
	if name == "down" or text == "j" then
		move(s, 1, effects)
	elseif name == "up" or text == "k" then
		move(s, -1, effects)
	elseif name == "home" or text == "g" then
		move(s, -math.huge, effects)
	elseif name == "end" or text == "G" then
		move(s, math.huge, effects)
	elseif name == "enter" or name == "return" then
		openHit(s, s.search_sel, env, effects)
	elseif text == "o" then
		openHitBlock(s, s.search_sel, effects)
	elseif text == "/" then
		startEdit(s, "q", effects)
	elseif text and #text == 1 then
		local from, to = Timerange.forKey(text, s.from, s.to, env.now_ms)
		return setRange(s, from, to, env, effects)
	else
		return false
	end
	return true
end

local function normalKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	if key.ctrl or key.meta or key.alt then
		return false
	end
	local name, text = key.name, key.text
	if name == "tab" then
		switchTab(s, if s.tab == "trace" then "search" else "trace", env, effects)
		return true
	elseif text == "r" then
		reload(s, env, effects)
		return true
	elseif text == "c" then
		cycleContext(s, env, 1, effects)
		return true
	elseif text == "C" then
		cycleContext(s, env, -1, effects)
		return true
	end
	if s.tab == "trace" then
		return traceKey(s, key, effects)
	end
	return searchKey(s, key, env, effects)
end

function M.key(s: State, key: any, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	local handled = if s.editing ~= nil then editKey(s, key, env, effects) else normalKey(s, key, env, effects)
	return s, effects, handled
end

local function onAction(s: State, act: string, value: string?, env: Env, effects: { Effect })
	local n = tonumber(value or "")
	if act == "ctx" and value then
		if table.find(s.contexts, value) then
			switchContext(s, env, value, effects)
		end
	elseif act == "tab" and (value == "trace" or value == "search") then
		switchTab(s, value :: Tab, env, effects)
	elseif act == "row" and n then
		-- Click on a row: select it; a second click opens its detail.
		local row = table.find(s.rows, n)
		if row then
			s.detail = if s.sel == row then not s.detail else s.detail
			s.sel = row
		end
	elseif act == "fold" and n then
		toggle(s, n)
	elseif act == "hit" and n then
		openHit(s, n, env, effects)
	elseif act == "tag" and value then
		pickTag(s, value, effects)
	elseif act == "value" and n then
		pickValue(s, n, env, effects)
	elseif act == "edit" then
		startEdit(s, if s.tab == "trace" then "id" else "q", effects)
	elseif act == "reload" then
		reload(s, env, effects)
	elseif act == "error" then
		nextError(s, 1, effects)
	elseif act == "link" and value then
		local link = Scheme.decode(value)
		if link and link.action == "trace" then
			table.insert(effects, { kind = "open", target = value })
		end
	end
end

function M.update(s: State, msg: Msg, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		local kind, seq = string.match(msg.tag, "^(%a+):(%d+)$")
		if kind == nil or s.pending[kind :: string] ~= tonumber(seq) then
			return s, effects
		end
		s.pending[kind :: string] = nil
		answered(s, kind :: Kind, msg.response, env, effects)
	elseif msg.kind == "key" then
		local _, list = M.key(s, msg.key, env)
		return s, list
	elseif msg.kind == "event" then
		local ev: any = msg.ev
		if ev.ev == "action" and type(ev.act) == "string" then
			onAction(s, ev.act, ev.value, env, effects)
		elseif ev.ev == "focus" and ev.id == M.INPUT_ID and s.editing == nil then
			startEdit(s, if s.tab == "trace" then "id" else "q", effects)
		end
	end
	return s, effects
end

function M.title(s: State): string?
	if s.tab == "trace" and s.trace_id then
		local short = Ids.short(s.trace_id :: string)
		local t = s.trace
		local head = "Trace " .. string.sub(short, 1, 8)
		return if t then head .. ": " .. t.root_service .. " " .. t.root_name else head
	end
	return "Trace search"
end

-- Only what to reopen with: ids and the query, never span data.
function M.save(s: State): any
	return {
		context = s.context,
		tab = s.tab,
		trace_id = s.trace_id,
		q = s.q,
		from = s.from,
		to = s.to,
	}
end

return M
