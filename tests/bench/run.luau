--!strict
-- Benchmark runner for the pure core under the pinned standalone luau (see
-- docs/benchmarks.md). Run through `make bench` (tests/bench/bench.sh), which
-- embeds the fixtures and plugin sources first and saves the JSON report:
--
--   .tools/bin/luau --codegen tests/bench/run.luau -a [--iters N] [--warmup N]
--       [--only SUBSTRING]... [--no-phases] [--meta KEY=VALUE]...
--
-- Prints a table per scenario, then one line `BENCH_JSON {...}` with every
-- metric for tests/bench/compare.luau.

local Probes = require("./lib/probes")
local json = require("../lib/json")

local opts = {
	iters = 10,
	warmup = 2,
	only = {} :: { string },
	phases = true,
	meta = {} :: { [string]: string },
	match = function(_name: string): boolean
		return true
	end,
}

local args = { ... }
do
	local i = 1
	while i <= #args do
		local a = args[i]
		if a == "--iters" then
			opts.iters = assert(tonumber(args[i + 1]), "--iters needs a number")
			i += 1
		elseif a == "--warmup" then
			opts.warmup = assert(tonumber(args[i + 1]), "--warmup needs a number")
			i += 1
		elseif a == "--only" then
			table.insert(opts.only, args[i + 1])
			i += 1
		elseif a == "--no-phases" then
			opts.phases = false
		elseif a == "--meta" then
			local k, v = string.match(args[i + 1] or "", "^([^=]+)=(.*)$")
			if k then
				opts.meta[k] = v :: string
			end
			i += 1
		elseif a ~= "" then
			error("run.luau: unknown argument " .. tostring(a), 0)
		end
		i += 1
	end
	opts.match = function(name: string): boolean
		if #opts.only == 0 then
			return true
		end
		for _, o in opts.only do
			if string.find(name, o, 1, true) then
				return true
			end
		end
		return false
	end
end

if opts.phases then
	Probes.install()
end

-- Required after the probes so modules that cache functions at load see them.
local SCENARIOS = {
	"./scenarios/dashboard",
	"./scenarios/query",
	"./scenarios/logs",
	"./scenarios/compat",
	"./scenarios/irm",
	"./scenarios/settings",
	"./scenarios/window",
	"./scenarios/panel_cursor",
}

local function fmt(v: number): string
	if v == math.floor(v) and math.abs(v) < 1e15 then
		return tostring(v)
	elseif math.abs(v) >= 100 then
		return string.format("%.0f", v)
	elseif math.abs(v) >= 1 then
		return string.format("%.2f", v)
	end
	return string.format("%.3f", v)
end

local function pad(s: string, n: number): string
	return s .. string.rep(" ", math.max(1, n - #s))
end

local results: { any } = {}
local t0 = os.clock()
for _, path in SCENARIOS do
	local scenario = (require :: any)(path)
	for _, r in scenario.run(opts) do
		table.insert(results, r)
		print("\n## " .. r.name)
		local keys: { string } = {}
		for k in r.metrics do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, k in keys do
			local v = r.metrics[k]
			if type(v) == "table" then
				print(
					string.format(
						"  %s median %s  p95 %s  min %s  (n=%d)",
						pad(k, 36),
						fmt(v.median),
						fmt(v.p95),
						fmt(v.min),
						v.n
					)
				)
			else
				print(string.format("  %s %s", pad(k, 36), fmt(v)))
			end
		end
		if opts.phases and r.phases then
			local passes: { string } = {}
			for p in r.phases do
				table.insert(passes, p)
			end
			table.sort(passes)
			for _, pass in passes do
				print(string.format("  phases (%s, one attributed pass; self / inclusive ms, calls):", pass))
				for i, ph in r.phases[pass] do
					if i > 12 then
						break
					end
					print(string.format("    %s %9.2f %9.2f %7d", pad(ph.label, 34), ph.self_ms, ph.incl_ms, ph.calls))
				end
			end
		end
	end
end
print(string.format("\nbench: %d scenarios in %.1f s", #results, os.clock() - t0))

local report = { version = 1, meta = opts.meta, iters = opts.iters, warmup = opts.warmup, scenarios = {} }
for _, r in results do
	report.scenarios[r.name] = { metrics = r.metrics, phases = r.phases }
end
print("BENCH_JSON " .. json.encode(report))
