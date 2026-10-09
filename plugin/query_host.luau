--!strict
-- Registers the Query block (`tern-grafana.query`). Every decision lives in
-- lib/query/state.luau and lib/query/view.luau; block_runner executes the
-- effects they return.

local BlockRunner = require("./block_runner")
local State = require("./lib/query/state")
local View = require("./lib/query/view")

local M = {}

M.ID = "query"

function M.register()
	BlockRunner.define("query", {
		init = State.init,
		update = State.update,
		view = View.view,
		title = State.title,
		save = State.save,
		key = State.key,
	})
end

return M
