--!strict
-- Registers the Investigate preview block (`tern-grafana.investigate`, G4).
-- Every decision, including when a prompt is sent, lives in
-- lib/investigate/state.luau; the agent itself is started by the window
-- (plugin/investigate_window.luau).

local BlockRunner = require("./block_runner")
local State = require("./lib/investigate/state")
local View = require("./lib/investigate/view")

local M = {}

function M.register()
	BlockRunner.define(
		"investigate",
		{
			init = State.init,
			update = State.update,
			view = View.view,
			title = State.title,
			save = State.save,
			key = State.key,
		} :: any
	)
end

return M
