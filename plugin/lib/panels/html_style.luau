--!strict
-- Inline `style` attributes as class lists against one static stylesheet
-- (plugin/dynamictext.css, generated from M.stylesheet() by
-- scripts/gen-dynamictext-css.luau). Tern `el` nodes take classes but no
-- inline style, and plugin CSS cannot be added at run time, so every value is
-- spelled by classes that set CSS custom properties, and one rule per
-- property consumes them:
-- - colors: an element has COLOR_SLOTS color slots; a slot is four integer
--   custom properties set one class each (`dtc1r238 dtc1g68 dtc1b204
--   dtc1a50`), and `.dt-col1 { color: rgb(var(--dtc1r) ... / var(--dtc1a)) }`
--   reads slot 1. Channels are exact (calc() inside rgb() does not work in
--   Tern, so they cannot be composed from digits); alpha keeps 2 decimals.
-- - numbers: NUM_SLOTS number slots spell a value by decimal digit (`dt3h1
--   dt3t7 dt3o0` = 170), a sign class and a unit class (px default, %, em,
--   rem, vh, vw, deg or none); `.dt-h3 { height: calc(var(--dt3) *
--   var(--dt3u)) }`. Values keep 2 decimals below 10000.
-- - keywords (display, position, flex and alignment, text-transform, ...):
--   one class per allowed value.
-- Every element resets all slot properties (`.tgd *`), so nothing leaks to
-- children. Shorthands expand to longhands (margin, padding, inset, border,
-- border-radius, gap, flex, overflow, background, flex-flow); box-shadow
-- draws its first shadow, linear-gradient up to 3 stops without positions
-- at an angle rounded to 5 degrees (Tern drops a gradient whose angle is a
-- calc()).
-- Font weights round to a multiple of 50 and font families to sans-serif
-- (Inter), serif or monospace. Declarations outside the allowlist are
-- dropped and named in Result.dropped; ones without a static visual effect
-- (cursor, transition, animation, pointer-events, user-select) are ignored.

local M = {}

M.NUM_SLOTS = 10
M.COLOR_SLOTS = 4

export type Result = { class: string, dropped: { string } }

-- Number-valued properties: CSS name -> class code.
local LENGTH: { [string]: string } = {
	width = "w",
	height = "h",
	["min-width"] = "mnw",
	["min-height"] = "mnh",
	["max-width"] = "mxw",
	["max-height"] = "mxh",
	top = "t",
	right = "r",
	bottom = "b",
	left = "l",
	["margin-top"] = "mt",
	["margin-right"] = "mr",
	["margin-bottom"] = "mb",
	["margin-left"] = "ml",
	["padding-top"] = "pt",
	["padding-right"] = "pr",
	["padding-bottom"] = "pb",
	["padding-left"] = "pl",
	["row-gap"] = "rg",
	["column-gap"] = "cg",
	["font-size"] = "fs",
	["letter-spacing"] = "ls",
	["word-spacing"] = "wsp",
	["line-height"] = "lh",
	["text-indent"] = "ti",
	["border-top-width"] = "btw",
	["border-right-width"] = "brw",
	["border-bottom-width"] = "bbw",
	["border-left-width"] = "blw",
	["border-top-left-radius"] = "rtl",
	["border-top-right-radius"] = "rtr",
	["border-bottom-right-radius"] = "rbr",
	["border-bottom-left-radius"] = "rbl",
	["flex-basis"] = "fb",
	["flex-grow"] = "fg",
	["flex-shrink"] = "fsh",
	order = "ord",
	["z-index"] = "z",
	opacity = "op",
}

-- Properties whose plain numbers are valid (others take 0 only).
local UNITLESS: { [string]: boolean } = {
	["line-height"] = true,
	["flex-grow"] = true,
	["flex-shrink"] = true,
	order = true,
	["z-index"] = true,
	opacity = true,
}

-- Keyword values number-valued properties also take.
local LENGTH_KEYWORDS: { [string]: { string } } = {
	auto = {
		"width",
		"height",
		"top",
		"right",
		"bottom",
		"left",
		"margin-top",
		"margin-right",
		"margin-bottom",
		"margin-left",
		"flex-basis",
		"z-index",
	},
	none = { "max-width", "max-height" },
	normal = { "line-height", "letter-spacing", "word-spacing", "row-gap", "column-gap" },
	["fit-content"] = { "width", "height", "min-width", "min-height", "max-width", "max-height", "flex-basis" },
	["max-content"] = { "width", "height", "min-width", "min-height", "max-width", "max-height", "flex-basis" },
	["min-content"] = { "width", "height", "min-width", "min-height", "max-width", "max-height", "flex-basis" },
	["xx-small"] = { "font-size" },
	["x-small"] = { "font-size" },
	small = { "font-size" },
	medium = { "font-size" },
	large = { "font-size" },
	["x-large"] = { "font-size" },
	["xx-large"] = { "font-size" },
	smaller = { "font-size" },
	larger = { "font-size" },
}

local function words(s: string): { string }
	local out: { string } = {}
	for w in string.gmatch(s, "%S+") do
		table.insert(out, w)
	end
	return out
end

local ALIGN = words("flex-start flex-end start end center stretch baseline normal")
local DISTRIBUTE = words("flex-start flex-end start end center stretch space-between space-around space-evenly normal")
local OVERFLOW = words("visible hidden auto scroll clip")
local BORDER_STYLE = words("none hidden solid dashed dotted double groove ridge inset outset")

-- Keyword properties: CSS name -> class code and allowed values.
local KEYWORDS: { [string]: { code: string, values: { string } } } = {
	display = {
		code = "d",
		values = words(
			"block inline inline-block flex inline-flex grid inline-grid none contents table table-row table-cell list-item flow-root"
		),
	},
	position = { code = "pos", values = words("static relative absolute sticky") },
	["flex-direction"] = { code = "fd", values = words("row row-reverse column column-reverse") },
	["flex-wrap"] = { code = "fw", values = words("nowrap wrap wrap-reverse") },
	["align-items"] = { code = "ai", values = ALIGN },
	["align-self"] = { code = "as", values = table.move({ "auto" }, 1, 1, #ALIGN + 1, table.clone(ALIGN)) },
	["align-content"] = { code = "ac", values = DISTRIBUTE },
	["justify-content"] = { code = "jc", values = DISTRIBUTE },
	["justify-items"] = { code = "ji", values = ALIGN },
	["justify-self"] = { code = "js", values = table.move({ "auto" }, 1, 1, #ALIGN + 1, table.clone(ALIGN)) },
	["text-align"] = { code = "ta", values = words("left right center justify start end") },
	["text-transform"] = { code = "tt", values = words("none uppercase lowercase capitalize") },
	["white-space"] = { code = "wh", values = words("normal nowrap pre pre-wrap pre-line break-spaces") },
	["overflow-x"] = { code = "ovx", values = OVERFLOW },
	["overflow-y"] = { code = "ovy", values = OVERFLOW },
	["object-fit"] = { code = "of", values = words("contain cover fill none scale-down") },
	["font-style"] = { code = "fst", values = words("normal italic oblique") },
	["font-weight"] = {
		code = "fwt",
		values = words(
			"normal bold bolder lighter 100 150 200 250 300 350 400 450 500 550 600 650 700 750 800 850 900 950"
		),
	},
	["text-decoration-line"] = { code = "tdl", values = words("none underline line-through overline") },
	["vertical-align"] = { code = "va", values = words("top middle bottom baseline text-top text-bottom sub super") },
	["box-sizing"] = { code = "bxs", values = words("border-box content-box") },
	["word-break"] = { code = "wb", values = words("normal break-all keep-all break-word") },
	["overflow-wrap"] = { code = "ow", values = words("normal anywhere break-word") },
	["text-overflow"] = { code = "tov", values = words("clip ellipsis") },
	visibility = { code = "vis", values = words("visible hidden collapse") },
	["border-top-style"] = { code = "bts", values = BORDER_STYLE },
	["border-right-style"] = { code = "brs", values = BORDER_STYLE },
	["border-bottom-style"] = { code = "bbs", values = BORDER_STYLE },
	["border-left-style"] = { code = "bls", values = BORDER_STYLE },
	["list-style-type"] = { code = "lst", values = words("none disc circle square decimal") },
	["border-collapse"] = { code = "bcl", values = words("collapse separate") },
	["table-layout"] = { code = "tl", values = words("auto fixed") },
	["background-color"] = { code = "bgk", values = words("transparent") },
	["box-shadow"] = { code = "shk", values = words("none") },
	["background-image"] = { code = "bgi", values = words("none") },
}

local FONT_FAMILIES: { [string]: string } = {
	sans = "Inter, Helvetica, Arial, sans-serif",
	serif = "Georgia, 'Times New Roman', serif",
	mono = "'Roboto Mono', Menlo, Consolas, monospace",
}

-- Color-valued properties: CSS name -> class code.
local COLOR: { [string]: string } = {
	color = "col",
	["background-color"] = "bg",
	["border-top-color"] = "btc",
	["border-right-color"] = "brc",
	["border-bottom-color"] = "bbc",
	["border-left-color"] = "blc",
}

-- KEYWORDS entries that only hold the keyword forms of a richer property
-- (its values go through their own parser).
local SHORTHAND_KEYWORD: { [string]: boolean } = { ["box-shadow"] = true, ["background-image"] = true }

-- Declarations with no visual effect in a static picture.
local IGNORED: { [string]: boolean } = {
	cursor = true,
	transition = true,
	animation = true,
	["pointer-events"] = true,
	["user-select"] = true,
	["will-change"] = true,
}

local UNITS: { [string]: string } = {
	px = "",
	["%"] = "pc",
	em = "em",
	rem = "rem",
	vh = "vh",
	vw = "vw",
	deg = "deg",
	[""] = "x",
}
local UNIT_CSS: { [string]: string } =
	{ [""] = "1px", pc = "1%", em = "1em", rem = "1rem", vh = "1vh", vw = "1vw", deg = "1deg", x = "1" }
local UNIT_ORDER = { "pc", "em", "rem", "vh", "vw", "deg", "x" }

-- Decimal digit positions of a number slot, most significant first, and
-- their weight in hundredths.
type Digit = { name: string, weight: number }
local DIGITS: { Digit } = {
	{ name = "k", weight = 100000 },
	{ name = "h", weight = 10000 },
	{ name = "t", weight = 1000 },
	{ name = "o", weight = 100 },
	{ name = "d", weight = 10 },
	{ name = "c", weight = 1 },
}
local DIGIT_WEIGHT = { k = "1000", h = "100", t = "10", o = "1", d = ".1", c = ".01" }

-- CSS named colors.
local NAMED: { [string]: string } = {}
do
	local list = "aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc "
		.. "bisque ffe4c4 black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a "
		.. "burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e coral ff7f50 "
		.. "cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff darkblue 00008b darkcyan 008b8b "
		.. "darkgoldenrod b8860b darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b "
		.. "darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 "
		.. "darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f "
		.. "darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 deepskyblue 00bfff "
		.. "dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 floralwhite fffaf0 "
		.. "forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 "
		.. "goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 honeydew f0fff0 "
		.. "hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa "
		.. "lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 "
		.. "lightcyan e0ffff lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 "
		.. "lightpink ffb6c1 lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa "
		.. "lightslategray 778899 lightslategrey 778899 lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 "
		.. "limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 mediumaquamarine 66cdaa "
		.. "mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 "
		.. "mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc mediumvioletred c71585 "
		.. "midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead "
		.. "navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 "
		.. "orchid da70d6 palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee palevioletred db7093 "
		.. "papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 "
		.. "purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 "
		.. "saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee "
		.. "sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 "
		.. "snow fffafa springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 "
		.. "tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 "
		.. "yellow ffff00 yellowgreen 9acd32"
	local w = words(list)
	for i = 1, #w, 2 do
		NAMED[w[i]] = w[i + 1]
	end
end

-- Parsing ------------------------------------------------------------------------

type Rgba = { r: number, g: number, b: number, a: number }

local function clamp255(v: number): number
	return math.clamp(math.floor(v + 0.5), 0, 255)
end

local function channel(s: string): number?
	local pct = string.match(s, "^([%d%.]+)%%$")
	if pct then
		local v = tonumber(pct)
		return if v then clamp255(v * 2.55) else nil
	end
	local v = tonumber(s)
	return if v then clamp255(v) else nil
end

local function alpha(s: string?): number?
	if s == nil then
		return 1
	end
	local pct = string.match(s, "^([%d%.]+)%%$")
	local v = if pct then (tonumber(pct) or 0) / 100 else tonumber(s)
	return if v then math.clamp(v, 0, 1) else nil
end

local function hue(h: number, s: number, l: number): (number, number, number)
	local function f(n: number): number
		local k = (n + h / 30) % 12
		local a = s * math.min(l, 1 - l)
		return l - a * math.max(-1, math.min(k - 3, 9 - k, 1))
	end
	return f(0) * 255, f(8) * 255, f(4) * 255
end

-- A CSS color as rgba, nil when it is not one this compiler spells.
function M.parseColor(raw: string): Rgba?
	local s = string.lower(raw)
	if s == "transparent" then
		return { r = 0, g = 0, b = 0, a = 0 }
	end
	local named = NAMED[s]
	if named then
		s = "#" .. named
	end
	local hex = string.match(s, "^#(%x+)$")
	if hex then
		local n = #hex
		if n == 3 or n == 4 then
			local function d(i: number): number
				return (tonumber(string.sub(hex, i, i), 16) :: number) * 17
			end
			return { r = d(1), g = d(2), b = d(3), a = if n == 4 then d(4) / 255 else 1 }
		elseif n == 6 or n == 8 then
			local function d(i: number): number
				return tonumber(string.sub(hex, i, i + 1), 16) :: number
			end
			return { r = d(1), g = d(3), b = d(5), a = if n == 8 then d(7) / 255 else 1 }
		end
		return nil
	end
	local fn, args = string.match(s, "^(%a+)%((.*)%)$")
	if fn == nil or args == nil then
		return nil
	end
	local a: string? = nil
	local body = args
	local slash = string.find(body, "/", 1, true)
	if slash then
		a = string.match(string.sub(body, slash + 1), "^%s*(.-)%s*$")
		body = string.sub(body, 1, slash - 1)
	end
	local parts = words((string.gsub(body, ",", " ")))
	if a == nil and #parts == 4 then
		a = parts[4]
	elseif #parts ~= 3 then
		return nil
	end
	local av = alpha(a)
	if av == nil then
		return nil
	end
	if fn == "rgb" or fn == "rgba" then
		local r, g, b = channel(parts[1]), channel(parts[2]), channel(parts[3])
		if r == nil or g == nil or b == nil then
			return nil
		end
		return { r = r, g = g, b = b, a = av }
	elseif fn == "hsl" or fn == "hsla" then
		local h = tonumber((string.gsub(parts[1], "deg$", "")))
		local sat = tonumber(string.match(parts[2], "^([%d%.]+)%%?$") or "")
		local lig = tonumber(string.match(parts[3], "^([%d%.]+)%%?$") or "")
		if h == nil or sat == nil or lig == nil then
			return nil
		end
		local r, g, b = hue(h % 360, math.clamp(sat / 100, 0, 1), math.clamp(lig / 100, 0, 1))
		return { r = clamp255(r), g = clamp255(g), b = clamp255(b), a = av }
	end
	return nil
end

-- A number with its unit (lowercased; "" for none), nil when not one.
local function parseNumber(s: string): (number?, string)
	local num, unit = string.match(string.lower(s), "^([+-]?%d*%.?%d+)([%a%%]*)$")
	if num == nil then
		num, unit = string.match(string.lower(s), "^([+-]?%d+%.)([%a%%]*)$")
	end
	local v = if num then tonumber(num) else nil
	if v == nil then
		return nil, ""
	end
	local u = unit :: string
	if u == "pt" then
		return v * 4 / 3, "px"
	elseif u == "turn" then
		return v * 360, "deg"
	elseif u == "rad" then
		return v * 180 / math.pi, "deg"
	end
	return v, u
end

-- Splits a value on top-level spaces (not inside parentheses or quotes).
local function tokens(value: string, sep: string?): { string }
	local out: { string } = {}
	local depth, quote = 0, nil :: string?
	local buf: { string } = {}
	local splitter = sep or "%s"
	for _, cp in utf8.codes(value) do
		local c = utf8.char(cp)
		if quote then
			if c == quote then
				quote = nil
			end
			table.insert(buf, c)
		elseif c == '"' or c == "'" then
			quote = c
			table.insert(buf, c)
		elseif c == "(" then
			depth += 1
			table.insert(buf, c)
		elseif c == ")" then
			depth = math.max(0, depth - 1)
			table.insert(buf, c)
		elseif depth == 0 and string.match(c, "^" .. splitter .. "$") then
			if #buf > 0 then
				table.insert(out, table.concat(buf))
				table.clear(buf)
			end
		else
			table.insert(buf, c)
		end
	end
	if #buf > 0 then
		table.insert(out, table.concat(buf))
	end
	return out
end

-- Compilation ----------------------------------------------------------------------

type State = {
	-- Longhand -> its classes; the last declaration of a longhand wins.
	long: { [string]: { string } },
	order: { string },
	nums: { [string]: number },
	cols: { [string]: number },
	slots: { string },
	dropped: { string },
	full: boolean,
}

local function drop(st: State, what: string)
	if not table.find(st.dropped, what) then
		table.insert(st.dropped, what)
	end
end

local function set(st: State, longhand: string, classes: { string })
	if st.long[longhand] == nil then
		table.insert(st.order, longhand)
	end
	st.long[longhand] = classes
end

-- The number slot spelling v in unit u (px "", pc, em, ...), nil when the
-- element has no slot left or the value is out of range.
local function numSlot(st: State, v: number, unitCode: string): number?
	local q = math.floor(math.abs(v) * 100 + 0.5)
	if q > 999999 then
		return nil
	end
	local key = (if v < 0 and q > 0 then "-" else "") .. q .. unitCode
	local found = st.nums[key]
	if found then
		return found
	end
	local n = 0
	for _ in st.nums do
		n += 1
	end
	if n >= M.NUM_SLOTS then
		st.full = true
		return nil
	end
	local slot = n + 1
	st.nums[key] = slot
	for _, d in DIGITS do
		local digit = (q // d.weight) % 10
		if digit > 0 then
			table.insert(st.slots, "dt" .. slot .. d.name .. digit)
		end
	end
	if v < 0 and q > 0 then
		table.insert(st.slots, "dt" .. slot .. "n")
	end
	if unitCode ~= "" then
		table.insert(st.slots, "dt" .. slot .. "u" .. unitCode)
	end
	return slot
end

local function colSlot(st: State, c: Rgba): number?
	local a = math.floor(c.a * 100 + 0.5)
	local key = c.r .. "," .. c.g .. "," .. c.b .. "," .. a
	local found = st.cols[key]
	if found then
		return found
	end
	local n = 0
	for _ in st.cols do
		n += 1
	end
	if n >= M.COLOR_SLOTS then
		st.full = true
		return nil
	end
	local slot = n + 1
	st.cols[key] = slot
	for _, ch in { "r", "g", "b" } do
		local v: number = if ch == "r" then c.r elseif ch == "g" then c.g else c.b
		if v > 0 then
			table.insert(st.slots, "dtc" .. slot .. ch .. v)
		end
	end
	if a < 100 then
		table.insert(st.slots, "dtc" .. slot .. "a" .. a)
	end
	return slot
end

-- A number-valued longhand; false when the value is not supported.
local function length(st: State, prop: string, value: string): boolean
	local kws = LENGTH_KEYWORDS[value]
	if kws and table.find(kws, prop) then
		set(st, prop, { "dt-" .. LENGTH[prop] .. "-" .. value })
		return true
	end
	if prop == "font-weight" then
		return false
	end
	local v, u = parseNumber(value)
	if v == nil then
		return false
	end
	if prop == "opacity" and u == "%" then
		v, u = v / 100, ""
	end
	if u == "" and not UNITLESS[prop] and v ~= 0 then
		return false
	end
	if UNITLESS[prop] and prop ~= "line-height" and u ~= "" then
		return false
	end
	if (prop == "z-index" or prop == "order") and v ~= math.floor(v) then
		return false
	end
	if u == "" and not UNITLESS[prop] then
		u = "px"
	end
	local code = UNITS[u]
	if code == nil or (code == "deg") then
		return false
	end
	local slot = numSlot(st, v, code)
	if slot == nil then
		return false
	end
	set(st, prop, { "dt-" .. LENGTH[prop] .. slot })
	return true
end

local function keyword(st: State, prop: string, value: string): boolean
	local k = KEYWORDS[prop]
	if k == nil then
		return false
	end
	local v = value
	if prop == "font-weight" then
		local n = tonumber(value)
		if n then
			v = tostring(math.clamp(math.floor(n / 50 + 0.5) * 50, 100, 950))
		end
	end
	if not table.find(k.values, v) then
		return false
	end
	set(st, prop, { "dt-" .. k.code .. "-" .. v })
	return true
end

local function color(st: State, prop: string, value: string): boolean
	if value == "currentcolor" and prop ~= "color" then
		st.long[prop] = nil
		return true
	end
	local c = M.parseColor(value)
	if c == nil then
		return false
	end
	if (prop :: string) == "background-color" and c.a == 0 then
		set(st, prop, { "dt-bgk-transparent" })
		return true
	end
	local slot = colSlot(st, c)
	if slot == nil then
		return false
	end
	set(st, prop, { "dt-" .. COLOR[prop] .. slot })
	return true
end

local SIDES = { "top", "right", "bottom", "left" }
local CORNERS = { "top-left", "top-right", "bottom-right", "bottom-left" }

-- 1 to 4 values to the four sides (CSS box shorthand order).
local function box(values: { string }): { string }?
	local n = #values
	if n == 1 then
		return { values[1], values[1], values[1], values[1] }
	elseif n == 2 then
		return { values[1], values[2], values[1], values[2] }
	elseif n == 3 then
		return { values[1], values[2], values[3], values[2] }
	elseif n == 4 then
		return values
	end
	return nil
end

local BORDER_WIDTH = { thin = "1px", medium = "3px", thick = "5px" }

local function borderSide(st: State, side: string, value: string): boolean
	local width, style, col = "3px", "none", nil :: string?
	for _, t in tokens(value) do
		if BORDER_WIDTH[t] or parseNumber(t) then
			width = BORDER_WIDTH[t] or t
		elseif table.find(BORDER_STYLE, t) then
			style = t
		else
			col = t
		end
	end
	local ok = length(st, "border-" .. side .. "-width", width) and keyword(st, "border-" .. side .. "-style", style)
	if col then
		ok = color(st, "border-" .. side .. "-color", col) and ok
	else
		st.long["border-" .. side .. "-color"] = nil
	end
	return ok
end

local GRADIENT_SIDES: { [string]: number } = {
	["to top"] = 0,
	["to right"] = 90,
	["to bottom"] = 180,
	["to left"] = 270,
	["to top right"] = 45,
	["to right top"] = 45,
	["to bottom right"] = 135,
	["to right bottom"] = 135,
	["to bottom left"] = 225,
	["to left bottom"] = 225,
	["to top left"] = 315,
	["to left top"] = 315,
}

local function gradient(st: State, value: string): boolean
	local body = string.match(value, "^linear%-gradient%((.*)%)$")
	if body == nil then
		return false
	end
	local args = tokens(body, ",")
	for i, a in args do
		args[i] = string.match(a, "^%s*(.-)%s*$") :: string
	end
	local angle = 180
	local first = args[1]
	local v, u = parseNumber(first or "")
	if v and u == "deg" then
		angle = v
		table.remove(args, 1)
	elseif first and GRADIENT_SIDES[first] then
		angle = GRADIENT_SIDES[first]
		table.remove(args, 1)
	end
	local stops: { Rgba } = {}
	for _, a in args do
		local parts = tokens(a)
		local c = M.parseColor(parts[1] or "")
		if c == nil then
			return false
		end
		if #parts > 1 then
			drop(st, "linear-gradient stop positions")
		end
		table.insert(stops, c)
	end
	if #stops < 2 then
		return false
	end
	if #stops > 3 then
		drop(st, "linear-gradient beyond 3 stops")
		stops = { stops[1], stops[#stops // 2 + 1], stops[#stops] }
	end
	local deg = math.floor(angle / 5 + 0.5) * 5 % 360
	local classes = { "dt-ga-" .. deg, "dt-lg" .. #stops }
	for i, c in stops do
		local cs = colSlot(st, c)
		if cs == nil then
			return false
		end
		table.insert(classes, "dt-g" .. i .. "c" .. cs)
	end
	set(st, "background-image", classes)
	return true
end

local function background(st: State, value: string): boolean
	if value == "none" then
		set(st, "background-color", { "dt-bgk-transparent" })
		set(st, "background-image", { "dt-bgi-none" })
		return true
	end
	local ok = true
	local sawColor = false
	for _, t in tokens(value) do
		if string.match(t, "^linear%-gradient%(") then
			ok = gradient(st, t) and ok
		elseif string.find(t, "(", 1, true) and not string.match(t, "^rgba?%(") and not string.match(t, "^hsla?%(") then
			ok = false
		elseif M.parseColor(t) then
			sawColor = true
			ok = color(st, "background-color", t) and ok
		end
	end
	if not sawColor then
		set(st, "background-color", { "dt-bgk-transparent" })
	end
	return ok
end

local function shadow(st: State, value: string): boolean
	if value == "none" then
		set(st, "box-shadow", { "dt-shk-none" })
		return true
	end
	local list = tokens(value, ",")
	if #list > 1 then
		drop(st, "box-shadow beyond the first shadow")
	end
	local inset = false
	local lens: { string } = {}
	local col: Rgba? = nil
	for _, t in tokens(list[1] or "") do
		if t == "inset" then
			inset = true
		elseif parseNumber(t) then
			table.insert(lens, t)
		else
			col = M.parseColor(t)
			if col == nil then
				return false
			end
		end
	end
	if #lens < 2 or #lens > 4 then
		return false
	end
	local classes = { if inset then "dt-shi" else "dt-sh" }
	for i, t in lens do
		local v, u = parseNumber(t)
		if v == nil or (u ~= "px" and u ~= "em" and u ~= "rem" and not (u == "" and v == 0)) then
			return false
		end
		local slot = numSlot(st, v, UNITS[if u == "" then "px" else u])
		if slot == nil then
			return false
		end
		table.insert(classes, "dt-s" .. string.sub("xybs", i, i) .. slot)
	end
	if col then
		local cs = colSlot(st, col)
		if cs == nil then
			return false
		end
		table.insert(classes, "dt-sc" .. cs)
	else
		table.insert(classes, "dt-sc0")
	end
	set(st, "box-shadow", classes)
	return true
end

local function fontFamily(st: State, value: string): boolean
	local v = string.lower(value)
	if v == "inherit" or v == "initial" or v == "unset" then
		return true
	end
	local kind = "sans"
	for _, f in tokens(v, ",") do
		local name = string.match(f, "^%s*['\"]?(.-)['\"]?%s*$") or ""
		if
			name == "monospace"
			or string.find(name, "mono", 1, true)
			or name == "courier"
			or name == "consolas"
			or name == "menlo"
		then
			kind = "mono"
			break
		elseif name == "serif" or name == "georgia" or string.find(name, "times", 1, true) then
			kind = "serif"
			break
		elseif name == "sans-serif" or name == "system-ui" then
			break
		end
	end
	set(st, "font-family", { "dt-ff-" .. kind })
	return true
end

local function flex(st: State, value: string): boolean
	local t = tokens(value)
	local grow, shrink, basis = "0", "1", "auto"
	if value == "none" then
		grow, shrink, basis = "0", "0", "auto"
	elseif value == "auto" then
		grow, shrink, basis = "1", "1", "auto"
	elseif value == "initial" then
		grow, shrink, basis = "0", "1", "auto"
	else
		local nums: { string } = {}
		local b: string? = nil
		for _, w in t do
			local v, u = parseNumber(w)
			if v and u == "" and #nums < 2 and b == nil then
				table.insert(nums, w)
			else
				b = w
			end
		end
		if #nums == 0 then
			grow, shrink, basis = "1", "1", b or "0%"
		else
			grow, shrink, basis = nums[1], nums[2] or "1", b or "0%"
		end
	end
	return length(st, "flex-grow", grow) and length(st, "flex-shrink", shrink) and length(st, "flex-basis", basis)
end

-- One declaration; false when (part of) it is not drawn.
local function declare(st: State, prop: string, value: string): boolean
	if IGNORED[prop] then
		return true
	end
	if value == "inherit" or value == "initial" or value == "unset" or value == "revert" then
		return false
	end
	if string.find(value, "var(", 1, true) or string.find(value, "calc(", 1, true) then
		return false
	end
	if prop == "position" and value == "fixed" then
		drop(st, "position fixed (drawn as absolute)")
		set(st, prop, { "dt-pos-absolute" })
		return true
	elseif LENGTH[prop] then
		return length(st, prop, value)
	elseif KEYWORDS[prop] and not COLOR[prop] and not SHORTHAND_KEYWORD[prop] then
		return keyword(st, prop, value)
	elseif COLOR[prop] then
		return color(st, prop, value)
	elseif prop == "margin" or prop == "padding" then
		local b = box(tokens(value))
		if b == nil then
			return false
		end
		local ok = true
		for i, side in SIDES do
			ok = length(st, prop .. "-" .. side, b[i]) and ok
		end
		return ok
	elseif prop == "inset" then
		local b = box(tokens(value))
		if b == nil then
			return false
		end
		local ok = true
		for i, side in SIDES do
			ok = length(st, side, b[i]) and ok
		end
		return ok
	elseif prop == "gap" or prop == "grid-gap" then
		local t = tokens(value)
		return length(st, "row-gap", t[1] or "") and length(st, "column-gap", t[2] or t[1] or "")
	elseif prop == "overflow" then
		local t = tokens(value)
		return keyword(st, "overflow-x", t[1] or "") and keyword(st, "overflow-y", t[2] or t[1] or "")
	elseif prop == "border" then
		local ok = true
		for _, side in SIDES do
			ok = borderSide(st, side, value) and ok
		end
		return ok
	elseif table.find(SIDES, string.match(prop, "^border%-(%a+)$") or "") then
		return borderSide(st, string.match(prop, "^border%-(%a+)$") :: string, value)
	elseif prop == "border-width" or prop == "border-style" or prop == "border-color" then
		local b = box(tokens(value))
		if b == nil then
			return false
		end
		local kind = string.sub(prop, 8)
		local ok = true
		for i, side in SIDES do
			local long = "border-" .. side .. "-" .. kind
			if kind == "width" then
				ok = length(st, long, BORDER_WIDTH[b[i]] or b[i]) and ok
			elseif kind == "style" then
				ok = keyword(st, long, b[i]) and ok
			else
				ok = color(st, long, b[i]) and ok
			end
		end
		return ok
	elseif prop == "border-radius" then
		local main = string.match(value, "^([^/]*)") :: string
		if main ~= value then
			drop(st, "elliptical border-radius")
		end
		local b = box(tokens(main))
		if b == nil then
			return false
		end
		local ok = true
		for i, corner in CORNERS do
			ok = length(st, "border-" .. corner .. "-radius", b[i]) and ok
		end
		return ok
	elseif prop == "background" then
		return background(st, value)
	elseif prop == "background-image" then
		if value == "none" then
			set(st, prop, { "dt-bgi-none" })
			return true
		end
		return gradient(st, value)
	elseif prop == "box-shadow" then
		return shadow(st, value)
	elseif prop == "font-family" then
		return fontFamily(st, value)
	elseif prop == "font-weight" then
		return keyword(st, prop, value)
	elseif prop == "flex" then
		return flex(st, value)
	elseif prop == "flex-flow" then
		local ok = true
		for _, t in tokens(value) do
			if table.find(KEYWORDS["flex-direction"].values, t) then
				ok = keyword(st, "flex-direction", t) and ok
			else
				ok = keyword(st, "flex-wrap", t) and ok
			end
		end
		return ok
	elseif prop == "text-decoration" then
		for _, t in tokens(value) do
			if table.find(KEYWORDS["text-decoration-line"].values, t) then
				return keyword(st, "text-decoration-line", t)
			end
		end
		return false
	elseif prop == "list-style" then
		for _, t in tokens(value) do
			if table.find(KEYWORDS["list-style-type"].values, t) then
				return keyword(st, "list-style-type", t)
			end
		end
		return false
	elseif prop == "word-wrap" then
		return keyword(st, "overflow-wrap", value)
	end
	return false
end

-- Splits `a: b; c: d` into declarations (semicolons inside parentheses or
-- quotes, as in data: URLs, do not split).
local function declarations(style: string): { { string } }
	local out: { { string } } = {}
	for _, d in tokens(style, ";") do
		local prop, value = string.match(d, "^%s*([%w%-]+)%s*:%s*(.-)%s*$")
		if prop and value and value ~= "" then
			value = string.gsub(value, "%s*!%s*important$", "")
			table.insert(out, { string.lower(prop), value })
		end
	end
	return out
end

local cache: { [string]: Result } = {}
local cached = 0

-- The text panel's sanitizer (packages/grafana-data/src/text/sanitize.ts:
-- js-xss with cssfilter's default whiteList plus flex and gap); Grafana
-- removes every other declaration.
M.TEXT_PANEL_CSS = {} :: { [string]: boolean }
for _, p in
	words(
		"background background-attachment background-clip background-color background-image background-origin "
			.. "background-position background-repeat background-size border border-bottom border-bottom-color "
			.. "border-bottom-left-radius border-bottom-right-radius border-bottom-style border-bottom-width "
			.. "border-collapse border-color border-image border-image-outset border-image-repeat border-image-slice "
			.. "border-image-source border-image-width border-left border-left-color border-left-style "
			.. "border-left-width border-radius border-right border-right-color border-right-style border-right-width "
			.. "border-spacing border-style border-top border-top-color border-top-left-radius border-top-right-radius "
			.. "border-top-style border-top-width border-width box-decoration-break box-shadow box-sizing box-snap "
			.. "box-suppress break-after break-before break-inside clear color color-interpolation-filters display "
			.. "display-inside display-list display-outside font font-family font-feature-settings font-kerning "
			.. "font-language-override font-size font-size-adjust font-stretch font-style font-synthesis font-variant "
			.. "font-variant-alternates font-variant-caps font-variant-east-asian font-variant-ligatures "
			.. "font-variant-numeric font-variant-position font-weight height letter-spacing lighting-color "
			.. "list-style list-style-image list-style-position list-style-type margin margin-bottom margin-left "
			.. "margin-right margin-top max-height max-width min-height min-width padding padding-bottom "
			.. "padding-left padding-right padding-top text-align text-align-last text-combine-upright "
			.. "text-decoration text-decoration-color text-decoration-line text-decoration-skip "
			.. "text-decoration-style text-emphasis text-emphasis-color text-emphasis-position text-emphasis-style "
			.. "text-height text-indent text-justify text-orientation text-overflow text-shadow text-space-collapse "
			.. "text-transform text-underline-position text-wrap width word-break word-spacing word-wrap "
			.. "flex-direction flex-wrap flex-basis flex-grow flex-shrink flex-flow gap order justify-content "
			.. "justify-items justify-self align-items align-content align-self"
	)
do
	M.TEXT_PANEL_CSS[p] = true
end

-- The classes drawing `style`, and what of it is not drawn. With `allow`,
-- declarations of other properties are removed first (not reported: the
-- browser never sees them either).
function M.compile(style: string, allow: { [string]: boolean }?): Result
	local cacheKey = if allow then "\0" .. style else style
	local hit = cache[cacheKey]
	if hit then
		return hit
	end
	local st: State = { long = {}, order = {}, nums = {}, cols = {}, slots = {}, dropped = {}, full = false }
	for _, d in declarations(style) do
		if allow and not allow[d[1]] then
			continue
		end
		local prop, raw = d[1], d[2]
		local value = if prop == "font-family" then raw else string.lower(raw)
		if not declare(st, prop, value) then
			drop(st, prop)
		end
	end
	if st.full then
		drop(st, "more values than one element can hold")
	end
	local classes: { string } = {}
	for _, c in st.slots do
		table.insert(classes, c)
	end
	for _, long in st.order do
		local list = st.long[long]
		if list then
			for _, c in list do
				table.insert(classes, c)
			end
		end
	end
	local result = { class = table.concat(classes, " "), dropped = st.dropped }
	if cached > 4096 then
		table.clear(cache)
		cached = 0
	end
	cache[cacheKey] = result
	cached += 1
	return result
end

-- Stylesheet ---------------------------------------------------------------------

local function slotVar(n: number): string
	return "calc(var(--dt" .. n .. ")*var(--dt" .. n .. "u))"
end

local function colorVar(n: number): string
	return string.format("rgb(var(--dtc%dr) var(--dtc%dg) var(--dtc%db)/var(--dtc%da))", n, n, n, n)
end

local function sortedKeys(t: { [string]: any }): { string }
	local keys: { string } = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

-- plugin/dynamictext.css: the rules every class M.compile emits refers to.
function M.stylesheet(): string
	local out: { string } = {}
	local function add(s: string)
		table.insert(out, s)
	end
	add("/* Generated by scripts/gen-dynamictext-css.luau from plugin/lib/panels/html_style.luau; do not edit. */")
	-- The plugin's row frame (Text.styles.ts) and links.
	add(".tgd{min-width:0;font-family:" .. FONT_FAMILIES.sans .. "}")
	add(".tgd .dt-row{padding:8px;margin-bottom:16px;border-bottom:1px solid var(--l2)}")
	add(".tgd .dt-row:last-child{margin-bottom:0;border-bottom:0}")
	add(".tgd [data-href]{color:var(--sf-c-link);cursor:pointer}")
	add(".tgd [data-href]:hover{text-decoration:underline}")
	local reset: { string } = {}
	for n = 1, M.NUM_SLOTS do
		local terms: { string } = {}
		for _, d in DIGITS do
			table.insert(reset, string.format("--dt%d%s:0", n, d.name))
			table.insert(terms, string.format("var(--dt%d%s)*%s", n, d.name, DIGIT_WEIGHT[d.name]))
		end
		table.insert(reset, string.format("--dt%ds:1;--dt%du:1px", n, n))
		table.insert(reset, string.format("--dt%d:calc((%s)*var(--dt%ds))", n, table.concat(terms, " + "), n))
	end
	for n = 1, M.COLOR_SLOTS do
		table.insert(reset, string.format("--dtc%dr:0;--dtc%dg:0;--dtc%db:0;--dtc%da:1", n, n, n, n))
	end
	table.insert(reset, "--dtsb:0px;--dtss:0px;--dtsc:currentColor;--dtga:180deg")
	add(".tgd,.tgd *{" .. table.concat(reset, ";") .. "}")
	for n = 1, M.NUM_SLOTS do
		for _, d in DIGITS do
			for digit = 1, 9 do
				add(string.format(".dt%d%s%d{--dt%d%s:%d}", n, d.name, digit, n, d.name, digit))
			end
		end
		add(string.format(".dt%dn{--dt%ds:-1}", n, n))
		for _, u in UNIT_ORDER do
			add(string.format(".dt%du%s{--dt%du:%s}", n, u, n, UNIT_CSS[u]))
		end
	end
	for n = 1, M.COLOR_SLOTS do
		for _, ch in { "r", "g", "b" } do
			for v = 1, 255 do
				add(string.format(".dtc%d%s%d{--dtc%d%s:%d}", n, ch, v, n, ch, v))
			end
		end
		for a = 0, 99 do
			add(string.format(".dtc%da%d{--dtc%da:%s}", n, a, n, if a < 10 then ".0" .. a else "." .. a))
		end
	end
	for _, prop in sortedKeys(LENGTH) do
		local code = LENGTH[prop]
		for n = 1, M.NUM_SLOTS do
			add(string.format(".dt-%s%d{%s:%s}", code, n, prop, slotVar(n)))
		end
	end
	for _, kw in sortedKeys(LENGTH_KEYWORDS) do
		for _, prop in LENGTH_KEYWORDS[kw] do
			add(string.format(".dt-%s-%s{%s:%s}", LENGTH[prop], kw, prop, kw))
		end
	end
	for _, prop in sortedKeys(KEYWORDS) do
		local k = KEYWORDS[prop]
		for _, v in k.values do
			add(string.format(".dt-%s-%s{%s:%s}", k.code, v, prop, v))
		end
	end
	for _, prop in sortedKeys(COLOR) do
		for n = 1, M.COLOR_SLOTS do
			-- An inline color beats the link color of an element inside a link.
			local sel = string.format(".dt-%s%d", COLOR[prop], n)
			if prop == "color" then
				sel = sel .. ",.tgd [data-href]" .. sel
			end
			add(string.format("%s{%s:%s}", sel, prop, colorVar(n)))
		end
	end
	for _, kind in sortedKeys(FONT_FAMILIES) do
		add(string.format(".dt-ff-%s{font-family:%s}", kind, FONT_FAMILIES[kind]))
	end
	for n = 1, M.NUM_SLOTS do
		for _, v in { "x", "y", "b", "s" } do
			add(string.format(".dt-s%s%d{--dts%s:%s}", v, n, v, slotVar(n)))
		end
	end
	for deg = 0, 355, 5 do
		add(string.format(".dt-ga-%d{--dtga:%ddeg}", deg, deg))
	end
	add(".dt-sc0{--dtsc:currentColor}")
	for n = 1, M.COLOR_SLOTS do
		add(string.format(".dt-sc%d{--dtsc:%s}", n, colorVar(n)))
		for g = 1, 3 do
			add(string.format(".dt-g%dc%d{--dtg%d:%s}", g, n, g, colorVar(n)))
		end
	end
	add(".dt-sh{box-shadow:var(--dtsx) var(--dtsy) var(--dtsb) var(--dtss) var(--dtsc)}")
	add(".dt-shi{box-shadow:inset var(--dtsx) var(--dtsy) var(--dtsb) var(--dtss) var(--dtsc)}")
	add(".dt-lg2{background:linear-gradient(var(--dtga),var(--dtg1),var(--dtg2))}")
	add(".dt-lg3{background:linear-gradient(var(--dtga),var(--dtg1),var(--dtg2),var(--dtg3))}")
	return table.concat(out, "\n") .. "\n"
end

return M
