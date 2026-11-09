--!strict
-- Timing, memory and phase-attribution helpers for the benchmark scenarios
-- (tests/bench/run.luau). Standalone luau has os.clock (CPU seconds, high
-- resolution) and collectgarbage("count"|"collect") only: no allocation
-- counter and no debug hooks. So:
-- - times are os.clock deltas per iteration, after warmup, as median and p95;
-- - "heap delta" is collectgarbage("count") after minus before one iteration
--   without a collection in between: a lower bound of what it allocated (an
--   incremental GC step inside the iteration frees some of it);
-- - "retained" is the heap after a full collection, so it counts only what
--   stays reachable (state, caches);
-- - phases come from wrapping module functions (`probe`) and are reported
--   inclusive (with callees) and self (without wrapped callees). Wrapping is
--   off while iterations are timed and on during one separate attribution
--   pass, so probes never distort the medians.

local M = {}

export type Stats = { n: number, median: number, p95: number, min: number, max: number, mean: number }

function M.stats(samples: { number }): Stats
	local sorted = table.clone(samples)
	table.sort(sorted)
	local n = #sorted
	if n == 0 then
		return { n = 0, median = 0, p95 = 0, min = 0, max = 0, mean = 0 }
	end
	local sum = 0
	for _, v in sorted do
		sum += v
	end
	local mid = if n % 2 == 1 then sorted[(n + 1) // 2] else (sorted[n // 2] + sorted[n // 2 + 1]) / 2
	return {
		n = n,
		median = mid,
		p95 = sorted[math.clamp(math.ceil(n * 0.95), 1, n)],
		min = sorted[1],
		max = sorted[n],
		mean = sum / n,
	}
end

-- The tern type definitions and selene's std omit collectgarbage("collect"),
-- which standalone luau has.
-- selene: allow(global_usage)
local gc = (_G :: any).collectgarbage :: (what: string) -> number

function M.heapKb(): number
	return gc("count")
end

-- Heap in KiB after a full collection (two passes: finalizers and weak
-- tables can free more on the second).
function M.liveKb(): number
	gc("collect")
	gc("collect")
	return gc("count")
end

-- Live heap held by what `make()` returns, as the median over `n` fresh
-- builds. The test JSON codec tags decoded arrays in a weak-keyed table
-- whose hash part grows and shrinks with GC timing, so one measurement can
-- be off by a power-of-two block (8 MiB seen); the median is stable.
function M.retainedKb(n: number, make: () -> any): number
	local samples: { number } = {}
	for i = 1, n do
		local base = M.liveKb()
		local kept = make()
		samples[i] = M.liveKb() - base
		assert(kept ~= nil, "retainedKb: make() must return what it keeps")
	end
	return M.stats(samples).median
end

-- JSON decoding stands apart: machines get it through Env, and in Tern it is
-- tern.json (native), while here it is the Luau test codec (tests/lib/json),
-- which is far slower. Every sample also reports its time without decoding.
local decodeSeconds = 0

function M.countDecode(decode: (string) -> any): (string) -> any
	return function(text: string): any
		local t0 = os.clock()
		local v = decode(text)
		decodeSeconds += os.clock() - t0
		return v
	end
end

export type Sample = { ms: { number }, nodecode_ms: { number }, heap_kb: { number } }

-- Runs `body(setup())` warmup + iters times; only `body` is timed.
function M.sample<T>(warmup: number, iters: number, setup: () -> T, body: (T) -> ()): Sample
	local out: Sample = { ms = {}, nodecode_ms = {}, heap_kb = {} }
	for i = 1, warmup + iters do
		local ctx = setup()
		local h0 = gc("count")
		local d0 = decodeSeconds
		local t0 = os.clock()
		body(ctx)
		local t1 = os.clock()
		local h1 = gc("count")
		if i > warmup then
			table.insert(out.ms, (t1 - t0) * 1000)
			table.insert(out.nodecode_ms, (t1 - t0 - (decodeSeconds - d0)) * 1000)
			table.insert(out.heap_kb, math.max(0, h1 - h0))
		end
	end
	return out
end

-- Adds `<name>_ms`, `<name>_nodecode_ms` and `<name>_heap_kb` for a sample.
function M.put(into: { [string]: any }, name: string, s: Sample)
	into[name .. "_ms"] = M.stats(s.ms)
	into[name .. "_nodecode_ms"] = M.stats(s.nodecode_ms)
	into[name .. "_heap_kb"] = M.stats(s.heap_kb)
end

-- Phase probes -----------------------------------------------------------------------------

type Bucket = { calls: number, incl: number, self: number }

local enabled = false
local buckets: { [string]: Bucket } = {}
local order: { string } = {}
-- Per active wrapped call: time spent in wrapped callees.
local childStack: { number } = {}
local wrapped: { [any]: { [string]: boolean } } = {}

local function bucket(label: string): Bucket
	local b = buckets[label]
	if b == nil then
		b = { calls = 0, incl = 0, self = 0 }
		buckets[label] = b
		table.insert(order, label)
	end
	return b
end

-- Times calls to `fn` under `label` while probes are enabled.
function M.timed<A..., R...>(label: string, fn: (A...) -> R...): (A...) -> R...
	bucket(label)
	return function(...: A...): R...
		if not enabled then
			return fn(...)
		end
		local depth = #childStack + 1
		childStack[depth] = 0
		local t0 = os.clock()
		local r = table.pack(fn(...))
		local dt = os.clock() - t0
		local children = childStack[depth]
		childStack[depth] = nil
		local b = buckets[label]
		b.calls += 1
		b.incl += dt
		b.self += dt - children
		if depth > 1 then
			childStack[depth - 1] += dt
		end
		return table.unpack(r :: any, 1, r.n)
	end
end

-- Replaces module[name] with a timed wrapper (once per module and name).
-- Callers must look the function up on the module at call time, or be
-- required after this runs; a module that captured it in a local earlier is
-- not attributed (its time lands in the caller's self time).
function M.probe(module: any, name: string, label: string)
	local seen = wrapped[module]
	if seen == nil then
		seen = {}
		wrapped[module] = seen
	end
	if seen[name] then
		return
	end
	local fn = module[name]
	assert(type(fn) == "function", "probe: no function " .. name .. " for " .. label)
	module[name] = M.timed(label, fn)
	seen[name] = true
end

export type Phase = { label: string, calls: number, incl_ms: number, self_ms: number }

-- Runs `fn` once with probes on and returns the phases it hit, by self time.
function M.attribute(fn: () -> ()): { Phase }
	for _, b in buckets do
		b.calls, b.incl, b.self = 0, 0, 0
	end
	enabled = true
	local ok, err = pcall(fn :: any)
	enabled = false
	table.clear(childStack)
	if not ok then
		error(err, 0)
	end
	local out: { Phase } = {}
	for _, label in order do
		local b = buckets[label]
		if b.calls > 0 then
			table.insert(out, { label = label, calls = b.calls, incl_ms = b.incl * 1000, self_ms = b.self * 1000 })
		end
	end
	table.sort(out, function(a, b)
		return a.self_ms > b.self_ms
	end)
	return out
end

-- View accounting ---------------------------------------------------------------------------

export type AssetStats = { count: number, bytes: number, max: number, svg: number, png: number }

function M.assets(assets: any): AssetStats
	local s: AssetStats = { count = 0, bytes = 0, max = 0, svg = 0, png = 0 }
	for _, a in assets or {} do
		local n = #a.bytes
		s.count += 1
		s.bytes += n
		s.max = math.max(s.max, n)
		if string.find(a.mime, "svg", 1, true) then
			s.svg += 1
		else
			s.png += 1
		end
	end
	return s
end

-- Number of nodes in a view tree (what Tern diffs and the runner serializes).
function M.nodes(node: any): number
	if type(node) ~= "table" then
		return 0
	end
	local n = if node.k ~= nil then 1 else 0
	local c = node.c
	if type(c) == "table" then
		for _, child in c do
			n += M.nodes(child)
		end
	end
	return n
end

return M
