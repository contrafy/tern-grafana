--!strict
-- The panel block (`tern-grafana.panel`, B3): one dashboard panel on its own,
-- from a `tern-grafana://panel?uid=&panel=` link (the dashboard block's `p`
-- key, a Grafana `/d-solo/` URL, or a saved block). It is the dashboard
-- machine in solo mode: the same loading, variables, repeat resolution and
-- ladder, showing only that panel at full width with the keyboard cursor.
-- Floating it picture-in-picture is a Tern layout choice, not the block's.

local Effect = require("../effect")
local Env = require("../env")
local State = require("./state")

local M = {}

function M.init(args: { string }, saved: any, env: Env.Env): (State.State, { Effect.Effect })
	return State.initWith(args, saved, env, true)
end

M.update = State.update
M.key = State.key
M.title = State.title
M.save = State.save

return M
