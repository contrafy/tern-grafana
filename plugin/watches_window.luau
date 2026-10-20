--!strict
-- Window glue for threshold watches: the status-line segments (from the kv
-- summary watches_poll_host writes; alerts_window's formatter shows them,
-- since Tern keeps one status formatter per plugin, and refreshes the chrome
-- when they change), a timer that toasts transitions (decisions in
-- lib/watches/toasts.luau, deduped across windows through kv), and the
-- "Grafana: Watches" palette command, which is also what clicking the
-- segment runs: it opens the most urgent watch's query.
--
-- The watches stack loads through `load`, which alerts_window's warm-up
-- timer calls, or on the first command or toast check; never with the
-- window entry (50 ms load budget, docs/architecture.md).

local M = {}

M.COMMAND_ID = "watches"
M.QUERY_BLOCK = "tern-grafana.query"
-- lib/watches/segment.luau ICON; a literal so the command needs no lib module.
M.ICON = "eye"
-- How often the window re-reads the kv summary for toasts.
M.CHECK_MS = 5000

type Stack = { Poll: any, Segment: any, Toasts: any }

local stack: Stack? = nil

-- Loads the watches stack (once) and returns lib/watches/segment.
function M.load(): any
	if stack == nil then
		stack = {
			Poll = require("./lib/watches/poll"),
			Segment = require("./lib/watches/segment"),
			Toasts = require("./lib/watches/toasts"),
		}
	end
	return (stack :: Stack).Segment
end

local function nowMs(): number
	return os.time() * 1000
end

local function summary(t: any, s: Stack): any
	local ok, raw = pcall(t.kv.get, s.Poll.KEY)
	return if ok then raw else nil
end

-- The watches segments for the status line; nil adds none, also before
-- `load` ran (the formatter never loads modules).
function M.segments(t: any): { any }?
	local s = stack
	if s == nil then
		return nil
	end
	return s.Segment.segments(summary(t, s), nowMs())
end

local function open(t: any, cx: any)
	M.load()
	local s = stack :: Stack
	local raw = summary(t, s)
	local entry = s.Segment.focus(raw)
	if entry == nil then
		local payload = s.Poll.read(raw)
		if payload == nil or #payload.watches == 0 then
			cx:toast("info", "No watches configured", "Add a `watches` list to the tern-grafana config")
		else
			cx:toast("info", string.format("All %d watches are ok", #payload.watches))
		end
		return
	end
	local Scheme = require("./lib/links/scheme")
	cx:new_block(M.QUERY_BLOCK, { Scheme.encode(s.Segment.link(entry) :: any) }, "beside")
end

function M.register(t: any)
	t.command({
		id = M.COMMAND_ID,
		title = "Grafana: Watches",
		icon = M.ICON,
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
		M.load()
		local s = stack :: Stack
		local okNotified, notified = pcall(t.kv.get, s.Toasts.KEY)
		if not okNotified then
			return
		end
		local record, toasts = s.Toasts.check(summary(t, s), notified, nowMs())
		if record then
			t.kv.set(s.Toasts.KEY, record)
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
