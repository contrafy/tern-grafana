--!strict
-- The traces panel (public/app/plugins/panel/traces/TracesPanel.tsx, which
-- renders public/app/features/explore/TraceView with the panel's Trace
-- frame): the trace header (root service and operation, trace id, start,
-- duration, services, depth, span count) and the span timeline, one row
-- per span in depth-first order with its service, name, duration and a bar
-- at its offset and width in the trace, colored by service (errors
-- marked). Spans come from lib/trace/frame (Grafana's Trace frame) and
-- lib/trace/model (tree, clock skew, critical path), drawn with the trace
-- block's waterfall classes (plugin/trace.css, lib/trace/view colors).
-- The panel shows the rows that fit its height and counts the rest; a
-- response without a trace frame is Grafana's "No data found in
-- response".

local Assets = require("../render/assets")
local Common = require("./common")
local Env = require("../env")
local Frame = require("../frame/types")
local Ids = require("../trace/ids")
local Model = require("../trace/model")
local Range = require("../time/range")
local TraceFrame = require("../trace/frame")
local TraceTypes = require("../trace/types")
local TraceView = require("../trace/view")
local ui = require("../ui")

type Env = Env.Env
type Frame = Frame.Frame
type Node = ui.Node
type Trace = TraceTypes.Trace
type Span = TraceTypes.Span

local M = {}

M.types = { "traces" }

-- Row height in px of one span row (a text line with padding).
M.ROW_PX = 22
-- Header, legend and axis.
M.CHROME_PX = 96
M.MAX_INDENT = 12

function M.supports(_: any, _: Env): (boolean, string?)
	return true, nil
end

-- The trace in the frames (the first Trace frame with spans), or nil.
function M.trace(frames: { Frame }, env: Env): Trace?
	for _, f in frames do
		local pref = if f.meta then (f.meta :: any).preferredVisualisationType else nil
		if pref ~= nil and pref ~= "trace" then
			continue
		end
		local raw = TraceFrame.spans(f, env)
		if raw and #raw > 0 then
			return Model.build(raw, nil)
		end
	end
	return nil
end

local function cell(key: string, class: string, props: { [string]: any }, children: { Node }?): Node
	props.key = key
	props.class = class
	return ui.el("div", props, children)
end

local function header(t: Trace, opts: Common.Options): Node
	local title = ui.text({ ui.span(t.root_service .. ": ", "strong"), ui.span(t.root_name) }, { key = "title" })
	local maxDepth = 0
	for _, s in t.spans do
		maxDepth = math.max(maxDepth, s.depth + 1)
	end
	local facts = ui.text({
		ui.span("Trace ID ", "muted"),
		ui.span(Ids.short(t.trace_id), "mono"),
		ui.span("  Start time ", "muted"),
		ui.span(Range.formatMs(t.start_ms, opts.offset_min)),
		ui.span("  Duration ", "muted"),
		ui.span(TraceView.duration(t.duration_ns)),
		ui.span("  Services ", "muted"),
		ui.span(tostring(#t.services)),
		ui.span("  Depth ", "muted"),
		ui.span(tostring(maxDepth)),
		ui.span("  Total spans ", "muted"),
		ui.span(tostring(#t.spans)),
	}, { key = "facts" })
	return ui.col({ title, facts }, { key = "head", gap = "none" })
end

local function legend(t: Trace): Node
	local items: { Node } = {}
	for i, svc in t.services do
		local children: { Node } = {
			ui.el("span", { key = "w", class = "tg-tr-sw " .. TraceView.colorClass(i) }),
			ui.el("span", { key = "n", text = string.format("%s (%d)", svc.name, svc.spans) }),
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

local function axis(t: Trace): Node
	local ticks: { Node } = {}
	for k = 0, 3 do
		ticks[k + 1] =
			cell("t" .. k, "tg-tr-tick", { basis = 0.25, shrink = 0, text = TraceView.duration(t.duration_ns * k / 4) })
	end
	return cell("axis", "tg-tr-row tg-tr-axis", {}, {
		cell("n", "tg-tr-name", { basis = TraceView.NAME_BASIS, shrink = 0, text = "Service & Operation" }),
		cell("d", "tg-tr-dur", { min = { w = "9ch" }, shrink = 0, text = "Duration" }),
		cell("k", "tg-tr-track", { grow = 1, basis = 0 }, ticks),
	})
end

local function row(t: Trace, span: Span): Node
	local indent = string.rep("  ", math.min(span.depth, M.MAX_INDENT))
	local glyph = if #span.children == 0 then "  " else "- "
	local left, width = Model.fractions(t, span)
	local barClass = "tg-tr-bar "
		.. TraceView.colorClass(span.service_index)
		.. (if span.error then " tg-tr-err" else "")
	return cell("r" .. span.index, "tg-tr-row" .. (if span.error then " is-err" else ""), {}, {
		cell("n", "tg-tr-name", { basis = TraceView.NAME_BASIS, shrink = 0 }, {
			ui.text({
				ui.span(indent .. glyph, "muted"),
				ui.span(span.raw.service .. " ", "muted"),
				ui.span(span.raw.name, if span.error then "error" else nil),
			}, { key = "t", wrap = "none", truncate = "end" }),
		}),
		cell("d", "tg-tr-dur", { min = { w = "9ch" }, shrink = 0, text = TraceView.duration(span.dur_ns) }),
		cell("k", "tg-tr-track", { grow = 1, basis = 0 }, {
			cell("sp", "tg-tr-gap", { basis = left, shrink = 0 }),
			cell("b", barClass, { basis = width, shrink = 0 }),
		}),
	})
end

function M.view(panel: any, frames: { Frame }, env: Env, opts: Common.Options): (Node, Assets.Assets?)
	local maybe = M.trace(frames, env)
	if maybe == nil then
		if not Common.hasData(frames) then
			return Common.noData(panel, env, opts.key), nil
		end
		return ui.muted("No data found in response", { key = opts.key }), nil
	end
	local t = maybe :: Trace
	local height = if opts.size then opts.size.h else 300
	local fit = math.max(3, math.floor((height - M.CHROME_PX) / M.ROW_PX))
	local rows: { Node } = { axis(t) }
	for i, span in t.spans do
		if i > fit then
			break
		end
		table.insert(rows, row(t, span))
	end
	local children: { Node } = { header(t, opts), legend(t), ui.col(rows, { key = "wf", gap = "none" }) }
	if #t.spans > fit then
		table.insert(children, ui.muted(string.format("%d more spans", #t.spans - fit), { key = "more" }))
	end
	return ui.col(children, { key = opts.key, gap = "xs" }), nil
end

return M
