--!strict
-- Shared panel view pieces: the options every panel view takes, the panel
-- module interface (one file per panel type, registered in registry.luau),
-- Grafana's no-data message, tone -> span token, and the stat sparkline as
-- Tern's native `chart` spark.

local Assets = require("../render/assets")
local DsTypes = require("../datasources/types")
local Env = require("../env")
local Frame = require("../frame/types")
local Json = require("./json")
local Lttb = require("../time/lttb")
local Range = require("../time/range")
local Thresholds = require("../units/thresholds")
local TransportTypes = require("../transport/types")
local TsData = require("../render/ts_data")
local ui = require("../ui")

type Env = Env.Env
type Node = ui.Node

export type Options = {
	-- Node key and asset key prefix.
	key: string,
	-- Keyboard cursor time (ms) for time series read-outs.
	cursor: number?,
	theme: Thresholds.Theme?,
	-- Panel size in px (time series SVG design size).
	width: number?,
	height: number?,
	from_ms: number?,
	to_ms: number?,
	-- The dashboard timezone for times (Range.offsetAt per value).
	offset_min: Range.Offset?,
	-- Dashboard variable interpolation for text content and titles.
	interpolate: ((string) -> string)?,
	-- Dashboard variable interpolation in Grafana's default format (glob), as
	-- the panel's replaceVariables applies it to field config displayName.
	replace: ((string) -> string)?,
	-- Logs: override the panel's showLabels (the block's labels toggle).
	show_labels: boolean?,
	-- Time series: exemplar markers (lib/frame/prom Exemplar) and the
	-- selected one's index into the chart's drawn exemplars.
	exemplars: { any }?,
	exemplar: number?,
	-- Time series: the dashboard annotations shown on this panel
	-- (lib/dashboard/layers.luau marks, lib/render/svg_annotations Mark).
	annotations: { any }?,
	-- Panel size in px from its gridPos (lib/dashboard/render_png size).
	size: { w: number, h: number }?,
	-- The panel card body's height in px under the card's height cap
	-- (lib/dashboard/view cardHeight), often less than size.h; nil when the
	-- card is not capped (an expanded panel).
	card_height: number?,
	-- Table: the page the user flipped to (1-based; nil is the first).
	page: number?,
	-- Table: the frame the user picked in the frame selector (1-based; nil
	-- is options.frameIndex, else the first).
	frame: number?,
	-- The panel's query range after its own time overrides (timeFrom,
	-- timeShift); from_ms/to_ms carry the same range.
	time: { from_ms: number, to_ms: number }?,
	-- Parsed answers to the module's `requests`, by tag; a tag is absent
	-- until its answer arrives.
	extra: { [string]: any }?,
	-- The dashboard's timezone as written ("", "browser", "utc", IANA).
	timezone: string?,
	-- The decoded panel JSON the rendered `panel` was copied from (only the
	-- title may differ); keys the legacy-migration cache (Registry.view).
	source: any?,
	-- The viewer's local UTC offset (minutes east) at env.now_ms.
	local_offset_min: number?,
	-- Grafana's frontend feature toggles (/api/frontend/settings
	-- featureToggles), e.g. newGauge.
	features: { [string]: boolean }?,
	-- The Grafana's browser URL without a trailing slash: text panel links
	-- and images with rooted paths resolve against it.
	base_url: string?,
}

-- Context for a module's non-datasource requests.
export type RequestContext = {
	time: { from_ms: number, to_ms: number },
	dashboard_uid: string?,
	-- The Grafana's data sources (frontend settings); nil until they are known.
	datasources: { DsTypes.Datasource }?,
}

-- dashboards, alerts and annotations go to the dashboard's Grafana (Grafana's
-- own panels read its API); external is a plain unauthenticated GET whose
-- request.path is the absolute http(s) URL.
export type Signal = "dashboards" | "alerts" | "annotations" | "external"

export type PanelRequest = { tag: string, signal: Signal, request: TransportTypes.Request }

-- One native panel type (local://PANELS2.md). `supports` and `view` are
-- required; the rest are optional:
-- - queries: false for panels that need no datasource query (text, clock in
--   input mode, dashlist); `view` then gets no frames;
-- - requests/parse: Grafana API or external fetches; parse's result reaches
--   `view` as opts.extra[tag];
-- - liveMs: redraw period for live panels (clock), no re-query.
export type PanelModule = {
	types: { string },
	supports: (panel: any, env: Env) -> (boolean, string?),
	view: (panel: any, frames: { Frame.Frame }, env: Env, opts: Options) -> (Node, Assets.Assets?),
	queries: ((panel: any) -> boolean)?,
	requests: ((panel: any, ctx: RequestContext, env: Env) -> { PanelRequest })?,
	parse: ((panel: any, tag: string, response: TransportTypes.Response, env: Env) -> any)?,
	liveMs: ((panel: any, env: Env) -> number?)?,
	-- Grafana's PanelPlugin.setNoPadding(): PanelChrome gives the panel its
	-- whole box less the 1 px border (and the title header), no padding.
	no_padding: boolean?,
}

local M = {}

-- PanelChrome's header above a titled panel's content, px: 40 with
-- newPanelPadding (a Grafana 12 feature toggle, always on in 13), else 32.
function M.headerPx(opts: Options): number
	local features = opts.features
	return if features and features.newPanelPadding then 40 else 32
end

-- Whether any frame holds a value (PanelDataErrorView hasData).
function M.hasData(frames: { Frame.Frame }): boolean
	for _, f in frames do
		for _, field in f.fields do
			if #field.values > 0 then
				return true
			end
		end
	end
	return false
end

-- PanelDataErrorView's message for a panel without data: the field
-- defaults' noValue, else "No data".
function M.noDataText(panel: any, env: Env): string
	local nv = Json.str(env, Json.path(env, panel, "fieldConfig", "defaults", "noValue"))
	return nv or "No data"
end

-- PanelDataErrorView: the message centered in the panel's box, in the
-- secondary text color (dashboard.css tg-nodata).
function M.noData(panel: any, env: Env, key: string): Node
	return {
		k = "el",
		p = { tag = "div", key = key, class = "tg-nodata" },
		c = { ui.text({ ui.span(M.noDataText(panel, env), "muted") }) },
	}
end

-- Most bars in a stat sparkline (a spark bar is 4 px wide).
M.SPARK_POINTS = 60

-- Span style token for a tone ("" for neutral).
function M.token(tone: Thresholds.Tone): string
	if tone == "success" or tone == "warning" or tone == "error" or tone == "info" or tone == "accent" then
		return tone
	elseif tone == "pending" then
		return "accent"
	elseif tone == "muted" then
		return "muted"
	end
	return ""
end

-- A class token for a tone (panels.css: tgp-<tone>).
function M.toneClass(tone: Thresholds.Tone): string
	return "tgp-" .. tone
end

export type SparkOptions = {
	-- The value's tone; nil draws the accent color.
	tone: Thresholds.Tone?,
	-- The field's config: min, max, decimals and noValue (getYRange).
	min: number?,
	max: number?,
	decimals: number?,
	no_value: string?,
	-- The panel's time range and the time field's sample interval: the
	-- sparkline spans the range, with gaps where samples are missing.
	from_ms: number?,
	to_ms: number?,
	interval: number?,
}

-- guessDecimals: the digits after the point of the number as written.
local function guessDecimals(n: number): number
	local frac = string.match(tostring(n), "%.(%d+)")
	return if frac then #frac else 0
end

-- roundDecimals (Math.round at `decimals` places).
local function roundDecimals(n: number, decimals: number): number
	local f = 10 ^ decimals
	return math.floor(n * f + 0.5) / f
end

-- Sparkline's getYRange: the samples' range widened by the config's min,
-- max and numeric noValue; when it rounds to one value at the field's
-- decimals, a flat series sits at the bottom of [v, 2v] ([0, 1] for zero)
-- and a negative one at the top of [2v, v].
local function sparkRange(lo: number, hi: number, o: SparkOptions): (number, number)
	lo = math.min(lo, o.min or math.huge)
	hi = math.max(hi, o.max or -math.huge)
	local nv = if o.no_value then tonumber(o.no_value) else nil
	if nv and nv == nv then
		lo, hi = math.min(lo, nv), math.max(hi, nv)
	end
	local decimals = o.decimals or math.max(guessDecimals(lo), guessDecimals(hi))
	local rlo, rhi = roundDecimals(lo, decimals), roundDecimals(hi, decimals)
	if rlo ~= rhi then
		return lo, hi
	elseif rlo == 0 then
		return 0, 1
	elseif rlo < 0 then
		return rlo * 2, rlo
	end
	return rlo, rlo * 2
end

-- A sparkline of `values` (NULL/NaN as gaps) as Grafana's stat draws it:
-- across the panel's time range, with nulls where samples are more than
-- the interval apart (applyNullInsertThreshold), downsampled to
-- SPARK_POINTS and scaled to getYRange (a Tern spark grows bars from zero,
-- which would flatten a series far from 0).
function M.spark(key: string, values: { any }, times: { any }?, o: SparkOptions): Node?
	local ts: { number }, vs: { any }
	local count = #values
	local dense = times ~= nil and #times == count
	if dense then
		local tt = times :: { any }
		for i = 1, count do
			if type(tt[i]) ~= "number" then
				dense = false
				break
			end
		end
	end
	if dense then
		-- Lttb treats non-finite values as gaps itself and every reader below
		-- goes through Frame.finite, so the column needs no NULL-mapped copy.
		ts, vs = times :: { number }, values
	else
		ts, vs = {}, {}
		for i, v in values do
			local t = if times then times[i] else i
			if type(t) == "number" then
				table.insert(ts, t)
				table.insert(vs, if Frame.finite(v) then v else Frame.NULL)
			end
		end
	end
	if #ts < 2 then
		return nil
	end
	local interval = o.interval
	if dense and interval and interval > 0 then
		local filled
		ts, filled = TsData.insertNulls(ts, { vs }, interval, o.from_ms, o.to_ms)
		vs = filled[1]
	end
	ts, vs = Lttb.downsample(ts, vs, M.SPARK_POINTS, Frame.NULL)
	local lo, hi = math.huge, -math.huge
	for _, v in vs do
		local n = Frame.finite(v)
		if n then
			lo, hi = math.min(lo, n), math.max(hi, n)
		end
	end
	if lo > hi then
		return nil
	end
	lo, hi = sparkRange(lo, hi, o)
	local span = hi - lo
	local series: { { value: number? } } = table.create(#vs)
	for i, v in vs do
		local n = Frame.finite(v)
		-- 5% floor keeps the minimum visible as a bar, not a stub.
		series[i] = if n == nil then {} else { value = 0.05 + 0.95 * math.clamp((n - lo) / span, 0, 1) }
	end
	local token = if o.tone then M.token(o.tone) else ""
	return {
		k = "chart",
		p = { key = key, kind = "spark", token = if token ~= "" then token else "accent", series = series },
	}
end

return M
