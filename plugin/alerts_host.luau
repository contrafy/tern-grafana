--!strict
-- Registers the Alerts inbox block (`tern-grafana.alerts`). Every decision
-- lives in lib/alerts/state.luau and lib/alerts/render.luau; block_runner
-- executes the effects they return.

local BlockRunner = require("./block_runner")
local Render = require("./lib/alerts/render")
local State = require("./lib/alerts/state")

local M = {}

M.ID = "alerts"

function M.register()
	BlockRunner.define("alerts", {
		init = State.init,
		update = State.update,
		view = Render.view,
		title = State.title,
		save = State.save,
		key = State.key,
	})
end

return M
