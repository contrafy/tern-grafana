--!strict
-- Blob ids by content. Tern keeps every blob file a block sends for the rest
-- of the session (no eviction observed), so unchanged chart bytes must reuse
-- their id instead of minting a new blob. Two levels:
-- - per asset key, the last bytes and id: an unchanged view costs one string
--   comparison, no hashing;
-- - a bounded LRU of ids by content hash (FNV-1a 64, length, mime), so the
--   same bytes under another key, or returning to earlier bytes, reuse ids.

local M = {}

M.DEFAULT_CAPACITY = 64

local TWO32 = 0x100000000

-- FNV-1a 64-bit as 16 hex digits, on two 32-bit halves (Luau numbers are
-- doubles). The prime is 2^40 + 0x1b3, so h * prime = h * 0x1b3 + (h << 40).
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

type Memo = { bytes: string, mime: string, id: string }

export type Cache = {
	capacity: number,
	ids: { [string]: string },
	stamps: { [string]: number },
	size: number,
	clock: number,
	last: { [string]: Memo },
}

export type Mint = (bytes: string, mime: string) -> string

function M.new(capacity: number?): Cache
	return {
		capacity = math.max(1, capacity or M.DEFAULT_CAPACITY),
		ids = {},
		stamps = {},
		size = 0,
		clock = 0,
		last = {},
	}
end

local function evictOldest(cache: Cache)
	local oldest: string? = nil
	local stamp = math.huge
	for h, s in cache.stamps do
		if s < stamp then
			oldest, stamp = h, s
		end
	end
	if oldest then
		cache.ids[oldest] = nil
		cache.stamps[oldest] = nil
		cache.size -= 1
	end
end

-- The blob id for `bytes`, calling `mint` only for content not cached.
function M.get(cache: Cache, assetKey: string, bytes: string, mime: string, mint: Mint): string
	local memo = cache.last[assetKey]
	if memo and memo.mime == mime and memo.bytes == bytes then
		return memo.id
	end
	local h = M.fnv1a64(bytes) .. ":" .. #bytes .. ":" .. mime
	cache.clock += 1
	local id = cache.ids[h]
	if id == nil then
		id = mint(bytes, mime)
		cache.ids[h] = id
		cache.size += 1
		if cache.size > cache.capacity then
			cache.stamps[h] = cache.clock
			evictOldest(cache)
		end
	end
	cache.stamps[h] = cache.clock
	cache.last[assetKey] = { bytes = bytes, mime = mime, id = id :: string }
	return id :: string
end

return M
