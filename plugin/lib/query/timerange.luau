--!strict
-- Range keys shared by the blocks that show a time range: quick ranges on
-- 1..9, `[`/`]` shift by half a span, `-`/`+` zoom. Ranges stay Grafana time
-- strings ("now-1h", or epoch-ms digits once absolute) so they round-trip
-- through links and saved state.

local Range = require("../time/range")

local M = {}

-- Keys 1..9.
M.QUICK = table.freeze({ "5m", "15m", "1h", "3h", "6h", "12h", "24h", "2d", "7d" })

-- Narrowest live range a zoom in produces.
M.MIN_SPAN_MS = 10000

local UNITS: { [string]: number } = { s = 1000, m = 60000, h = 3600000, d = 86400000, w = 604800000 }
local UNIT_ORDER = { "w", "d", "h", "m", "s" }

local function ms(n: number): string
	return string.format("%d", math.floor(n))
end

function M.quick(i: number): (string?, string?)
	local q = M.QUICK[i]
	if q == nil then
		return nil, nil
	end
	return "now-" .. q, "now"
end

-- Span of a live range ("now-<N><unit>" to "now"), nil for any other range.
function M.liveSpan(from: string, to: string): number?
	if to ~= "now" then
		return nil
	end
	local n, unit = string.match(from, "^now%-(%d+)([smhdw])$")
	if n == nil or unit == nil then
		return nil
	end
	return (tonumber(n) :: number) * UNITS[unit]
end

-- "now-<N><unit>" in the largest unit that divides the span.
function M.liveFrom(span_ms: number): string
	local span = math.max(1000, math.floor(span_ms / 1000 + 0.5) * 1000)
	for _, unit in UNIT_ORDER do
		local size = UNITS[unit]
		if span % size == 0 then
			return "now-" .. ms(span // size) .. unit
		end
	end
	return "now-" .. ms(span // 1000) .. "s"
end

-- Half a span back (-1) or forward (+1), as absolute times.
function M.shift(from: string, to: string, dir: number, now_ms: number): (string?, string?)
	local r = Range.resolve(from, to, { now_ms = now_ms })
	if r == nil then
		return nil, nil
	end
	local s = Range.shift(r, dir)
	return ms(s.from_ms), ms(s.to_ms)
end

-- `factor` > 1 zooms out. A live range stays live (its end stays at now);
-- any other range zooms around its center.
function M.zoom(from: string, to: string, factor: number, now_ms: number): (string?, string?)
	local span = M.liveSpan(from, to)
	if span then
		return M.liveFrom(math.max(M.MIN_SPAN_MS, span * factor)), "now"
	end
	local r = Range.resolve(from, to, { now_ms = now_ms })
	if r == nil then
		return nil, nil
	end
	local z = Range.zoom(r, factor)
	if z.to_ms - z.from_ms < M.MIN_SPAN_MS then
		return nil, nil
	end
	return ms(z.from_ms), ms(z.to_ms)
end

-- The range after typing `ch` (a key's text), nil when it is not a range key.
function M.forKey(ch: string, from: string, to: string, now_ms: number): (string?, string?)
	local digit = string.match(ch, "^[1-9]$")
	if digit then
		return M.quick(tonumber(digit) :: number)
	elseif ch == "[" then
		return M.shift(from, to, -1, now_ms)
	elseif ch == "]" then
		return M.shift(from, to, 1, now_ms)
	elseif ch == "-" then
		return M.zoom(from, to, 2, now_ms)
	elseif ch == "+" or ch == "=" then
		return M.zoom(from, to, 0.5, now_ms)
	end
	return nil, nil
end

return M
