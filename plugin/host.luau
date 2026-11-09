--!strict
-- Host entry: registers blocks and lenses. Decisions live in plugin/lib; adapters execute them.
-- Blocks and lenses without their own adapter require their modules when first opened.

local BlockRunner = require("./block_runner")
local Effect = require("./lib/effect")
local LensHost = require("./lens_host")

type Machine = Effect.Machine<any>

-- A machine from a state module (init/update/title/save/key) and a view.
local function machine(state: any, view: any): Machine
	return {
		init = state.init,
		update = state.update,
		view = view,
		title = state.title,
		save = state.save,
		key = state.key,
	}
end

BlockRunner.define("query", function()
	return machine(require("./lib/query/state"), require("./lib/query/view").view)
end)
require("./settings_host").register()
BlockRunner.define("dashboard", function()
	return machine(require("./lib/dashboard/state"), require("./lib/dashboard/view").view)
end)
BlockRunner.define("panel", function()
	return machine(require("./lib/dashboard/panel_state"), require("./lib/dashboard/view").view)
end)
BlockRunner.define("alerts", function()
	return machine(require("./lib/alerts/state"), require("./lib/alerts/render").view)
end)
require("./silence_host").register()
require("./alerts_poll_host").start()
require("./watches_poll_host").start()
BlockRunner.define("ops", function()
	return machine(require("./lib/ops/state"), require("./lib/ops/view").view)
end)
BlockRunner.define("logs", function()
	return machine(require("./lib/logs/state"), require("./lib/logs/view").view)
end)
BlockRunner.define("trace", function()
	return machine(require("./lib/trace/state"), require("./lib/trace/view").view)
end)
BlockRunner.define("investigate", function()
	return machine(require("./lib/investigate/state"), require("./lib/investigate/view").view)
end)
require("./annotations_host").register()
BlockRunner.define("impact", function()
	return machine(require("./lib/impact/state"), require("./lib/impact/render").view)
end)
BlockRunner.define("compat", function()
	return machine(require("./lib/compat/state"), require("./lib/compat/view").view)
end)
require("./irm_host").register()
require("./irm_poll_host").start()

LensHost.define("promtool-query", function()
	return require("./lib/lens/promtool_query").lens
end)
LensHost.define("promtool-check", function()
	return require("./lib/lens/promtool_check").lens
end)
LensHost.define("curl", function()
	return require("./lib/lens/curl").lens
end)
LensHost.define("amtool", function()
	return require("./lib/lens/amtool").lens
end)
LensHost.define("logcli", function()
	return require("./lib/lens/logcli").lens
end)

return nil
