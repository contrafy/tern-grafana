--!strict
-- Window glue for block visibility (lib/visibility.luau): on window start,
-- focus, pane and tab events, and on a short check timer (zoom, park and
-- float changes raise no event), records which panes the active tab shows in
-- kv, writing only when that changed. Block machines read it to pause
-- auto-refresh in background tabs. lib/visibility loads on the first
-- update, not with the window entry (50 ms load budget).

local M = {}

-- Backstop for layout changes without an event.
M.CHECK_MS = 2000

local EVENTS = { "focus", "pane_created", "pane_closed", "tab_created", "tab_closed" }

function M.register(t: any)
	local written: string? = nil

	local function update(cx: any)
		if cx == nil then
			return
		end
		local ok, err = pcall(function()
			local Visibility = require("./lib/visibility")
			local session = cx.session
			local focused: number? = session:focused()
			local tab = if focused then session:tab_of(focused) else nil
			local layout = if tab then session:layout(tab) else nil
			local known: { number } = {}
			for _, p in session:panes() do
				table.insert(known, p.pane)
			end
			local record = Visibility.record(known, Visibility.visible(layout, focused))
			local sig = Visibility.signature(record)
			if sig ~= written then
				t.kv.set(Visibility.KEY, record)
				written = sig
			end
		end)
		if not ok then
			pcall(t.log.warn, "tern-grafana visibility update failed", tostring(err))
		end
	end

	t.on("window_start", function(cx: any)
		update(cx)
	end)
	for _, name in EVENTS do
		t.on(name, function(_ev: any, cx: any)
			update(cx)
		end)
	end
	local function check(cx: any)
		update(cx)
		t.timer(M.CHECK_MS, check)
	end
	t.timer(M.CHECK_MS, check)
end

return M
