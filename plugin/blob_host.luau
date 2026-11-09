--!strict
-- Turns a pure view's assets into blob ids for one block: `cx:blob` sends the
-- bytes, and lib/render/blob_cache decides when that is needed. One cache per
-- block `cx` (Tern passes the same `cx` to every handler of a block, and a
-- blob belongs to the pane it was sent to); weak keys drop it with the block.

local Assets = require("./lib/render/assets")
local BlobCache = require("./lib/render/blob_cache")
local ui = require("./lib/ui")

local M = {}

export type Regions = { main: ui.Node?, dock: ui.Node?, layer: ui.Node? }

local caches: { [BlockCx]: BlobCache.Cache } = setmetatable({}, { __mode = "k" }) :: any

-- Replaces every `p.asset` in the regions (in place) with a blob id. A view
-- without an assets table references none, so its tree is not walked.
function M.materialize(regions: Regions, assets: Assets.Assets?, cx: BlockCx)
	local cache = caches[cx]
	if cache == nil then
		if assets == nil then
			return
		end
		cache = BlobCache.new()
		caches[cx] = cache
	end
	local c = cache :: BlobCache.Cache
	if assets ~= nil then
		local mint = function(bytes: string, mime: string): string
			return cx:blob(bytes, mime)
		end
		local resolve = function(key: string, asset: Assets.Asset): string
			return BlobCache.get(c, key, asset.bytes, asset.mime, mint)
		end
		for _, region in { regions.main, regions.dock, regions.layer } :: { any } do
			Assets.materialize(region, assets, resolve)
		end
	end
	BlobCache.sweep(c)
end

return M
