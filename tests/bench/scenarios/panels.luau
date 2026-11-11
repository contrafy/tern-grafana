--!strict
-- Single panels on hot paths added in 0.6.0, rendered as the dashboard does
-- (Registry.view, then the host's paint with its blob cache) over frames
-- built once:
-- - timeseries-window-3y: a 6 h range over 5 series holding three years of
--   hourly samples (a SQL or JSON API query without a time filter), so all
--   but a few samples lie outside the range;
-- - timezone-*: 10k-sample time fields formatted in America/New_York (an
--   IANA zone, offset looked up per value across DST) against UTC: a table
--   with a time column, and a time series;
-- - dynamictext-50: tern-s4-dynamictext panels 1 and 2 (Handlebars, inline
--   HTML styles, markdown) rendered once per row over 50 rows;
-- - zabbix-problems-500: tern-s4-zabbix panel 7 (table layout) over 500
--   problems built from the recorded ones; `job` is the datasource job on
--   the recorded answers (tests/lib/zabbix.luau);
-- - json-api-2000: tern-s4-json panels 6 (time series grouped by city) and 7
--   (table) through the JSON API datasource job on a 2000-entry forecast
--   document, then rendered.
-- A case whose modules this checkout lacks is skipped, so the scenario runs
-- unchanged against older releases for before/after numbers.

local Bench = require("../lib/bench")
local Fixtures = require("../../lib/fixtures")
local Paint = require("../lib/paint")
local Registry = require("../../../plugin/lib/panels/registry")
local S = require("../../unit/dashboard/support")
local json = require("../../lib/json")

local VERSION = "12.4.12"
local HOUR = 3600000
local NOW = S.NOW_MS

local function optional(path: string): any
	local ok, m = pcall(require :: any, path)
	return if ok then m else nil
end

local function env(): any
	local e = S.env()
	e.array = json.array
	return e
end

local function dashboardPanel(file: string, pick: (any) -> boolean): any
	for _, p in json.decode(Fixtures.read(S.grafana(VERSION, file))).dashboard.panels do
		if pick(p) then
			return p
		end
	end
	error("no panel in " .. file)
end

local function firstTimeseries(): any
	return dashboardPanel("dashboard_tern_panels.json", function(p)
		return p.type == "timeseries"
	end)
end

-- `n` samples every `step` ms ending at `to`, a seeded walk per series.
local function seriesFrames(count: number, n: number, step: number, to: number): { any }
	local frames = {}
	local state = 12345
	for i = 1, count do
		local times = table.create(n)
		local values = table.create(n)
		local v = 10 * i
		for k = 1, n do
			times[k] = to - (n - k) * step
			state = (1664525 * state + 1013904223) % 4294967296
			v = math.max(0, v + (state / 4294967296 - 0.5) * i)
			values[k] = v
		end
		frames[i] = {
			refId = "A",
			fields = {
				{ name = "Time", type = "time", values = times, config = {} },
				{
					name = "Value",
					type = "number",
					values = values,
					labels = { instance = string.format("host-%02d", i) },
					config = {},
				},
			},
		}
	end
	return frames
end

type Case = { name: string, run: (opts: any) -> { [string]: any }? }

local function render(panel: any, frames: { any }, e: any, o: any): (any, any)
	local view, assets = Registry.view(panel, frames, e, o)
	local p = Paint.new()
	Paint.paint(p, view, assets)
	return view, assets
end

local function sizes(view: any, assets: any, into: { [string]: any })
	local a = Bench.assets(assets)
	into.view_nodes = Bench.nodes(view)
	into.asset_bytes = a.bytes
	into.svg_assets = a.svg
end

local W = 960

local function windowCase(opts: any): { [string]: any }?
	local panel = firstTimeseries()
	local e = env()
	local frames = seriesFrames(5, 3 * 365 * 24, HOUR, NOW)
	local o = { key = "p", from_ms = NOW - 6 * HOUR, to_ms = NOW, width = W, height = 300, source = panel }
	local m: { [string]: any } = {}
	local w = W
	Bench.put(
		m,
		"render",
		Bench.sample(opts.warmup, opts.iters, function()
			w += 1
			return w
		end, function(width: number)
			o.width = width
			render(panel, frames, e, o)
		end)
	)
	o.width = W
	local view, assets = render(panel, frames, e, o)
	sizes(view, assets, m)
	return m
end

local function timezoneCases(): { Case }
	local ClockZone = optional("../../../plugin/lib/panels/clock_zone")
	local function zones(): { { any } }
		local list: { { any } } = { { "utc", 0 } }
		if ClockZone and ClockZone.dashboardOffset then
			table.insert(list, { "new_york", ClockZone.dashboardOffset("America/New_York", 0) })
		end
		return list
	end
	local N = 10000
	-- 10k samples a minute apart across the March 2026 DST change in New York.
	local TO = 1773558000000 + N // 2 * 60000
	local function tableCase(opts: any): { [string]: any }?
		local panel = dashboardPanel("dashboard_tern_all_panels.json", function(p)
			return p.type == "table" and p.id == 14
		end)
		local e = env()
		local frames = seriesFrames(1, N, 60000, TO)
		local m: { [string]: any } = {}
		for _, z in zones() do
			local o = { key = "p", from_ms = TO - N * 60000, to_ms = TO, width = W, height = 300, source = panel }
			o.offset_min = z[2]
			Bench.put(
				m,
				"render_" .. z[1],
				Bench.sample(opts.warmup, opts.iters, function()
					return nil
				end, function()
					render(panel, frames, e, o)
				end)
			)
		end
		return m
	end
	local function seriesCase(opts: any): { [string]: any }?
		local panel = firstTimeseries()
		local e = env()
		local frames = seriesFrames(1, N, 60000, TO)
		local m: { [string]: any } = {}
		for _, z in zones() do
			local o = { key = "p", from_ms = TO - N * 60000, to_ms = TO, width = W, height = 300, source = panel }
			o.offset_min = z[2]
			local w = W
			Bench.put(
				m,
				"render_" .. z[1],
				Bench.sample(opts.warmup, opts.iters, function()
					w += 1
					return w
				end, function(width: number)
					o.width = width
					render(panel, frames, e, o)
				end)
			)
		end
		return m
	end
	return {
		{ name = "panel/timezone-table-10k", run = tableCase },
		{ name = "panel/timezone-timeseries-10k", run = seriesCase },
	}
end

local function dynamictextCase(opts: any): { [string]: any }?
	if optional("../../../plugin/lib/panels/dynamictext") == nil then
		return nil
	end
	local ROWS = 50
	local doc = json.decode(Fixtures.read(S.grafana(VERSION, "dashboard_tern_s4_dynamictext.json"))).dashboard
	local e = env()
	local m: { [string]: any } = {}
	local function strings(name: string, make: (number) -> string): any
		local values = table.create(ROWS)
		for i = 1, ROWS do
			values[i] = make(i)
		end
		return { name = name, type = "string", values = values, config = {} }
	end
	local function numbers(name: string, typ: string, make: (number) -> number): any
		local values = table.create(ROWS)
		for i = 1, ROWS do
			values[i] = make(i)
		end
		return { name = name, type = typ, values = values, config = {} }
	end
	local frames: { [number]: { any } } = {
		[1] = {
			{
				refId = "A",
				fields = {
					strings("site", function(i)
						return string.format("SITE-%02d", i)
					end),
					strings("status", function(i)
						return if i % 7 == 0 then "Major outage" else "Operational"
					end),
					numbers("outage", "boolean", function(i)
						return if i % 7 == 0 then 1 else 0
					end),
					numbers("affected", "number", function(i)
						return if i % 7 == 0 then i * 13 else 0
					end),
					strings("affected_display", function(i)
						return if i % 7 == 0
							then string.format('<b style="color:#f87171">%d subscribers</b> in 3 buildings', i * 13)
							else "<b>none</b>"
					end),
					strings("updated", function(i)
						return string.format("2026-11-09 08:%02d", i % 60)
					end),
				},
			},
		},
		[2] = {
			{
				refId = "A",
				fields = {
					strings("reviewer", function(i)
						return "Reviewer " .. i
					end),
					numbers("time", "time", function(i)
						return 1794211200000 + i * HOUR
					end),
					strings("review_rows", function(i)
						return string.format(
							'<tr><td>INC-%d</td><td style="color:#4ade80">approved</td></tr>'
								.. '<tr><td>INC-%d</td><td style="color:#facc15">changes</td></tr>',
							100 + i,
							200 + i
						)
					end),
				},
			},
		},
	}
	for _, p in doc.panels do
		local f = frames[p.id]
		if f == nil then
			continue
		end
		-- Panel 1's outage column is a boolean in the CSV.
		for _, fld in f[1].fields do
			if fld.type == "boolean" then
				for i, v in fld.values do
					fld.values[i] = v == 1
				end
			end
		end
		local o = { key = "p", from_ms = NOW - 6 * HOUR, to_ms = NOW, width = W, height = 600, source = p }
		Bench.put(
			m,
			"render_panel" .. p.id,
			Bench.sample(opts.warmup, opts.iters, function()
				return nil
			end, function()
				render(p, f, e, o)
			end)
		)
		local view = render(p, f, e, o)
		m["view_nodes_panel" .. p.id] = Bench.nodes(view)
	end
	return m
end

local function zabbixCase(opts: any): { [string]: any }?
	if optional("../../../plugin/lib/panels/zabbix_problems") == nil then
		return nil
	end
	local Z = require("../../lib/zabbix")
	local panel = Z.panel(VERSION, 7)
	local m: { [string]: any } = {}
	Bench.put(
		m,
		"job",
		Bench.sample(opts.warmup, opts.iters, function()
			return nil
		end, function()
			Z.run(VERSION, panel.targets)
		end)
	)
	local recorded = Z.run(VERSION, panel.targets).data.frames
	local PROBLEMS = 500
	local templates: { any } = {}
	for _, f in recorded do
		for _, v in f.fields[1].values do
			table.insert(templates, json.encode(v))
		end
	end
	local values = table.create(PROBLEMS)
	for i = 1, PROBLEMS do
		local p = json.decode(templates[(i - 1) % #templates + 1])
		p.eventid = tostring(1000 + i)
		p.severity = tostring(i % 6)
		p.timestamp = 1794254325 - i * 97
		p.hosts[1].name = string.format("edge-%03d", i % 120)
		p.hosts[1].host = p.hosts[1].name
		p.acknowledged = if i % 5 == 0 then "1" else "0"
		values[i] = p
	end
	local frames = { { refId = "A", fields = { { name = "Problems", type = "other", values = values, config = {} } } } }
	local e = Z.env
	local o = { key = "p", from_ms = NOW - HOUR, to_ms = NOW, width = W, height = 400, source = panel }
	Bench.put(
		m,
		"render",
		Bench.sample(opts.warmup, opts.iters, function()
			return nil
		end, function()
			render(panel, frames, e, o)
		end)
	)
	m.view_nodes = Bench.nodes((render(panel, frames, e, o)))
	return m
end

local function jsonApiCase(opts: any): { [string]: any }?
	local JsonApi = optional("../../../plugin/lib/datasources/json_api")
	if JsonApi == nil then
		return nil
	end
	local ENTRIES = 2000
	local doc = json.decode(Fixtures.read(S.grafana(VERSION, "s4_json_forecast.json")))
	local base = doc.list
	local list = table.create(ENTRIES)
	for i = 1, ENTRIES do
		local item = json.decode(json.encode(base[(i - 1) % #base + 1]))
		local dt = 1762689600 + ((i - 1) // #base) * 3600
		item.dt = dt
		item.dt_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", dt)
		item.dt_txt = os.date("!%Y-%m-%d %H:%M:%S", dt)
		item.main.temp = 40 + (i * 37 % 400) / 10
		list[i] = item
	end
	doc.list = list
	doc.cnt = ENTRIES
	local body = json.encode(doc)
	local dash = json.decode(Fixtures.read(S.grafana(VERSION, "dashboard_tern_s4_json.json"))).dashboard
	local e = env()
	e.decode = Bench.countDecode(e.decode)
	local ds = { uid = "json-api", name = "JSON API", type = JsonApi.TYPE, is_default = false, url = "/" }
	local m: { [string]: any } = {}
	for _, p in dash.panels do
		if p.id ~= 6 and p.id ~= 7 then
			continue
		end
		local from = 1762678800000
		local to = 1762732800000
		local ctx = {
			scope = {},
			from_ms = from,
			to_ms = to,
			interval_ms = 60000,
			max_points = 1000,
			now_ms = to,
			datasources = { ds },
			ds = ds,
			grafana_major = 12,
		}
		local o = { key = "p", from_ms = from, to_ms = to, width = W, height = 300, source = p }
		local function run(): { any }
			local job, reqs, outcome = JsonApi.step(JsonApi.start(p.targets, ctx, e), {}, e)
			while outcome == nil do
				local answers = {}
				for _, r in reqs do
					answers[r.tag] = {
						status = 200,
						headers = { ["Content-Type"] = "application/json" },
						body = body,
						timed_out = false,
					}
				end
				job, reqs, outcome = JsonApi.step(job, answers, e)
			end
			assert(outcome.data, outcome.error)
			return outcome.data.frames
		end
		Bench.put(
			m,
			"job_panel" .. p.id,
			Bench.sample(opts.warmup, opts.iters, function()
				return nil
			end, function()
				run()
			end)
		)
		local frames = run()
		Bench.put(
			m,
			"render_panel" .. p.id,
			Bench.sample(opts.warmup, opts.iters, function()
				return nil
			end, function()
				render(p, frames, e, o)
			end)
		)
		m["frames_panel" .. p.id] = #frames
		m["view_nodes_panel" .. p.id] = Bench.nodes((render(p, frames, e, o)))
	end
	return m
end

local M = {}

function M.run(opts: any): { any }
	local cases: { Case } = {
		{ name = "panel/timeseries-window-3y", run = windowCase },
	}
	for _, c in timezoneCases() do
		table.insert(cases, c)
	end
	table.insert(cases, { name = "panel/dynamictext-50", run = dynamictextCase })
	table.insert(cases, { name = "panel/zabbix-problems-500", run = zabbixCase })
	table.insert(cases, { name = "panel/json-api-2000", run = jsonApiCase })
	local out = {}
	for _, c in cases do
		if not opts.match(c.name) then
			continue
		end
		local metrics = c.run(opts)
		if metrics then
			table.insert(out, { name = c.name, metrics = metrics })
		end
	end
	return out
end

return M
