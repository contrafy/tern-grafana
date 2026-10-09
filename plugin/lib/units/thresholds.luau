--!strict
-- Grafana thresholds and named colors. Step selection follows
-- packages/grafana-data/src/field/thresholds.ts (getActiveThreshold) and the
-- percent of field/scale.ts; names resolve through the palettes of
-- themes/createVisualizationColors.ts (getColorByName).
--
-- Tone table (a step's severity, not its exact hue):
--   green*                -> success
--   red*                  -> error
--   orange*, yellow*      -> warning
--   blue*                 -> info
--   purple*               -> accent
--   text, missing color   -> neutral
--   transparent           -> muted
--   #hex, rgb(), rgba()   -> by hue with the same families: red [0,15) and [330,360),
--                            orange/yellow [15,70), green [70,165), blue [165,255),
--                            purple [255,330); low chroma -> neutral; alpha 0 -> muted
--   any other name        -> neutral
-- "*" covers the super-light-, light-, semi-dark- and dark- shades. "pending" is
-- never produced: no Grafana color means in-progress.

export type Tone = "success" | "error" | "warning" | "info" | "accent" | "pending" | "muted" | "neutral"
export type Theme = "dark" | "light"
-- `value` is a number, or nil / a JSON null sentinel for the base step.
export type Step = { value: any, color: string }
export type Thresholds = { mode: string?, steps: { Step } }
export type Active = {
	-- 1-based position in `steps`; 0 when there are no steps.
	index: number,
	-- The step's color as written in the dashboard ("" for the fallback).
	name: string,
	-- A CSS color for SVG fills.
	color: string,
	tone: Tone,
	-- Position of the value in min..max, 0 for nil/NaN/-Inf.
	percent: number,
}

local M = {}

local FALLBACK_COLOR = "#808080"

local SHADES = { "super-light-", "light-", "", "semi-dark-", "dark-" }

local HUES: { { name: string, tone: Tone, dark: { string }, light: { string } } } = {
	{
		name = "red",
		tone = "error",
		dark = { "#FFA6B0", "#FF7383", "#F2495C", "#E02F44", "#C4162A" },
		light = { "#FF7383", "#F2495C", "#E02F44", "#C4162A", "#AD0317" },
	},
	{
		name = "orange",
		tone = "warning",
		dark = { "#FFCB7D", "#FFB357", "#FF9830", "#FF780A", "#FA6400" },
		light = { "#FFB357", "#FF9830", "#FF780A", "#FA6400", "#E55400" },
	},
	{
		name = "yellow",
		tone = "warning",
		dark = { "#FFF899", "#FFEE52", "#FADE2A", "#F2CC0C", "#E0B400" },
		light = { "#FFEE52", "#FADE2A", "#F2CC0C", "#E0B400", "#CC9D00" },
	},
	{
		name = "green",
		tone = "success",
		dark = { "#C8F2C2", "#96D98D", "#73BF69", "#56A64B", "#37872D" },
		light = { "#96D98D", "#73BF69", "#56A64B", "#37872D", "#19730E" },
	},
	{
		name = "blue",
		tone = "info",
		dark = { "#C0D8FF", "#8AB8FF", "#5794F2", "#3274D9", "#1F60C4" },
		light = { "#8AB8FF", "#5794F2", "#3274D9", "#1F60C4", "#1250B0" },
	},
	{
		name = "purple",
		tone = "accent",
		dark = { "#DEB6F2", "#CA95E5", "#B877D9", "#A352CC", "#8F3BB8" },
		light = { "#CA95E5", "#B877D9", "#A352CC", "#8F3BB8", "#7C2EA3" },
	},
}

type Named = { dark: string, light: string, tone: Tone }

local NAMED: { [string]: Named } = {
	text = { dark = "rgb(204, 204, 220)", light = "rgba(36, 41, 46, 1)", tone = "neutral" },
	transparent = { dark = "rgba(0,0,0,0)", light = "rgba(255, 255, 255, 0)", tone = "muted" },
}
for _, hue in HUES do
	for i, shade in SHADES do
		NAMED[shade .. hue.name] = { dark = hue.dark[i], light = hue.light[i], tone = hue.tone }
	end
end

function M.color(name: string?, theme: Theme?): string
	if name == nil or name == "" then
		return FALLBACK_COLOR
	end
	local named = NAMED[name]
	if named then
		return if theme == "light" then named.light else named.dark
	end
	return name
end

local function rgba(color: string): (number?, number, number, number)
	local hex = string.match(color, "^#(%x+)$")
	if hex and (#hex == 3 or #hex == 4) then
		local r = tonumber(string.sub(hex, 1, 1), 16) :: number
		local g = tonumber(string.sub(hex, 2, 2), 16) :: number
		local b = tonumber(string.sub(hex, 3, 3), 16) :: number
		local a = if #hex == 4 then (tonumber(string.sub(hex, 4, 4), 16) :: number) * 17 / 255 else 1
		return r * 17, g * 17, b * 17, a
	elseif hex and (#hex == 6 or #hex == 8) then
		local r = tonumber(string.sub(hex, 1, 2), 16) :: number
		local g = tonumber(string.sub(hex, 3, 4), 16) :: number
		local b = tonumber(string.sub(hex, 5, 6), 16) :: number
		local a = if #hex == 8 then (tonumber(string.sub(hex, 7, 8), 16) :: number) / 255 else 1
		return r, g, b, a
	end
	local args = string.match(color, "^rgba?%((.*)%)$")
	if args then
		local parts: { number } = {}
		for piece in string.gmatch(args, "[^,%s/]+") do
			local n = tonumber(piece)
			if n == nil then
				return nil, 0, 0, 0
			end
			table.insert(parts, n)
		end
		if #parts == 3 or #parts == 4 then
			return parts[1], parts[2], parts[3], parts[4] or 1
		end
	end
	return nil, 0, 0, 0
end

local function toneOfRgb(color: string): Tone
	local r, g, b, a = rgba(color)
	if r == nil then
		return "neutral"
	elseif a <= 0 then
		return "muted"
	end
	local hi = math.max(r, g, b)
	local chroma = hi - math.min(r, g, b)
	if chroma < 0.15 * 255 then
		return "neutral"
	end
	local hue
	if hi == r then
		hue = 60 * (((g - b) / chroma) % 6)
	elseif hi == g then
		hue = 60 * ((b - r) / chroma + 2)
	else
		hue = 60 * ((r - g) / chroma + 4)
	end
	if hue < 15 or hue >= 330 then
		return "error"
	elseif hue < 70 then
		return "warning"
	elseif hue < 165 then
		return "success"
	elseif hue < 255 then
		return "info"
	end
	return "accent"
end

function M.tone(name: string?): Tone
	if name == nil or name == "" then
		return "neutral"
	end
	local named = NAMED[name]
	if named then
		return named.tone
	end
	return toneOfRgb(name)
end

-- The value's position in min..max (Grafana's percent, 0..1 inside the range).
-- Without a known range Grafana's 0..100 default applies.
local function percentOf(value: number, min: number?, max: number?): number
	if value == -math.huge then
		return 0
	end
	local lo = min or 0
	local p = (value - lo) / ((max or 100) - lo)
	return if p ~= p then 0 else p
end

function M.active(value: number?, spec: Thresholds?, min: number?, max: number?, theme: Theme?): Active
	local v = if value == nil or value ~= value then -math.huge else value
	local percent = percentOf(v, min, max)
	local steps: { Step } = if spec then spec.steps else {}
	if #steps == 0 then
		return { index = 0, name = "", color = FALLBACK_COLOR, tone = "neutral", percent = percent }
	end
	local probe = if spec and spec.mode == "percentage" then percent * 100 else v
	-- getActiveThreshold on the sorted steps: the highest step at or below the
	-- probe, later steps winning ties; the base step (no number) is -Inf.
	local best = 0
	local bestValue = -math.huge
	for i, step in steps do
		local sv = if type(step.value) == "number" then step.value else -math.huge
		if (best == 0 or sv >= bestValue) and probe >= sv then
			best = i
			bestValue = sv
		end
	end
	if best == 0 then
		-- Every step is above the probe: Grafana keeps the lowest one.
		for i, step in steps do
			local sv = if type(step.value) == "number" then step.value else -math.huge
			if best == 0 or sv < bestValue then
				best = i
				bestValue = sv
			end
		end
	end
	local name = steps[best].color
	return { index = best, name = name, color = M.color(name, theme), tone = M.tone(name), percent = percent }
end

return M
