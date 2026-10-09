--!strict
-- View assets: pure views reference image bytes by key (`image` nodes carry
-- `p.asset`), and the host adapter swaps each key for a blob id
-- (plugin/blob_host.luau), because only a live block `cx` can send blobs.

local ui = require("../ui")

type Node = ui.Node

export type Asset = { mime: string, bytes: string }
export type Assets = { [string]: Asset }

-- Returns the blob id for an asset.
export type Resolve = (key: string, asset: Asset) -> string

local M = {}

M.SVG = "image/svg+xml"
M.PNG = "image/png"

-- Replaces `p.asset` with `p.blob` throughout the tree, in place, and returns
-- `node`. A key with no asset leaves the image without a blob, so Tern shows
-- its placeholder (with `alt`) instead of a stale picture.
function M.materialize(node: Node, assets: Assets, resolve: Resolve): Node
	local p = node.p
	if p then
		local key = p.asset
		if type(key) == "string" then
			local asset = assets[key]
			p.asset = nil
			p.blob = if asset then resolve(key, asset) else nil
		end
	end
	local c = node.c
	if c then
		for _, child in c do
			M.materialize(child, assets, resolve)
		end
	end
	return node
end

return M
