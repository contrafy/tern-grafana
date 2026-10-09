--!strict
-- Window glue for alerts: the status-line segment (from the kv summary the
-- host poller writes), a timer that refreshes the chrome only when the
-- segments would change, and the "Grafana: Alerts" palette command, which is
-- also what clicking the segment runs. Status segments only show while the
-- user's status bar is on.

local Segment = require("./lib/alerts/segment")
local Summary = require("./lib/alerts/summary")

local M = {}

M.COMMAND_ID = "alerts"
M.BLOCK = "tern-grafana.alerts"
-- How often the window re-reads the kv summary.
M.CHECK_MS = 5000

local function current(t: any): { Segment.Segment }?
	local ok, raw = pcall(t.kv.get, Summary.KEY)
	if not ok then
		return nil
	end
	return Segment.segments(raw, os.time() * 1000)
end

function M.register(t: any)
	t.command({
		id = M.COMMAND_ID,
		title = "Grafana: Alerts",
		icon = Segment.ICON,
		group = "Tern Grafana",
		run = function(cx: any)
			cx:new_block(M.BLOCK, {})
		end,
	})

	t.chrome.status(function(_pane: any): { any }?
		return current(t)
	end)

	local shown = Segment.signature(current(t))
	local function check()
		pcall(function()
			local sig = Segment.signature(current(t))
			if sig ~= shown then
				shown = sig
				t.chrome.refresh()
			end
		end)
		t.timer(M.CHECK_MS, check)
	end
	t.timer(M.CHECK_MS, check)
end

return M
