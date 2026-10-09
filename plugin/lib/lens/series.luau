--!strict
-- Shared by the lenses that show PromQL results (promtool query, curl): the
-- series model, the Prometheus JSON value reader (promtool `-o json` prints
-- the same `model.Value` shapes as the HTTP API's `data.result`), sparks, and
-- the result body: a per-series spark grid for matrices, a table for
-- instant vectors, one number for scalars, with Show all and Graph/Table
-- chips whose actions carry the whole view choice.

local Format = require("../units/format")
local Frame = require("../frame/types")
local Grid = require("../render/grid")
local Lttb = require("../time/lttb")
local Range = require("../time/range")
local TableView = require("../render/table")
local ui = require("../ui")

type Node = ui.Node

export type Labels = { [string]: string }

export type Series = { labels: Labels, times: { number }, values: { number } }

export type Kind = "vector" | "matrix" | "scalar"

local M = {}

-- Bars in one spark; a spark bar is 4 px, so 60 fit a narrow pane.
M.MAX_SPARK = 60
-- Rows shown before "Show all", and the hard cap behind it.
M.MAX_ROWS = 50
M.MAX_ALL_ROWS = 500

-- Values ------------------------------------------------------------------------------

-- model.SampleValue.String() and the API's sample strings: strconv 'f'
-- formatting, NaN, +Inf, -Inf.
function M.sampleValue(text: string): number?
	if text == "NaN" then
		return 0 / 0
	elseif text == "+Inf" then
		return math.huge
	elseif text == "-Inf" then
		return -math.huge
	elseif string.match(text, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*$") then
		return tonumber(text)
	end
	return nil
end

-- Unix seconds (model.Time.String(), or a JSON number) to epoch ms.
function M.secondsToMs(v: any): number?
	local n = if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
	if n == nil or n ~= n then
		return nil
	end
	return math.floor(n * 1000 + 0.5)
end

-- A JSON label object; nil when anything in it is not a string.
function M.stringLabels(v: any): Labels?
	if type(v) ~= "table" then
		return nil
	end
	local out: Labels = {}
	for k, val in v do
		if type(k) ~= "string" or type(val) ~= "string" then
			return nil
		end
		out[k] = val
	end
	return out
end

local function jsonSample(pair: any): (number?, number?)
	if type(pair) ~= "table" or type(pair[2]) ~= "string" then
		return nil, nil
	end
	local t = M.secondsToMs(pair[1])
	local v = M.sampleValue(pair[2])
	if t == nil or v == nil then
		return nil, nil
	end
	return t, v
end

-- A decoded Prometheus value: `[t, "v"]` (scalar) or a list of
-- `{metric, value}` (vector) / `{metric, values}` (matrix). Returns the kind
-- (nil when nothing was read), the series, and how many entries could not be
-- read (native histograms have no plain value).
function M.readJson(doc: any): (Kind?, { Series }, number)
	local series: { Series } = {}
	if type(doc) ~= "table" then
		return nil, series, 1
	end
	if type(doc[1]) == "number" then
		local t, v = jsonSample(doc)
		if t and v then
			table.insert(series, { labels = {}, times = { t }, values = { v } })
			return "scalar", series, 0
		end
		return nil, series, 1
	end
	local kind: Kind? = nil
	local unparsed = 0
	for _, entry in doc do
		local labels = if type(entry) == "table" then M.stringLabels(entry.metric) else nil
		if labels == nil then
			unparsed += 1
			continue
		end
		if type(entry.values) == "table" then
			local s: Series = { labels = labels, times = {}, values = {} }
			for _, pair in entry.values do
				local t, v = jsonSample(pair)
				if t and v then
					table.insert(s.times, t)
					table.insert(s.values, v)
				end
			end
			table.insert(series, s)
			kind = "matrix"
		elseif type(entry.value) == "table" then
			local t, v = jsonSample(entry.value)
			if t and v then
				table.insert(series, { labels = labels, times = { t }, values = { v } })
				if kind ~= "matrix" then
					kind = "vector"
				end
			else
				unparsed += 1
			end
		else
			unparsed += 1
		end
	end
	return kind, series, unparsed
end

-- Spark -----------------------------------------------------------------------------

export type SparkBar = { value: number?, title: string }

local function finite(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

-- At most `maxBars` bars (LTTB keeps the shape; a gap-heavy series is then
-- thinned evenly). Tern scales bars to the tallest, so values are mapped
-- onto 0.1..1 of the series' own min..max: a flat series at 1000 and one
-- moving 1000..1001 both stay readable. A series that never changes has no
-- shape to show: all zeros draws flat 1 px stubs (Tern's look for zero), any
-- other constant draws flat full-height bars, because Tern scales every
-- spark to its own tallest bar and no value can draw a flat mid-level line;
-- the Last/Min/Max columns carry the level. Missing samples (NaN, Inf) draw
-- as stubs.
function M.spark(times: { number }, values: { number }, maxBars: number?): { SparkBar }
	local limit = math.max(2, maxBars or M.MAX_SPARK)
	local t, v = Lttb.downsample(times, values, limit, Frame.NULL)
	local n = #t
	local picked: { number } = {}
	if n > limit then
		for i = 1, limit do
			picked[i] = math.floor((i - 1) * (n - 1) / (limit - 1)) + 1
		end
	else
		for i = 1, n do
			picked[i] = i
		end
	end
	local lo, hi = math.huge, -math.huge
	for _, i in picked do
		local x = v[i]
		if type(x) == "number" and finite(x) then
			lo = math.min(lo, x)
			hi = math.max(hi, x)
		end
	end
	local bars: { SparkBar } = table.create(#picked)
	for k, i in picked do
		local x = v[i]
		local when = Range.formatMs(t[i])
		if type(x) == "number" and finite(x) then
			local h = if hi > lo then 0.1 + 0.9 * (x - lo) / (hi - lo) elseif x == 0 then 0 else 1
			bars[k] = { value = h, title = Format.text(x) .. " at " .. when }
		else
			bars[k] =
				{ value = nil, title = (if type(x) == "number" then Format.text(x) else "no value") .. " at " .. when }
		end
	end
	return bars
end

-- Names -------------------------------------------------------------------------------

function M.seriesName(labels: Labels): string
	local name = (labels.__name__ or "") .. Frame.formatLabels(labels)
	return if name == "" then "{}" else name
end

-- Labels (`__name__` included) with the same value in every series; empty for
-- fewer than two series, where nothing is common to drop.
function M.commonLabels(series: { Series }): Labels
	local common: Labels = {}
	if #series < 2 then
		return common
	end
	for k, v in series[1].labels do
		common[k] = v
	end
	for i = 2, #series do
		local labels = series[i].labels
		for k, v in common do
			if labels[k] ~= v then
				common[k] = nil
			end
		end
	end
	return common
end

-- The series name without the labels every series shares (Grafana's legend
-- does the same), so rows read by what tells them apart; the full name when
-- nothing is left.
function M.distinctName(labels: Labels, common: Labels): string
	local rest: Labels = {}
	local any = false
	for k, v in labels do
		if common[k] ~= v then
			rest[k] = v
			any = true
		end
	end
	return M.seriesName(if any then rest else labels)
end

-- View state --------------------------------------------------------------------------

-- Carried whole in every action ("v=table:1;all:1"), so a click on a
-- rehydrated lens lands on the same view.
export type ViewState = { table: boolean, all: boolean }

function M.defaultView(): ViewState
	return { table = false, all = false }
end

function M.encodeView(vs: ViewState): string
	local parts: { string } = {}
	if vs.table then
		table.insert(parts, "table:1")
	end
	if vs.all then
		table.insert(parts, "all:1")
	end
	return table.concat(parts, ";")
end

-- Unknown fields are ignored (actions from another plugin version).
function M.decodeView(s: string): ViewState
	local vs = M.defaultView()
	for part in string.gmatch(s, "[^;]+") do
		local k, v = string.match(part, "^([^:]+):(.*)$")
		if k == "table" then
			vs.table = v == "1"
		elseif k == "all" then
			vs.all = v == "1"
		end
	end
	return vs
end

-- The `v=...` action that switches to `vs`.
function M.viewAction(vs: ViewState): string
	return "v=" .. M.encodeView(vs)
end

-- Rendering -----------------------------------------------------------------------------

function M.chip(text: string, action: string, active: boolean, title: string?): Node
	return ui.badge(text, if active then "accent" else "neutral", { actions = { click = action }, title = title })
end

function M.timeText(ms: number?): string
	return if ms then Range.formatMs(ms) .. " UTC" else "?"
end

-- Earliest and latest sample time over all series.
function M.dataSpan(series: { Series }): (number?, number?)
	local lo, hi = math.huge, -math.huge
	for _, s in series do
		for _, t in s.times do
			lo = math.min(lo, t)
			hi = math.max(hi, t)
		end
	end
	if lo > hi then
		return nil, nil
	end
	return lo, hi
end

function M.countText(n: number, one: string, many: string): string
	return string.format("%d %s", n, if n == 1 then one else many)
end

function M.shownCount(total: number, vs: ViewState): number
	return math.min(total, if vs.all then M.MAX_ALL_ROWS else M.MAX_ROWS)
end

-- "N more" with a Show all chip, or the hard-cap note once everything allowed
-- is shown.
function M.overflow(total: number, shown: number, vs: ViewState, out: { Node })
	if total <= shown then
		return
	end
	if not vs.all then
		table.insert(
			out,
			ui.row({
				ui.muted(string.format("%d more", total - shown)),
				M.chip(string.format("Show all %d", total), M.viewAction({ table = vs.table, all = true }), false),
			})
		)
	else
		table.insert(out, ui.muted(string.format("... %d more (Raw shows everything)", total - shown)))
	end
end

-- The Graph/Table chips a matrix offers.
function M.viewChips(vs: ViewState, tools: { Node })
	table.insert(tools, M.chip("Graph", M.viewAction({ table = false, all = vs.all }), not vs.table))
	table.insert(tools, M.chip("Table", M.viewAction({ table = true, all = vs.all }), vs.table))
end

local function rangeGrid(series: { Series }, shown: number, common: Labels): Node
	local columns: { Grid.Column } = {
		{ head = "Series" },
		{ head = "Trend" },
		{ head = "Last", numeric = true },
		{ head = "Min", numeric = true },
		{ head = "Max", numeric = true },
	}
	local rows: { Grid.Row } = table.create(shown)
	for i = 1, shown do
		local s = series[i]
		local lo, hi = math.huge, -math.huge
		for _, v in s.values do
			if finite(v) then
				lo = math.min(lo, v)
				hi = math.max(hi, v)
			end
		end
		local n = #s.values
		local full = M.seriesName(s.labels)
		local name = M.distinctName(s.labels, common)
		rows[i] = {
			key = "s" .. i,
			cells = {
				{ k = "text", p = { spans = { { t = name } }, title = full } },
				{ k = "chart", p = { kind = "spark", series = M.spark(s.times, s.values), token = "accent" } },
				Grid.text(if n > 0 then Format.text(s.values[n]) else TableView.NO_VALUE),
				Grid.text(if lo <= hi then Format.text(lo) else TableView.NO_VALUE),
				Grid.text(if lo <= hi then Format.text(hi) else TableView.NO_VALUE),
			},
		}
	end
	return Grid.grid("series", columns, rows, "tern-grafana.lens-series")
end

local function framesOf(series: { Series }, shown: number): { Frame.Frame }
	local frames: { Frame.Frame } = table.create(shown)
	for i = 1, shown do
		local s = series[i]
		frames[i] = Frame.timeSeries(s.labels, s.times, s.values)
	end
	return frames
end

-- The result body appended to `out`: one number for a scalar, a spark grid
-- (or, with `vs.table`, a table) for a matrix, a table for a vector, each
-- capped with Show all. `common` are the labels the grid leaves out of names.
function M.body(kind: Kind, series: { Series }, vs: ViewState, common: Labels, out: { Node })
	if kind == "scalar" then
		local s = series[1]
		table.insert(out, ui.text({ ui.span(Format.text(s.values[1]), "strong num") }, { key = "body" }))
		return
	end
	local shown = M.shownCount(#series, vs)
	if kind == "matrix" and not vs.table then
		table.insert(out, rangeGrid(series, shown, common))
	else
		table.insert(out, TableView.view(framesOf(series, shown), { key = "table", show_time = kind == "matrix" }))
	end
	M.overflow(#series, shown, vs, out)
end

return M
