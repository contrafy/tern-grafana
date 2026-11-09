--!strict
-- Window entry load cost: the modules plugin/window.luau requires at load
-- (the set scripts/check-window-load.sh budgets) and, for scale, every
-- shipped module (what the host half and lazy requires compile over a
-- session). Bytes and module counts are exact; `compile_ms` is loadstring
-- (parse + bytecode compile, no execution) of every module per iteration
-- under this luau. Tern additionally JIT-compiles, so its load time is
-- higher (docs/architecture.md: about 0.11 ms per KiB).
--
-- Sources come from tests/bench/out/sources.luau, written by
-- tests/bench/bench.sh; without it the scenario is skipped.

local Bench = require("../lib/bench")

type Sources = { window: { string }, files: { [string]: string } }

local function compile(paths: { string }, files: { [string]: string })
	for _, path in paths do
		local fn, err = loadstring(files[path], "=" .. path)
		assert(fn, err)
	end
end

local M = {}

function M.run(opts: any): { any }
	local name = "window/load"
	if not opts.match(name) then
		return {}
	end
	local ok, loaded = pcall(require :: any, "../out/sources")
	if not ok then
		print("\n## window/load skipped: tests/bench/out/sources.luau missing (run `make bench`)")
		return {}
	end
	local sources = loaded :: Sources
	local all: { string } = {}
	for path in sources.files do
		table.insert(all, path)
	end
	table.sort(all)
	local function bytes(paths: { string }): number
		local n = 0
		for _, p in paths do
			n += #sources.files[p]
		end
		return n
	end
	local entry = Bench.sample(opts.warmup, opts.iters, function()
		return nil
	end, function()
		compile(sources.window, sources.files)
	end)
	local whole = Bench.sample(opts.warmup, math.max(3, opts.iters // 2), function()
		return nil
	end, function()
		compile(all, sources.files)
	end)
	return {
		{
			name = name,
			metrics = {
				window_entry_modules = #sources.window,
				window_entry_bytes = bytes(sources.window),
				window_entry_compile_ms = Bench.stats(entry.ms),
				plugin_modules = #all,
				plugin_bytes = bytes(all),
				plugin_compile_ms = Bench.stats(whole.ms),
			},
		},
	}
end

return M
