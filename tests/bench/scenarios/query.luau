--!strict
-- Query block on a large range: direct Prometheus, `now-7d` at the largest
-- point budget the config allows (query.max_points 11000, Prometheus' own
-- per-series cap), 20 series. First paint is init to the drawn chart;
-- refreshes press `r` and answer with a different matrix each time
-- (alternating two), then paint. `cursor` moves the keyboard cursor one
-- point and paints (an overlay: the chart's bytes must not change).

local Bench = require("../lib/bench")
local Options = require("../../../plugin/lib/query/options")
local Paint = require("../lib/paint")
local Probes = require("../lib/probes")
local Q = require("../../unit/query/support")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/query/state")
local Synth = require("../lib/synth")
local View = require("../../../plugin/lib/query/view")

local SERIES = 20
local EXPR = "rate(node_cpu_seconds_total[$__rate_interval])"

local CONFIG = Q.config(nil, { max_points = Options.MAX_POINTS_LIMIT })

type Harness = { s: any, env: any, p: Paint.Painter, bytes: number }

local function form(body: string): { [string]: string }
	local out: { [string]: string } = {}
	for _, kv in (Scheme.parseQuery(body) or {}) :: { any } do
		out[kv.name] = kv.value
	end
	return out
end

local answers: { [string]: string } = {}

local function answer(e: any, variant: number): string
	local f = form(e.request.body or "")
	local key = f.start .. ":" .. f["end"] .. ":" .. f.step .. "#" .. variant % 2
	local body = answers[key]
	if body == nil then
		body = Synth.promMatrix(
			SERIES,
			tonumber(f.start) :: number,
			tonumber(f["end"]) :: number,
			tonumber(f.step) :: number,
			1 + variant % 2
		)
		answers[key] = body
	end
	return body
end

local function paint(h: Harness)
	local view, assets = View.view(h.s, h.env)
	Paint.paint(h.p, view, assets)
end

local function deliver(h: Harness, effects: { any }, variant: number)
	for _, e in effects do
		if e.kind == "http" and string.sub(e.tag, 1, #State.QUERY_TAG) == State.QUERY_TAG then
			local body = answer(e, variant)
			h.bytes = #body
			local response = { status = 200, headers = {}, body = body, timed_out = false }
			State.update(h.s, { kind = "http_done", tag = e.tag, response = response }, h.env)
			paint(h)
		end
	end
end

local function open(variant: number): Harness
	local env = Q.env(CONFIG)
	env.decode = Probes.decoder(env.decode)
	local link =
		Scheme.encode({ action = "query", params = { context = "lab", expr = EXPR, from = "now-7d" }, vars = {} })
	local s, effects = State.init({ link }, nil, env)
	local h: Harness = { s = s, env = env, p = Paint.new(), bytes = 0 }
	paint(h)
	deliver(h, effects, variant)
	return h
end

local function press(h: Harness, ch: string, variant: number)
	local _, effects = State.key(h.s, Q.key(ch, if #ch == 1 then ch else nil), h.env)
	paint(h)
	deliver(h, effects, variant)
end

local M = {}

function M.run(opts: any): { any }
	local name = "query/now-7d-20x11000"
	if not opts.match(name) then
		return {}
	end
	open(0)
	open(1)
	local first = Bench.sample(opts.warmup, opts.iters, function()
		return nil
	end, function()
		open(0)
	end)
	local h = open(0)
	local sizes: { [string]: any } = {}
	Paint.metrics(h.p, sizes)
	local variant = 0
	local minted0 = h.p.minted
	local refresh = Bench.sample(opts.warmup, opts.iters, function()
		variant += 1
		return h
	end, function(hh: Harness)
		press(hh, "r", variant)
	end)
	local minted = (h.p.minted - minted0) / (opts.warmup + opts.iters)
	local mintedBeforeCursor = h.p.minted
	local cursor = Bench.sample(opts.warmup, opts.iters, function()
		return h
	end, function(hh: Harness)
		press(hh, "right", 0)
	end)

	local retainedOpen = Bench.retainedKb(5, function()
		return open(0)
	end)
	local hm = open(0)
	-- Live heap after each of 32 refreshes; growth compares the medians of
	-- the first and last 8 samples, because single samples jump by
	-- power-of-two blocks with GC timing (see Bench.retainedKb).
	local live: { number } = {}
	for i = 1, 32 do
		press(hm, "r", i)
		live[i] = Bench.liveKb()
	end
	local function median(from: number, to: number): number
		return Bench.stats(table.move(live, from, to, 1, {})).median
	end
	local growth = (median(25, 32) - median(1, 8)) / 24

	local phasesFirst = Bench.attribute(function()
		open(0)
	end)
	local phasesRefresh = Bench.attribute(function()
		variant += 1
		press(h, "r", variant)
	end)
	local metrics: { [string]: any } = {
		answer_bytes = h.bytes,
		blobs_minted_per_refresh = minted,
		retained_open_kb = retainedOpen,
		retained_growth_kb_per_refresh = growth,
	}
	Bench.put(metrics, "first_paint", first)
	Bench.put(metrics, "refresh", refresh)
	Bench.put(metrics, "cursor", cursor)
	metrics.blobs_minted_by_cursor = h.p.minted - mintedBeforeCursor
	for k, v in sizes do
		metrics[k] = v
	end
	assert(hm.s ~= nil, "the measured block stays alive until here")
	return { { name = name, metrics = metrics, phases = { first_paint = phasesFirst, refresh = phasesRefresh } } }
end

return M
