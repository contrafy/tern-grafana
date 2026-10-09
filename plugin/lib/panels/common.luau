--!strict
-- Shared panel view pieces: the options every panel view takes, tone ->
-- span token, and the stat sparkline as Tern's native `chart` spark.

local Frame = require("../frame/types")
local Lttb = require("../time/lttb")
local Thresholds = require("../units/thresholds")
local ui = require("../ui")

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
}

local M = {}

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
