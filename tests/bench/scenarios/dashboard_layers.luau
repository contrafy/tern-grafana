--!strict
-- Dashboard block paths added in 0.6.0, load to first paint and refreshes:
-- - alert-states-adhoc: tern-alert-states (three time series, the built-in
--   "Annotations & Alerts" layer, a Prometheus layer and a disabled one)
--   with tern-fid2-adhoc's datasource and ad hoc variables (three filters)
--   and its panels repeated to 12; the built-in layer answers 300
--   annotations (regions and alert state changes) over the range, the
--   Prometheus layer the recorded range capture, the rules request the
--   recorded rules (panel 2 firing); panels answer 10 series x 360 points.
--   `alert-states-plain` is the same dashboard without the ad hoc variables
--   and the Prometheus layer, its annotation and rules requests answered
--   empty: the difference is what layers, alert states and filters cost.
-- - tern-s4-json: the recorded JSON API dashboard (gauges, stats, a time
--   series grouped by city and a table), every datasource proxy request
--   answered from its capture.
-- Paint and refresh semantics as in scenarios/dashboard.luau.

local Bench = require("../lib/bench")
local Fixtures = require("../../lib/fixtures")
local Paint = require("../lib/paint")
local Probes = require("../lib/probes")
local S = require("../../unit/dashboard/support")
local State = require("../../../plugin/lib/dashboard/state")
local Synth = require("../lib/synth")
local View = require("../../../plugin/lib/dashboard/view")
local json = require("../../lib/json")

local VERSION = "12.4.12"
local PANELS = 12
local SERIES, POINTS = 10, 360
local ANNOTATIONS = 300

local function grafana(name: string): string
	return S.grafana(VERSION, name)
end

local function ok(body: string, status: number?): any
	return {
		status = status or 200,
		headers = { ["Content-Type"] = "application/json" },
		body = body,
		timed_out = false,
	}
end

type Answer = (e: any, variant: number) -> any

type Case = { name: string, uid: string, args: string, dash: string, fs: string, answer: Answer }

local function layered(withLayers: boolean): string
	local doc = json.decode(Fixtures.read(grafana("dashboard_tern_alert_states.json")))
	local d = doc.dashboard
	local adhoc = json.decode(Fixtures.read(grafana("dashboard_tern_fid2_adhoc.json"))).dashboard
	local base = d.panels
	local panels = {}
	for i = 1, PANELS do
		local p = json.decode(json.encode(base[(i - 1) % #base + 1]))
		p.id = i
		p.gridPos = { x = ((i - 1) % 2) * 12, y = ((i - 1) // 2) * 8, w = 12, h = 8 }
		if withLayers then
			p.datasource = { type = "prometheus", uid = "${datasource}" }
			for _, t in p.targets do
				t.datasource = p.datasource
			end
		end
		table.insert(panels, p)
	end
	d.panels = panels
	d.uid = if withLayers then "bench-layers" else "bench-plain"
	if withLayers then
		local vars = {}
		for _, v in adhoc.templating.list do
			if v.name == "datasource" or v.name == "filter" then
				table.insert(vars, v)
			end
		end
		vars[2].filters = {
			{ key = "job", operator = "=", value = "prometheus" },
			{ key = "instance", operator = "=~", value = "localhost:.*" },
			{ key = "code", operator = "!=", value = "500" },
		}
		d.templating = { list = vars }
	else
		d.annotations = { list = json.decode("[]") }
		d.templating = { list = json.decode("[]") }
	end
	return json.encode(doc)
end

-- The built-in layer's answer: points and regions on every panel, alert
-- state changes among them, newest first as Grafana sorts them.
local function annotationsBody(): string
	local to = S.NOW_MS
	local states = { "Alerting", "Normal", "Pending", "Normal (NoData)" }
	local items = table.create(ANNOTATIONS)
	for i = 1, ANNOTATIONS do
		local t = to - i * (3600000 // ANNOTATIONS)
		local a: { [string]: any } = {
			id = i,
			dashboardUID = "bench-layers",
			panelId = (i - 1) % PANELS + 1,
			time = t,
			timeEnd = if i % 3 == 0 then t + 60000 else t,
			text = "deploy " .. i,
			tags = { "deploy", "service:" .. (i % 7) },
		}
		if i % 4 == 0 then
			a.alertId = i
			a.newState = states[(i // 4) % #states + 1]
			a.prevState = "Normal"
		end
		items[i] = a
	end
	return json.encode(items)
end

local NO_RULES = '{"status":"success","data":{"groups":[]}}'

local function layeredAnswer(empty: boolean): Answer
	local cache: { [string]: string } = {}
	local annotations = if empty then "[]" else annotationsBody()
	return function(e: any, variant: number): any
		local tg = e.tag
		if string.match(tg, "^layer/") then
			local path = e.request.path
			if path == "/api/annotations" then
				return ok(annotations)
			elseif path == "/api/ds/query" then
				return ok(Fixtures.read(grafana("ds_query_prom_range.json")))
			end
			return ok(if empty then NO_RULES else Fixtures.read(grafana("alerting_prom_rules.json")))
		elseif string.match(tg, "^q/") then
			local key = tg:gsub("^q/%d+/%d+/", "") .. "#" .. (variant % 2)
			local body = cache[key]
			if body == nil then
				body = Synth.grafanaAnswer(json.decode(e.request.body), SERIES, POINTS, 1 + variant % 2)
				cache[key] = body
			end
			return ok(body :: string)
		end
		return nil
	end
end

-- The capture answering a datasource proxy request (the appid the capture
-- scrubbed is "redacted-appid" in the frontend settings).
local function jsonAnswer(): Answer
	local byUrl: { [string]: { any } } = {}
	for line in string.gmatch(Fixtures.read("MANIFEST.tsv"), "[^\n]+") do
		local cols = string.split(line, "\t")
		if
			string.find(cols[1], "grafana/" .. VERSION .. "/s4_json_", 1, true) == 1
			and cols[2] == "GET"
			and string.find(cols[3], "/api/datasources/proxy/", 1, true) == 1
		then
			local url = string.gsub(cols[3], "appid=REDACTED", "appid=redacted-appid")
			byUrl[url] = { cols[1], tonumber(cols[4]) }
		end
	end
	return function(e: any, _variant: number): any
		if e.request.path == "/api/annotations" then
			return ok("[]")
		end
		local hit = byUrl[e.request.path]
		-- Chicago and Seattle by coordinates were not captured: Dallas'
		-- document has their shape.
		if hit == nil and string.match(e.request.path, "^/api/datasources/proxy/uid/json%-%a+%?lat=") then
			hit =
				byUrl["/api/datasources/proxy/uid/json-dallas?lat=32.78&lon=-96.8&units=imperial&appid=redacted-appid"]
		end
		if hit == nil then
			return nil
		end
		local r = ok(Fixtures.read(hit[1]), hit[2])
		if string.match(hit[1], "%.html$") then
			r.headers = { ["Content-Type"] = "text/html" }
		end
		return r
	end
end

local function cases(): { Case }
	return {
		{
			name = "alert-states-adhoc",
			uid = "bench-layers",
			args = "",
			dash = layered(true),
			fs = grafana("frontend_settings.json"),
			answer = layeredAnswer(false),
		},
		{
			name = "alert-states-plain",
			uid = "bench-plain",
			args = "",
			dash = layered(false),
			fs = grafana("frontend_settings.json"),
			answer = layeredAnswer(true),
		},
		{
			name = "tern-s4-json",
			uid = "tern-s4-json",
			args = "&var-city=chicago",
			dash = Fixtures.read(grafana("dashboard_tern_s4_json.json")),
			fs = grafana("s4_json_frontend_settings.json"),
			answer = jsonAnswer(),
		},
	}
end

type Harness = { s: any, env: any, p: Paint.Painter, unanswered: { [string]: boolean } }

local function paint(h: Harness)
	local view, assets = View.view(h.s, h.env)
	Paint.paint(h.p, view, assets)
end

local function answer(c: Case, e: any, variant: number): any
	local tg = e.tag
	if string.match(tg, "^dash/") then
		return ok(c.dash)
	elseif string.match(tg, "^fs/") then
		return ok(Fixtures.read(c.fs))
	elseif string.match(tg, "^user/") then
		return ok(Fixtures.read(grafana("user.json")))
	end
	return c.answer(e, variant)
end

local function drive(h: Harness, c: Case, effects: { any }, variant: number, paintEach: boolean)
	local queue = effects
	while #queue > 0 do
		local nextQueue = {}
		for _, e in queue do
			if e.kind ~= "http" then
				continue
			end
			local response = answer(c, e, variant)
			if response == nil then
				h.unanswered[e.request.method .. " " .. e.request.path] = true
				continue
			end
			local _, more = State.update(h.s, { kind = "http_done", tag = e.tag, response = response }, h.env)
			for _, m in more do
				table.insert(nextQueue, m)
			end
			if paintEach then
				paint(h)
			end
		end
		queue = nextQueue
	end
end

local R_KEY = { name = "r", text = "r", ctrl = false, alt = false, shift = false, meta = false }

local function open(c: Case, paintEach: boolean): Harness
	local env = S.env()
	env.array = json.array
	env.decode = Probes.decoder(env.decode)
	local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=" .. c.uid .. c.args }, nil, env)
	local h: Harness = { s = s, env = env, p = Paint.new(), unanswered = {} }
	paint(h)
	drive(h, c, effects, 0, paintEach)
	paint(h)
	return h
end

local function refresh(h: Harness, c: Case, variant: number, paintEach: boolean)
	local _, effects = State.key(h.s, R_KEY :: any, h.env)
	paint(h)
	drive(h, c, effects, variant, paintEach)
	paint(h)
end

local M = {}

function M.run(opts: any): { any }
	local out = {}
	for _, c in cases() do
		local name = "dashboard/" .. c.name
		if not opts.match(name) then
			continue
		end
		do
			local h = open(c, false)
			refresh(h, c, 1, false)
		end
		local first = Bench.sample(opts.warmup, opts.iters, function()
			return nil
		end, function()
			open(c, true)
		end)
		local h0 = open(c, true)
		local same = Bench.sample(opts.warmup, opts.iters, function()
			return h0
		end, function(h: Harness)
			refresh(h, c, 0, false)
		end)
		local variant = 0
		local fresh = Bench.sample(opts.warmup, opts.iters, function()
			variant += 1
			return h0
		end, function(h: Harness)
			refresh(h, c, variant, false)
		end)
		local phasesFirst = Bench.attribute(function()
			open(c, false)
		end)
		local phasesNew = Bench.attribute(function()
			variant += 1
			refresh(h0, c, variant, false)
		end)
		local unanswered = 0
		for _ in h0.unanswered do
			unanswered += 1
		end
		local metrics: { [string]: any } = {
			unanswered_requests = unanswered,
			retained_open_kb = Bench.retainedKb(5, function()
				return open(c, true)
			end),
		}
		Paint.metrics(h0.p, metrics)
		Bench.put(metrics, "first_paint", first)
		Bench.put(metrics, "refresh_same", same)
		Bench.put(metrics, "refresh_new", fresh)
		table.insert(
			out,
			{ name = name, metrics = metrics, phases = { first_paint = phasesFirst, refresh_new = phasesNew } }
		)
	end
	return out
end

return M
