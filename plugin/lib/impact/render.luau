--!strict
-- View of the impact watch: what ran and when, then one row per signal and
-- series with a before spark, an after spark (same scale) and the change of
-- the mean, toned by whether it moved the bad way.

local Delta = require("./delta")
local Env = require("../env")
local Format = require("../units/format")
local State = require("./state")
local Step = require("../time/step")
local ui = require("../ui")

type Node = ui.Node
type State = State.State

local M = {}

local TOKEN: { [string]: string } = {
	success = "success",
	warning = "warning",
	error = "error",
	info = "info",
	muted = "muted",
}

local function ago(ms: number): string
	return Step.formatDuration(math.max(0, math.floor(ms / 1000)) * 1000)
end

-- Both sparks on one scale so the bars compare.
local function sparks(r: State.SeriesResult, tone: string): (Node, Node)
	local lo, hi = math.huge, -math.huge
	for _, list in { r.before, r.after } do
		for b = 1, State.SPARK_POINTS do
			local v = list[b]
			if v ~= nil then
				lo = math.min(lo, v)
				hi = math.max(hi, v)
			end
		end
	end
	local function series(list: { number? }): { { value: number? } }
		local out: { { value: number? } } = table.create(State.SPARK_POINTS)
		for b = 1, State.SPARK_POINTS do
			local v = list[b]
			if v == nil or lo > hi then
				out[b] = {}
			elseif hi <= lo then
				out[b] = { value = 0.5 }
			else
				out[b] = { value = 0.05 + 0.95 * (v - lo) / (hi - lo) }
			end
		end
		return out
	end
	return { k = "chart", p = { key = "before", kind = "spark", token = "muted", series = series(r.before) } }, {
		k = "chart",
		p = { key = "after", kind = "spark", token = TOKEN[tone] or "accent", series = series(r.after) },
	}
end

local function value(v: number?, unit: string?): string
	if v == nil then
		return "-"
	end
	return Format.text(v, unit)
end

local function seriesRows(row: State.Row, r: State.SeriesResult, key: string): { Node }
	local c = r.cmp
	local before, after = sparks(r, c.tone)
	local change: string
	if c.before.n == 0 then
		change = "no data before"
	elseif c.after.n == 0 then
		change = "waiting for data"
	else
		change = Delta.formatPct(c)
	end
	local out: { Node } = {}
	if r.name ~= "" then
		table.insert(out, ui.text({ ui.span(r.name, "mono") }, { key = key .. "n" }))
	end
	table.insert(
		out,
		ui.row({
			ui.text({ ui.span("before", "muted") }),
			before,
			ui.text({ ui.span(value(c.before.mean, row.signal.unit), "muted") }),
		}, { key = key .. "b" })
	)
	table.insert(
		out,
		ui.row({
			ui.text({ ui.span("after", "muted") }),
			after,
			ui.text({ ui.span(value(c.after.mean, row.signal.unit)) }),
			ui.badge(change, if c.delta == nil then "muted" else c.tone),
		}, { key = key .. "a" })
	)
	return out
end

local function signalBlock(s: State, i: number, row: State.Row): Node
	local head: { Node } = {
		ui.text({ ui.span(row.signal.name, "strong") }),
	}
	if row.signal.guessed then
		table.insert(head, ui.badge("guessed", "warning", { title = row.signal.expr }))
	end
	if row.loading then
		table.insert(head, ui.badge("loading", "accent"))
	end
	local body: { Node } = {
		ui.row(head, { key = "h" }),
		ui.text({ ui.span(row.signal.expr, "muted") }, { key = "x" }),
	}
	if row.error then
		table.insert(body, ui.text({ ui.span(row.error :: string, "error") }, { key = "err" }))
	elseif #row.series == 0 and not row.loading then
		table.insert(body, ui.muted("no data: the query returned no series", { key = "none" }))
	end
	for k, r in row.series do
		for _, node in seriesRows(row, r, "r" .. k) do
			table.insert(body, node)
		end
	end
	if row.more > 0 then
		table.insert(
			body,
			ui.muted(string.format("+%d more series (open in Query to see all)", row.more), { key = "more" })
		)
	end
	-- An `el`: only `el` nodes take a class (the selection outline).
	return ui.el("div", {
		key = "s" .. i,
		class = "tg-im-signal" .. (if s.sel == i then " is-sel" else ""),
		actions = { click = "row=" .. i, dblclick = "open=" .. i },
	}, body)
end

local function header(s: State, env: Env.Env): Node
	local spans: { ui.SpanLike } = {
		ui.span((s.kind or "deploy") .. " ", "strong"),
	}
	if s.vars.service then
		table.insert(spans, ui.span(s.vars.service :: string, "strong"))
		table.insert(spans, ui.span(" "))
	end
	if s.vars.namespace then
		table.insert(spans, ui.span("ns " .. (s.vars.namespace :: string) .. " ", "muted"))
	end
	if s.context then
		table.insert(spans, ui.span("in " .. (s.context :: string) .. "  ", "muted"))
	end
	local w = Step.formatDuration(s.window_ms)
	local status: string
	if s.final then
		status = string.format("final: %s before vs %s after", w, w)
	elseif s.start_ms > 0 then
		local left = s.finish_ms + s.window_ms - env.now_ms
		status = if left > 0
			then string.format("%s before vs after, %s left", w, ago(left))
			else string.format("%s before vs %s after", w, w)
	else
		status = ""
	end
	table.insert(spans, ui.span(status, "muted"))
	return ui.text(spans, { key = "head" })
end

function M.view(s: State, env: Env.Env): (any, any)
	local main: { Node } = { header(s, env) }
	if s.problem then
		table.insert(main, ui.text({ ui.span(s.problem :: string, "warning") }, { key = "problem" }))
	end
	if s.phase == "probing" then
		table.insert(main, ui.muted("Looking for request metrics to guess signals...", { key = "probing" }))
	end
	if s.guessed and #s.rows > 0 then
		table.insert(
			main,
			ui.muted("Guessed from metric names; set impact.signals for exact queries.", { key = "guessnote" })
		)
	end
	local sigs: { Node } = {}
	for i, row in s.rows do
		table.insert(sigs, signalBlock(s, i, row))
	end
	table.insert(main, ui.col(sigs, { key = "sigs" }))
	for k, sk in s.skipped do
		table.insert(
			main,
			ui.text(
				{ ui.span(sk.name .. ": ", "strong"), ui.span("skipped, " .. sk.reason, "muted") },
				{ key = "sk" .. k }
			)
		)
	end
	local hint = "up/down select, enter open in Query, r refresh"
	if s.loaded_ms then
		hint ..= "  (updated " .. ago(env.now_ms - (s.loaded_ms :: number)) .. " ago)"
	end
	return { main = ui.col(main), dock = ui.col({ ui.muted(hint, { key = "hints" }) }) }, nil
end

return M
