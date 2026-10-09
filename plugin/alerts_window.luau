--!strict
-- Window glue for alerts: the status-line segment (from the kv summary the
-- host poller writes), a timer that refreshes the chrome only when the
-- segments would change and shows toasts for newly firing alerts (opt-in;
-- decisions in lib/alerts/toasts.luau), and the "Grafana: Alerts" palette
-- command, which is also what clicking the segment runs. Status segments
-- only show while the user's status bar is on.

local Segment = require("./lib/alerts/segment")
local Summary = require("./lib/alerts/summary")
local Toasts = require("./lib/alerts/toasts")

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

	-- Records before toasting, so a second window finds the poll announced.
	local function announce(cx: any)
		local okSummary, summary = pcall(t.kv.get, Summary.KEY)
		local okNotified, notified = pcall(t.kv.get, Toasts.KEY)
		if not okSummary or not okNotified then
			return
		end
		local record, toasts = Toasts.check(summary, notified)
		if record then
			t.kv.set(Toasts.KEY, record)
		end
		if cx then
			for _, toast in toasts do
				cx:toast(toast.level, toast.text, toast.sub)
			end
		end
	end

	local shown = Segment.signature(current(t))
	local function check(cx: any)
		pcall(function()
			local sig = Segment.signature(current(t))
			if sig ~= shown then
				shown = sig
				t.chrome.refresh()
			end
		end)
		pcall(announce, cx)
		t.timer(M.CHECK_MS, check)
	end
	t.timer(M.CHECK_MS, check)
end

return M
