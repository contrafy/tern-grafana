--!strict
-- Logs block tailing a busy stream: direct Loki, logs.limit 5000 (the
-- largest allowed), the first answer 5000 lines (one every 100 ms), then
-- tail polls every 2 s that answer the overlap window plus the new lines,
-- as Loki does (tail.luau asks from just before the newest line shown).
-- One poll = the tail tick, the poll answer and a paint.

local Bench = require("../lib/bench")
local Options = require("../../../plugin/lib/logs/options")
local Paint = require("../lib/paint")
local Probes = require("../lib/probes")
local Q = require("../../unit/query/support")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/logs/state")
local Synth = require("../lib/synth")
local Tail = require("../../../plugin/lib/logs/tail")
local Validate = require("../../../plugin/lib/config/validate")
local View = require("../../../plugin/lib/logs/view")
local json = require("../../lib/json")

local EVERY_MS = 100
local LINES = Options.MAX_LIMIT

local CONFIG = (function(): any
	local cfg = Validate.validate(json.decode([[{
		"version": 1,
		"default_context": "lab",
		"contexts": {"lab": {"loki": {"url": "http://localhost:3100"}}},
		"logs": {"limit": ]] .. LINES .. [[}
	}]]))
	return assert(cfg, "bench logs config must validate")
end)()

type Harness = { s: any, env: any, p: Paint.Painter, polls: number }

local function paint(h: Harness)
	local view, assets = View.view(h.s, h.env)
	Paint.paint(h.p, view, assets)
end

local function ok(body: string): any
	return { status = 200, headers = {}, body = body, timed_out = false }
end

local VOLUME = require("../../lib/fixtures").read("loki/3.7.8/query_range_matrix.json")

local function deliver(h: Harness, effects: { any }, bodyFor: (any) -> string?)
	for _, e in effects do
		if e.kind ~= "http" then
			continue
		end
		local body = bodyFor(e)
		if body then
			State.update(h.s, { kind = "http_done", tag = e.tag, response = ok(body) }, h.env)
			paint(h)
		end
	end
end

local FIRST = Synth.lokiStreams(Q.NOW_MS - (LINES - 1) * EVERY_MS, Q.NOW_MS, EVERY_MS)

local function open(): Harness
	local env = Q.env(CONFIG)
	env.decode = Probes.decoder(env.decode)
	local link =
		Scheme.encode({ action = "logs", params = { expr = '{job="synthetic"}', from = "now-15m" }, vars = {} })
	local s, effects = State.init({ link }, nil, env)
	local h: Harness = { s = s, env = env, p = Paint.new(), polls = 0 }
	paint(h)
	deliver(h, effects, function(e: any): string?
		if string.sub(e.tag, 1, #State.QUERY_TAG) == State.QUERY_TAG then
			return FIRST
		elseif string.sub(e.tag, 1, #State.VOLUME_TAG) == State.VOLUME_TAG then
			return VOLUME
		end
		return nil
	end)
	return h
end

local function startTail(h: Harness)
	local _, effects = State.key(h.s, Q.key("t", "t"), h.env)
	paint(h)
	h.polls = 0
	-- The first poll goes out with the key; answer it like the others.
	deliver(h, effects, function(e: any): string?
		if string.sub(e.tag, 1, #State.POLL_TAG) == State.POLL_TAG then
			return Synth.lokiStreams(Q.NOW_MS - Tail.overlapMs(h.s.options.tail_ms), Q.NOW_MS, EVERY_MS)
		end
		return nil
	end)
end

-- The answer to the poll that follows poll `n`.
local function pollBody(h: Harness, n: number): string
	local tailMs = h.s.options.tail_ms
	local newest = Q.NOW_MS + n * tailMs
	return Synth.lokiStreams(newest - tailMs - Tail.overlapMs(tailMs), newest, EVERY_MS)
end

local function poll(h: Harness, body: string)
	h.polls += 1
	h.env.now_ms = Q.NOW_MS + h.polls * h.s.options.tail_ms
	local _, effects = State.update(h.s, { kind = "tick", tag = State.TAIL_TAG .. h.s.tail_gen }, h.env)
	deliver(h, effects, function(e: any): string?
		return if string.sub(e.tag, 1, #State.POLL_TAG) == State.POLL_TAG then body else nil
	end)
end

local M = {}

function M.run(opts: any): { any }
	local name = "logs/tail-5000"
	if not opts.match(name) then
		return {}
	end
	open()
	local first = Bench.sample(opts.warmup, opts.iters, function()
		return nil
	end, function()
		open()
	end)
	local h = open()
	local sizes: { [string]: any } = {}
	Paint.metrics(h.p, sizes)
	startTail(h)
	local bodies: { string } = {}
	for n = 1, opts.warmup + opts.iters + 1 do
		bodies[n] = pollBody(h, n)
	end
	local added0 = h.s.tail_added
	local polls = Bench.sample(opts.warmup, opts.iters, function()
		return bodies[h.polls + 1]
	end, function(body: string)
		poll(h, body)
	end)
	local addedPerPoll = (h.s.tail_added - added0) / (opts.warmup + opts.iters)

	-- Steady state: growth between poll 300 and poll 600. The heap rises
	-- for the first ~200 polls while the first answer's lines are replaced
	-- by polled ones (measured flat from there to poll 600), so earlier
	-- windows show turnover, not a leak.
	local base = Bench.liveKb()
	local hm = open()
	startTail(hm)
	for n = 1, 300 do
		poll(hm, pollBody(hm, n))
	end
	local afterOne = Bench.liveKb()
	local rounds = 301
	for n = 301, 600 do
		poll(hm, pollBody(hm, n))
	end
	local afterMany = Bench.liveKb()

	local phasesFirst = Bench.attribute(function()
		open()
	end)
	local phasesPoll = Bench.attribute(function()
		poll(h, pollBody(h, h.polls + 1))
	end)
	local metrics: { [string]: any } = {
		lines_kept = #h.s.lines,
		lines_added_per_poll = addedPerPoll,
		first_answer_bytes = #FIRST,
		retained_growth_kb_per_poll = (afterMany - afterOne) / (rounds - 1),
		retained_kb_after_600_polls = afterMany - base,
	}
	Bench.put(metrics, "first_paint", first)
	Bench.put(metrics, "tail_poll", polls)
	for k, v in sizes do
		metrics[k] = v
	end
	assert(hm.s ~= nil, "the measured block stays alive until here")
	return { { name = name, metrics = metrics, phases = { first_paint = phasesFirst, tail_poll = phasesPoll } } }
end

return M
