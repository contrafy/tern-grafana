--!strict
-- Registers the Panel block (`tern-grafana.panel`): one dashboard panel in
-- its own block (lib/dashboard/panel_state.luau), drawn by the dashboard view.

local BlockRunner = require("./block_runner")
local PanelState = require("./lib/dashboard/panel_state")
local View = require("./lib/dashboard/view")

local M = {}

M.ID = "panel"

function M.register()
	BlockRunner.define("panel", {
		init = PanelState.init,
		update = PanelState.update,
		view = View.view,
		title = PanelState.title,
		save = PanelState.save,
		key = PanelState.key,
	})
end

return M
