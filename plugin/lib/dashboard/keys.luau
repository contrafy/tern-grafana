--!strict
-- The dashboard machine's command keys (no picker open): focus moves, the
-- keyboard cursor and exemplars of the single-panel view, expand, rows,
-- range keys, refresh, sync, and the jumps to Grafana, logs, traces, a
-- pinned panel block and Investigate.

local Advance = require("./advance")
local Answers = require("./answers")
local Core = require("./core")
local Cursor = require("../render/cursor")
local Effect = require("../effect")
local Env = require("../env")
local FrameProm = require("../frame/prom")
local Handoff = require("../investigate/handoff")
local Interpolate = require("./interpolate")
local InvestigateSubject = require("../investigate/subject")
local Jumps = require("../query/jumps")
local Layout = require("./layout")
local Links = require("./links")
local PanelTime = require("./panel_time")
local Picker = require("./picker")
local Queries = require("./queries")
local SvgTimeseries = require("../render/svg_timeseries")
local Tbl = require("../tbl")
local TimeRange = require("../query/timerange")
local Types = require("./types")

type Env = Env.Env
type Effect = Effect.Effect
type State = Types.State

local M = {}

local DIRS: { [string]: Layout.Direction } = {
	left = "left",
	right = "right",
	up = "up",
	down = "down",
}

local function items(s: State): { Layout.Item }
	local out: { Layout.Item } = {}
	for _, key in s.order do
		local inst = Core.find(s, key)
		if inst then
			table.insert(out, { key = key, grid = inst.panel.grid })
		end
	end
	return out
end

-- Every sample time of the focused panel's frames, sorted; kept while the
-- panel's data is the same answer.
local function sampleTimes(s: State): { number }
	local ps = if s.focus then s.panels[s.focus] else nil
	if ps == nil or ps.data == nil then
		return {}
	end
	local data = ps.data :: Queries.PanelData
	local cached = s.sample_times
	if cached and cached.data == data then
		return cached.times
	end
	local out: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, f in data.frames do
		for _, field in f.fields do
			if field.type == "time" then
				for _, t in field.values do
					if type(t) == "number" and not seen[t] then
						seen[t] = true
						table.insert(out, t)
					end
				end
			end
		end
	end
	table.sort(out)
	s.sample_times = { data = data, times = out }
	return out
end

local function moveCursor(s: State, dir: number, big: boolean): boolean
	local times = sampleTimes(s)
	if #times == 0 then
		return false
	end
	local idx = #times
	if s.cursor then
		for i, t in times do
			if t >= (s.cursor :: number) then
				idx = i
				break
			end
		end
		idx = math.clamp(idx + dir * (if big then 10 else 1), 1, #times)
	end
	s.cursor = times[idx]
	s.exemplar, s.ex_anchor = nil, nil
	return true
end

local function toggleRowOfFocus(s: State)
	local _, sec = Core.find(s, s.focus or "")
	if sec and sec.row then
		s.collapsed[sec.key] = true
		s.focus = nil
	end
end

-- Flips label display of the focused logs panel, starting from the panel's
-- own `options.showLabels`.
local function toggleLabels(s: State): boolean
	local inst = if s.focus then Core.find(s, s.focus :: string) else nil
	if inst == nil or inst.panel.type ~= "logs" then
		return false
	end
	local current = s.labels[inst.key]
	if current == nil then
		local options = inst.panel.json.options
		current = type(options) == "table" and options.showLabels == true
	end
	s.labels[inst.key] = not current
	return true
end

-- Starts an Investigate preview (G4) for the focused panel with its
-- interpolated queries and the values it shows; nothing is sent before the
-- user presses Send there.
local function investigate(s: State, env: Env, effects: { Effect }): boolean
	local d = s.dashboard
	local inst = if s.focus then Core.find(s, s.focus :: string) else nil
	if d == nil or inst == nil then
		return false
	end
	local scope = Core.panelScope(s, inst)
	local fps = s.panels[inst.key]
	local range = if fps and fps.time then (fps.time :: PanelTime.Override).range else nil
	local pq = Queries.build(inst.panel.json, Core.queryContext(s, scope, env, range), env)
	local queries: { InvestigateSubject.Query } = {}
	if pq then
		for _, q in pq.queries do
			local text = if type(q.expr) == "string" then q.expr elseif type(q.query) == "string" then q.query else nil
			if text and text ~= "" then
				local ds = if type(q.datasource) == "table" then q.datasource.type else nil
				table.insert(queries, {
					ref = if type(q.refId) == "string" then q.refId else nil,
					expr = text,
					datasource = if type(ds) == "string" then ds else nil,
				})
			end
		end
	end
	local r = s.range or { from_ms = env.now_ms - 3600000, to_ms = env.now_ms }
	local ps = s.panels[inst.key]
	local subject = InvestigateSubject.fromPanel({
		context = s.context,
		dashboard = d.title,
		uid = s.uid,
		panel_id = inst.panel.id,
		title = Interpolate.replace(inst.panel.title, scope),
		type = inst.panel.type,
		queries = queries,
		range = { from = s.from or d.time.from, to = s.to or d.time.to, from_ms = r.from_ms, to_ms = r.to_ms },
		vars = Core.instanceVars(s, inst),
		frames = if ps and ps.data then (ps.data :: Queries.PanelData).frames else nil,
	}, env.config, env.encode)
	for _, e in Handoff.start(subject, env) do
		table.insert(effects, e)
	end
	return true
end

-- The exemplars the focused time series panel draws (the same list and
-- order as its chart's layout.exemplars).
function M.focusedExemplars(s: State): { FrameProm.Exemplar }
	local inst = if s.focus then Core.find(s, s.focus :: string) else nil
	local ps = if s.focus then s.panels[s.focus :: string] else nil
	local data = if ps then ps.data else nil
	local r = Core.drawRange(s, ps)
	if inst == nil or inst.panel.type ~= "timeseries" or data == nil or data.exemplars == nil or r == nil then
		return {}
	end
	return (SvgTimeseries.drawnExemplars(data.exemplars :: { FrameProm.Exemplar }, r.from_ms, r.to_ms))
end

function M.selectedExemplar(s: State): FrameProm.Exemplar?
	return if s.exemplar then M.focusedExemplars(s)[s.exemplar :: number] else nil
end

-- `x` in the single-panel view: the next exemplar nearest the cursor; the
-- cursor follows it.
local function cycleExemplar(s: State, env: Env, effects: { Effect }): boolean
	local list = M.focusedExemplars(s)
	local r = s.range
	if #list == 0 or r == nil then
		local text = if s.exemplars_on then "No exemplars in this panel" else "Exemplars are off (query.exemplars)"
		table.insert(effects, { kind = "toast", level = "info", text = text })
		return true
	end
	local layout: any = { exemplars = list }
	local anchor = if s.exemplar and s.ex_anchor then s.ex_anchor else (s.cursor or r.to_ms)
	local idx = Cursor.nextExemplar(layout, anchor, s.exemplar) :: number
	s.exemplar, s.ex_anchor = idx, anchor
	s.cursor = list[idx].time_ms
	Advance.share(s, env, effects)
	return true
end

local function openTrace(s: State, effects: { Effect })
	local e = M.selectedExemplar(s)
	if e == nil then
		return
	end
	local target, err = Jumps.traceLink(s.context, e, s.trace_label)
	if target then
		table.insert(effects, { kind = "open", target = target })
	else
		table.insert(effects, { kind = "toast", level = "info", text = err or "Cannot open the trace" })
	end
end

-- `L`: logs for the focused panel's series (the selected exemplar's series
-- when one is selected, else the labels all its series share) over the
-- dashboard's range.
local function openLogs(s: State, env: Env, effects: { Effect })
	local ps = if s.focus then s.panels[s.focus :: string] else nil
	local data = if ps then ps.data else nil
	if data == nil then
		table.insert(effects, { kind = "toast", level = "info", text = "Focus a panel with data: L opens its logs" })
		return
	end
	local labels: { [string]: string }
	local e = M.selectedExemplar(s)
	if e then
		labels = Tbl.copy(e.series)
		for k, v in e.labels do
			labels[k] = labels[k] or v
		end
	else
		labels = Jumps.commonLabels((data :: Queries.PanelData).frames)
	end
	local d = s.dashboard
	local from = s.from or (if d then d.time.from else "now-6h")
	local to = s.to or (if d then d.time.to else "now")
	local target, err = Jumps.logsLink(s.context, labels, Jumps.correlateLabels(env.config), from, to)
	if target then
		table.insert(effects, { kind = "open", target = target })
	else
		table.insert(effects, { kind = "toast", level = "info", text = err or "Cannot open logs" })
	end
end

function M.command(s: State, key: Key, env: Env, effects: { Effect }): boolean
	local name = key.name
	local ch = key.text or ""
	local singleView = s.solo ~= nil or s.expanded
	if ch == "/" and not s.solo then
		s.picker = { kind = "search", query = "" }
		Answers.startSearch(s, "", effects)
		return true
	end
	if s.phase ~= "ready" then
		if ch == "r" and s.phase == "error" and s.uid then
			Answers.startLoad(s, effects)
			return true
		end
		return false
	end
	local dir: Layout.Direction? = DIRS[name]
	if dir then
		if singleView and (dir == "left" or dir == "right") then
			local moved = moveCursor(s, if dir == "left" then -1 else 1, key.shift)
			if moved then
				Advance.share(s, env, effects)
			end
			return moved
		end
		if singleView or s.focus == nil then
			return false
		end
		local next_ = Layout.neighbor(items(s), s.focus :: string, dir :: Layout.Direction)
		if next_ then
			s.focus = next_
			return true
		end
		return false
	end
	if name == "tab" then
		if singleView or #s.order == 0 then
			return false
		end
		local idx = table.find(s.order, s.focus or "") or 0
		idx = (idx - 1 + (if key.shift then -1 else 1)) % #s.order + 1
		s.focus = s.order[idx]
		return true
	elseif (name == "enter" or name == "return") and s.exemplar and singleView then
		openTrace(s, effects)
		return true
	elseif name == "enter" and not s.solo then
		if s.focus == nil then
			return false
		end
		s.expanded = not s.expanded
		s.cursor = nil
		s.exemplar, s.ex_anchor = nil, nil
		Advance.advance(s, env, false, effects)
		return true
	elseif name == "escape" then
		if s.exemplar then
			s.exemplar, s.ex_anchor = nil, nil
			return true
		elseif s.expanded then
			s.expanded = false
			s.cursor = nil
			Advance.advance(s, env, false, effects)
			return true
		elseif s.cursor then
			s.cursor = nil
			return true
		end
		return false
	end
	if key.ctrl or key.meta then
		return false
	end
	if ch == "v" then
		if #Picker.itemsFor(s, "vars") == 0 then
			return false
		end
		s.picker = { kind = "vars", query = "" }
		return true
	elseif ch == "r" then
		Advance.refresh(s, env, effects)
		return true
	elseif ch == "a" then
		s.auto = not s.auto
		Advance.armRefresh(s, effects)
		return true
	elseif ch == "o" then
		Links.openPanelInBrowser(s, s.focus, effects)
		return #effects > 0
	elseif ch == "O" then
		local url = Links.grafanaUrl(s, env)
		if url then
			table.insert(effects, Links.browse(url))
		end
		return url ~= nil
	elseif ch == "y" then
		local url = Links.grafanaUrl(s, env)
		if url then
			table.insert(effects, { kind = "copy", text = url })
			table.insert(effects, { kind = "toast", level = "info", text = "Copied the Grafana URL" })
		end
		return url ~= nil
	elseif ch == "I" then
		return investigate(s, env, effects)
	elseif ch == "l" then
		return toggleLabels(s)
	elseif ch == "x" and singleView then
		return cycleExemplar(s, env, effects)
	elseif ch == "L" then
		openLogs(s, env, effects)
		return true
	elseif ch == "S" then
		Advance.toggleSync(s, env, effects)
		return true
	elseif ch == "p" and not s.solo then
		Links.pin(s, effects)
		return #effects > 0
	elseif ch == "c" and not s.solo then
		toggleRowOfFocus(s)
		Advance.advance(s, env, false, effects)
		return true
	elseif ch == "C" and not s.solo then
		for _, sec in s.sections do
			if sec.row then
				s.collapsed[sec.key] = false
			end
		end
		Advance.advance(s, env, false, effects)
		return true
	elseif ch == "0" then
		local d = s.dashboard
		if d then
			Advance.setRange(s, d.time.from, d.time.to, env, effects)
			return true
		end
		return false
	end
	local from, to = TimeRange.forKey(ch, s.from or "now-6h", s.to or "now", env.now_ms)
	if from and to then
		Advance.setRange(s, from, to, env, effects)
		return true
	end
	return false
end

return M
