--!strict
-- Registers the Compatibility block (`tern-grafana.compat`). Every decision
-- lives in lib/compat/state.luau and lib/compat/view.luau; block_runner
-- executes the effects they return.

local BlockRunner = require("./block_runner")
local State = require("./lib/compat/state")
local View = require("./lib/compat/view")

local M = {}

function M.register()
	BlockRunner.define("compat", {
		init = State.init,
		update = State.update,
		view = View.view,
		title = State.title,
		save = State.save,
		key = State.key,
	})
end

return M
