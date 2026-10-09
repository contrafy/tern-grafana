--!strict
-- The ops block view: header (contexts, tabs, server), the current tab, and
-- a key-hint dock. Tabs whose endpoint the server lacks show a note instead
-- of an error. Class names are prefixed `tg-op-` (plugin/ops.css).

local Effect = require("../effect")
local Env = require("../env")
local Format = require("../units/format")
local Grid = require("../render/grid")
local Info = require("./info")
local State = require("./state")
local Targets = require("./targets")
local Tsdb = require("./tsdb")
local TransportTypes = require("../transport/types")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type State = State.State
type Endpoint = State.Endpoint
type QueryError = TransportTypes.QueryError

local M = {}

local TAB_LABEL: { [string]: string } = {
	targets = "Targets",
	rules = "Rules",
	cardinality = "Cardinality",
	info = "Info",
}

local LIST_HEAD: { [string]: { title: string, name: string, value: string } } = {
	series_by_metric = { title = "Series by metric name", name = "metric", value = "series" },
	values_by_label = { title = "Values by label name", name = "label", value = "values" },
	series_by_pair = { title = "Series by label pair", name = "label=value", value = "series" },
	memory_by_label = { title = "Index memory by label name", name = "label", value = "bytes" },
}

local HEALTH_STYLE: { [string]: string } = { up = "success", down = "error", unknown = "warning" }

-- "42s", "5m", "3h", "2d".
function M.age(ms: number): string
	local sec = math.max(0, math.floor(ms / 1000))
	if sec < 60 then
		return sec .. "s"
	elseif sec < 3600 then
		return (sec // 60) .. "m"
	elseif sec < 86400 then
		return (sec // 3600) .. "h"
	end
	return (sec // 86400) .. "d"
end

-- An integer with thousands separators: "8,640".
function M.int(n: number): string
	local s = string.format("%d", math.floor(n + 0.5))
	local sign, digits = string.match(s, "^(%-?)(%d+)$")
	local out = string.reverse((string.gsub(string.reverse(digits :: string), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return (sign :: string) .. out
end

local function chip(text: string, action: string, key: string, tone: string?): Node
	return ui.badge(text, tone or "neutral", { key = key, actions = { click = action }, class = "tg-op-chip" })
end

local function button(text: string, action: string, key: string): Node
	return ui.el("button", { key = key, class = "tg-op-btn", text = text, actions = { click = action } })
end

local function server(s: State): { SpanLike }
	local spans: { SpanLike } = {}
	local b = s.build
	if b and b.version then
		table.insert(spans, ui.span("Prometheus API " .. (b.version :: string), "strong"))
	end
	local route = s.route
	if route then
		local via = if route.via == "direct"
			then "direct"
			else "via Grafana datasource " .. tostring(route.datasource_uid)
		table.insert(spans, ui.span((if #spans > 0 then "  " else "") .. via, "muted"))
	end
	local loading = false
	for _, slot in s.slots do
		if slot.loading then
			loading = true
			break
		end
	end
	if loading then
		table.insert(spans, ui.span("  loading", "accent"))
	end
	return spans
end

local function header(s: State): Node
	local items: { Node } = {}
	for i, name in s.contexts do
		table.insert(items, chip(name, "ctx=" .. name, "c" .. i, if name == s.context then "info" else "neutral"))
	end
	for i, tab in State.TABS do
		table.insert(
			items,
			chip(
				string.format("%d %s", i, TAB_LABEL[tab]),
				"tab=" .. tab,
				"t" .. tab,
				if tab == s.tab then "info" else "neutral"
			)
		)
	end
	table.insert(items, ui.text(server(s), { key = "server" }))
	return ui.row(items, { key = "head", class = "tg-op-head", wrap = true })
end

local UNSUPPORTED_HINT =
	"Prometheus-compatible stores such as Mimir, Cortex or VictoriaMetrics do not serve every Prometheus status endpoint."

-- The endpoint's failure: an "unsupported" note or the error with a retry
-- hint; nil when it answered. Tabs with one endpoint `explain` why an
-- endpoint can be missing; the Info tab says it once above its cards.
local function failure(s: State, e: Endpoint, what: string, key: string, hasData: boolean, explain: boolean): Node?
	local err: QueryError? = s.slots[e].error
	if err == nil then
		return nil
	end
	local e2 = err :: QueryError
	if e2.kind == "unsupported" then
		local spans: { SpanLike } = { ui.span(what .. " unavailable: ", "warning"), ui.span(e2.message, "muted") }
		if explain then
			table.insert(spans, ui.span(". " .. UNSUPPORTED_HINT, "muted"))
		end
		return ui.text(spans, { key = key })
	end
	return ui.text({
		ui.span(what .. ": " .. e2.message, "error"),
		ui.span(if hasData then "  (showing the last good answer; r retries)" else "  (r retries)", "muted"),
	}, { key = key })
end

local function pending(s: State, e: Endpoint, what: string, key: string): Node?
	local slot = s.slots[e]
	if slot.loading and slot.loaded_ms == nil then
		return ui.muted("Loading " .. what .. "...", { key = key })
	end
	return nil
end

local function filterLine(s: State, placeholder: string, summary: { SpanLike }): Node
	if s.editing ~= nil then
		return {
			k = "input",
			p = {
				key = "filter",
				text = s.editing,
				cursor = utf8.len(s.editing :: string) or #(s.editing :: string),
				placeholder = placeholder,
				prompt = { { t = "/ ", s = "muted" } },
			},
		}
	end
	local spans: { SpanLike } = {}
	if s.filter_text ~= "" then
		table.insert(spans, ui.span("filter ", "muted"))
		table.insert(spans, ui.span(s.filter_text, "mono"))
		for _, sp in summary do
			table.insert(spans, sp)
		end
	else
		table.insert(spans, ui.span("/ filter: " .. placeholder, "muted"))
	end
	if s.filter_error then
		table.insert(spans, ui.span("  " .. (s.filter_error :: string), "error"))
	end
	return ui.text(spans, { key = "filter", actions = { click = "filter" } })
end

-- Targets ------------------------------------------------------------------
local function item(k: { SpanLike }, v: { SpanLike }): { { SpanLike } }
	return { k, v }
end

local function targetDetail(t: Targets.Target): Node
	local items: { { { SpanLike } } } = {}
	table.insert(items, item({ "scrape url" }, { ui.span(t.url, "mono") }))
	if t.interval or t.timeout then
		table.insert(
			items,
			{ { "interval / timeout" }, { string.format("%s / %s", t.interval or "?", t.timeout or "?") } }
		)
	end
	if t.last_error then
		table.insert(items, item({ "last error" }, { ui.span(t.last_error :: string, "error") }))
	end
	local names: { string } = {}
	for name in t.labels do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		table.insert(items, { { ui.span(name, "mono") }, { ui.span(t.labels[name], "mono") } })
	end
	return ui.col({ ui.kv(items) }, { key = "detail", class = "tg-op-detail" })
end

local function targetRow(s: State, i: number, t: Targets.Target, env: Env.Env): Node
	local spans: { SpanLike } = {
		ui.span(string.format("%-5s ", t.health), HEALTH_STYLE[t.health]),
		ui.span(t.instance, "strong"),
	}
	if t.last_scrape_ms then
		table.insert(spans, ui.span("  " .. M.age(env.now_ms - (t.last_scrape_ms :: number)) .. " ago", "muted"))
	else
		table.insert(spans, ui.span("  never scraped", "muted"))
	end
	if t.duration_s then
		table.insert(spans, ui.span("  " .. Format.text(t.duration_s, "s"), "muted"))
	end
	if t.last_error then
		table.insert(spans, ui.span("  " .. (t.last_error :: string), "error"))
	end
	local class = "tg-op-row tg-op-" .. t.health .. (if i == s.sel then " is-sel" else "")
	local children: { Node } = { ui.text(spans) }
	if s.detail == t.key then
		table.insert(children, targetDetail(t))
	end
	return ui.el("div", { key = "r" .. i, class = class, actions = { click = "row=" .. i } }, children)
end

local function droppedList(t: Targets.Targets): Node
	if t.dropped_count == 0 then
		return ui.muted("No dropped targets.", { key = "dropped" })
	end
	if #t.dropped == 0 then
		return ui.muted(string.format("%s dropped targets (the server lists none).", M.int(t.dropped_count)), {
			key = "dropped",
		})
	end
	local rows: { Grid.Row } = {}
	for i, d in t.dropped do
		rows[i] = { key = "d" .. i, cells = { Grid.text(d.pool), Grid.text(d.address, "mono") } }
	end
	local children: { Node } = { Grid.grid("dgrid", { { head = "pool" }, { head = "address" } }, rows) }
	local hidden = t.dropped_count - #t.dropped
	if hidden > 0 then
		table.insert(children, ui.muted(string.format("... %s more", M.int(hidden)), { key = "dmore" }))
	end
	return ui.section({ string.format("Dropped targets (%s)", M.int(t.dropped_count)) }, children, { key = "dropped" })
end

local function targetsTab(s: State, env: Env.Env): { Node }
	local out: { Node } = {}
	local t = s.targets
	local fail = failure(s, "targets", "Targets", "terr", t ~= nil, true)
	if fail then
		table.insert(out, fail)
	end
	local wait = pending(s, "targets", "targets", "twait")
	if wait then
		table.insert(out, wait)
	end
	if t == nil then
		return out
	end
	local targets = t :: Targets.Targets
	local counts = Targets.counts(targets)
	local shown = 0
	for _, p in s.pools do
		shown += #p.targets
	end
	table.insert(
		out,
		ui.row({
			ui.badge(string.format("%d up", counts.up), if counts.up > 0 then "success" else "muted", { key = "nup" }),
			ui.badge(
				string.format("%d down", counts.down),
				if counts.down > 0 then "error" else "muted",
				{ key = "ndown" }
			),
			ui.badge(
				string.format("%d unknown", counts.unknown),
				if counts.unknown > 0 then "warning" else "muted",
				{ key = "nunk" }
			),
			chip(
				string.format("%s dropped", M.int(targets.dropped_count)),
				"dropped",
				"ndrop",
				if s.show_dropped then "info" else "neutral"
			),
			chip("unhealthy only", "unhealthy", "unh", if s.unhealthy_only then "info" else "neutral"),
		}, { key = "counts", wrap = true })
	)
	table.insert(
		out,
		filterLine(
			s,
			"job=node health=down text",
			{ ui.span(string.format("  %d of %d", shown, #targets.active), "muted") }
		)
	)
	if #targets.active == 0 then
		table.insert(out, ui.muted("The server scrapes no targets.", { key = "empty" }))
	elseif #s.rows == 0 then
		table.insert(out, ui.muted("No target matches. Esc clears the filter, u shows all.", { key = "empty" }))
	end
	local rowIndex: { [any]: number } = {}
	local poolRow: { [number]: number } = {}
	for i, r in s.rows do
		if r.kind == "pool" then
			poolRow[r.pool] = i
		else
			rowIndex[(r :: any).target] = i
		end
	end
	local cards: { Node } = {}
	for pi, p in s.pools do
		local head: { SpanLike } = {
			ui.span(p.name, "strong"),
			ui.span(string.format("   %d/%d up", p.up, #p.targets), "muted"),
		}
		if p.down > 0 then
			table.insert(head, ui.span(string.format("  %d down", p.down), "error"))
		end
		if p.unknown > 0 then
			table.insert(head, ui.span(string.format("  %d unknown", p.unknown), "warning"))
		end
		if p.dropped > 0 then
			table.insert(head, ui.span(string.format("  %s dropped", M.int(p.dropped)), "muted"))
		end
		local rows: { Node } = {}
		for _, target in p.targets do
			local i = rowIndex[target]
			if i then
				table.insert(rows, targetRow(s, i, target, env))
			end
		end
		table.insert(
			cards,
			ui.card(head, rows, {
				key = "p" .. pi,
				collapsible = true,
				collapsed = s.collapsed[p.name] == true,
				selected = poolRow[pi] == s.sel,
				tone = if p.down > 0 then "error" elseif p.unknown > 0 then "warning" else nil,
				inset = true,
			})
		)
	end
	table.insert(out, ui.col(cards, { key = "pools" }))
	if s.show_dropped then
		table.insert(out, droppedList(targets))
	end
	return out
end

-- Cardinality --------------------------------------------------------------

local function headStats(t: Tsdb.Tsdb): Node
	local h = t.head
	local items: { { { SpanLike } } } = {}
	local function n(label: string, v: number?)
		if v then
			table.insert(items, item({ label }, { ui.span(M.int(v :: number), "mono") }))
		end
	end
	n("series", h.series)
	n("label pairs", h.label_pairs)
	n("chunks", h.chunks)
	if h.min_time_ms and h.max_time_ms then
		table.insert(items, {
			{ "head span" },
			{ M.age((h.max_time_ms :: number) - (h.min_time_ms :: number)) },
		})
	end
	return ui.kv(items)
end

local function listSection(s: State, t: Tsdb.Tsdb, name: Tsdb.ListName, first: number): (Node, number)
	local head = LIST_HEAD[name]
	local entries = Tsdb.list(t, name)
	local open = s.open_lists[name] == true
	local children: { Node } = {}
	local idx = first
	if open then
		local series = name == "series_by_metric" or name == "series_by_pair"
		local cols: { Grid.Column } = { { head = "" }, { head = head.name }, { head = head.value, numeric = true } }
		if series then
			table.insert(cols, { head = "of head", numeric = true })
		end
		local rows: { Grid.Row } = {}
		for _, e in entries do
			local value = if name == "memory_by_label" then Format.text(e.value, "bytes") else M.int(e.value)
			local sel = idx == s.card_sel
			local cells: { Node } = {
				Grid.text(if sel then ">" else " ", "accent"),
				Grid.text(e.name, if sel then "strong" else "mono"),
				Grid.text(value),
			}
			if series then
				local share = Tsdb.share(t, e.value)
				table.insert(cells, Grid.text(if share then string.format("%.1f%%", share * 100) else ""))
			end
			table.insert(rows, { key = "e" .. idx, cells = cells, action = "drill=" .. idx })
			idx += 1
		end
		if #entries == 0 then
			table.insert(children, ui.muted("The server returned no entries.", { key = "none" }))
		else
			table.insert(children, Grid.grid("g", cols, rows))
		end
	end
	return ui.section(
		{ ui.span(head.title, "strong"), ui.span(string.format("  top %d", #entries), "muted") },
		children,
		{
			key = "l_" .. name,
			collapsible = true,
			collapsed = not open,
		}
	),
		idx
end

local function cardinalityTab(s: State): { Node }
	local out: { Node } = {}
	local t = s.tsdb
	local fail = failure(s, "tsdb", "Cardinality", "cerr", t ~= nil, true)
	if fail then
		table.insert(out, fail)
	end
	local wait = pending(s, "tsdb", "TSDB status", "cwait")
	if wait then
		table.insert(out, wait)
	end
	if t == nil then
		return out
	end
	local tsdb = t :: Tsdb.Tsdb
	table.insert(
		out,
		ui.row({
			headStats(tsdb),
			ui.col({
				ui.text({ ui.span(string.format("top %d per list", s.tsdb_limit), "muted") }, { key = "lim" }),
				ui.row({ button("fewer (-)", "limit=down", "ldown"), button("more (+)", "limit=up", "lup") }, {
					key = "lbtn",
				}),
			}, { key = "limit" }),
		}, { key = "stats", wrap = true })
	)
	local idx = 1
	for _, l in Tsdb.LISTS do
		local node
		node, idx = listSection(s, tsdb, l.name, idx)
		table.insert(out, node)
	end
	return out
end

-- Info ---------------------------------------------------------------------

local function buildCard(s: State): Node
	local children: { Node } = {}
	local fail = failure(s, "buildinfo", "Build info", "berr", s.build ~= nil, false)
	if fail then
		table.insert(children, fail)
	end
	local b = s.build
	if b then
		local items: { { { SpanLike } } } = {}
		local function add(k: string, v: string?)
			if v and v ~= "" then
				table.insert(items, item({ k }, { ui.span(v :: string, "mono") }))
			end
		end
		add("version", b.version)
		add("revision", if b.revision then string.sub(b.revision :: string, 1, 12) else nil)
		add("branch", b.branch)
		add("build date", b.build_date)
		add("go", b.go_version)
		table.insert(children, ui.kv(items))
	end
	return ui.card({ "Build" }, children, { key = "build", inset = true })
end

-- GOMEMLIMIT is math.MaxInt64 when unset.
local NO_MEMLIMIT = 2 ^ 62

local function runtimeCard(s: State, env: Env.Env): Node
	local children: { Node } = {}
	local fail = failure(s, "runtimeinfo", "Runtime info", "rerr", s.runtime ~= nil, false)
	if fail then
		table.insert(children, fail)
	end
	local r = s.runtime
	if r then
		local items: { { { SpanLike } } } = {}
		local function add(k: string, v: { SpanLike }?)
			if v then
				table.insert(items, item({ k }, v :: { SpanLike }))
			end
		end
		add("started", if r.start_ms then { M.age(env.now_ms - (r.start_ms :: number)) .. " ago" } else nil)
		add("hostname", if r.hostname then { ui.span(r.hostname :: string, "mono") } else nil)
		add("cwd", if r.cwd then { ui.span(r.cwd :: string, "mono") } else nil)
		if r.reload_ok ~= nil then
			add("config reload", { if r.reload_ok then ui.span("ok", "success") else ui.span("failed", "error") })
		end
		add(
			"last reload",
			if r.last_config_ms then { M.age(env.now_ms - (r.last_config_ms :: number)) .. " ago" } else nil
		)
		add("retention", if r.retention then { r.retention :: string } else nil)
		add("goroutines", if r.goroutines then { M.int(r.goroutines :: number) } else nil)
		add("GOMAXPROCS", if r.gomaxprocs then { M.int(r.gomaxprocs :: number) } else nil)
		if r.gomemlimit then
			local limit = r.gomemlimit :: number
			add("GOMEMLIMIT", { if limit >= NO_MEMLIMIT then "none" else Format.text(limit, "bytes") })
		end
		add("GOGC", if r.gogc and r.gogc ~= "" then { r.gogc :: string } else nil)
		if r.corruptions then
			local n = r.corruptions :: number
			add("corruptions", { ui.span(M.int(n), if n > 0 then "error" else "muted") })
		end
		table.insert(children, ui.kv(items))
	end
	return ui.card({ "Runtime" }, children, { key = "runtime", inset = true })
end

local MAX_JOBS_SHOWN = 12

local function configCard(s: State): Node
	local children: { Node } = {}
	local fail = failure(s, "config", "Configuration", "cfgerr", s.config ~= nil, false)
	if fail then
		table.insert(children, fail)
	end
	local c = s.config
	if c then
		local items: { { { SpanLike } } } = {}
		local function add(k: string, v: string?)
			if v and v ~= "" then
				table.insert(items, { { k }, { v :: string } })
			end
		end
		add("scrape interval", c.scrape_interval)
		add("scrape timeout", c.scrape_timeout)
		add("evaluation interval", c.evaluation_interval)
		if #c.external_labels > 0 then
			local parts: { string } = {}
			for _, l in c.external_labels do
				table.insert(parts, l.name .. "=" .. l.value)
			end
			table.insert(items, item({ "external labels" }, { ui.span(table.concat(parts, " "), "mono") }))
		end
		local jobs = table.concat(c.jobs, ", ", 1, math.min(#c.jobs, MAX_JOBS_SHOWN))
		if #c.jobs > MAX_JOBS_SHOWN then
			jobs ..= string.format(", ... %d more", #c.jobs - MAX_JOBS_SHOWN)
		end
		table.insert(items, { { string.format("scrape jobs (%d)", #c.jobs) }, { jobs } })
		if #c.rule_files > 0 then
			table.insert(items, item({ "rule files" }, { ui.span(table.concat(c.rule_files, " "), "mono") }))
		end
		add("alertmanager configs", tostring(c.alertmanagers))
		add("remote write / read", string.format("%d / %d", c.remote_write, c.remote_read))
		add("yaml", string.format("%d lines", c.lines))
		table.insert(children, ui.kv(items))
		table.insert(children, ui.row({ button("Copy YAML (y)", "copy", "bcopy") }, { key = "cfgbtn" }))
	end
	return ui.card({ "Configuration" }, children, { key = "config", inset = true })
end

local function flagItems(flags: { Info.Flag }): Node
	local items: { { { SpanLike } } } = {}
	for _, f in flags do
		table.insert(
			items,
			{ { ui.span(f.name, "mono") }, { ui.span(if f.value == "" then '""' else f.value, "mono") } }
		)
	end
	return ui.kv(items)
end

local function flagMatches(s: State, f: Info.Flag): boolean
	for _, w in s.filter.words do
		if not string.find(string.lower(f.name), w, 1, true) and not string.find(string.lower(f.value), w, 1, true) then
			return false
		end
	end
	return true
end

local function flagsCard(s: State): Node
	local children: { Node } = {}
	local fail = failure(s, "flags", "Flags", "ferr", s.flags ~= nil, false)
	if fail then
		table.insert(children, fail)
	end
	local flags = s.flags
	if flags then
		local list = flags :: { Info.Flag }
		local key = Info.keyFlags(list)
		if #key > 0 then
			table.insert(children, flagItems(key))
		end
		local matched: { Info.Flag } = {}
		for _, f in list do
			if flagMatches(s, f) then
				table.insert(matched, f)
			end
		end
		table.insert(
			children,
			filterLine(s, "flag name or value", { ui.span(string.format("  %d of %d", #matched, #list), "muted") })
		)
		local open = s.open_lists.flags == true or s.filter_text ~= ""
		table.insert(
			children,
			ui.section(
				{ string.format("All flags (%d)", #matched) },
				if open then { flagItems(matched) } else {},
				{ key = "l_flags", collapsible = true, collapsed = not open }
			)
		)
	end
	return ui.card({ "Flags" }, children, { key = "flags", inset = true })
end

local function infoTab(s: State, env: Env.Env): { Node }
	local out: { Node } = {}
	local loading = false
	local unsupported = false
	for _, e in State.endpoints("info") do
		local slot = s.slots[e :: Endpoint]
		if slot.loading and slot.loaded_ms == nil then
			loading = true
		end
		if slot.error and (slot.error :: QueryError).kind == "unsupported" then
			unsupported = true
		end
	end
	if loading and s.runtime == nil and s.flags == nil and s.config == nil then
		table.insert(out, ui.muted("Loading server info...", { key = "iwait" }))
	end
	if unsupported then
		table.insert(out, ui.muted(UNSUPPORTED_HINT, { key = "ihint" }))
	end
	table.insert(out, buildCard(s))
	table.insert(out, runtimeCard(s, env))
	table.insert(out, configCard(s))
	table.insert(out, flagsCard(s))
	return out
end

-- Rules --------------------------------------------------------------------

local function rulesTab(s: State): { Node }
	return {
		ui.text({
			ui.span("Alerting and recording rules live in the Alerts block's Rules view: ", "muted"),
			ui.span("health, state, last evaluation, last error and a query preview per rule", "muted"),
			ui.span(if s.context then " (context " .. (s.context :: string) .. ")." else ".", "muted"),
		}, { key = "rinfo" }),
		ui.row({ button("Open rules in Alerts (enter)", "rules", "brules") }, { key = "rbtn" }),
	}
end

local HINTS: { [string]: string } = {
	targets = "tab/1-4 tabs  j/k move  enter expand  / filter  u unhealthy  d dropped  r refresh  c context",
	rules = "tab/1-4 tabs  enter open rules  c context",
	cardinality = "tab/1-4 tabs  j/k move  enter query  +/- top N  r refresh  c context",
	info = "tab/1-4 tabs  / filter flags  y copy config  r refresh  c context",
}

function M.view(s: State, env: Env.Env): Effect.View
	local children: { Node } = { header(s) }
	if s.problem then
		table.insert(children, ui.text({ ui.span(s.problem :: string, "error") }, { key = "problem" }))
		return { main = ui.col(children, { role = "tern-grafana.ops" }) }
	end
	if s.note then
		table.insert(children, ui.text({ ui.span(s.note :: string, "muted") }, { key = "note" }))
	end
	local body: { Node }
	if s.tab == "targets" then
		body = targetsTab(s, env)
	elseif s.tab == "cardinality" then
		body = cardinalityTab(s)
	elseif s.tab == "info" then
		body = infoTab(s, env)
	else
		body = rulesTab(s)
	end
	for _, n in body do
		table.insert(children, n)
	end
	local hints = ui.text({ ui.span(HINTS[s.tab], "muted") }, { key = "keys" })
	return {
		main = ui.col(children, { role = "tern-grafana.ops" }),
		dock = ui.col({ hints }, { key = "dock" }),
	}
end

return M
