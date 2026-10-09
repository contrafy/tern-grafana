--!strict
-- Registers the Dashboard block (`tern-grafana.dashboard`). Every decision
-- lives in lib/dashboard/state.luau and lib/dashboard/view.luau;
-- block_runner executes the effects they return.

local BlockRunner = require("./block_runner")
local State = require("./lib/dashboard/state")
local View = require("./lib/dashboard/view")

local M = {}

M.ID = "dashboard"

function M.register()
	BlockRunner.define("dashboard", {
		init = State.init,
		update = State.update,
		view = View.view,
		title = State.title,
		save = State.save,
		key = State.key,
	})
end

return M
