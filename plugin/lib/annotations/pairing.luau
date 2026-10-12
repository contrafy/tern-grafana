--!strict
-- Pairs `command_started` with `command_finished` per pane. Only the start
-- carries the working directory (and its wall time is the annotation's
-- start), so the host remembers each pane's running command until it ends.
-- A finish without a matching start (the plugin loaded mid-command, or
-- another line started in between) still yields a run: its start is derived
-- from `took_ms` and its cwd is unknown.

export type Started = { line: string, cwd: string?, started_ms: number }

export type Tracker = { panes: { [number]: Started }, count: number }

export type Run = {
	pane: number,
	line: string,
	cwd: string?,
	started_ms: number,
	finished_ms: number,
	status: number,
	took_ms: number,
	-- Whether the start was seen (cwd and start time are exact).
	paired: boolean,
}

local M = {}

-- Bounds memory when panes close without a finish.
M.MAX_PANES = 256

function M.new(): Tracker
	return { panes = {}, count = 0 }
end

function M.started(t: Tracker, pane: number, line: string, cwd: string?, now_ms: number)
	if t.panes[pane] == nil then
		if t.count >= M.MAX_PANES then
			-- Drop the oldest start: its finish will be unpaired, never wrong.
			local oldest: number? = nil
			local oldestMs = math.huge
			for p, s in t.panes do
				if s.started_ms < oldestMs then
					oldest, oldestMs = p, s.started_ms
				end
			end
			if oldest then
				t.panes[oldest] = nil
				t.count -= 1
			end
		end
		t.count += 1
	end
	t.panes[pane] = { line = line, cwd = if cwd and cwd ~= "" then cwd else nil, started_ms = now_ms }
end

function M.finished(t: Tracker, pane: number, line: string, status: number, took_ms: number, now_ms: number): Run
	local s = t.panes[pane]
	if s then
		t.panes[pane] = nil
		t.count -= 1
	end
	local took = if type(took_ms) == "number" and took_ms >= 0 then took_ms else 0
	local paired = s ~= nil and s.line == line
	return {
		pane = pane,
		line = line,
		cwd = if paired and s then s.cwd else nil,
		started_ms = if paired and s then s.started_ms else now_ms - took,
		finished_ms = now_ms,
		status = status,
		took_ms = took,
		paired = paired,
	}
end

return M
