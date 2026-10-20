--!strict
-- Window glue for alerts: the status-line segment (from the kv summary the
-- host poller writes), a timer that refreshes the chrome only when the
-- segments would change and shows toasts for newly firing alerts (opt-in;
-- decisions in lib/alerts/toasts.luau), and the "Grafana: Alerts" palette
-- command, which is also what clicking the segment runs. Status segments
-- only show while the user's status bar is on. Tern keeps one status
-- formatter per plugin, so this one also shows the watches segment
-- (watches_window) and the IRM segment (lib/irm/segment.luau, from the kv
-- summary irm_poll_host writes); the signature covers all of them, so any
-- change refreshes.
--
-- The segment stack loads in timer callbacks right after the window entry,
-- one group per tick, never with the entry (50 ms load budget) nor in the
-- formatter (4 ms budget): until it is loaded the formatter shows nothing
-- and the last group's tick refreshes the chrome (docs/architecture.md).

local WatchesWindow = require("./watches_window")

local M = {}

M.COMMAND_ID = "alerts"
M.BLOCK = "tern-grafana.alerts"
-- lib/alerts/segment.luau ICON; a literal so the command needs no lib module.
M.ICON = "flame"
-- How often the window re-reads the kv summary.
M.CHECK_MS = 5000

-- Minutes east of UTC here now (the IRM segment shows shift ends in local
-- time): the UTC wall fields read back as local time differ by the offset.
local function localOffsetMin(seconds: number): number
	local utc: any = os.date("!*t", seconds)
	utc.isdst = (os.date("*t", seconds) :: any).isdst
	return math.floor(os.difftime(seconds, os.time(utc)) / 60 + 0.5)
end

type Stack = {
	Segment: any,
	Summary: any,
	Toasts: any,
	IrmSegment: any,
	IrmSummary: any,
	WatchSegment: any,
}

-- Nil until every group below is loaded.
local stack: Stack? = nil

-- Loading groups, one per timer tick; each stays far under the 50 ms budget.
local partial: { [string]: any } = {}
local GROUPS: { () -> () } = {
	function()
		partial.Segment = require("./lib/alerts/segment")
		partial.Summary = require("./lib/alerts/summary")
		partial.Toasts = require("./lib/alerts/toasts")
	end,
	function()
		partial.IrmSegment = require("./lib/irm/segment")
		partial.IrmSummary = require("./lib/irm/summary")
	end,
	function()
		partial.WatchSegment = WatchesWindow.load()
		stack = partial :: any
	end,
}

local function current(t: any, s: Stack): { any }?
	local seconds = os.time()
	local now = seconds * 1000
	local ok, raw = pcall(t.kv.get, s.Summary.KEY)
	local alerts = if ok then s.Segment.segments(raw, now) else nil
	local okIrm, irmRaw = pcall(t.kv.get, s.IrmSummary.KEY)
	local irm = if okIrm then s.IrmSegment.segments(irmRaw, now, localOffsetMin(seconds)) else nil
	local watches = WatchesWindow.segments(t)
	return s.WatchSegment.append(s.WatchSegment.append(alerts, watches), irm)
end

function M.register(t: any)
	t.command({
		id = M.COMMAND_ID,
		title = "Grafana: Alerts",
		icon = M.ICON,
		group = "Tern Grafana",
		run = function(cx: any)
			cx:new_block(M.BLOCK, {})
		end,
	})

	t.chrome.status(function(_pane: any): { any }?
		local s = stack
		if s == nil then
			return nil
		end
		return current(t, s)
	end)

	-- Records before toasting, so a second window finds the poll announced.
	local function announce(s: Stack, cx: any)
		local okSummary, summary = pcall(t.kv.get, s.Summary.KEY)
		local okNotified, notified = pcall(t.kv.get, s.Toasts.KEY)
		if not okSummary or not okNotified then
			return
		end
		local record, toasts = s.Toasts.check(summary, notified)
		if record then
			t.kv.set(s.Toasts.KEY, record)
		end
		if cx then
			for _, toast in toasts do
				cx:toast(toast.level, toast.text, toast.sub)
			end
		end
	end

	local shown: string? = nil
	local function check(cx: any)
		local s = stack
		if s ~= nil then
			pcall(function()
				local sig = s.Segment.signature(current(t, s))
				if sig ~= shown then
					shown = sig
					t.chrome.refresh()
				end
			end)
			pcall(announce, s, cx)
		end
		t.timer(M.CHECK_MS, check)
	end

	local function warm(i: number)
		t.timer(0, function(_cx: any)
			local ok, err = pcall(GROUPS[i] :: any)
			if not ok then
				pcall(t.log.warn, "tern-grafana status segments failed to load", tostring(err))
				return
			end
			if i < #GROUPS then
				warm(i + 1)
				return
			end
			local s = stack :: Stack
			pcall(function()
				shown = s.Segment.signature(current(t, s))
			end)
			pcall(t.chrome.refresh)
		end)
	end
	warm(1)
	t.timer(M.CHECK_MS, check)
end

return M
