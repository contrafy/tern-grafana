--!strict
-- Registers the Logs block (`tern-grafana.logs`). Every decision lives in
-- lib/logs/state.luau and lib/logs/view.luau; block_runner executes the
-- effects they return.

local BlockRunner = require("./block_runner")
local State = require("./lib/logs/state")
local View = require("./lib/logs/view")

local M = {}

M.ID = "logs"

function M.register()
	BlockRunner.define("logs", {
		init = State.init,
		update = State.update,
		view = View.view,
		title = State.title,
		save = State.save,
		key = State.key,
	})
end

return M
