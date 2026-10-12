--!strict
-- A flame graph (icicle) as SVG (packages/grafana-flamegraph/src/
-- FlameGraph/rendering.ts, colors.ts, murmur3.ts, constants.ts):
-- - a 22 px row per level, the root on top; a bar's width is its ticks
--   over the root's (less 0.5 px borders), bars under 0.5 px are left out
--   with their children;
-- - package based colors: the label's package name (the profiler name
--   matchers) hashed with murmurhash3_32_gc picks one of Grafana's 24
--   package colors; value based: hue 50 -> 0 and lightness 65 -> 72 with
--   the bar's share of the total;
-- - bars at least 20 px wide carry "label (value)" in 12 px monospace,
--   #222, cut at the bar's end; outlines are white as on Grafana's canvas.
-- Colors are Grafana's fixed colors as literal attributes; no <title>.

local Kit = require("./svg_kit")

local M = {}

local fmt = string.format

M.PIXELS_PER_LEVEL = 22
M.HIDE_THRESHOLD = 0.5
M.LABEL_THRESHOLD = 20
M.BAR_BORDER_WIDTH = 0.5
M.BAR_TEXT_PADDING_LEFT = 4
-- 12 px monospace advance.
M.MONO_CHAR_PX = 7.2

local U32 = 4294967296

local function u32(v: number): number
	return v % U32
end

local function mul32(a: number, c: number): number
	-- ((a & 0xffff) * c + ((((a >>> 16) * c) & 0xffff) << 16)) & 0xffffffff
	local lo = bit32.band(a, 0xffff) * c
	local hi = bit32.lshift(bit32.band(bit32.rshift(a, 16) * c % U32, 0xffff), 16)
	return u32(lo + hi)
end

local function rotl(v: number, n: number): number
	return bit32.bor(bit32.lshift(v, n), bit32.rshift(v, 32 - n))
end

-- murmurhash3_32_gc over the label's UTF-16 code units (low bytes).
function M.murmur3(key: string, seed: number?): number
	local codes: { number } = {}
	for _, cp in utf8.codes(key) do
		if cp >= 0x10000 then
			local v = cp - 0x10000
			table.insert(codes, 0xd800 + bit32.rshift(v, 10))
			table.insert(codes, 0xdc00 + bit32.band(v, 0x3ff))
		else
			table.insert(codes, cp)
		end
	end
	local len = #codes
	local remainder = bit32.band(len, 3)
	local bytes = len - remainder
	local h1 = u32(seed or 0)
	local c1, c2 = 0xcc9e2d51, 0x1b873593
	local i = 1
	while i <= bytes do
		local k1 = bit32.bor(
			bit32.band(codes[i], 0xff),
			bit32.lshift(bit32.band(codes[i + 1], 0xff), 8),
			bit32.lshift(bit32.band(codes[i + 2], 0xff), 16),
			bit32.lshift(bit32.band(codes[i + 3], 0xff), 24)
		)
		i += 4
		k1 = mul32(k1, c1)
		k1 = rotl(k1, 15)
		k1 = mul32(k1, c2)
		h1 = bit32.bxor(h1, k1)
		h1 = rotl(h1, 13)
		local h1b = mul32(h1, 5)
		h1 =
			u32(bit32.band(h1b, 0xffff) + 0x6b64 + bit32.lshift(bit32.band(bit32.rshift(h1b, 16) + 0xe654, 0xffff), 16))
	end
	local k1 = 0
	if remainder >= 3 then
		k1 = bit32.bxor(k1, bit32.lshift(bit32.band(codes[i + 2], 0xff), 16))
	end
	if remainder >= 2 then
		k1 = bit32.bxor(k1, bit32.lshift(bit32.band(codes[i + 1], 0xff), 8))
	end
	if remainder >= 1 then
		k1 = bit32.bxor(k1, bit32.band(codes[i], 0xff))
	end
	k1 = mul32(k1, c1)
	k1 = rotl(k1, 15)
	k1 = mul32(k1, c2)
	h1 = bit32.bxor(h1, k1)
	h1 = bit32.bxor(h1, len)
	h1 = bit32.bxor(h1, bit32.rshift(h1, 16))
	h1 = mul32(h1, 0x85ebca6b)
	h1 = bit32.bxor(h1, bit32.rshift(h1, 13))
	h1 = mul32(h1, 0xc2b2ae35)
	h1 = bit32.bxor(h1, bit32.rshift(h1, 16))
	return h1
end

-- tinycolor HSL (h degrees, s and l percent) to hex.
local function hsl(h: number, s: number, l: number): string
	local sf, lf = s / 100, l / 100
	local function f(n: number): number
		local k = (n + h / 30) % 12
		local a = sf * math.min(lf, 1 - lf)
		return lf - a * math.max(-1, math.min(k - 3, 9 - k, 1))
	end
	return fmt(
		"#%02x%02x%02x",
		math.floor(f(0) * 255 + 0.5),
		math.floor(f(8) * 255 + 0.5),
		math.floor(f(4) * 255 + 0.5)
	)
end

-- packageColors.
M.PACKAGE_COLORS = {
	hsl(24, 69, 60),
	hsl(34, 65, 65),
	hsl(194, 52, 61),
	hsl(163, 45, 55),
	hsl(211, 48, 60),
	hsl(246, 40, 65),
	hsl(305, 63, 79),
	hsl(47, 100, 73),
	"#b7dbab",
	"#f4d598",
	"#4e92f9",
	"#f9ba8f",
	"#f29191",
	"#82b5d8",
	"#e5a8e2",
	"#aea2e0",
	"#9ac48a",
	"#f2c96d",
	"#65c5db",
	"#f9934e",
	"#ea6460",
	"#5195ce",
	"#d683ce",
	"#806eb7",
}

-- getPackageName: the profiler matchers in Grafana's order (phpspy, pyspy,
-- rbspy, nodespy, then gospy, which matches any non-empty name).
function M.packageName(name: string): string?
	if name == "" then
		return nil
	end
	for _, ext in { "%.php+", "%.py+", "%.rb+" } do
		local s = string.find(name, ext)
		if s then
			-- Directories before the file.
			local prefix = string.sub(name, 1, s)
			local slash = string.match(prefix, "^.*()/")
			return if slash then string.sub(name, 1, slash) else ""
		end
	end
	local rest = string.gsub(name, "^%./node_modules/", "")
	local colons = select(2, string.gsub(rest, ":", ":"))
	if colons >= 2 then
		local secondLast = 0
		local seen = 0
		for at = #rest, 1, -1 do
			if string.sub(rest, at, at) == ":" then
				seen += 1
				if seen == 2 then
					secondLast = at
					break
				end
			end
		end
		local slash = string.find(rest, "/", 1, true)
		local stop = if slash and slash < secondLast then slash - 1 else secondLast - 1
		return string.sub(rest, 1, stop)
	end
	-- gospy: through the first "." after a "/", else through the first ".",
	-- else the whole name.
	local slash = string.find(name, "/", 1, true)
	if slash then
		local dot = string.find(name, ".", slash + 1, true)
		if dot then
			return string.sub(name, 1, dot)
		end
	end
	local dot = string.find(name, ".", 1, true)
	if dot then
		return string.sub(name, 1, dot)
	end
	return name
end

function M.packageColor(label: string, light: boolean?): string
	local hash = M.murmur3(M.packageName(label) or "", 0)
	local c = M.PACKAGE_COLORS[hash % #M.PACKAGE_COLORS + 1]
	if light then
		-- tinycolor brighten(15): each channel + 255 * 15%.
		local r = tonumber(string.sub(c, 2, 3), 16) :: number
		local g = tonumber(string.sub(c, 4, 5), 16) :: number
		local b = tonumber(string.sub(c, 6, 7), 16) :: number
		local d = math.floor(255 * 0.15 + 0.5)
		return fmt("#%02x%02x%02x", math.min(255, r + d), math.min(255, g + d), math.min(255, b + d))
	end
	return c
end

-- getBarColorByValue.
function M.valueColor(value: number, total: number): string
	local intensity = math.min(1, value / total)
	return hsl(50 - 50 * intensity, 100, 65 + 7 * intensity)
end

export type Bar = {
	level: number,
	-- Ticks before the bar on its level and the bar's ticks.
	start: number,
	value: number,
	label: string,
	-- Text after the label, "(value)".
	value_text: string,
	color: string,
}

export type Options = {
	width: number,
	total: number,
	levels: number,
	bars: { Bar },
	-- Most levels drawn (the rest would not fit the panel).
	max_levels: number?,
}

function M.render(opts: Options): string
	local W = math.max(40, opts.width)
	local levels = math.min(opts.levels, opts.max_levels or opts.levels)
	local H = math.max(1, levels) * M.PIXELS_PER_LEVEL
	local perTick = W / math.max(opts.total, 1e-12)
	local out: { string } = { Kit.open(W, H) }
	local rects: { string } = {}
	local texts: { string } = {}
	-- Byte budget: about 110 bytes a bar; past it, narrow bars go first
	-- (their children are narrower still).
	local minWidth = M.HIDE_THRESHOLD
	while true do
		local n = 0
		for _, b in opts.bars do
			if b.level < levels and b.value * perTick - M.BAR_BORDER_WIDTH * 2 >= minWidth then
				n += 1
			end
		end
		if n * 150 <= Kit.TARGET then
			break
		end
		minWidth *= 2
	end
	for _, b in opts.bars do
		if b.level >= levels then
			continue
		end
		local width = b.value * perTick - M.BAR_BORDER_WIDTH * 2
		if width < minWidth then
			continue
		end
		local x = b.start * perTick
		local y = b.level * M.PIXELS_PER_LEVEL
		table.insert(
			rects,
			fmt(
				'<rect x="%.1f" y="%d" width="%.1f" height="%d" fill="%s" stroke="#ffffff" stroke-width="1"/>',
				x + M.BAR_BORDER_WIDTH,
				y,
				width,
				M.PIXELS_PER_LEVEL,
				b.color
			)
		)
		if width >= M.LABEL_THRESHOLD then
			local text = b.label .. " " .. b.value_text
			local fits = math.floor((width - M.BAR_TEXT_PADDING_LEFT) / M.MONO_CHAR_PX)
			if fits > 0 then
				local len = utf8.len(text) or #text
				if len > fits then
					local stop = utf8.offset(text, fits + 1)
					text = string.sub(text, 1, (stop or (#text + 1)) - 1)
				end
				table.insert(
					texts,
					Kit.text(x + M.BAR_TEXT_PADDING_LEFT, y + M.PIXELS_PER_LEVEL / 2 + 2, text, {
						anchor = "start",
						class = "tgf-text",
						attrs = 'dominant-baseline="central" font-family="monospace" fill="#222222"',
					})
				)
			end
		end
	end
	table.insert(out, table.concat(rects))
	table.insert(out, table.concat(texts))
	return Kit.finish(out, "flamegraph")
end

return M
