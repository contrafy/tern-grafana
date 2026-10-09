--!strict
-- Silence durations: the form's presets, custom durations such as `90m` or
-- `1d12h`, their display, and the RFC 3339 times Alertmanager expects.

local M = {}

export type Preset = { label: string, s: number }

M.PRESETS = table.freeze({
	table.freeze({ label = "1h", s = 3600 }),
	table.freeze({ label = "2h", s = 7200 }),
	table.freeze({ label = "4h", s = 14400 }),
	table.freeze({ label = "1d", s = 86400 }),
}) :: { Preset }

-- Index of the "custom" choice after the presets.
M.CUSTOM = #M.PRESETS + 1

-- Alertmanager accepts any end time; a year bounds typos like `100000h`.
M.MAX_S = 366 * 86400

local UNIT: { [string]: number } = { w = 604800, d = 86400, h = 3600, m = 60, s = 1 }

-- Seconds in `1h`, `90m`, `1d12h`, `2w` (units w, d, h, m, s; spaces
-- allowed between parts); nil and why otherwise.
function M.parse(text: string): (number?, string?)
	local rest = string.lower((string.gsub(text, "%s+", "")))
	if rest == "" then
		return nil, "enter a duration such as 90m, 3h or 1d12h"
	end
	local total = 0
	while rest ~= "" do
		local n, unit, tail = string.match(rest, "^(%d+)([wdhms])(.*)$")
		if n == nil or unit == nil or tail == nil then
			return nil, string.format("%q is not a duration (use w, d, h, m, s: 90m, 3h, 1d12h)", text)
		end
		total += (tonumber(n) :: number) * UNIT[unit :: string]
		rest = tail :: string
	end
	if total <= 0 then
		return nil, "the duration must be longer than zero"
	end
	if total > M.MAX_S then
		return nil, "a silence lasts at most 366 days"
	end
	return total, nil
end

local UNITS: { { name: string, size: number } } = {
	{ name = "d", size = 86400 },
	{ name = "h", size = 3600 },
	{ name = "m", size = 60 },
}

-- "1d 2h", "45m", "30s"; at most two units.
function M.format(s: number): string
	local sec = math.max(0, math.floor(s))
	if sec < 60 then
		return sec .. "s"
	end
	local parts: { string } = {}
	for _, u in UNITS do
		if sec >= u.size and #parts < 2 then
			table.insert(parts, (sec // u.size) .. u.name)
			sec %= u.size
		elseif #parts > 0 then
			break
		end
	end
	return table.concat(parts, " ")
end

-- RFC 3339 UTC with milliseconds, as Alertmanager returns times.
function M.iso(ms: number): string
	local whole = math.floor(ms / 1000)
	local frac = math.floor(ms - whole * 1000)
	return os.date("!%Y-%m-%dT%H:%M:%S", whole) .. string.format(".%03dZ", frac)
end

return M
