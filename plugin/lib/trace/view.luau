--!strict
-- The trace block view. Trace tab: a summary, the service legend, a time
-- axis and the waterfall, one `el` row per visible span (name column,
-- duration column, and a track holding a spacer and a bar whose flex bases
-- are the span's offset and width as fractions of the trace), with the
-- selected span's detail under it. Search tab: the TraceQL line, tag and
-- value chips, and the matching traces. Class names are prefixed `tg-tr-`
-- (plugin/trace.css); service colors are classes `tg-tr-c1` .. `tg-tr-c10`.

local Edit = require("../query/edit")
local Effect = require("../effect")
local Env = require("../env")
local Format = require("../units/format")
local Ids = require("./ids")
local Model = require("./model")
local Nanos = require("./nanos")
local Range = require("../time/range")
local State = require("./state")
local Tempo = require("../source/tempo")
local TraceTypes = require("./types")
local TransportTypes = require("../transport/types")
local ui = require("../ui")

type Node = ui.Node
type SpanLike = ui.SpanLike
type State = State.State
type Trace = TraceTypes.Trace
type Span = TraceTypes.Span
type Attr = TraceTypes.Attr
type QueryError = TransportTypes.QueryError

local M = {}

M.COLORS = 10
-- Share of the row width the name column takes.
M.NAME_BASIS = 0.38
local MAX_INDENT = 12
local MAX_TAG_CHIPS = 40
local MAX_VALUE_CHIPS = 60
-- Intrinsic tags worth a chip (the rest are rarely searched by value).
local INTRINSIC_CHIPS = { name = true, status = true, kind = true }

function M.colorClass(index: number): string
	return "tg-tr-c" .. ((index - 1) % M.COLORS + 1)
end

function M.duration(ns: number): string
	return Format.text(ns, "ns")
end

local function chip(text: string, action: string, key: string, tone: string?): Node
	return ui.badge(text, tone or "neutral", { key = key, actions = { click = action }, class = "tg-tr-chip" })
end

local function header(s: State): Node
	local items: { Node } = {}
	for i, name in s.contexts do
		table.insert(items, chip(name, "ctx=" .. name, "c" .. i, if name == s.context then "info" else "neutral"))
	end
	table.insert(items, chip("Trace", "tab=trace", "ttrace", if s.tab == "trace" then "info" else "neutral"))
	table.insert(items, chip("Search", "tab=search", "tsearch", if s.tab == "search" then "info" else "neutral"))
	local spans: { SpanLike } = {}
	local route = s.route
	if route then
		local mode = if s.tab == "trace" then s.modes.trace else s.modes.search
		local via = if mode == "direct"
			then "Tempo direct"
			elseif mode == "proxy" then "via Grafana datasource proxy " .. tostring(route.datasource_uid)
			else "via Grafana datasource " .. tostring(route.datasource_uid)
		table.insert(spans, ui.span(via, "muted"))
	end
	if State.loading(s, "trace") or State.loading(s, "search") then
		table.insert(spans, ui.span("  loading", "accent"))
	end
	table.insert(items, ui.text(spans, { key = "server" }))
	return ui.row(items, { key = "head", class = "tg-tr-head", wrap = true, align = "center" })
end

local function errorLine(err: QueryError, key: string, hasData: boolean): Node
	return ui.text({
		ui.span(err.message, "error"),
		ui.span(if hasData then "  (showing the last answer; r retries)" else "  (r retries)", "muted"),
	}, { key = key })
end

local function inputNode(s: State, placeholder: string, aria: string): Node
	return {
		k = "input",
		p = {
			key = "input",
			text = s.line.text,
			cursor = Edit.utf16(s.line.text, s.line.cursor),
			placeholder = placeholder,
			prompt = { { t = "> ", s = "muted" } },
			aria = aria,
		},
	}
end

-- Trace tab ----------------------------------------------------------------

local function summary(t: Trace): Node
	local spans: { SpanLike } = {
		ui.span(t.root_service, "strong"),
		ui.span(" " .. t.root_name),
		ui.span("  " .. M.duration(t.duration_ns), "accent"),
		ui.span(string.format("  %d span%s", #t.spans, if #t.spans == 1 then "" else "s"), "muted"),
		ui.span(string.format("  %d service%s", #t.services, if #t.services == 1 then "" else "s"), "muted"),
	}
	if t.errors > 0 then
		table.insert(
			spans,
			ui.span(string.format("  %d error%s", t.errors, if t.errors == 1 then "" else "s"), "error")
		)
	end
	table.insert(spans, ui.span("  " .. Range.formatMs(t.start_ms) .. " UTC", "muted"))
	table.insert(spans, ui.span("  " .. Ids.short(t.trace_id), "muted"))
	return ui.text(spans, { key = "sum" })
end

local function notes(s: State, t: Trace): { Node }
	local out: { Node } = {}
	local parts: { string } = {}
	if t.orphans > 0 then
		table.insert(
			parts,
			string.format(
				"%d span%s whose parent is not in the trace %s shown as roots",
				t.orphans,
				if t.orphans == 1 then "" else "s",
				if t.orphans == 1 then "is" else "are"
			)
		)
	end
	if t.skewed > 0 then
		table.insert(
			parts,
			string.format("%d span%s shifted to correct clock skew", t.skewed, if t.skewed == 1 then "" else "s")
		)
	end
	if t.duplicates > 0 then
		table.insert(
			parts,
			string.format("%d duplicate span%s dropped", t.duplicates, if t.duplicates == 1 then "" else "s")
		)
	end
	if s.hidden_rows > 0 then
		table.insert(parts, string.format("%d more spans not drawn; fold subtrees (space) to see them", s.hidden_rows))
	end
	if #parts > 0 then
		table.insert(out, ui.text({ ui.span(table.concat(parts, "; ") .. ".", "warning") }, { key = "notes" }))
	end
	return out
end

local function legend(t: Trace): Node
	local items: { Node } = {}
	for i, svc in t.services do
		local label = svc.name .. string.format(" (%d)", svc.spans)
		local children: { Node } = {
			ui.el("span", { key = "w", class = "tg-tr-sw " .. M.colorClass(i) }),
			ui.el("span", { key = "n", text = label }),
		}
		if svc.errors > 0 then
			table.insert(
				children,
				ui.el("span", { key = "e", class = "tg-tr-errtext", text = string.format(" %d err", svc.errors) })
			)
		end
		table.insert(items, ui.el("span", { key = "s" .. i, class = "tg-tr-svc" }, children))
	end
	return ui.el("div", { key = "legend", class = "tg-tr-legend" }, items)
end

local function cell(key: string, class: string, props: { [string]: any }, children: { Node }?): Node
	props.key = key
	props.class = class
	return ui.el("div", props, children)
end

local function axis(t: Trace): Node
	local ticks: { Node } = {}
	for k = 0, 3 do
		ticks[k + 1] =
			cell("t" .. k, "tg-tr-tick", { basis = 0.25, shrink = 0, text = M.duration(t.duration_ns * k / 4) })
	end
	return cell("axis", "tg-tr-row tg-tr-axis", {}, {
		cell("n", "tg-tr-name", { basis = M.NAME_BASIS, shrink = 0, text = "span" }),
		cell("d", "tg-tr-dur", { min = { w = "9ch" }, shrink = 0, text = "duration" }),
		cell("k", "tg-tr-track", { grow = 1, basis = 0 }, ticks),
	})
end

local function rowNode(s: State, t: Trace, row: number, span: Span): Node
	local sel = row == s.sel
	local folded = s.collapsed[span.raw.span_id] == true
	local glyph = if #span.children == 0 then "  " elseif folded then "+ " else "- "
	local indent = string.rep("  ", math.min(span.depth, MAX_INDENT))
	local nameSpans: { SpanLike } = {
		ui.span(indent .. glyph, "muted"),
		ui.span(span.raw.service .. " ", "muted"),
		ui.span(span.raw.name, if span.error then "error" else (if sel then "strong" else nil)),
	}
	if span.orphan then
		table.insert(nameSpans, ui.span(" (parent missing)", "warning"))
	end
	if folded then
		table.insert(nameSpans, ui.span(string.format(" (+%d)", #span.children), "muted"))
	end
	local left, width = Model.fractions(t, span)
	local barClass = "tg-tr-bar " .. M.colorClass(span.service_index) .. (if span.error then " tg-tr-err" else "")
	local track = cell("k", "tg-tr-track", { grow = 1, basis = 0 }, {
		cell("sp", "tg-tr-gap", { basis = left, shrink = 0 }),
		cell("b", barClass, { basis = width, shrink = 0 }),
	})
	local durClass = "tg-tr-dur" .. (if span.on_critical_path then " is-crit" else "")
	local class = "tg-tr-row" .. (if sel then " is-sel" else "") .. (if span.error then " is-err" else "")
	return cell("r" .. span.index, class, {
		actions = { click = "row=" .. span.index, dblclick = "fold=" .. span.index },
	}, {
		cell("n", "tg-tr-name", { basis = M.NAME_BASIS, shrink = 0 }, {
			ui.text(nameSpans, { key = "t", wrap = "none", truncate = "end" }),
		}),
		cell("d", durClass, { min = { w = "9ch" }, shrink = 0, text = M.duration(span.dur_ns) }),
		track,
	})
end

local function attrItems(attrs: { Attr }): Node
	local items: { { { SpanLike } } } = {}
	for _, a in attrs do
		table.insert(items, { { ui.span(a.key, "mono") }, { ui.span(a.value, "mono") } })
	end
	return ui.kv(items)
end

local function add(items: { { { SpanLike } } }, key: string, value: { SpanLike })
	local k: { SpanLike } = { key }
	table.insert(items, { k, value })
end

local function detail(s: State, t: Trace, span: Span): Node
	local raw = span.raw
	local items: { { { SpanLike } } } = {}
	add(items, "service", { ui.span(raw.service, "strong") })
	add(items, "operation", { raw.name })
	add(items, "span id", { ui.span(raw.span_id, "mono") })
	if span.parent then
		add(items, "parent", { ui.span(t.spans[span.parent :: number].raw.span_id, "mono") })
	elseif raw.parent_id then
		add(items, "parent", { ui.span(raw.parent_id :: string, "mono"), ui.span("  not in this trace", "warning") })
	end
	add(items, "kind", { raw.kind :: string })
	local status: { SpanLike } = { ui.span(raw.status, if raw.status == "error" then "error" else nil) }
	if raw.status_message then
		table.insert(status, ui.span("  " .. (raw.status_message :: string), "muted"))
	end
	add(items, "status", status)
	add(items, "start", { "+" .. M.duration(span.start_ns) })
	add(items, "duration", { M.duration(span.dur_ns) })
	add(items, "self time", { M.duration(span.self_ns) })
	if span.on_critical_path then
		add(items, "critical path", { M.duration(span.critical_ns) .. " of its own" })
	else
		add(items, "critical path", { ui.span("not on it", "muted") })
	end
	if span.skew_ns ~= 0 then
		local shift = (if span.skew_ns > 0 then "+" else "-") .. M.duration(math.abs(span.skew_ns))
		add(items, "clock skew", { ui.span("shifted " .. shift .. " to fit its parent", "warning") })
	end
	if raw.scope then
		local scope = raw.scope :: string
		add(items, "scope", { if raw.scope_version then scope .. " " .. raw.scope_version else scope })
	end
	local children: { Node } = { ui.kv(items) }
	if #raw.attributes > 0 then
		table.insert(
			children,
			ui.section(
				{ string.format("Attributes (%d)", #raw.attributes) },
				{ attrItems(raw.attributes) },
				{ key = "attrs" }
			)
		)
	end
	if #raw.events > 0 then
		local evs: { Node } = {}
		for i, ev in raw.events do
			local at = if ev.time then "+" .. M.duration(Nanos.diff(ev.time :: TraceTypes.Nano, t.start)) .. " " else ""
			local list: { Node } = { ui.text({ ui.span(at, "muted"), ui.span(ev.name, "strong") }, { key = "h" }) }
			if #ev.attributes > 0 then
				table.insert(list, attrItems(ev.attributes))
			end
			table.insert(evs, ui.col(list, { key = "e" .. i }))
		end
		table.insert(children, ui.section({ string.format("Events (%d)", #raw.events) }, evs, { key = "events" }))
	end
	if #raw.links > 0 then
		local links: { Node } = {}
		for i, l in raw.links do
			local target = State.traceLink(s, l.trace_id, l.span_id)
			local label = string.format("trace %s span %s", Ids.short(l.trace_id), l.span_id)
			table.insert(
				links,
				ui.text({ ui.span(label, "accent") }, {
					key = "l" .. i,
					actions = if target then { click = "link=" .. target } else nil,
				})
			)
		end
		table.insert(children, ui.section({ string.format("Links (%d)", #raw.links) }, links, { key = "links" }))
	end
	if #raw.resource > 0 then
		table.insert(
			children,
			ui.section({ string.format("Resource (%d)", #raw.resource) }, { attrItems(raw.resource) }, {
				key = "res",
				collapsible = true,
				collapsed = true,
			})
		)
	end
	-- An `el`: `col` takes no class, and the detail needs its border.
	return ui.el("div", { key = "d" .. span.index, class = "tg-tr-detail" }, children)
end

local function idLine(s: State): Node
	if s.editing == "id" then
		return inputNode(s, "trace id (hex), Enter loads", "Trace id")
	end
	local spans: { SpanLike } = {}
	if s.trace_id then
		table.insert(spans, ui.span("trace ", "muted"))
		table.insert(spans, ui.span(Ids.short(s.trace_id :: string), "mono"))
		table.insert(spans, ui.span("   / another id", "muted"))
	else
		table.insert(spans, ui.span("Press / to enter a trace id, or pick one in Search (tab).", "muted"))
	end
	return ui.text(spans, { key = "input", actions = { click = "edit" } })
end

local function traceTab(s: State): { Node }
	local out: { Node } = { idLine(s) }
	local t = s.trace
	if s.trace_error then
		table.insert(out, errorLine(s.trace_error :: QueryError, "terr", false))
	end
	if t == nil then
		if State.loading(s, "trace") then
			table.insert(out, ui.muted("Loading trace...", { key = "twait" }))
		end
		return out
	end
	local tr = t :: Trace
	table.insert(out, summary(tr))
	for _, n in notes(s, tr) do
		table.insert(out, n)
	end
	table.insert(out, legend(tr))
	table.insert(out, axis(tr))
	local rows: { Node } = {}
	for r, i in s.rows do
		local span = tr.spans[i]
		table.insert(rows, rowNode(s, tr, r, span))
		if s.detail and r == s.sel then
			table.insert(rows, detail(s, tr, span))
		end
	end
	table.insert(out, ui.col(rows, { key = "wf", gap = "none" }))
	return out
end

-- Search tab ---------------------------------------------------------------

local function queryLine(s: State): Node
	if s.editing == "q" then
		return inputNode(
			s,
			'TraceQL, e.g. { resource.service.name = "api" && status = error }; Enter searches',
			"TraceQL"
		)
	end
	return ui.text({ ui.span("TraceQL ", "muted"), ui.span(s.q, "mono"), ui.span("   / edit", "muted") }, {
		key = "input",
		actions = { click = "edit" },
	})
end

local function rangeLine(s: State, env: Env.Env): Node
	local spans: { SpanLike } = {
		ui.span(Range.describe(s.from, s.to), "accent"),
		ui.span(string.format("  limit %d", s.limit), "muted"),
	}
	if s.searched_ms and s.hits then
		local n = #(s.hits :: { Tempo.SearchHit })
		table.insert(spans, ui.span(string.format("  %d trace%s", n, if n == 1 then "" else "s"), "muted"))
		local age = math.max(0, math.floor((env.now_ms - (s.searched_ms :: number)) / 1000))
		table.insert(spans, ui.span(string.format(", searched %ds ago", age), "muted"))
	end
	return ui.text(spans, { key = "range" })
end

local function tagChips(s: State): { Node }
	local out: { Node } = {}
	local tags = s.tags
	if tags == nil or #tags == 0 then
		return out
	end
	local items: { Node } = { ui.text({ ui.span("add a condition:", "muted") }, { key = "lbl" }) }
	local n = 0
	for _, tag in tags do
		if (tag.scope == "intrinsic" and not INTRINSIC_CHIPS[tag.name]) or n >= MAX_TAG_CHIPS then
			continue
		end
		n += 1
		local name = State.tagName(tag)
		table.insert(items, chip(name, "tag=" .. name, "g" .. n, if name == s.tag then "info" else "neutral"))
	end
	table.insert(out, ui.row(items, { key = "tags", wrap = true, align = "center" }))
	if s.tag then
		local values = s.values
		local vitems: { Node } = { ui.text({ ui.span((s.tag :: string) .. " =", "muted") }, { key = "lbl" }) }
		if values == nil then
			table.insert(vitems, ui.muted("loading values...", { key = "wait" }))
		elseif #values == 0 then
			table.insert(vitems, ui.muted("no values in the recent blocks", { key = "none" }))
		else
			for i, v in values do
				if i > MAX_VALUE_CHIPS then
					break
				end
				table.insert(vitems, chip(v, "value=" .. i, "v" .. i, "accent"))
			end
		end
		table.insert(out, ui.row(vitems, { key = "values", wrap = true, align = "center" }))
	end
	return out
end

local function hitRow(s: State, i: number, hit: Tempo.SearchHit): Node
	local spans: { SpanLike } = {
		ui.span(if hit.start_ms then Range.formatMs(hit.start_ms :: number) .. "  " else "", "muted"),
		ui.span((hit.root_service or "<root span not yet received>") .. " ", "strong"),
		ui.span(hit.root_name or ""),
	}
	if hit.duration_ms then
		table.insert(spans, ui.span("  " .. Format.text(hit.duration_ms, "ms"), "accent"))
	end
	if hit.matched then
		table.insert(spans, ui.span(string.format("  %d matched", hit.matched :: number), "muted"))
	end
	if hit.errors > 0 then
		table.insert(
			spans,
			ui.span(string.format("  %d error%s", hit.errors, if hit.errors == 1 then "" else "s"), "error")
		)
	end
	table.insert(spans, ui.span("  " .. Ids.short(hit.trace_id), "muted"))
	local class = "tg-tr-hit" .. (if i == s.search_sel then " is-sel" else "")
	return ui.el("div", {
		key = "h" .. i,
		class = class,
		actions = { click = "hit=" .. i },
	}, { ui.text(spans, { key = "t", wrap = "none", truncate = "end" }) })
end

local function searchTab(s: State, env: Env.Env): { Node }
	local out: { Node } = { queryLine(s), rangeLine(s, env) }
	for _, n in tagChips(s) do
		table.insert(out, n)
	end
	if s.search_error then
		table.insert(out, errorLine(s.search_error :: QueryError, "serr", s.hits ~= nil))
	end
	local hits = s.hits
	if hits == nil then
		if State.loading(s, "search") then
			table.insert(out, ui.muted("Searching...", { key = "swait" }))
		end
		return out
	end
	if #hits == 0 then
		table.insert(out, ui.muted("No traces matched in this range.", { key = "none" }))
		return out
	end
	local rows: { Node } = {}
	for i, hit in hits do
		rows[i] = hitRow(s, i, hit)
	end
	table.insert(out, ui.col(rows, { key = "hits", gap = "none" }))
	return out
end

local HINTS: { [string]: string } = {
	trace = "j/k move  h/l fold  space fold  enter detail  e/E errors  p parent  / id  y/Y copy  tab search  r reload  c context",
	search = "j/k move  enter open  o new block  / TraceQL  1-9 range  [ ] shift  -/+ zoom  tab trace  r search  c context",
}

function M.view(s: State, env: Env.Env): Effect.View
	local children: { Node } = { header(s) }
	for i, p in s.config_problems do
		table.insert(children, ui.text({ ui.span("config " .. p, "warning") }, { key = "cp" .. i }))
	end
	if s.problem then
		table.insert(children, ui.text({ ui.span(s.problem :: string, "error") }, { key = "problem" }))
		return { main = ui.col(children, { role = "tern-grafana.trace" }) }
	end
	if s.note then
		table.insert(children, ui.text({ ui.span(s.note :: string, "muted") }, { key = "note" }))
	end
	local body: { Node } = if s.tab == "trace" then traceTab(s) else searchTab(s, env)
	for _, n in body do
		table.insert(children, n)
	end
	return {
		main = ui.col(children, { role = "tern-grafana.trace" }),
		dock = ui.col({ ui.text({ ui.span(HINTS[s.tab], "muted") }, { key = "keys" }) }, { key = "dock" }),
	}
end

return M
