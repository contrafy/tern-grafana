--!strict
-- Registers the impact watch block (`tern-grafana.impact`). The command hook
-- in annotations_host.luau opens it after a matching deploy; every decision
-- lives in lib/impact/state.luau, which needs only http and timer effects.

local BlockRunner = require("./block_runner")
local Render = require("./lib/impact/render")
local State = require("./lib/impact/state")

local M = {}

function M.register()
	BlockRunner.define(
		"impact",
		{
			init = State.init,
			update = State.update,
			view = Render.view,
			title = State.title,
			key = State.key,
		} :: any
	)
end

return M
