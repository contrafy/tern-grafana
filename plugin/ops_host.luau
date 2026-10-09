--!strict
-- Registers the Prometheus ops block (`tern-grafana.ops`): targets,
-- cardinality, server info, and a link to the alerts Rules view. Every
-- decision lives in lib/ops/state.luau and lib/ops/view.luau; block_runner
-- executes the effects they return.

local BlockRunner = require("./block_runner")
local State = require("./lib/ops/state")
local View = require("./lib/ops/view")

local M = {}

M.ID = "ops"

function M.register()
	BlockRunner.define("ops", {
		init = State.init,
		update = State.update,
		view = View.view,
		title = State.title,
		save = State.save,
		key = State.key,
	})
end

return M
