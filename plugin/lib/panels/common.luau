--!strict
-- Shared panel view pieces: the options every panel view takes, the panel
-- module interface (one file per panel type, registered in registry.luau),
-- Grafana's no-data message, tone -> span token, and the stat sparkline as
-- Tern's native `chart` spark.

local Assets = require("../render/assets")
local Env = require("../env")
local Frame = require("../frame/types")
local Json = require("./json")
local Lttb = require("../time/lttb")
local Thresholds = require("../units/thresholds")
local TransportTypes = require("../transport/types")
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
	-- Minutes east of UTC for times.
	offset_min: number?,
	-- Dashboard variable interpolation for text content and titles.
	interpolate: ((string) -> string)?,
	-- Logs: override the panel's showLabels (the block's labels toggle).
	show_labels: boolean?,
	-- Time series: exemplar markers (lib/frame/prom Exemplar) and the
	-- selected one's index into the chart's drawn exemplars.
	exemplars: { any }?,
	exemplar: number?,
	-- Panel size in px from its gridPos (lib/dashboard/render_png size).
	size: { w: number, h: number }?,
	-- The panel's query range after its own time overrides (timeFrom,
	-- timeShift); from_ms/to_ms carry the same range.
	time: { from_ms: number, to_ms: number }?,
	-- Parsed answers to the module's `requests`, by tag; a tag is absent
	-- until its answer arrives.
	extra: { [string]: any }?,
	-- The dashboard's timezone as written ("", "browser", "utc", IANA).
	timezone: string?,
	-- The viewer's local UTC offset (minutes east) at env.now_ms.
	local_offset_min: number?,
	-- Grafana's frontend feature toggles (/api/frontend/settings
	-- featureToggles), e.g. newGauge.
	features: { [string]: boolean }?,
}

-- Context for a module's non-datasource requests.
export type RequestContext = {
	time: { from_ms: number, to_ms: number },
	dashboard_uid: string?,
	-- The Grafana's data sources (frontend settings); nil until they are known.
	datasources: { { uid: string, type: string, name: string, is_default: boolean, manage_alerts: boolean? } }?,
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
}

local M = {}

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

function M.noData(panel: any, env: Env, key: string): Node
	return ui.muted(M.noDataText(panel, env), { key = key })
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

-- A sparkline of `values` (NULL/NaN as gaps), downsampled to SPARK_POINTS
-- and scaled to the series' own min..max like Grafana's sparkline axis (a
-- Tern spark grows bars from zero, which would flatten a series far from 0).
function M.spark(
	key: string,
	values: { any },
	times: { any }?,
	tone: Thresholds.Tone?,
	min: number?,
	max: number?
): Node?
	local ts: { number } = {}
	local vs: { any } = {}
	for i, v in values do
		local t = if times then times[i] else i
		if type(t) == "number" then
			table.insert(ts, t)
			table.insert(vs, if Frame.finite(v) then v else Frame.NULL)
		end
	end
	if #ts < 2 then
		return nil
	end
	ts, vs = Lttb.downsample(ts, vs, M.SPARK_POINTS, Frame.NULL)
	local lo, hi = min, max
	if lo == nil or hi == nil then
		for _, v in vs do
			local n = Frame.finite(v)
			if n then
				lo = if lo == nil or n < lo then n else lo
				hi = if hi == nil or n > hi then n else hi
			end
		end
	end
	if lo == nil or hi == nil then
		return nil
	end
	local span = (hi :: number) - (lo :: number)
	local series: { { value: number? } } = table.create(#vs)
	for i, v in vs do
		local n = Frame.finite(v)
		if n == nil then
			series[i] = {}
		elseif span <= 0 then
			series[i] = { value = 1 }
		else
			-- 5% floor keeps the minimum visible as a bar, not a stub.
			series[i] = { value = 0.05 + 0.95 * math.clamp((n - (lo :: number)) / span, 0, 1) }
		end
	end
	local token = if tone then M.token(tone) else ""
	return {
		k = "chart",
		p = { key = key, kind = "spark", token = if token ~= "" then token else "accent", series = series },
	}
end

return M
