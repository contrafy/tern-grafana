--!strict
-- What the host does with a view on every render (plugin/block_runner.luau
-- `view`): split it into regions and turn every asset into a blob id through
-- one blob cache per block (plugin/blob_host.luau). Minting is counted
-- instead of sent.

local Assets = require("../../../plugin/lib/render/assets")
local Bench = require("./bench")
local BlobCache = require("../../../plugin/lib/render/blob_cache")
local Effect = require("../../../plugin/lib/effect")

local M = {}

export type Painter = {
	cache: BlobCache.Cache,
	minted: number,
	views: number,
	regions: any,
	assets: any,
}

function M.new(): Painter
	return { cache = BlobCache.new(), minted = 0, views = 0, regions = nil, assets = nil }
end

function M.paint(p: Painter, view: any, assets: any)
	local regions = Effect.regions(view)
	local all = assets or {}
	local function mint(_bytes: string, _mime: string): string
		p.minted += 1
		return "blob-" .. p.minted
	end
	for _, region in { regions.main, regions.dock, regions.layer } do
		if region then
			Assets.materialize(region :: any, all, function(key: string, asset: Assets.Asset): string
				return BlobCache.get(p.cache, key, asset.bytes, asset.mime, mint)
			end)
		end
	end
	p.views += 1
	p.regions, p.assets = regions, all
end

-- Assets and view nodes of the last paint.
function M.sizes(p: Painter): (Bench.AssetStats, number)
	local nodes = 0
	for _, region in { p.regions.main, p.regions.dock, p.regions.layer } do
		nodes += Bench.nodes(region)
	end
	return Bench.assets(p.assets), nodes
end

-- The common size metrics of the last paint.
function M.metrics(p: Painter, into: { [string]: any })
	local a, nodes = M.sizes(p)
	into.assets = a.count
	into.svg_assets = a.svg
	into.asset_bytes_total = a.bytes
	into.asset_bytes_max = a.max
	into.asset_bytes_mean = if a.count > 0 then math.floor(a.bytes / a.count) else 0
	into.view_nodes = nodes
end

return M
