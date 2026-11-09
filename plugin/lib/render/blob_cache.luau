--!strict
-- Blob ids by content. Tern keeps every blob file a block sends for the rest
-- of the session (no eviction observed), so unchanged chart bytes must reuse
-- their id instead of minting a new blob. Two levels:
-- - per asset key, the last bytes and id: an unchanged view costs one string
--   comparison, no hashing; keys the latest view pass did not use are swept;
-- - a bounded LRU of ids by content hash (length, mime), so the same bytes
--   under another key, or returning to earlier bytes, reuse ids.

local Hash = require("../hash")

local M = {}

M.DEFAULT_CAPACITY = 64

-- FNV-1a 64-bit as 16 hex digits (lib/hash; watch default names persist it).
M.fnv1a64 = Hash.fnv1a64

local TWO32 = 0x100000000

-- An in-memory content digest (never persisted, free to change): two 32-bit
-- multiply-xor lanes over 4-byte little-endian words, so about a quarter of
-- the steps of a byte-wise hash. As 16 hex digits.
function M.digest(s: string): string
	local n = #s
	local b = buffer.fromstring(s)
	local h1 = bit32.bxor(0x811c9dc5, n)
	local h2 = bit32.bxor(0x9747b28c, n)
	local words = n // 4
	for i = 0, words * 4 - 4, 4 do
		local w = buffer.readu32(b, i)
		-- h1 * 16777619 (2^24 + 403) and h2 * 0x5bd1e995, exact mod 2^32.
		local x = bit32.bxor(h1, w)
		h1 = (bit32.lshift(x, 24) + x * 403) % TWO32
		local y = bit32.bxor(h2, bit32.lrotate(w, 13))
		h2 = (bit32.lshift((y * 0x5bd1) % TWO32, 16) + y * 0xe995) % TWO32
		h2 = bit32.bxor(h2, bit32.rshift(h2, 15))
	end
	for i = words * 4, n - 1 do
		local w = buffer.readu8(b, i)
		local x = bit32.bxor(h1, w)
		h1 = (bit32.lshift(x, 24) + x * 403) % TWO32
		local y = bit32.bxor(h2, w)
		h2 = (bit32.lshift((y * 0x5bd1) % TWO32, 16) + y * 0xe995) % TWO32
	end
	h2 = bit32.bxor(h2, bit32.rshift(h1, 15))
	return string.format("%08x%08x", h1, h2)
end

type Memo = { bytes: string, mime: string, id: string, pass: number }

export type Cache = {
	capacity: number,
	ids: { [string]: string },
	stamps: { [string]: number },
	size: number,
	clock: number,
	last: { [string]: Memo },
	-- The current view pass; `last` entries from older passes are swept.
	pass: number,
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
		pass = 0,
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
		memo.pass = cache.pass
		return memo.id
	end
	local h = M.digest(bytes) .. ":" .. #bytes .. ":" .. mime
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
	cache.last[assetKey] = { bytes = bytes, mime = mime, id = id :: string, pass = cache.pass }
	return id :: string
end

-- Ends a view pass: forgets the last bytes of asset keys the pass did not
-- use (their ids stay in the LRU), so a long session does not keep every
-- chart it ever showed.
function M.sweep(cache: Cache)
	local pass = cache.pass
	for key, memo in cache.last do
		if memo.pass ~= pass then
			cache.last[key] = nil
		end
	end
	cache.pass = pass + 1
end

return M
