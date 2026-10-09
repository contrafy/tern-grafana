--!strict
-- The `alerts` block: the inbox (one context's alerts, grouped and
-- filtered) and the rules view (the context's alerting and recording rules
-- with their health). Turns keys and clicks into effects (open a link,
-- refresh, write the status summary). Rendering lives in ./render.

local Effect = require("../effect")
local Env = require("../env")
local Group = require("./group")
local Normalize = require("./normalize")
local Rules = require("./rules")
local Scheme = require("../links/scheme")
local Settings = require("./settings")
local SilenceApi = require("../silences/api")
local Sources = require("./sources")
local Summary = require("./summary")
local SilenceMatchers = require("../silences/matchers")
local TransportTypes = require("../transport/types")

type Alert = Normalize.Alert
type Effect = Effect.Effect
type Msg = Effect.Msg
type Env = Env.Env
type Plan = Sources.Plan
type Rule = Normalize.Rule
type Response = TransportTypes.Response

export type Row = { kind: "group", group: number } | { kind: "alert", group: number, alert: Alert }

export type View = "inbox" | "rules"

export type State = {
	-- Every configured context, sorted (the context switcher).
	contexts: { string },
	context: string?,
	plan: Plan?,
	-- Why nothing can load (no config, unroutable context).
	problem: string?,
	settings: Settings.Settings,
	gen: number,
	loading: boolean,
	responses: { [string]: Response },
	alerts: { Alert },
	loaded_ms: number?,
	-- The last load failed; `alerts` are from the load before it.
	error: string?,
	warnings: { string },
	filter_text: string,
	filter: Group.Filter,
	filter_error: string?,
	-- Text being typed into the filter; nil when not editing.
	editing: string?,
	-- Show silenced and inhibited alerts.
	show_muted: boolean,
	collapsed: { [string]: boolean },
	-- Derived from alerts, filter, show_muted and collapsed.
	groups: { Group.Group },
	rows: { Row },
	shown: number,
	sel: number,
	-- Fingerprint of the alert whose detail is open.
	detail: string?,
	-- A transient note (no silences on Prometheus, nothing to open).
	note: string?,
	view: View,
	-- The rules view: its own load generation, answers and selection.
	rules_plan: Rules.Plan?,
	rules_problem: string?,
	rules_gen: number,
	rules_loading: boolean,
	rules_responses: { [string]: Response },
	rules: { Rule },
	rules_errors: { string },
	rules_loaded_ms: number?,
	-- Only rules whose last evaluation failed.
	problems_only: boolean,
	-- Derived from rules, filter and problems_only.
	rule_rows: { Rule },
	rule_sel: number,
	-- Rules.key of the rule whose detail is open.
	rule_detail: string?,
}

local M = {}

M.KV_KEY = Summary.KEY
-- Inbox refresh when background polling is off.
M.DEFAULT_REFRESH_S = 60

local EMPTY_FILTER: Group.Filter = { matchers = {}, words = {} }

local function sortedContexts(env: Env): { string }
	local out: { string } = {}
	local cfg = env.config
	if cfg then
		for name in cfg.contexts do
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

function M.derive(s: State)
	local visible: { Alert } = {}
	for _, a in Group.apply(s.filter, s.alerts) do
		if s.show_muted or (a.state ~= "silenced" and a.state ~= "inhibited") then
			table.insert(visible, a)
		end
	end
	s.shown = #visible
	s.groups = Group.group(visible, s.settings.group_by)
	local rows: { Row } = {}
	for gi, g in s.groups do
		table.insert(rows, { kind = "group", group = gi })
		if not s.collapsed[g.key] then
			for _, a in g.alerts do
				table.insert(rows, { kind = "alert", group = gi, alert = a })
			end
		end
	end
	s.rows = rows
	if s.sel > #rows then
		s.sel = #rows
	end
	if s.sel < 1 and #rows > 0 then
		s.sel = 1
	end
	if s.detail then
		local found = false
		for _, r in rows do
			if r.kind == "alert" and (r :: any).alert.fingerprint == s.detail then
				found = true
				break
			end
		end
		if not found then
			s.detail = nil
		end
	end
	M.deriveRules(s)
end

function M.deriveRules(s: State)
	s.rule_rows = Rules.select(s.rules, s.filter, s.problems_only)
	s.rule_sel = math.clamp(s.rule_sel, 1, math.max(1, #s.rule_rows))
	if s.rule_detail then
		local found = false
		for _, r in s.rule_rows do
			if Rules.key(r) == s.rule_detail then
				found = true
				break
			end
		end
		if not found then
			s.rule_detail = nil
		end
	end
end

function M.selectedRule(s: State): Rule?
	return s.rule_rows[s.rule_sel]
end

local function setFilter(s: State, text: string)
	local f, err = Group.parseFilter(text)
	s.filter_text = text
	if f then
		s.filter = f
		s.filter_error = nil
	else
		s.filter = EMPTY_FILTER
		s.filter_error = err
	end
end

local function refreshMs(s: State): number
	local p = s.settings.poll_s
	return (if p > 0 then p else M.DEFAULT_REFRESH_S) * 1000
end

local function loadRules(s: State, env: Env, effects: { Effect })
	s.rules_gen += 1
	s.rules_responses = {}
	local cfg = env.config
	if cfg == nil then
		s.rules_problem = "No valid config: open Grafana: Settings or see docs/configuration.md."
		s.rules_plan, s.rules_loading = nil, false
		return
	end
	local plan, err = Rules.plan(cfg, s.context)
	if plan == nil then
		s.rules_problem = err
		s.rules_plan, s.rules_loading = nil, false
		return
	end
	if s.rules_plan == nil or (s.rules_plan :: Rules.Plan).context ~= plan.context then
		s.rules, s.rules_errors, s.rules_loaded_ms = {}, {}, nil
		s.rule_sel, s.rule_detail = 1, nil
	end
	s.rules_problem = nil
	s.rules_plan = plan
	s.rules_loading = true
	for _, f in plan.fetches do
		table.insert(effects, {
			kind = "http",
			tag = string.format("r%d:%s", s.rules_gen, f.tag),
			route = f.route,
			request = f.request,
		})
	end
end

local function settleRules(s: State, env: Env, effects: { Effect })
	local result = Rules.combine(env, s.rules_plan :: Rules.Plan, s.rules_responses)
	s.rules_loading = false
	s.rules_responses = {}
	if not result.failed then
		s.rules = result.rules
		s.rules_loaded_ms = env.now_ms
	end
	s.rules_errors = result.errors
	M.deriveRules(s)
	table.insert(effects, { kind = "timer", tag = string.format("rauto:%d", s.rules_gen), ms = refreshMs(s) })
end

local function load(s: State, env: Env, effects: { Effect })
	s.gen += 1
	s.responses = {}
	s.note = nil
	local cfg = env.config
	if cfg == nil then
		s.problem = "No valid config: open Grafana: Settings or see docs/configuration.md."
		s.plan = nil
		s.loading = false
		return
	end
	local plan, err = Sources.plan(cfg, s.context)
	if plan == nil then
		s.problem = err
		s.plan = nil
		s.loading = false
		return
	end
	s.problem = nil
	if s.plan == nil or (s.plan :: Plan).context ~= plan.context then
		s.alerts = {}
		s.loaded_ms = nil
		s.error = nil
		s.warnings = {}
	end
	s.plan = plan
	s.context = plan.context
	s.loading = true
	for _, f in plan.fetches do
		table.insert(effects, {
			kind = "http",
			tag = string.format("%d:%s", s.gen, f.tag),
			route = f.route,
			request = f.request,
		})
	end
end

-- The inbox doubles as a poll of the context it shows, so the status
-- segment catches up as soon as the user looks; only contexts the poller
-- watches are written, so the segment never shows one it would not poll.
local function writeSummary(s: State, env: Env, effects: { Effect }, ok: boolean, kind: Summary.ErrorKind?)
	local context = s.context
	if context == nil or s.settings.poll_s == 0 or table.find(s.settings.contexts, context) == nil then
		return
	end
	local prev = Summary.readPayload(if env.kv_get then env.kv_get(Summary.KEY) else nil)
	local summary = if ok
		then Summary.summarize(s.alerts, env.now_ms)
		else Summary.failed(if prev then prev.contexts[context] else nil, kind or "http", env.now_ms)
	table.insert(effects, {
		kind = "kv_set",
		key = Summary.KEY,
		value = Summary.withContext(prev, context, summary, env.now_ms, s.settings.poll_s),
	})
end

local function settle(s: State, env: Env, effects: { Effect })
	local plan = s.plan :: Plan
	local result = Sources.combine(env, plan, s.responses)
	s.loading = false
	s.responses = {}
	if result.ok then
		s.alerts = result.alerts
		s.error = nil
		s.warnings = result.warnings
		s.loaded_ms = env.now_ms
	else
		s.error = result.error
	end
	M.derive(s)
	writeSummary(s, env, effects, result.ok, result.error_kind)
	table.insert(effects, { kind = "timer", tag = string.format("auto:%d", s.gen), ms = refreshMs(s) })
end

local function linkParams(args: { string }): { [string]: string }
	local first = args[1]
	if first == nil or first == "" then
		return {}
	end
	local link = Scheme.decode(first)
	if link == nil or link.action ~= "alerts" then
		return {}
	end
	return link.params
end

function M.init(args: { string }, saved: any, env: Env): (State, { Effect })
	local params = linkParams(args)
	local settings = Settings.read(env.config)
	local s: State = {
		contexts = sortedContexts(env),
		context = nil,
		plan = nil,
		problem = nil,
		settings = settings,
		gen = 0,
		loading = false,
		responses = {},
		alerts = {},
		loaded_ms = nil,
		error = nil,
		warnings = {},
		filter_text = "",
		filter = EMPTY_FILTER,
		filter_error = nil,
		editing = nil,
		show_muted = false,
		collapsed = {},
		groups = {},
		rows = {},
		shown = 0,
		sel = 1,
		detail = nil,
		note = nil,
		view = "inbox",
		rules_plan = nil,
		rules_problem = nil,
		rules_gen = 0,
		rules_loading = false,
		rules_responses = {},
		rules = {},
		rules_errors = {},
		rules_loaded_ms = nil,
		problems_only = false,
		rule_rows = {},
		rule_sel = 1,
		rule_detail = nil,
	}
	local savedT = if type(saved) == "table" then saved else {}
	s.context = params.context or (if type(savedT.context) == "string" then savedT.context else nil)
	if s.context and env.config and env.config.contexts[s.context :: string] == nil then
		s.context = nil
	end
	s.show_muted = savedT.show_muted == true
	s.problems_only = savedT.problems_only == true
	local view = params.view or savedT.view
	if view == "rules" then
		s.view = "rules"
	end
	local text = params.filter or (if type(savedT.filter) == "string" then savedT.filter else "")
	if params.rule then
		text = string.format('__alert_rule_uid__="%s" %s', params.rule, text)
	end
	setFilter(s, (string.gsub(text, "%s+$", "")))
	local effects: { Effect } = {}
	load(s, env, effects)
	if s.view == "rules" then
		loadRules(s, env, effects)
	end
	M.derive(s)
	return s, effects
end

function M.selectedAlert(s: State): Alert?
	local r = s.rows[s.sel]
	if r and r.kind == "alert" then
		return (r :: any).alert
	end
	if s.detail then
		for _, row in s.rows do
			if row.kind == "alert" and (row :: any).alert.fingerprint == s.detail then
				return (row :: any).alert
			end
		end
	end
	return nil
end

local function move(s: State, delta: number)
	if #s.rows == 0 then
		return
	end
	s.sel = math.clamp(s.sel + delta, 1, #s.rows)
end

local function toggleGroup(s: State, gi: number)
	local g = s.groups[gi]
	if g == nil then
		return
	end
	if s.collapsed[g.key] then
		s.collapsed[g.key] = nil
	else
		s.collapsed[g.key] = true
	end
	M.derive(s)
	for i, r in s.rows do
		if r.kind == "group" and r.group == gi then
			s.sel = i
			break
		end
	end
end

local function activate(s: State)
	local r = s.rows[s.sel]
	if r == nil then
		return
	end
	if r.kind == "group" then
		toggleGroup(s, r.group)
	else
		local fp = (r :: any).alert.fingerprint
		s.detail = if s.detail == fp then nil else fp
	end
end

local function switchContext(s: State, env: Env, name: string, effects: { Effect })
	if name == s.context then
		return
	end
	s.context = name
	s.collapsed = {}
	s.sel = 1
	s.detail = nil
	load(s, env, effects)
	if s.view == "rules" then
		loadRules(s, env, effects)
	end
	M.derive(s)
end

local function setView(s: State, env: Env, view: View, effects: { Effect })
	s.view = view
	s.note = nil
	if view == "rules" then
		local plan = s.rules_plan
		if plan == nil or plan.context ~= s.context or (s.rules_loaded_ms == nil and not s.rules_loading) then
			loadRules(s, env, effects)
		end
	end
end

-- The rules view's actions on the selected rule.
local function ruleAction(s: State, env: Env, what: string, effects: { Effect })
	local rule = M.selectedRule(s)
	if rule == nil then
		s.note = "Select a rule first."
		return
	end
	local r = rule :: Rule
	if what == "query" then
		local link = Rules.queryLink(r)
		if link == nil then
			s.note = "This rule has no query to open."
			return
		end
		s.note = nil
		table.insert(effects, { kind = "open", target = link :: string })
	elseif what == "alerts" then
		local text = Rules.alertsFilter(r)
		if text == nil then
			s.note = "Recording rules have no alerts."
			return
		end
		setFilter(s, text :: string)
		s.sel = 1
		s.show_muted = true
		setView(s, env, "inbox", effects)
		M.derive(s)
	elseif what == "detail" then
		local k = Rules.key(r)
		s.rule_detail = if s.rule_detail == k then nil else k
	end
end

local function cycleContext(s: State, env: Env, step: number, effects: { Effect })
	local n = #s.contexts
	if n < 2 then
		return
	end
	local i = table.find(s.contexts, s.context or "") or 0
	local next = s.contexts[(i - 1 + step) % n + 1]
	switchContext(s, env, next, effects)
end

local function open(s: State, what: string, effects: { Effect })
	local a = M.selectedAlert(s)
	if a == nil then
		s.note = "Select an alert first."
		return
	end
	local alert = a :: Alert
	local target: string?
	if what == "runbook" then
		target = Sources.runbookTarget(alert)
	elseif what == "dashboard" then
		target = Sources.dashboardTarget(alert)
	elseif what == "generator" then
		target = Sources.generatorTarget(alert)
	elseif what == "silence" then
		if s.plan == nil then
			return
		end
		if SilenceApi.target(s.plan :: Plan) == nil then
			s.note = "Prometheus has no silences: silence this alert in the Alertmanager it notifies."
			return
		end
		target = SilenceApi.linkFor(alert)
	end
	if target == nil then
		s.note = string.format("This alert has no %s link.", what)
		return
	end
	s.note = nil
	table.insert(effects, { kind = "open", target = target :: string })
end

local function copyMatchers(s: State, effects: { Effect })
	local a = M.selectedAlert(s)
	if a == nil then
		return
	end
	table.insert(effects, { kind = "copy", text = SilenceMatchers.formatList(SilenceMatchers.fromLabels(a :: Alert)) })
end

local function editKey(s: State, key: any): boolean
	local text = s.editing :: string
	local name = key.name
	if name == "escape" then
		s.editing = nil
	elseif name == "enter" then
		s.editing = nil
		setFilter(s, text)
		s.sel = 1
		M.derive(s)
	elseif name == "backspace" then
		s.editing = string.sub(text, 1, -2)
	elseif name == "paste" and type(key.text) == "string" then
		s.editing = text .. string.gsub(key.text, "[%c]", " ")
	elseif key.text and key.text ~= "" and not key.ctrl and not key.meta then
		s.editing = text .. key.text
	elseif key.ctrl and name == "u" then
		s.editing = ""
	else
		return false
	end
	return true
end

-- Keyboard moves scroll the selection into view (a block's main region does
-- not follow the selection by itself). Ids follow the view's keys.
local function revealRule(s: State, effects: { Effect })
	if s.rule_rows[s.rule_sel] then
		table.insert(effects, { kind = "reveal", id = "main.rules.u" .. s.rule_sel })
	end
end

local function revealRow(s: State, effects: { Effect })
	local r = s.rows[s.sel]
	if r == nil then
		return
	end
	local id = "main.groups.g" .. r.group
	if r.kind == "alert" then
		id ..= ".r" .. (r :: any).alert.fingerprint
	end
	table.insert(effects, { kind = "reveal", id = id })
end

-- (handled) for a key in the rules view.
local function rulesKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	local name = key.name
	local text = key.text
	local n = #s.rule_rows
	if name == "down" or text == "j" then
		s.rule_sel = math.min(math.max(1, n), s.rule_sel + 1)
		revealRule(s, effects)
	elseif name == "up" or text == "k" then
		s.rule_sel = math.max(1, s.rule_sel - 1)
		revealRule(s, effects)
	elseif name == "home" then
		s.rule_sel = 1
		revealRule(s, effects)
	elseif name == "end" then
		s.rule_sel = math.max(1, n)
		revealRule(s, effects)
	elseif name == "enter" or name == "space" then
		ruleAction(s, env, "detail", effects)
	elseif text == "q" then
		ruleAction(s, env, "query", effects)
	elseif text == "a" then
		ruleAction(s, env, "alerts", effects)
	elseif text == "p" then
		s.problems_only = not s.problems_only
		M.deriveRules(s)
	elseif text == "r" then
		loadRules(s, env, effects)
	elseif name == "escape" then
		if s.rule_detail then
			s.rule_detail = nil
		elseif s.filter_text ~= "" then
			setFilter(s, "")
			M.derive(s)
		else
			return false
		end
	else
		return false
	end
	return true
end

-- (handled) for a key in normal mode.
local function normalKey(s: State, key: any, env: Env, effects: { Effect }): boolean
	if key.ctrl or key.meta or key.alt then
		return false
	end
	local name = key.name
	local text = key.text
	if text == "v" then
		setView(s, env, if s.view == "rules" then "inbox" else "rules", effects)
		return true
	elseif text == "/" then
		s.editing = s.filter_text
		table.insert(effects, { kind = "focus", id = "main.filter" })
		return true
	elseif text == "c" then
		cycleContext(s, env, 1, effects)
		return true
	elseif text == "C" then
		cycleContext(s, env, -1, effects)
		return true
	elseif s.view == "rules" then
		return rulesKey(s, key, env, effects)
	end
	if name == "down" or text == "j" then
		move(s, 1)
		revealRow(s, effects)
	elseif name == "up" or text == "k" then
		move(s, -1)
		revealRow(s, effects)
	elseif name == "home" then
		move(s, -#s.rows)
		revealRow(s, effects)
	elseif name == "end" then
		move(s, #s.rows)
		revealRow(s, effects)
	elseif name == "enter" or name == "space" then
		activate(s)
	elseif name == "escape" then
		if s.detail then
			s.detail = nil
		elseif s.filter_text ~= "" then
			setFilter(s, "")
			M.derive(s)
		else
			return false
		end
	elseif text == "r" then
		load(s, env, effects)
	elseif text == "m" then
		s.show_muted = not s.show_muted
		M.derive(s)
	elseif text == "s" then
		open(s, "silence", effects)
	elseif text == "o" then
		open(s, "runbook", effects)
	elseif text == "d" then
		open(s, "dashboard", effects)
	elseif text == "g" then
		open(s, "generator", effects)
	elseif text == "y" then
		copyMatchers(s, effects)
	else
		return false
	end
	return true
end

function M.key(s: State, key: any, env: Env): (State, { Effect }, boolean)
	local effects: { Effect } = {}
	local handled = if s.editing ~= nil then editKey(s, key) else normalKey(s, key, env, effects)
	return s, effects, handled
end

local function onAction(s: State, act: string, value: string?, env: Env, effects: { Effect })
	if act == "ctx" and value then
		if table.find(s.contexts, value) then
			switchContext(s, env, value, effects)
		end
	elseif act == "reload" then
		load(s, env, effects)
	elseif act == "muted" then
		s.show_muted = not s.show_muted
		M.derive(s)
	elseif act == "filter" then
		s.editing = s.filter_text
		table.insert(effects, { kind = "focus", id = "main.filter" })
	elseif act == "clear" then
		s.editing = nil
		setFilter(s, "")
		M.derive(s)
	elseif act == "row" and value then
		local i = tonumber(value)
		if i and s.rows[i] then
			s.sel = i
			activate(s)
		end
	elseif act == "open" and value then
		open(s, value, effects)
	elseif act == "copy" then
		copyMatchers(s, effects)
	elseif act == "view" and (value == "inbox" or value == "rules") then
		setView(s, env, value :: View, effects)
	elseif act == "rrow" and value then
		local i = tonumber(value)
		if i and s.rule_rows[i] then
			s.rule_sel = i
			ruleAction(s, env, "detail", effects)
		end
	elseif act == "rule" and value then
		ruleAction(s, env, value, effects)
	elseif act == "problems" then
		s.problems_only = not s.problems_only
		M.deriveRules(s)
	elseif act == "rreload" then
		loadRules(s, env, effects)
	end
end

function M.update(s: State, msg: Msg, env: Env): (State, { Effect })
	local effects: { Effect } = {}
	if msg.kind == "http_done" then
		local rgen, rtag = string.match(msg.tag, "^r(%d+):(.+)$")
		if rgen then
			if tonumber(rgen) ~= s.rules_gen or s.rules_plan == nil or not s.rules_loading then
				return s, effects
			end
			s.rules_responses[rtag :: string] = msg.response
			for _, f in (s.rules_plan :: Rules.Plan).fetches do
				if s.rules_responses[f.tag] == nil then
					return s, effects
				end
			end
			settleRules(s, env, effects)
			return s, effects
		end
		local gen, tag = string.match(msg.tag, "^(%d+):(.+)$")
		if gen == nil or tonumber(gen) ~= s.gen or s.plan == nil or not s.loading then
			return s, effects
		end
		s.responses[tag :: string] = msg.response
		for _, f in (s.plan :: Plan).fetches do
			if s.responses[f.tag] == nil then
				return s, effects
			end
		end
		settle(s, env, effects)
	elseif msg.kind == "tick" then
		if msg.tag == string.format("auto:%d", s.gen) and not s.loading then
			load(s, env, effects)
		elseif msg.tag == string.format("rauto:%d", s.rules_gen) and not s.rules_loading and s.view == "rules" then
			loadRules(s, env, effects)
		end
	elseif msg.kind == "key" then
		local _, list = M.key(s, msg.key, env)
		return s, list
	elseif msg.kind == "event" then
		local ev: any = msg.ev
		if ev.ev == "action" and type(ev.act) == "string" then
			onAction(s, ev.act, ev.value, env, effects)
		elseif ev.ev == "toggle" and type(ev.id) == "string" then
			local gi = tonumber(string.match(ev.id, "%.g(%d+)$") or "")
			if gi then
				toggleGroup(s, gi)
			end
		end
	end
	return s, effects
end

function M.title(s: State): string?
	local firing = 0
	for _, a in s.alerts do
		if a.state == "firing" then
			firing += 1
		end
	end
	if s.view == "rules" then
		return if s.context then "Rules: " .. (s.context :: string) else "Rules"
	end
	local base = if s.context then "Alerts: " .. (s.context :: string) else "Alerts"
	return if firing > 0 then string.format("%s (%d firing)", base, firing) else base
end

-- Only what to reopen with: never alerts, labels or credentials.
function M.save(s: State): any
	return {
		context = s.context,
		filter = s.filter_text,
		show_muted = s.show_muted,
		view = s.view,
		problems_only = s.problems_only,
	}
end

return M
