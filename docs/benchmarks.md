# Benchmarks

`make bench` measures the pure core (`plugin/lib/**`) under the pinned standalone `luau`, driving the same code
paths a block runs in Tern with recorded fixtures and synthetic answers. It needs no Tern and no dev stack, so two
runs on one machine are comparable and every performance change can be backed by a before/after pair. It does not
measure Tern itself: blob writes, view diffing, layout and painting happen in Tern and are covered by the long-session
measurements in [performance.md](performance.md).

## Commands

| Command | What it does |
| --- | --- |
| `make bench` | Embeds the fixtures and plugin sources, runs every scenario, prints a table and saves the report as `tests/bench/out/<UTC stamp>.json` and `tests/bench/out/latest.json` (gitignored) |
| `make bench BENCH_ARGS="--only logs --iters 20"` | Runner flags: `--only SUBSTRING` (repeatable), `--iters N` (default 10), `--warmup N` (default 2), `--no-phases` |
| `make bench-compare BASE=tests/bench/out/<stamp>.json [NEW=<report>]` | Every metric of both reports, base -> new with the change; timed metrics (medians) moving more than 10% (`BENCH_THRESHOLD`) and any changed count or byte size are flagged |
| `make bench-profile [BENCH_ARGS=...]` | Runs the scenarios under `luau --profile` (interpreter, 10 kHz sampling) and prints the hottest functions by self and inclusive time; raw samples in `tests/bench/out/profile.out` |

`BENCH_LUAU_FLAGS` sets the luau flags (default `--codegen`, since Tern runs plugins natively compiled; `-O1` is
the interpreter `make test` uses). Compare reports taken with the same flags on the same machine, with the machine
otherwise idle: other load moves medians by 10-50% (seen while other agents ran e2e suites and Docker).

Workflow for a change: `make bench` on the base, keep the report path, change the code, `make bench`, then
`make bench-compare BASE=<base report>`.

## Scenarios

The harness is `tests/bench/` (`run.luau` runner, `scenarios/*.luau`, `lib/bench.luau` statistics and probes,
`lib/synth.luau` synthetic answers, `lib/paint.luau` the host's render step, `compare.luau`, `bench.sh`).

| Scenario | What runs |
| --- | --- |
| `dashboard/tern-all-panels`, `tern-panels`, `tern-sql` | The Dashboard block on the Grafana 12 fixture dashboards: `init`, dashboard, frontend settings and every panel query answered from recorded captures (a panel without its own capture gets the matching generic capture, renamed to its refIds), painted |
| `dashboard/large-60x50x1000` | A synthetic dashboard: 60 time series panels (tern-panels' first panel repeated), each answered with 50 series x 1000 points; fewer iterations (warmup 1, at least 3) |
| `query/now-7d-20x11000` | Query block, direct Prometheus, `now-7d` at `query.max_points` 11000, 20 series (6.7 MB answers) |
| `logs/tail-5000` | Logs block, `logs.limit` 5000, a 5000-line first answer, then tail polls answering the overlap window plus 20 new lines |
| `compat/100-dashboards` | The Compat block's whole scan over 100 dashboards (the five fixture dashboards cycled) |
| `irm/poll` | One IRM status poll from the scrubbed IRM captures, cold (with discovery) and warm |
| `window/load` | Bytes and modules `plugin/window.luau` loads (the set `scripts/check-window-load.sh` budgets) and every shipped module, with `loadstring` compile time |

"Paint" is what `plugin/block_runner.luau` does on a render: the machine's `view`, then every asset through a blob
cache as `plugin/blob_host.luau` does (`lib/render/assets` + `lib/render/blob_cache`), minting counted instead of
sent.

## Metrics

- `*_ms`: median, p95, min and max over the iterations, `os.clock` per iteration after the warmup.
- `*_nodecode_ms`: the same without JSON decoding. Machines decode through `Env.decode`, which in Tern is
  `tern.json` (native) and here is the Luau test codec (`tests/lib/json.luau`), far slower: decoding is 63% of the
  large dashboard's refresh and 87% of the Query block's here. Use the `nodecode` numbers for plugin CPU.
- `*_heap_kb`: heap after minus before one iteration, without a collection in between: a lower bound of what it
  allocated (an incremental GC step can free part of it), noisy.
- `retained_*`: live heap after full collections. `retained_open_kb` is the median over fresh opens (the test
  codec's weak table makes single measurements jump by power-of-two blocks); growth metrics compare steady states
  (dashboard: refresh 1 to 50, Query: medians of refreshes 1-8 and 25-32, logs: poll 300 to 600).
- `answer_bodies_kept_bytes`: raw answers the dashboard keeps for its identical-answer check. In this harness those
  strings are shared with the harness' answer cache, so `retained_open_kb` does not count them; in Tern they are
  retained on top.
- `asset_*`, `svg_assets`, `view_nodes`, `views_per_refresh`, `blobs_minted_*`: what the last paint produced.
- `phases`: one extra pass per scenario with probes on (`lib/probes.luau` wraps module functions; self and
  inclusive ms and calls). Probes are off while iterations are timed.

## Baseline

2026-11-09, commit `356c4d8` (plugin 0.4.0, clean `plugin/`), Apple M5 (10 cores, 24 GB), macOS 27.0.1, luau
`--codegen`, 10 iterations after 2 warmups (large dashboard 3 after 1). Medians; times in ms.

| Scenario | First paint | Refresh, new data | Refresh, same answer | Other |
| --- | --- | --- | --- | --- |
| tern-all-panels (30 queries) | 41.1 (25.9 without decode) | 26.8 (16.5) | 1.12 | painted after each answer: 33.1 (22.8), 32 views |
| tern-panels (12 queries) | 15.2 (6.6) | 8.7 (4.8) | 0.47 | |
| tern-sql (6 queries) | 6.3 (1.3) | 0.95 (0.74) | 0.21 | |
| large, 60 x 50 x 1000 | 2318 (901) | 2237 (819) | 2.30 | painted after each answer: 2319 (910) |
| Query, 7 d, 20 x 11000 | 232 (27.8) | 239 (30.0) | | cursor move 0.014 |
| Logs, 5000 lines | 139 (127) | tail poll 16.8 (16.5) | | |
| Compat, 100 dashboards | scan 70.0 (24.4) | | | one paint at the end: 52.2 (8.8) |
| IRM poll | cold 0.70 (0.048) | warm 0.68 (0.046) | | |

| Scenario | Sizes and memory |
| --- | --- |
| tern-all-panels | 25 SVG assets, 347 KB (largest 72 KB), 708 view nodes; 1.4 MB retained when open, 545 KB raw answers kept; no growth over 50 refreshes |
| tern-panels | 25 SVG assets, 83 KB, 577 nodes; 0.7 MB retained, 179 KB answers kept |
| tern-sql | 6 SVG assets, 12.6 KB, 183 nodes; 151 KB retained |
| large | 60 SVG assets of 229 KB each (13.7 MB; the 240 KiB target caps them), 6325 nodes; 102 MB retained plus 98.5 MB raw answers kept |
| Query | one 115 KB SVG, 42 nodes; 6.8 MB retained; no growth over 32 refreshes |
| Logs | 20014 view nodes for 5000 lines; 18.8 MB live after 600 polls, flat from poll 300 to 600 |
| Compat | 495 nodes, 1.2 MB retained |
| Window | entry 23.3 KB in 9 modules, 0.35 ms compile; all 269 modules 2.59 MB, 70 ms compile |

No scenario grows between refreshes once warm.

### Where the time goes

`make bench-profile` (interpreter) and the phase pass, without the test codec:

- Large dashboard, per refresh with new data: SVG time series rendering 350 ms self (the per-point path writer
  `edge` alone 7% of all samples, plus the per-point `xOfTime`/`yOfValue`/`Axis.position` calls), the blob cache's
  FNV-1a hash of every changed SVG 174 ms (13.7 MB, byte by byte), `Reduce.standard` 96 ms for 3600 calls (all
  20 reducers computed for a two-column legend), Grafana frame conversion 86 ms, LTTB 17 ms.
- Logs tail poll: rebuilding all 5000 rows (20k nodes) is 63% of the poll, per-row timestamp formatting about 10%,
  the full re-sort in `Tail.merge` about 12%, and GC 18%; the host's asset walk visits every node although logs
  have no images.
- Query: after decoding, Prometheus matrix conversion 10 ms and SVG rendering 9 ms of the 28 ms.
- SVG bytes: path data is 90% (8 series x 600 points) to 98% (20 x 11000) of a time series chart. Writing series
  paths with relative coordinates and without trailing `.0` would make them 36-42% smaller (measured on the Query
  scenario's charts); element attributes are under 2%.

## After the performance round

Before: `tests/bench/out/base-phaseB.json` (commit `73f5a6c`, 17:01Z). After: commit `8ea0bd6` plus the uncommitted
time series gradient work, 18:09Z. Same machine and flags as the baseline (Apple M5, luau `--codegen`, 10 iterations
after 2 warmups); CPU otherwise idle, load average about 5 from idle background VMs. Medians in ms, `nodecode` in
parentheses (see Metrics); "same answer" refreshes are sub-millisecond and move with noise.

| Scenario | Metric | Before | After | Change |
| --- | --- | --- | --- | --- |
| tern-all-panels | first paint | 37.6 (23.5) | 30.1 (15.4) | -20% (-35%) |
| | refresh, new data | 23.7 (14.5) | 20.7 (11.2) | -13% (-23%) |
| | painted after each answer | 28.9 (19.5) | 24.9 (15.5) | -14% (-21%) |
| | refresh, same answer | 1.04 | 1.17 | +13% |
| tern-panels | first paint | 13.9 (6.1) | 12.4 (4.6) | -11% (-25%) |
| | refresh, new data | 7.3 (3.9) | 7.0 (3.6) | -4% (-8%) |
| tern-sql | first paint | 5.8 (1.2) | 5.6 (1.1) | -4% |
| | refresh, new data | 0.86 (0.65) | 1.18 (0.96) | +38% (+49%) |
| large, 60 x 50 x 1000 | first paint | 2044 (806) | 1644 (342) | -20% (-58%) |
| | refresh, new data | 2016 (769) | 1591 (305) | -21% (-60%) |
| | painted after each answer | 2114 (831) | 1643 (352) | -22% (-58%) |
| | refresh, same answer | 2.05 | 3.49 | +70% |
| Query, 7 d, 20 x 11000 | refresh | 214 (28.1) | 227 (17.0) | +6% (-40%) |
| | cursor move | 0.014 | 0.015 | |
| Logs, 5000 lines | first paint | 131 (121) | 116 (105) | -11% (-13%) |
| | tail poll | 14.1 (13.8) | 1.65 (1.43) | -88% (-90%) |
| Compat, 100 dashboards | scan | 58.9 (20.1) | 72.4 (33.5) | +23% (+67%) |
| | one paint at the end | 46.9 (6.8) | 63.6 (24.6) | +36% (+263%) |
| IRM poll | cold / warm | 0.65 / 0.64 | 0.65 / 0.91 | warm is noise-level (0.04 -> 0.09 without decode) |

| Scenario | Sizes and memory, before -> after |
| --- | --- |
| tern-all-panels | SVG assets 347 KB -> 261 KB (largest 72 -> 44 KB); retained when open 1.44 -> 1.36 MB |
| tern-panels | 83 -> 66 KB; 719 -> 613 KB retained |
| tern-sql | 12.6 -> 10.5 KB |
| large | 13.7 MB -> 8.2 MB of SVG (229 -> 136 KB per chart) |
| Query | one SVG 115 -> 73 KB; heap per refresh 50.9 -> 41.9 MB |
| Logs | heap per tail poll 18 MB -> 0.7 MB; 19.3 -> 20.5 MB live after 600 polls, still flat from poll 300 to 600 |
| Window | entry 23.4 KB in 9 modules, unchanged; all modules 2.60 -> 2.67 MB (272 -> 286), 68 -> 74 ms compile |

New scenarios (no before): expanded-panel cursor move 0.15 ms against a full 10 x 1000 time series render of
3.1 ms; Settings block 40 list keys 21.7 ms with views (0.04 ms state only), 32 form keys 0.43 ms; Compat over
1000 dashboards 1491 ms (1084 without decode).

The Compat scan is slower than before (reproduced in a second run: 37.8 ms without decode). In `make bench-profile`
the top plugin entries are the `panels/registry` support wrappers (`valuesWhy` and the time series `supports`, both
`require` their module on each call since panel modules load lazily), 9-10% self each, and `compat/analyze`
`summarize`, 10%. Same-answer refreshes are 0.1-1.4 ms slower on every dashboard.
