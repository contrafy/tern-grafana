--!strict
-- Tern keeps every blob a block sends for the session (no eviction), so an
-- unchanged chart must reuse its id instead of minting another blob, while
-- the id cache itself stays bounded.
local t = require("../../lib/test")
local Assets = require("../../../plugin/lib/render/assets")
local BlobCache = require("../../../plugin/lib/render/blob_cache")
local describe, it, expect = t.describe, t.it, t.expect

local function minter(): (BlobCache.Mint, () -> number)
	local count = 0
	local mint = function(bytes: string, mime: string): string
		count += 1
		return "id" .. count .. ":" .. #bytes .. ":" .. mime
	end
	return mint, function()
		return count
	end
end

describe("BlobCache.fnv1a64", function()
	it("matches the published FNV-1a 64 test vectors", function()
		expect(BlobCache.fnv1a64("")).toBe("cbf29ce484222325")
		expect(BlobCache.fnv1a64("a")).toBe("af63dc4c8601ec8c")
		expect(BlobCache.fnv1a64("foobar")).toBe("85944171f73967e8")
	end)

	it("separates inputs that differ in one byte", function()
		expect(BlobCache.fnv1a64("<svg>1</svg>") ~= BlobCache.fnv1a64("<svg>2</svg>")).toBe(true)
	end)
end)

describe("BlobCache.get", function()
	it("returns the same id for the same bytes without minting again", function()
		local cache = BlobCache.new()
		local mint, count = minter()
		local a = BlobCache.get(cache, "chart", "<svg>a</svg>", Assets.SVG, mint)
		local b = BlobCache.get(cache, "chart", "<svg>a</svg>", Assets.SVG, mint)
		expect(a).toBe(b)
		expect(count()).toBe(1)
	end)

	-- Identical bytes under another key (a second panel, a re-render after
	-- flipping back) are found by content.
	it("reuses ids by content across asset keys and earlier versions", function()
		local cache = BlobCache.new()
		local mint, count = minter()
		local first = BlobCache.get(cache, "p1", "v1", Assets.SVG, mint)
		expect(BlobCache.get(cache, "p2", "v1", Assets.SVG, mint)).toBe(first)
		BlobCache.get(cache, "p1", "v2", Assets.SVG, mint)
		expect(BlobCache.get(cache, "p1", "v1", Assets.SVG, mint)).toBe(first)
		expect(count()).toBe(2)
	end)

	it("treats a different mime as different content", function()
		local cache = BlobCache.new()
		local mint, count = minter()
		BlobCache.get(cache, "a", "bytes", Assets.SVG, mint)
		BlobCache.get(cache, "b", "bytes", Assets.PNG, mint)
		expect(count()).toBe(2)
	end)

	it("evicts the least recently used id beyond capacity", function()
		local cache = BlobCache.new(2)
		local mint, count = minter()
		BlobCache.get(cache, "k1", "A", Assets.SVG, mint)
		BlobCache.get(cache, "k2", "B", Assets.SVG, mint)
		-- Touch A so B is the oldest.
		BlobCache.get(cache, "k3", "A", Assets.SVG, mint)
		BlobCache.get(cache, "k4", "C", Assets.SVG, mint)
		expect(cache.size).toBe(2)
		expect(count()).toBe(3)
		-- A survived; B was evicted and is minted again.
		BlobCache.get(cache, "k5", "A", Assets.SVG, mint)
		expect(count()).toBe(3)
		BlobCache.get(cache, "k6", "B", Assets.SVG, mint)
		expect(count()).toBe(4)
		expect(cache.size).toBe(2)
	end)
end)

describe("Assets.materialize", function()
	it("swaps asset keys for blob ids throughout the tree", function()
		local image: any = { k = "image", p = { asset = "chart", alt = "x" } }
		local row: any = { k = "row", c = { { k = "image", p = { asset = "missing" } } } }
		local node: any = { k = "col", c = { image, row } }
		local assets = { chart = { mime = Assets.SVG, bytes = "<svg/>" } }
		local out = Assets.materialize(node, assets, function(key, asset)
			return key .. "=" .. asset.bytes
		end)
		local c = out.c :: { any }
		expect(c[1].p.blob).toBe("chart=<svg/>")
		expect(c[1].p.asset).toBeNil()
		-- No bytes: no blob, so Tern shows the placeholder rather than a stale image.
		expect(c[2].c[1].p.blob).toBeNil()
		expect(c[2].c[1].p.asset).toBeNil()
	end)
end)

return nil
