--!strict
-- Dashboard block: load to first paint, then refreshes, for the recorded
-- tern-all-panels, tern-panels and tern-sql dashboards (Grafana 12 fixtures)
-- and a synthetic large dashboard (60 time series panels, 50 series x 1000
-- points each, built on tern-panels' first panel).
--
-- Answers are served immediately in effect order. "Paint" is what the host
-- does on a render: View.view, then every asset through a blob cache as
-- plugin/blob_host.luau does (lib/render/assets + lib/render/blob_cache).
-- The runner (plugin/block_runner.luau) renders after every delivered
-- message, so `refresh_per_answer` paints after each query answer; the other
-- refresh numbers paint once at the end, which isolates data handling.
--
-- "same" refreshes get byte-identical answers (Grafana's step-aligned
-- answers inside one step: the identical-answer shortcut and view memo);
-- "new" refreshes alternate between two different answers per panel, so
-- every panel parses and redraws (for fixtures the second answer is the
-- first plus a trailing space: same data, new parse, same SVG bytes).

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

type Answer = (e: any, variant: number) -> string?

type Case = {
	name: string,
	uid: string,
	dash: string,
	fs: string,
	query: Answer,
	now_ms: number?,
}

local function grafana(name: string): string
	return S.grafana(VERSION, name)
end

-- Fixture used for a query nothing recorded per panel, picked by what the
-- request asks for, with its result renamed to every requested refId.
local function generic(request: any): string
	local q = request.queries[1] or {}
	local dsType = if type(q.datasource) == "table" then q.datasource.type else nil
	local path = if dsType == "loki"
		then "ds_query_loki_logs.json"
		elseif q.format == "heatmap" then "ds_query_prom_heatmap.json"
		elseif q.instant == true and q.range ~= true then "ds_query_prom_instant.json"
		else "ds_query_prom_range.json"
	local doc = json.decode(Fixtures.read(grafana(path)))
	local first: any = nil
	for _, r in doc.results do
		first = r
		break
	end
	local results: { [string]: any } = {}
	for _, rq in request.queries do
		local r = json.decode(json.encode(first))
		for _, f in r.frames or {} do
			f.schema.refId = rq.refId
		end
		results[rq.refId] = r
	end
	return json.encode({ results = results })
end

local function panelId(tag: string): string?
	return string.match(tag, "^q/%d+/%d+/p(%d+)")
end

-- Per-panel captures `<prefix><id>.json` when recorded, else `generic`.
local function fixtureQuery(prefix: string?): Answer
	local cache: { [string]: string } = {}
	return function(e: any, variant: number): string?
		local key = e.tag:gsub("^q/%d+/%d+/", "")
		local base = cache[key]
		if base == nil then
			local id = panelId(e.tag)
			local path = if id and prefix then grafana(prefix .. id .. ".json") else nil
			base = if path and Fixtures.has(path) then Fixtures.read(path) else generic(json.decode(e.request.body))
			cache[key] = base
		end
		return if variant % 2 == 0 then base else (base :: string) .. " "
	end
end

local SERIES, POINTS, PANELS = 50, 1000, 60

local function syntheticDashboard(): string
	local doc = json.decode(Fixtures.read(grafana("dashboard_tern_panels.json")))
	local template: any = nil
	for _, p in doc.dashboard.panels do
		if p.type == "timeseries" then
			template = p
			break
		end
	end
	local text = json.encode(template)
	local panels = {}
	for i = 1, PANELS do
		local p = json.decode(text)
		p.id = i
		p.title = "Synthetic " .. i
		p.gridPos = { x = ((i - 1) % 3) * 8, y = ((i - 1) // 3) * 8, w = 8, h = 8 }
		p.targets = {
			{
				refId = "A",
				datasource = template.datasource,
				expr = "rate(synthetic_metric_" .. i .. "[$__rate_interval])",
			},
		}
		table.insert(panels, p)
	end
	doc.dashboard.uid = "bench-large"
	doc.dashboard.title = "Bench large"
	doc.dashboard.panels = panels
	doc.dashboard.templating = { list = json.decode("[]") }
	return json.encode(doc)
end

local function syntheticQuery(): Answer
	local cache: { [string]: string } = {}
	return function(e: any, variant: number): string?
		local key = e.tag:gsub("^q/%d+/%d+/", "") .. "#" .. (variant % 2)
		local body = cache[key]
		if body == nil then
			body = Synth.grafanaAnswer(json.decode(e.request.body), SERIES, POINTS, 1 + variant % 2)
			cache[key] = body
		end
		return body
	end
end

local function cases(): { Case }
	return {
		{
			name = "tern-all-panels",
			uid = "tern-all-panels",
			dash = grafana("dashboard_tern_all_panels.json"),
			fs = grafana("frontend_settings_all_panels.json"),
			query = fixtureQuery("ds_query_all_panels_"),
			now_ms = tonumber(json.decode(Fixtures.read(grafana("ds_query_all_panels_3.request.json"))).to),
		},
		{
			name = "tern-panels",
			uid = "tern-panels",
			dash = grafana("dashboard_tern_panels.json"),
			fs = grafana("frontend_settings.json"),
			query = fixtureQuery(nil),
		},
		{
			name = "tern-sql",
			uid = "tern-sql",
			dash = grafana("dashboard_tern_sql.json"),
			fs = grafana("frontend_settings_sql.json"),
			query = fixtureQuery("ds_query_sql_"),
		},
		{
			name = "large-60x50x1000",
			uid = "bench-large",
			dash = "",
			fs = grafana("frontend_settings.json"),
			query = syntheticQuery(),
		},
	}
end

local function ok(body: string): any
	return { status = 200, headers = {}, body = body, timed_out = false }
end

type Harness = { s: any, env: any, p: Paint.Painter }

local function paint(h: Harness)
	local view, assets = View.view(h.s, h.env)
	Paint.paint(h.p, view, assets)
end

local function staticAnswer(c: Case, dashBody: string, e: any): string?
	local tg = e.tag
	if string.match(tg, "^dash/") then
		return dashBody
	elseif string.match(tg, "^fs/") then
		return Fixtures.read(c.fs)
	elseif string.match(tg, "^user/") then
		return Fixtures.read(grafana("user.json"))
	elseif string.match(tg, "^lib/") then
		return Fixtures.read(grafana("library_element.json"))
	elseif string.match(tg, "^var/") then
		if e.request.path == "/api/ds/query" then
			return Fixtures.read(grafana("ds_query_prom_instant.json"))
		elseif string.find(e.request.path, "__name__", 1, true) then
			return Fixtures.read("prometheus/3.15.0/label_values_name.json")
		end
		return Fixtures.read(grafana("ds_proxy_prom_label_values.json"))
	end
	return nil
end

-- Answers `effects` (and whatever the answers ask for) until nothing is left.
local function drive(
	h: Harness,
	c: Case,
	dashBody: string,
	effects: { any },
	variant: number,
	paintEach: boolean
): number
	local answered = 0
	local queue = effects
	while #queue > 0 do
		local nextQueue = {}
		for _, e in queue do
			if e.kind ~= "http" then
				continue
			end
			local body = staticAnswer(c, dashBody, e)
			if body == nil and string.match(e.tag, "^q/") then
				body = c.query(e, variant)
				answered += 1
			end
			if body then
				local _, more = State.update(h.s, { kind = "http_done", tag = e.tag, response = ok(body) }, h.env)
				for _, m in more do
					table.insert(nextQueue, m)
				end
				if paintEach then
					paint(h)
				end
			end
		end
		queue = nextQueue
	end
	return answered
end

local R_KEY = { name = "r", text = "r", ctrl = false, alt = false, shift = false, meta = false }

local function open(c: Case, dashBody: string, paintEach: boolean): Harness
	local env = S.env()
	env.decode = Probes.decoder(env.decode)
	if c.now_ms then
		env.now_ms = c.now_ms
	end
	local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=" .. c.uid }, nil, env)
	local h: Harness = { s = s, env = env, p = Paint.new() }
	paint(h)
	drive(h, c, dashBody, effects, 0, paintEach)
	paint(h)
	return h
end

local function refresh(h: Harness, c: Case, dashBody: string, variant: number, paintEach: boolean): number
	local _, effects = State.key(h.s, R_KEY :: any, h.env)
	paint(h)
	local n = drive(h, c, dashBody, effects, variant, paintEach)
	paint(h)
	return n
end

local M = {}

function M.run(opts: any): { any }
	local out = {}
	for _, c in cases() do
		local name = "dashboard/" .. c.name
		if not opts.match(name) then
			continue
		end
		local large = c.dash == ""
		local dashBody = if large then syntheticDashboard() else Fixtures.read(c.dash)
		local warmup = if large then math.min(opts.warmup, 1) else opts.warmup
		local iters = if large then math.max(3, opts.iters // 3) else opts.iters

		-- Warm the answer caches (synthetic bodies are generated once).
		do
			local h = open(c, dashBody, false)
			refresh(h, c, dashBody, 1, false)
		end

		local first = Bench.sample(warmup, iters, function()
			return nil
		end, function()
			open(c, dashBody, true)
		end)
		local h0 = open(c, dashBody, true)
		local sizes: { [string]: any } = {}
		Paint.metrics(h0.p, sizes)
		-- Raw answers the state keeps for the identical-answer check.
		local kept = 0
		for _, ps in h0.s.panels do
			if ps.answer then
				kept += #ps.answer.body
			end
		end
		sizes.answer_bodies_kept_bytes = kept
		local queries = 0
		local same = Bench.sample(warmup, iters, function()
			return h0
		end, function(h: Harness)
			queries = refresh(h, c, dashBody, 0, false)
		end)
		local variant = 0
		local minted0 = h0.p.minted
		local fresh = Bench.sample(warmup, iters, function()
			variant += 1
			return h0
		end, function(h: Harness)
			refresh(h, c, dashBody, variant, false)
		end)
		local mintedPerNew = (h0.p.minted - minted0) / (warmup + iters)
		local views0 = h0.p.views
		local perAnswer = Bench.sample(warmup, iters, function()
			variant += 1
			return h0
		end, function(h: Harness)
			refresh(h, c, dashBody, variant, true)
		end)
		local viewsPerRefresh = (h0.p.views - views0) / (warmup + iters)

		-- Retained heap: one open dashboard, then growth over many new-answer refreshes.
		local retainedOpen = Bench.retainedKb(if large then 3 else 5, function()
			return open(c, dashBody, true)
		end)
		local hm = open(c, dashBody, true)
		local rounds = if large then 10 else 50
		refresh(hm, c, dashBody, 1, false)
		local afterOne = Bench.liveKb()
		for i = 2, rounds do
			refresh(hm, c, dashBody, i, false)
		end
		local afterMany = Bench.liveKb()

		local phasesFirst = Bench.attribute(function()
			open(c, dashBody, false)
		end)
		local phasesNew = Bench.attribute(function()
			variant += 1
			refresh(h0, c, dashBody, variant, false)
		end)

		local metrics: { [string]: any } = {
			queries_per_refresh = queries,
			views_per_refresh = viewsPerRefresh,
			blobs_minted_per_new_refresh = mintedPerNew,
			retained_open_kb = retainedOpen,
			retained_growth_kb_per_refresh = (afterMany - afterOne) / (rounds - 1),
		}
		Bench.put(metrics, "first_paint", first)
		Bench.put(metrics, "refresh_same", same)
		Bench.put(metrics, "refresh_new", fresh)
		Bench.put(metrics, "refresh_per_answer", perAnswer)
		for k, v in sizes do
			metrics[k] = v
		end
		table.insert(
			out,
			{ name = name, metrics = metrics, phases = { first_paint = phasesFirst, refresh_new = phasesNew } }
		)
		assert(hm.s ~= nil, "the measured block stays alive until here")
	end
	return out
end

return M
