--!strict
-- The contract between a block's pure state machine (lib/<feature>/state)
-- and plugin/block_runner.luau, which executes the effects and feeds the
-- results back as messages. Nothing here touches `tern`.

local Assets = require("./render/assets")
local Env = require("./env")
local Route = require("./config/route")
local TransportTypes = require("./transport/types")
local ui = require("./ui")

type Node = ui.Node

export type Effect =
	-- Sent through transport_host; answered by `http_done` with the same tag.
	-- A late answer to a superseded request still arrives: the machine drops it
	-- by tag (generation), the runner never does.
	{ kind: "http", tag: string, route: Route.Route, request: TransportTypes.Request }
	-- Answered by `tick` with the same tag after `ms`, unless the block is gone.
	| { kind: "timer", tag: string, ms: number }
	-- tern.kv (a 0644 file): never secrets.
	| { kind: "kv_set", key: string, value: any }
	| { kind: "toast", level: "info" | "warn" | "error", text: string, sub: string? }
	-- A path or URL, through the window's route.link.
	| { kind: "open", target: string }
	| { kind: "copy", text: string }
	| { kind: "exit" }
	-- Moves keyboard focus to a view id ("main.q"); nil drops it. The view
	-- diff never sends focus, so inputs need this to take the caret.
	| { kind: "focus", id: string? }

export type Msg =
	{ kind: "http_done", tag: string, response: TransportTypes.Response }
	| { kind: "tick", tag: string }
	| { kind: "event", ev: UiEvent }
	| { kind: "key", key: Key }

-- A view is the main region's root node, or the regions by name.
export type Regions = { main: Node?, dock: Node?, layer: Node? }
export type View = Node | Regions

export type Machine<S> = {
	init: (args: { string }, saved: any, env: Env.Env) -> (S, { Effect }),
	update: (state: S, msg: Msg, env: Env.Env) -> (S, { Effect }),
	view: (state: S, env: Env.Env) -> (View, Assets.Assets?),
	title: ((state: S) -> string?)?,
	-- JSON values only, never secrets (saved state lands in Tern's state file).
	save: ((state: S) -> any)?,
	-- Optional fast path for keys; `changed = false` with no effects tells
	-- Tern nothing happened (no render, no save). Without it keys arrive as
	-- `{kind = "key"}` messages through update.
	key: ((state: S, key: Key, env: Env.Env) -> (S, { Effect }, boolean))?,
}

local M = {}

local function isRegions(view: any): boolean
	return type(view) == "table" and view.k == nil
end

-- The view as Tern's regions: a bare node becomes the main region.
function M.regions(view: View): Regions
	if isRegions(view) then
		return view :: Regions
	end
	return { main = view :: Node }
end

-- What a block shows when its machine raised: the block stays alive and says
-- what failed instead of disappearing.
function M.errorView(name: string, what: string, err: any): Regions
	local message = tostring(err)
	return {
		main = ui.col({
			ui.text({ ui.span(string.format("%s failed in %s", name, what), "error") }),
			ui.muted(message),
		}),
	}
end

return M
