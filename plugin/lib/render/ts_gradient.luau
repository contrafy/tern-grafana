--!strict
-- Time series colors as classes: the stops of gradientMode hue and scheme
-- (packages/grafana-ui/src/components/uPlot/config/gradientFills.ts) and
-- the plain color of a fixed or continuous-scheme series.
--
-- Tern drops inline styles and resolves no var() in SVG attributes, so every
-- color is a class: `tg-gc<n>` (a color from STOPS, generated into
-- tern-grafana.css as stop-color, stroke, fill and `color` for legend
-- swatches), `tg-gt-<tone>` (a threshold tone stop, theme-colored as
-- threshold colors are everywhere else), `tg-gc-bg` (panel-bg) and `tg-gx`
-- (transparent). STOPS holds the colors Grafana computes for the named
-- colors in both themes, their hue variants, the classic palette and the
-- continuous schemes, so those map exactly; any other color maps to its
-- nearest entry.

local Data = require("./ts_data")
local Thresholds = require("../units/thresholds")

type Theme = Thresholds.Theme
export type Scheme = Data.Scheme

local M = {}

type Rgb = { number }

local function parse(color: string): Rgb?
	local hex = string.match(color, "^#(%x+)$")
	if hex and (#hex == 3 or #hex == 4) then
		local out: Rgb = {}
		for k = 1, 3 do
			out[k] = (tonumber(string.sub(hex, k, k), 16) :: number) * 17
		end
		return out
	elseif hex and (#hex == 6 or #hex == 8) then
		local out: Rgb = {}
		for k = 1, 3 do
			out[k] = tonumber(string.sub(hex, 2 * k - 1, 2 * k), 16) :: number
		end
		return out
	end
	local args = string.match(color, "^rgba?%((.*)%)$")
	if args then
		local out: Rgb = {}
		for piece in string.gmatch(args, "[^,%s/]+") do
			local n = tonumber(piece)
			if n == nil then
				return nil
			end
			table.insert(out, n)
		end
		if #out >= 3 then
			return { out[1], out[2], out[3] }
		end
	end
	return nil
end

local function hexOf(c: Rgb): string
	return string.format(
		"#%02x%02x%02x",
		math.clamp(math.floor(c[1] + 0.5), 0, 255),
		math.clamp(math.floor(c[2] + 0.5), 0, 255),
		math.clamp(math.floor(c[3] + 0.5), 0, 255)
	)
end

-- tinycolor2 toHsl / fromHsl (h 0..360, s and l 0..1).
local function toHsl(c: Rgb): (number, number, number)
	local r, g, b = c[1] / 255, c[2] / 255, c[3] / 255
	local hi, lo = math.max(r, g, b), math.min(r, g, b)
	local l = (hi + lo) / 2
	if hi == lo then
		return 0, 0, l
	end
	local d = hi - lo
	local s = if l > 0.5 then d / (2 - hi - lo) else d / (hi + lo)
	local h
	if hi == r then
		h = (g - b) / d + (if g < b then 6 else 0)
	elseif hi == g then
		h = (b - r) / d + 2
	else
		h = (r - g) / d + 4
	end
	return h * 60, s, l
end

local function hue2rgb(p: number, q: number, t: number): number
	if t < 0 then
		t += 1
	end
	if t > 1 then
		t -= 1
	end
	if t < 1 / 6 then
		return p + (q - p) * 6 * t
	elseif t < 1 / 2 then
		return q
	elseif t < 2 / 3 then
		return p + (q - p) * (2 / 3 - t) * 6
	end
	return p
end

local function fromHsl(h: number, s: number, l: number): Rgb
	h = (h % 360) / 360
	s, l = math.clamp(s, 0, 1), math.clamp(l, 0, 1)
	if s == 0 then
		return { l * 255, l * 255, l * 255 }
	end
	local q = if l < 0.5 then l * (1 + s) else l + s - l * s
	local p = 2 * l - q
	return { hue2rgb(p, q, h + 1 / 3) * 255, hue2rgb(p, q, h) * 255, hue2rgb(p, q, h - 1 / 3) * 255 }
end

local function spin(c: Rgb, amount: number): Rgb
	local h, s, l = toHsl(c)
	return fromHsl((h + amount) % 360, s, l)
end

local function lighten(c: Rgb, amount: number): Rgb
	local h, s, l = toHsl(c)
	return fromHsl(h, s, math.clamp(l + amount / 100, 0, 1))
end

local function saturate(c: Rgb, amount: number): Rgb
	local h, s, l = toHsl(c)
	return fromHsl(h, math.clamp(s + amount / 100, 0, 1), l)
end

-- tinycolor brighten: on the rounded rgb, JS Math.round(-25.5) is -25.
local function brighten(c: Rgb, amount: number): Rgb
	local add = -math.floor(-255 * amount / 100 + 0.5)
	local out: Rgb = {}
	for k = 1, 3 do
		out[k] = math.clamp(math.floor(c[k] + 0.5) + add, 0, 255)
	end
	return out
end

-- getHueGradientFn: the top stop (color2 lightened) and the bottom one
-- (color1, darkened again in the dark theme).
local function hueStops(c: Rgb, theme: Theme?): (Rgb, Rgb)
	local color1 = lighten(spin(c, -25), -5)
	local color2 = brighten(spin(saturate(c, 20), 20), 10)
	local top = lighten(color2, 10)
	local bottom = if theme == "light" then color1 else lighten(color1, -10)
	return top, bottom
end

-- d3-scale-chromatic schemes as Grafana samples them (getColors: nine
-- interpolator values at i/8).
local SEQUENTIAL: { [string]: { string } } = {
	["continuous-viridis"] = {
		"#440154",
		"#472d7b",
		"#3b528b",
		"#2c728e",
		"#21918c",
		"#28ae80",
		"#5ec962",
		"#addc30",
		"#fde725",
	},
	["continuous-magma"] = {
		"#000004",
		"#1d1147",
		"#51127c",
		"#832681",
		"#b73779",
		"#e75263",
		"#fc8961",
		"#fec488",
		"#fcfdbf",
	},
	["continuous-plasma"] = {
		"#0d0887",
		"#4c02a1",
		"#7e03a8",
		"#aa2395",
		"#cc4778",
		"#e66c5c",
		"#f89540",
		"#fdc527",
		"#f0f921",
	},
	["continuous-inferno"] = {
		"#000004",
		"#210c4a",
		"#57106e",
		"#8a226a",
		"#bc3754",
		"#e45a31",
		"#f98e09",
		"#f9cb35",
		"#fcffa4",
	},
	["continuous-cividis"] = {
		"#002051",
		"#11366c",
		"#3c4d6e",
		"#62646f",
		"#7f7c75",
		"#9a9478",
		"#bbaf71",
		"#e2cb5c",
		"#fdea45",
	},
}

-- fieldColor.ts getColors of the named-color schemes.
local NAMED_SCHEMES: { [string]: { string } } = {
	["continuous-GrYlRd"] = { "green", "yellow", "red" },
	["continuous-RdYlGr"] = { "red", "yellow", "green" },
	["continuous-BlYlRd"] = { "dark-blue", "super-light-yellow", "dark-red" },
	["continuous-YlRd"] = { "super-light-yellow", "dark-red" },
	["continuous-BlPu"] = { "blue", "purple" },
	["continuous-YlBl"] = { "super-light-yellow", "dark-blue" },
	["continuous-blues"] = { "panel-bg", "dark-blue" },
	["continuous-reds"] = { "panel-bg", "dark-red" },
	["continuous-greens"] = { "panel-bg", "dark-green" },
	["continuous-purples"] = { "panel-bg", "dark-purple" },
}

-- createVisualizationColors getClassicPalette.
local CLASSIC = {
	"green",
	"semi-dark-yellow",
	"blue",
	"orange",
	"red",
	"purple",
	"dark-green",
	"dark-yellow",
	"dark-blue",
	"dark-orange",
	"dark-red",
	"dark-purple",
	"super-light-green",
	"super-light-yellow",
	"super-light-blue",
	"super-light-orange",
	"super-light-red",
	"super-light-purple",
	"#447EBC",
	"#C15C17",
	"#890F02",
	"#0A437C",
	"#6D1F62",
	"#584477",
	"#B7DBAB",
	"#F4D598",
	"#70DBED",
	"#F9BA8F",
	"#F29191",
	"#82B5D8",
	"#E5A8E2",
	"#AEA2E0",
	"#629E51",
	"#E5AC0E",
	"#64B0C8",
	"#E0752D",
	"#BF1B00",
	"#0A50A1",
	"#962D82",
	"#614D93",
	"#9AC48A",
	"#F2C96D",
	"#65C5DB",
	"#F9934E",
	"#EA6460",
	"#5195CE",
	"#D683CE",
	"#806EB7",
	"#3F6833",
	"#967302",
	"#2F575E",
	"#99440A",
	"#58140C",
	"#052B51",
	"#511749",
	"#3F2B5B",
	"#E0F9D7",
	"#FCEACA",
	"#CFFAFF",
	"#F9E2D2",
	"#FCE2DE",
	"#BADFF4",
	"#F9D9F9",
	"#DEDAF7",
}

-- The series palette classes' colors (tern-grafana.css tg-s1..tg-s10).
M.PALETTE_HEX =
	{ "#73bf69", "#f2cc0c", "#5794f2", "#ff9830", "#f2495c", "#b877d9", "#37872d", "#e0b400", "#1f60c4", "#fa6400" }

local NAMED_HUES = { "red", "orange", "yellow", "green", "blue", "purple" }
local SHADES = { "super-light-", "light-", "", "semi-dark-", "dark-" }

-- STOPS[n] is the stop-color of class tg-gc<n>.
M.STOPS = {} :: { string }
local stopRgb: { Rgb } = {}
local stopIndex: { [string]: number } = {}

local function addStop(hex: string)
	hex = string.lower(hex)
	if stopIndex[hex] == nil then
		table.insert(M.STOPS, hex)
		table.insert(stopRgb, parse(hex) :: Rgb)
		stopIndex[hex] = #M.STOPS
	end
end

do
	local bases: { string } = {}
	for _, hue in NAMED_HUES do
		for _, shade in SHADES do
			table.insert(bases, Thresholds.color(shade .. hue, "dark"))
			table.insert(bases, Thresholds.color(shade .. hue, "light"))
		end
	end
	for _, hex in M.PALETTE_HEX do
		table.insert(bases, hex)
	end
	for _, hex in bases do
		addStop(hex)
		local c = parse(hex) :: Rgb
		local top, bottomLight = hueStops(c, "light")
		local _, bottomDark = hueStops(c, "dark")
		addStop(hexOf(top))
		addStop(hexOf(bottomLight))
		addStop(hexOf(bottomDark))
	end
	for _, name in CLASSIC do
		addStop(Thresholds.color(name, "dark"))
		addStop(Thresholds.color(name, "light"))
	end
	for _, list in SEQUENTIAL do
		for _, hex in list do
			addStop(hex)
		end
	end
end

-- Nearest stop class by the "redmean" weighted RGB distance.
local nearestCache: { [string]: string } = {}

local function classOfRgb(c: Rgb): string
	local key = hexOf(c)
	local hit = nearestCache[key]
	if hit then
		return hit
	end
	local exact = stopIndex[key]
	local best = exact or 1
	if exact == nil then
		local bestD = math.huge
		for n, s in stopRgb do
			local rm = (c[1] + s[1]) / 2
			local dr, dg, db = c[1] - s[1], c[2] - s[2], c[3] - s[3]
			local d = (2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db
			if d < bestD then
				best, bestD = n, d
			end
		end
	end
	local class = "tg-gc" .. best
	nearestCache[key] = class
	return class
end

-- The stop class of a Grafana color (name, hex or rgb()) in `theme`. The
-- dark-theme named colors' classes take their light shade under Tern's
-- light theme (tern-grafana.css), as Grafana resolves names per theme; a
-- literal color that is not exactly one of them (it only has the nearest
-- class) also gets `tg-hex`, which keeps it as it is in both themes.
function M.stopClass(color: string, theme: Theme?): string
	if color == "panel-bg" then
		return "tg-gc-bg"
	elseif color == "transparent" then
		return "tg-gx"
	end
	local resolved = Thresholds.color(color, theme)
	local c = parse(resolved)
	if c == nil then
		return classOfRgb({ 128, 128, 128 })
	end
	if resolved == color and Thresholds.lightOf(color) == color then
		return classOfRgb(c) .. " tg-hex"
	end
	return classOfRgb(c)
end

-- A fixed color (fieldConfig color.fixedColor): a literal stays that color
-- in both themes, even when it equals a named color's dark shade.
function M.fixedClass(color: string, theme: Theme?): string
	local class = M.stopClass(color, theme)
	if Thresholds.color(color, theme) == color and string.find(class, " tg-hex", 1, true) == nil then
		return class .. " tg-hex"
	end
	return class
end

-- gradientMode hue: the top and bottom stop classes for a series color.
function M.hue(color: string, theme: Theme?): { string }
	local c = parse(Thresholds.color(color, theme)) or { 128, 128, 128 }
	local top, bottom = hueStops(c, theme)
	return { classOfRgb(top), classOfRgb(bottom) }
end

-- PieChart's radial slice gradient (getGradientColorFrom at the inner
-- radius to getGradientColorTo at the outer one) in `theme`, sampled as the
-- stop classes of `n` concentric rings (Tern's SVG drops radialGradient);
-- kept exact in both themes.
function M.pieRings(color: string, theme: Theme?, n: number): { string }
	local c = parse(Thresholds.color(color, theme)) or { 128, 128, 128 }
	local k = if theme == "light" then -0.7 else 1
	local from = spin(lighten(c, -20 * k), 4)
	local to = spin(lighten(c, -10 * k), -4)
	local out: { string } = table.create(n)
	for i = 1, n do
		local t = (i - 0.5) / n
		local mix: Rgb = {}
		for j = 1, 3 do
			mix[j] = from[j] + (to[j] - from[j]) * t
		end
		out[i] = classOfRgb(mix) .. " tg-hex"
	end
	return out
end

-- The color name of palette class tg-s<k> (getClassicPalette).
function M.paletteColor(k: number): string
	return CLASSIC[(k - 1) % #M.PALETTE_HEX + 1]
end

-- The colors a by-value scheme runs through, or nil when the mode has none
-- (fixed, shades and palettes other than the classic one).
local function schemeColors(mode: string): { string }?
	local named = NAMED_SCHEMES[mode]
	if named then
		return named
	end
	local seq = SEQUENTIAL[mode]
	if seq then
		return seq
	end
	if mode == "palette-classic" or mode == "palette-classic-by-name" then
		return CLASSIC
	end
	return nil
end

local function isStepTransparent(color: string): boolean
	return color == "transparent" or (string.sub(color, 1, 1) == "#" and #color == 9 and string.sub(color, -2) == "00")
end

-- getScaleGradientFn: the value stops of a series in gradientMode scheme,
-- or nil when its color mode draws a plain color (fixed, shades).
-- Thresholds steps are hard stops in their tones (absolute values, or
-- percents of the gradient range); scheme colors spread evenly over the
-- gradient range.
function M.scheme(mode: string, thresholds: Thresholds.Thresholds?, theme: Theme?): Scheme?
	if mode == "thresholds" then
		local steps: { Thresholds.Step } = if thresholds then thresholds.steps else {}
		local percentage = thresholds ~= nil and thresholds.mode == "percentage"
		local stops: { Data.SchemeStop } = {}
		for _, step in steps do
			local v = if type(step.value) == "number" then step.value else -math.huge
			local class = if isStepTransparent(step.color) then "tg-gx" else "tg-gt-" .. Thresholds.tone(step.color)
			table.insert(stops, { at = if percentage then v / 100 else v, class = class })
		end
		if #stops == 0 then
			table.insert(stops, { at = -math.huge, class = "tg-gt-success" })
		end
		return { stops = stops, relative = percentage, discrete = true }
	end
	local colors = schemeColors(mode)
	if colors == nil then
		return nil
	end
	local stops = table.create(#colors)
	for i, color in colors do
		stops[i] = { at = (i - 1) / math.max(1, #colors - 1), class = M.stopClass(color, theme) }
	end
	return { stops = stops, relative = true, discrete = false }
end

-- The color a series is drawn in when the scheme is evaluated at `percent`
-- (the base of a by-value series' hue gradient).
function M.schemeColor(mode: string, percent: number, theme: Theme?): string?
	local colors = schemeColors(mode)
	if colors == nil then
		return nil
	end
	local p = math.clamp(if percent == percent then percent else 0, 0, 1) * (#colors - 1)
	local k = math.floor(p)
	local a = parse(Thresholds.color(colors[k + 1], theme))
	local b = parse(Thresholds.color(colors[math.min(#colors, k + 2)], theme))
	if a == nil or b == nil then
		return nil
	end
	local f = p - k
	return hexOf({ a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f })
end

return M
