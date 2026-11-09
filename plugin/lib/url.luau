--!strict
-- URL helpers.

local M = {}

-- %XX for every byte, precomputed: gsub then needs no closure call per byte.
local ESCAPES: { [string]: string } = {}
for b = 0, 255 do
	local c = string.char(b)
	ESCAPES[c] = string.format("%%%02X", b)
end

-- RFC 3986 percent-encoding: unreserved characters (ALPHA, DIGIT, "-", ".",
-- "_", "~") stay, every other byte becomes %XX (upper-case hex). Usable for
-- query keys, values and single path segments; also Grafana's
-- encodeURIComponentStrict, which encodes !'()* as well.
function M.percentEncode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", ESCAPES))
end

return M
