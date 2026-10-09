--!strict
-- Palette commands that open the plugin's blocks beside the focused pane.

local M = {}

type Command = { id: string, title: string, icon: string, block: string }

local COMMANDS: { Command } = {
	{ id = "query", title = "Grafana: Query", icon = "chart", block = "tern-grafana.query" },
	{ id = "dashboard", title = "Grafana: Dashboard", icon = "chart", block = "tern-grafana.dashboard" },
	{ id = "silences", title = "Grafana: Silences", icon = "flame", block = "tern-grafana.silence" },
	{ id = "ops", title = "Grafana: Ops", icon = "chart", block = "tern-grafana.ops" },
	{ id = "settings", title = "Grafana: Settings", icon = "sliders", block = "tern-grafana.settings" },
}

function M.register(t: any)
	for _, c in COMMANDS do
		t.command({
			id = c.id,
			title = c.title,
			icon = c.icon,
			group = "Tern Grafana",
			run = function(cx: any)
				cx:new_block(c.block, {}, "beside")
			end,
		})
	end
end

return M
