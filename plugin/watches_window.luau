--!strict
-- Window glue for threshold watches: the status-line segments (from the kv
-- summary watches_poll_host writes; alerts_window's formatter shows them,
-- since Tern keeps one status formatter per plugin, and refreshes the chrome
-- when they change), a timer that toasts transitions (decisions in
-- lib/watches/toasts.luau, deduped across windows through kv), and the
-- "Grafana: Watches" palette command, which is also what clicking the
-- segment runs: it opens the most urgent watch's query.

local Poll = require("./lib/watches/poll")
local Scheme = require("./lib/links/scheme")
local Segment = require("./lib/watches/segment")
local Toasts = require("./lib/watches/toasts")

local M = {}

M.COMMAND_ID = "watches"
M.QUERY_BLOCK = "tern-grafana.query"
-- How often the window re-reads the kv summary for toasts.
M.CHECK_MS = 5000

local function nowMs(): number
	return os.time() * 1000
end

local function summary(t: any): any
	local ok, raw = pcall(t.kv.get, Poll.KEY)
	return if ok then raw else nil
end

-- The watches segments for the status line; nil adds none.
function M.segments(t: any): { Segment.Segment }?
	return Segment.segments(summary(t), nowMs())
end

local function open(t: any, cx: any)
	local raw = summary(t)
	local entry = Segment.focus(raw)
	if entry == nil then
		local payload = Poll.read(raw)
		if payload == nil or #payload.watches == 0 then
			cx:toast("info", "No watches configured", "Add a `watches` list to the tern-grafana config")
		else
			cx:toast("info", string.format("All %d watches are ok", #payload.watches))
		end
		return
	end
	cx:new_block(M.QUERY_BLOCK, { Scheme.encode(Segment.link(entry) :: any) }, "beside")
end

function M.register(t: any)
	t.command({
		id = M.COMMAND_ID,
		title = "Grafana: Watches",
		icon = Segment.ICON,
		group = "Tern Grafana",
		run = function(cx: any)
			local ok, err = pcall(function()
				open(t, cx)
			end)
			if not ok then
				cx:toast("error", "Tern Grafana could not open the watch", tostring(err))
			end
		end,
	})

	-- Records before toasting, so a second window finds the transition announced.
	local function announce(cx: any)
		local okNotified, notified = pcall(t.kv.get, Toasts.KEY)
		if not okNotified then
			return
		end
		local record, toasts = Toasts.check(summary(t), notified, nowMs())
		if record then
			t.kv.set(Toasts.KEY, record)
		end
		if cx then
			for _, toast in toasts do
				cx:toast(toast.level, toast.text, toast.sub)
			end
		end
	end

	local function check(cx: any)
		pcall(announce, cx)
		t.timer(M.CHECK_MS, check)
	end
	t.timer(M.CHECK_MS, check)
end

return M
