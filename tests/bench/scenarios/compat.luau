--!strict
-- Compatibility report over 100 and 1000 dashboards: the Compat block's
-- whole scan (settings, search, every dashboard and library panel fetched and
-- analyzed), the dashboards cycling through the five recorded Grafana 12
-- fixture dashboards. `scan_ms` paints after every answer, as the runner
-- does; `scan_one_paint_ms` paints once at the end (analysis cost alone).

local Bench = require("../lib/bench")
local CompatState = require("../../../plugin/lib/compat/state")
local CompatView = require("../../../plugin/lib/compat/view")
local Fixtures = require("../../lib/fixtures")
local Paint = require("../lib/paint")
local Probes = require("../lib/probes")
local S = require("../../unit/dashboard/support")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")

local COUNTS = { 100, 1000 }
local DASHBOARDS = { "tern_panels", "tern_variables", "tern_all_panels", "tern_observability", "tern_sql" }

local CONFIG = assert(Validate.parseFile(
	[[{"default_context": "lab", "compat": {"max_dashboards": 1000}, "contexts": {
	"lab": {"grafana": {"url": "http://localhost:3000", "org_id": 1}}}}]],
	json.decode
))

local function search(count: number): string
	local list: { any } = {}
	for i = 1, count do
		table.insert(list, { uid = "d" .. i, title = "D" .. i, type = "dash-db" })
	end
	return json.encode(list)
end

local function grafana(name: string): string
	return S.grafana("12.4.12", name)
end

local function bodyFor(e: any, searchBody: string): string?
	local path: string = e.request.path
	if path == "/api/search" then
		local page = 1
		for _, q in e.request.query or {} do
			if q[1] == "page" then
				page = tonumber(q[2]) or 1
			end
		end
		return if page == 1 then searchBody else "[]"
	elseif path == "/api/frontend/settings" then
		return Fixtures.read(grafana("frontend_settings_all_panels.json"))
	end
	local uid = string.match(path, "^/api/dashboards/uid/d(%d+)$")
	if uid then
		local name = DASHBOARDS[(tonumber(uid) :: number - 1) % #DASHBOARDS + 1]
		return Fixtures.read(grafana("dashboard_" .. name .. ".json"))
	elseif string.find(path, "/api/library-elements/", 1, true) then
		return Fixtures.read(grafana("library_element.json"))
	end
	return nil
end

local function scan(searchBody: string, paintEach: boolean): (any, Paint.Painter, number)
	local env = S.env(CONFIG)
	env.decode = Probes.decoder(env.decode)
	local p = Paint.new()
	local s, effects = CompatState.init({}, nil, env)
	local answered = 0
	local queue = effects
	while #queue > 0 do
		local nextQueue = {}
		for _, e: any in queue do
			local body = if e.kind == "http" then bodyFor(e, searchBody) else nil
			if body then
				answered += 1
				local response = { status = 200, headers = {}, body = body, timed_out = false }
				local _, more = CompatState.update(s, { kind = "http_done", tag = e.tag, response = response }, env)
				for _, m in more do
					table.insert(nextQueue, m)
				end
				if paintEach then
					Paint.paint(p, CompatView.view(s, env), nil)
				end
			end
		end
		queue = nextQueue
	end
	Paint.paint(p, CompatView.view(s, env), nil)
	return s, p, answered
end

local M = {}

local function case(opts: any, count: number): any?
	local name = string.format("compat/%d-dashboards", count)
	if not opts.match(name) then
		return nil
	end
	local body = search(count)
	local s, p, answered = scan(body, false)
	local analyzed = #CompatState.ordered(s)
	assert(analyzed == count, "compat bench analyzed " .. analyzed .. " of " .. count .. " dashboards")
	local each = Bench.sample(opts.warmup, opts.iters, function()
		return nil
	end, function()
		scan(body, true)
	end)
	local once = Bench.sample(opts.warmup, opts.iters, function()
		return nil
	end, function()
		scan(body, false)
	end)
	local retained = Bench.retainedKb(5, function()
		return scan(body, false)
	end)
	local phases = Bench.attribute(function()
		scan(body, false)
	end)
	local metrics: { [string]: any } = {
		requests_answered = answered,
		dashboards = analyzed,
		retained_kb = retained,
	}
	Bench.put(metrics, "scan", each)
	Bench.put(metrics, "scan_one_paint", once)
	local sizes: { [string]: any } = {}
	Paint.metrics(p, sizes)
	metrics.view_nodes = sizes.view_nodes
	return { name = name, metrics = metrics, phases = { scan = phases } }
end

function M.run(opts: any): { any }
	local out: { any } = {}
	for _, count in COUNTS do
		local r = case(opts, count)
		if r then
			table.insert(out, r)
		end
	end
	return out
end

return M
