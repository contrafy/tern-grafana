--!strict
-- The dashboard machine's loading and answers: the dashboard, Grafana's
-- frontend settings and user, library panels, variable values, panel
-- queries, module requests and renders. Handlers that may find their answer
-- stale return whether they changed anything.

local Advance = require("./advance")
local Core = require("./core")
local DashConfig = require("./config")
local DsRegistry = require("../datasources/registry")
local Effect = require("../effect")
local Env = require("../env")
local GrafanaSource = require("../source/grafana")
local Model = require("./model")
local Png = require("./png")
local Queries = require("./queries")
local Registry = require("../panels/registry")
local Route = require("../config/route")
local Search = require("./search")
local Types = require("./types")
local Variables = require("./variables")

type Env = Env.Env
type Effect = Effect.Effect
type Route = Route.Route
type State = Types.State

local tag, http = Core.tag, Core.http

local M = {}

function M.startLoad(s: State, effects: { Effect })
	local route = s.route
	local uid = s.uid
	if route == nil or uid == nil then
		return
	end
	s.gen += 1
	s.phase = "loading"
	s.error = nil
	s.dashboard = nil
	s.vars = {}
	s.var_runs = {}
	Core.changed(s)
	s.panels = {}
	s.memo = {}
	Core.setSections(s, {})
	s.sections_rev = nil
	s.order = {}
	s.png_tags = {}
	s.png_errors = {}
	s.png_wait = false
	s.live_gen += 1
	s.live_ms = nil
	s.layers = Types.newLayers()
	table.insert(effects, http(tag("dash", s.gen), route, Model.request(uid)))
	if s.settings.status ~= "ready" then
		s.settings = { status = "loading", renderer = nil, datasources = {}, features = {} }
		table.insert(effects, http(tag("fs", s.gen), route, GrafanaSource.frontendSettingsRequest(route)))
	end
	if s.user.status ~= "ready" then
		s.user = { status = "loading" }
		table.insert(effects, http(tag("user", s.gen), route, GrafanaSource.userRequest(route)))
	end
end

function M.startSearch(s: State, query: string, effects: { Effect })
	local route = s.route
	if route == nil then
		return
	end
	s.search.gen += 1
	s.search.status = "loading"
	table.insert(effects, http(tag("search", s.search.gen), route, Search.request(query)))
end

function M.onDashboard(s: State, response: any, env: Env, effects: { Effect })
	local d, err = Model.parseResponse(response, env)
	if d == nil then
		Core.setError(s, err or "the dashboard could not be loaded")
		return
	end
	s.dashboard = d
	s.phase = "ready"
	if s.from == nil or s.to == nil then
		s.from, s.to = d.time.from, d.time.to
	end
	Core.resolveRange(s, env)
	local vars, verr = Variables.fromModel(d.templating, env)
	s.vars = vars
	s.vars_error = verr
	Variables.applyUrl(s.vars, s.link_vars)
	Core.changed(s)
	s.refresh_ms = DashConfig.refreshMs(d.refresh, s.cfg)
	if s.link_panel and not s.solo then
		for _, sec in d.sections do
			for _, p in sec.panels do
				if p.id == s.link_panel then
					s.expanded = true
				end
			end
		end
	end
	local route = s.route :: Route
	for _, uid in Model.libraryRefs(d) do
		table.insert(effects, http(tag("lib", s.gen, uid), route, Model.libraryRequest(uid)))
	end
	s.updated_ms = env.now_ms
	Advance.armRefresh(s, effects)
	Advance.advance(s, env, false, effects)
	if s.link_panel then
		for _, key in s.order do
			local inst = Core.find(s, key)
			if inst and inst.panel.id == s.link_panel then
				s.focus = key
				break
			end
		end
	end
end

function M.onSettings(s: State, response: any, env: Env, effects: { Effect })
	local route = s.route :: Route
	local r = GrafanaSource.parseFrontendSettings(route, response, env)
	if r.ok then
		local fs = (r :: any).settings :: GrafanaSource.FrontendSettings
		-- The OpenFeature flags come from their own requests; the settings
		-- stay loading until every one is answered, so panels are laid out
		-- once, as the frontend lays them out after initOpenFeature.
		local pending = 0
		for _, flag in Queries.OPEN_FEATURE_FLAGS do
			local req = Queries.flagRequest(response, flag, env)
			if req then
				pending += 1
				table.insert(effects, http(tag("flag", s.gen, flag), route, req))
			end
		end
		s.settings = {
			status = if pending > 0 then "loading" else "ready",
			renderer = fs.renderer_available == true,
			datasources = Queries.frontendDatasources(response, env),
			features = Queries.frontendFeatures(response, env),
			major = Queries.major(fs.version),
			pending_flags = pending,
		}
	else
		s.settings = {
			status = "error",
			renderer = false,
			datasources = {},
			features = {},
			error = (r :: any).error.message,
		}
	end
	Advance.advance(s, env, false, effects)
end

-- An OpenFeature flag's evaluation (Queries.flagRequest): on joins the
-- feature toggles; the last answer readies the settings.
function M.onFlag(s: State, flag: string, response: any, env: Env, effects: { Effect }): boolean
	local settings = s.settings
	local pending = settings.pending_flags or 0
	if settings.status ~= "loading" or pending <= 0 then
		return false
	end
	if Queries.flagOn(response, env) then
		settings.features[flag] = true
	end
	settings.pending_flags = pending - 1
	if pending == 1 then
		settings.status = "ready"
	end
	Advance.advance(s, env, false, effects)
	return true
end

function M.onUser(s: State, response: any, env: Env, effects: { Effect })
	local r = GrafanaSource.parseUser(s.route :: Route, response, env)
	s.user = if r.ok then { status = "ready", login = (r :: any).user.login } else { status = "error" }
	Advance.advance(s, env, false, effects)
end

function M.onLibrary(s: State, uid: string, response: any, env: Env, effects: { Effect }): boolean
	local d = s.dashboard
	if d == nil then
		return false
	end
	local model = Model.parseLibrary(response, env)
	Model.applyLibrary(d, uid, model, env)
	Core.changed(s)
	Advance.advance(s, env, false, effects)
	return true
end

function M.onVariable(s: State, name: string, response: any, env: Env, effects: { Effect }): boolean
	local v = Variables.find(s.vars, name)
	local route = s.route
	if v == nil or route == nil or v.status ~= "loading" then
		return false
	end
	local scope = Core.scopeOf(s)
	local uid, source = Advance.variableSource(s, v, scope)
	local fetch = Variables.fetchFor(v, scope, Core.builtinScope(s), source)
	if fetch == nil or uid == nil then
		Variables.setError(v, "variable query changed while loading")
	else
		local values, err = Variables.parseFetch(fetch, Core.datasourceRoute(route, uid), response, env)
		if values == nil then
			Variables.setError(v, err or "no values")
		else
			local options, rerr = Variables.optionsFrom(v, values, scope)
			if rerr then
				Variables.setError(v, rerr)
			else
				Variables.setOptions(v, options)
			end
		end
	end
	Core.changed(s)
	Advance.advance(s, env, false, effects)
	return true
end

local function readAnswer(s: State, key: string, response: any, env: Env)
	local ps = s.panels[key]
	if ps == nil then
		return
	end
	-- The same query answered byte for byte as last time (Grafana aligns a
	-- range to its step, so refreshes inside one step do): keep the parsed
	-- data, whose identity keys the view memo, so nothing is redrawn.
	local last = ps.answer
	local body = if type(response.body) == "string" then response.body else nil
	if
		last
		and body
		and ps.data ~= nil
		and last.sig == ps.signature
		and last.status == response.status
		and last.body == body
	then
		ps.status = last.panel_status
		ps.drawn = ps.asked
		s.updated_ms = env.now_ms
		return
	end
	local pq = ps.pq
	if pq == nil or Core.find(s, Core.instanceKey(key)) == nil then
		return
	end
	if pq.jobs then
		-- One part of several: shown once the jobs answered too.
		Queries.setAnswer(pq, response, env)
		local all = Queries.combine(pq)
		if all then
			Core.showData(s, key, ps, all, env)
		end
		return
	end
	local data, err = Queries.parse(response, pq, env)
	if data == nil then
		ps.status, ps.error = "error", err
		return
	end
	Core.showData(s, key, ps, data, env)
	ps.answer = if body and ps.signature
		then { sig = ps.signature :: string, status = response.status, body = body, panel_status = ps.status }
		else nil
end

function M.onQuery(s: State, key: string, response: any, env: Env)
	readAnswer(s, key, response, env)
	Advance.syncShared(s, env)
end

-- A panel's datasource job answer: tag ds/<gen>/<panel gen>/<job>/<request
-- tag>/<panel key>. Answers to a superseded query, or that the job does
-- not wait for, are dropped.
function M.onJob(s: State, parts: { string }, response: any, env: Env, effects: { Effect }): boolean
	local key = table.concat(parts, "/", 6)
	local ps = s.panels[key]
	if ps == nil or tonumber(parts[3] or "") ~= ps.gen or Core.find(s, Core.instanceKey(key)) == nil then
		return false
	end
	local pq = ps.pq
	local jobs = if pq then pq.jobs else nil
	local index = tonumber(parts[4] or "") or 0
	local job = if jobs then jobs[index] else nil
	if job == nil then
		return false
	end
	local ok, more = DsRegistry.answer(job.run, parts[5] or "", response, env)
	if not ok then
		return false
	end
	Core.jobRequests(s, ps, key, index, more, effects)
	local data = Queries.combine(pq :: Queries.PanelQuery)
	if data then
		Core.showData(s, key, ps, data, env)
		Advance.syncShared(s, env)
	end
	return true
end

-- A query variable's datasource job answer: tag dsv/<gen>/<var gen>/<request
-- tag>/<name>.
function M.onVariableJob(s: State, parts: { string }, response: any, env: Env, effects: { Effect }): boolean
	local name = table.concat(parts, "/", 5)
	local entry = s.var_runs[name]
	local v = Variables.find(s.vars, name)
	if entry == nil or v == nil or v.status ~= "loading" or entry.gen ~= tonumber(parts[3] or "") then
		return false
	end
	local ok, more = DsRegistry.answer(entry.run, parts[4] or "", response, env)
	if not ok then
		return false
	end
	Core.variableRequests(s, entry.gen, name, more, effects)
	local outcome = entry.run.outcome
	if outcome then
		s.var_runs[name] = nil
		Variables.applyOutcome(v, outcome, Core.scopeOf(s))
		Core.changed(s)
		Advance.advance(s, env, false, effects)
	end
	return true
end

-- A module request's answer: tag x/<gen>/<req_gen>/<index>/<panel key>.
function M.onExtra(s: State, parts: { string }, response: any, env: Env): boolean
	local key = table.concat(parts, "/", 5)
	local ps = s.panels[key]
	local inst = Core.find(s, key)
	if ps == nil or inst == nil or tonumber(parts[3] or "") ~= ps.req_gen then
		return false
	end
	local name = ps.req_tags[tonumber(parts[4] or "") or 0]
	if name == nil then
		return false
	end
	ps.extra = ps.extra or {}
	(ps.extra :: any)[name] = Registry.parse(inst.panel.json, name, response, env)
	ps.extra_gen += 1
	s.updated_ms = env.now_ms
	return true
end

M.PNG_BACKOFF_MS = 5000
M.PNG_BACKOFF_MAX_MS = 60000

function M.onPng(s: State, t: string, response: any, env: Env, effects: { Effect }): boolean
	local key = s.png_tags[t]
	if key == nil then
		return false
	end
	s.png_tags[t] = nil
	local status = response.status
	if status == 200 and response.failure == nil and string.sub(response.body or "", 2, 4) == "PNG" then
		Png.remember(s, key, response.body)
		s.png_backoff_ms = 0
	elseif status == 429 or status == 503 or response.timed_out then
		-- The renderer is busy: try again later, backing off.
		s.png_backoff_ms = math.min(M.PNG_BACKOFF_MAX_MS, math.max(M.PNG_BACKOFF_MS, s.png_backoff_ms * 2))
		s.png_wait = true
		table.insert(effects, { kind = "timer", tag = tag("pngretry", s.gen, s.png_gen), ms = s.png_backoff_ms })
	else
		local why = if response.failure then response.failure.message else "HTTP " .. tostring(status)
		s.png_errors[key] = "render failed (" .. why .. ")"
	end
	Advance.advance(s, env, false, effects)
	return true
end

return M
