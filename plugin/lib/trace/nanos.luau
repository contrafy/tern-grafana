--!strict
-- Exact nanosecond timestamps. OTLP JSON writes epoch nanoseconds as decimal
-- strings ("1791577563622704346"), about 2^60: a double rounds them to 256 ns,
-- which would turn back-to-back spans into overlapping ones. A timestamp is
-- whole seconds plus nanoseconds; differences within a trace (well under
-- 2^53 ns, 104 days) are exact.

local Types = require("./types")

type Nano = Types.Nano

local M = {}

local NS = 1e9

local function normalize(sec: number, nsec: number): Nano
	local carry = nsec // NS
	return { sec = sec + carry, nsec = nsec - carry * NS }
end

-- A decimal string of epoch nanoseconds or a number (already rounded by the
-- JSON decoder); nil for anything else.
function M.parse(v: any): Nano?
	if type(v) == "string" then
		if not string.match(v, "^%d+$") then
			return nil
		end
		local n = #v
		if n <= 9 then
			return { sec = 0, nsec = tonumber(v) :: number }
		end
		return {
			sec = tonumber(string.sub(v, 1, n - 9)) :: number,
			nsec = tonumber(string.sub(v, n - 8)) :: number,
		}
	elseif type(v) == "number" and v >= 0 and v == v and v ~= math.huge then
		local sec = v // NS
		return normalize(sec, math.floor(v - sec * NS))
	end
	return nil
end

-- Epoch milliseconds (fractional), as Grafana's data frames carry times.
function M.fromMs(ms: number): Nano
	local sec = ms // 1000
	return normalize(sec, math.floor((ms - sec * 1000) * 1e6 + 0.5))
end

function M.toMs(t: Nano): number
	return t.sec * 1000 + t.nsec / 1e6
end

-- a - b in nanoseconds.
function M.diff(a: Nano, b: Nano): number
	return (a.sec - b.sec) * NS + (a.nsec - b.nsec)
end

-- t + ns.
function M.add(t: Nano, ns: number): Nano
	local whole = ns // NS
	return normalize(t.sec + whole, t.nsec + (ns - whole * NS))
end

function M.less(a: Nano, b: Nano): boolean
	return a.sec < b.sec or (a.sec == b.sec and a.nsec < b.nsec)
end

return M
