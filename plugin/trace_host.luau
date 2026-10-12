--!strict
-- Registers the trace block (`tern-grafana.trace`): a Tempo trace waterfall
-- and TraceQL search. Every decision lives in lib/trace/state.luau and
-- lib/trace/view.luau; block_runner executes the effects they return.

local BlockRunner = require("./block_runner")
local State = require("./lib/trace/state")
local View = require("./lib/trace/view")

local M = {}

M.ID = "trace"

function M.register()
	BlockRunner.define("trace", {
		init = State.init,
		update = State.update,
		view = View.view,
		title = State.title,
		save = State.save,
		key = State.key,
	})
end

return M
