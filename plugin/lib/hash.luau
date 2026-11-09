--!strict
-- FNV-1a hashes. Their outputs are persisted or compared (Loki line ids,
-- settings base_hash, watch default names, handoff nonces): they never change.

local M = {}

local TWO32 = 0x100000000

-- FNV-1a 32-bit as a number in [0, 2^32). The prime 16777619 = 2^24 + 403
-- keeps every product exact in a double.
function M.fnv1a32(s: string): number
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		h = (bit32.lshift(h, 24) + h * 403) % TWO32
	end
	return h
end

-- FNV-1a 32-bit as 8 lower-case hex digits.
function M.fnv1a32hex(s: string): string
	return string.format("%08x", M.fnv1a32(s))
end

-- FNV-1a 64-bit as 16 lower-case hex digits, on two 32-bit halves (Luau
-- numbers are doubles). The prime is 2^40 + 0x1b3, so
-- h * prime = h * 0x1b3 + (h << 40).
function M.fnv1a64(s: string): string
	local hi, lo = 0xcbf29ce4, 0x84222325
	local b = buffer.fromstring(s)
	for i = 0, #s - 1 do
		lo = bit32.bxor(lo, buffer.readu8(b, i))
		local l = lo * 0x1b3
		hi = (hi * 0x1b3 + l // TWO32 + bit32.lshift(lo, 8)) % TWO32
		lo = l % TWO32
	end
	return string.format("%08x%08x", hi, lo)
end

return M
