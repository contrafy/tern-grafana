--!strict
-- Turns a pure view's assets into blob ids for one block: `cx:blob` sends the
-- bytes, and lib/render/blob_cache decides when that is needed. One cache per
-- block `cx` (Tern passes the same `cx` to every handler of a block, and a
-- blob belongs to the pane it was sent to); weak keys drop it with the block.

local Assets = require("./lib/render/assets")
local BlobCache = require("./lib/render/blob_cache")
local ui = require("./lib/ui")

local M = {}

local caches: { [BlockCx]: BlobCache.Cache } = setmetatable({}, { __mode = "k" }) :: any

-- Replaces every `p.asset` in `node` (in place) with a blob id; returns `node`.
function M.materialize(node: ui.Node, assets: Assets.Assets, cx: BlockCx): ui.Node
	local cache = caches[cx]
	if cache == nil then
		cache = BlobCache.new()
		caches[cx] = cache
	end
	local mint = function(bytes: string, mime: string): string
		return cx:blob(bytes, mime)
	end
	return Assets.materialize(node, assets, function(key: string, asset: Assets.Asset): string
		return BlobCache.get(cache :: BlobCache.Cache, key, asset.bytes, asset.mime, mint)
	end)
end

return M
