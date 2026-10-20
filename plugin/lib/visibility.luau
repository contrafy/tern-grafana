--!strict
-- Which plugin blocks the user can see. Only the window half knows tabs,
-- zoom and focus (host `tern.pane.list` has no visibility field:
-- docs/sdk-capability-matrix.md row 12), so plugin/visibility_window.luau
-- writes a record to kv on focus, tab and pane events (and on a short check
-- timer), and block machines read it through Env to pause auto-refresh while
-- their tab is in the background: a hidden block sends no queries, renders
-- nothing and mints no blobs, and refreshes as soon as it is shown again.
--
-- Safe by default: a pane is hidden only when the record knows it and does
-- not list it as visible. No record, a pane the record does not know (a
-- second window, a block opened since) or a malformed value read as
-- visible, so a mistake costs a refresh, never a stale view on screen.

local Env = require("./env")

local M = {}

M.KEY = "visible_panes"
-- How often a paused block checks whether it was shown again.
M.POLL_MS = 1000

export type Record = { known: { number }, visible: { number } }

-- The parts of Tern's TabLayout this reads.
export type Layout = {
	root: any,
	floats: { { pane: number } }?,
	zoomed: boolean?,
	focus: number?,
}

local function leaves(tree: any, out: { number })
	if type(tree) ~= "table" then
		return
	end
	if type(tree.pane) == "number" then
		table.insert(out, tree.pane)
	end
	for _, child in ipairs(tree) do
		leaves(child, out)
	end
end

local function sorted(list: { number }): { number }
	local out: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, p in list do
		if type(p) == "number" and not seen[p] then
			seen[p] = true
			table.insert(out, p)
		end
	end
	table.sort(out)
	return out
end

-- The panes the active tab shows: its tiled leaves (only the focused one
-- when zoomed) and its floating blocks, plus the focused pane.
function M.visible(layout: Layout?, focused: number?): { number }
	local out: { number } = {}
	if layout then
		if layout.zoomed and type(layout.focus) == "number" then
			table.insert(out, layout.focus :: number)
		else
			leaves(layout.root, out)
		end
		local floats: { any } = layout.floats or {}
		for _, f in floats do
			if type(f) == "table" and type(f.pane) == "number" then
				table.insert(out, f.pane)
			end
		end
	end
	if focused then
		table.insert(out, focused)
	end
	return sorted(out)
end

-- The kv record: every pane the window knows and the ones it shows.
function M.record(known: { number }, visible: { number }): Record
	return { known = sorted(known), visible = sorted(visible) }
end

-- A string equal for equal records (the window writes kv only on change).
function M.signature(r: Record): string
	return table.concat(r.known, ",") .. "|" .. table.concat(r.visible, ",")
end

local function contains(list: any, pane: number): boolean
	if type(list) ~= "table" then
		return false
	end
	for _, p in ipairs(list) do
		if p == pane then
			return true
		end
	end
	return false
end

-- Whether `raw` (the kv value) says `pane` is in a background tab, parked
-- or zoomed away.
function M.hidden(raw: any, pane: number?): boolean
	if pane == nil or type(raw) ~= "table" then
		return false
	end
	return contains(raw.known, pane :: number) and not contains(raw.visible, pane :: number)
end

-- Whether the block the Env was made for is hidden now.
function M.isHidden(env: Env.Env): boolean
	local get = env.kv_get
	if get == nil or env.pane == nil then
		return false
	end
	return M.hidden(get(M.KEY), env.pane)
end

return M
