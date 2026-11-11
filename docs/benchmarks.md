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
| `dashboard/large-60x50x1000` | A synthetic dashboard: 60 time series panels (tern-panels' first panel repeated), each answered with 50 series x 1000 points; fewer iterations (warmup 1, at least 3). The run fails when the open dashboard holds more than 224 MiB (`retained_open_kb` plus `answer_bodies_kept_bytes`, what Tern keeps; the plugin VM's heap is 256 MiB) |
| `query/now-7d-20x11000` | Query block, direct Prometheus, `now-7d` at `query.max_points` 11000, 20 series (6.7 MB answers) |
| `logs/tail-5000` | Logs block, `logs.limit` 5000, a 5000-line first answer, then tail polls answering the overlap window plus 20 new lines |
| `compat/100-dashboards` | The Compat block's whole scan over 100 dashboards (the five fixture dashboards cycled) |
| `irm/poll` | One IRM status poll from the scrubbed IRM captures, cold (with discovery) and warm |
| `window/load` | Bytes and modules `plugin/window.luau` loads (the set `scripts/check-window-load.sh` budgets) and every shipped module, with `loadstring` compile time |
| `dashboard/alert-states-adhoc`, `alert-states-plain` | tern-alert-states (built-in "Annotations & Alerts" layer, a Prometheus layer, a disabled one) with tern-fid2-adhoc's datasource and ad hoc variables (three filters), its three time series repeated to 12 panels of 10 series x 360 points; the built-in layer answers 300 annotations (points, regions, alert state changes), the rules request the recorded rules (panel 2 firing). `plain` is the same dashboard without ad hoc variables and the Prometheus layer, its annotation and rules requests answered empty: the difference is what layers, alert states and filters cost |
| `dashboard/tern-s4-json` | The recorded JSON API dashboard (gauges, stats, a time series grouped by city, a table), every datasource proxy request answered from its capture |
| `panel/timeseries-window-3y` | One time series panel, a 6 h range over 5 series of three years of hourly samples (a query without a time filter): all but a few samples lie outside the range |
| `panel/timezone-table-10k`, `timezone-timeseries-10k` | A table with a 10k-row time column and a time series of 10k samples, a minute apart across the March 2026 DST change, in `utc` and in `America/New_York` (offset looked up per value) |
| `panel/dynamictext-50` | tern-s4-dynamictext panels 1 and 2 (Handlebars, inline HTML styles, markdown) rendered once per row over 50 rows |
| `panel/zabbix-problems-500` | `job`: the Zabbix datasource job for tern-s4-zabbix panel 7 on the recorded API answers; `render`: the Problems panel (table layout) over 500 problems built from the recorded ones |
| `panel/json-api-2000` | tern-s4-json panels 6 (time series grouped by city) and 7 (table): the JSON API datasource job on a 2000-entry forecast document (`job_*`; it parses the document itself with `lib/datasources/jsonpath`, outside `Env.decode`, so `nodecode` includes that parse), then the render |

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

## 0.7.0 against 0.5.0, first round

2026-11-11, Apple M5, luau `--codegen`. Before: `git archive v0.5.0` in a temporary directory with this harness
(unchanged since 0.5.0) and the current fixtures (only additions since 0.5.0), new scenarios skipped where 0.5.0 lacks
the module. After: the 0.7.0 branch at the time (before time series panels drew every series) with the fixes below.
The machine ran other agents' suites throughout (load average 10-35), which moved medians of the same code by
50-300% between runs, so every number here is the minimum over 2 interleaved rounds of each tree (30 iterations, 200
for the timezone panels, 3 for the large dashboard); a regression was only acted on when the minimums reproduced it
and a profile showed the cause. Times in ms.

| Scenario | Metric | 0.5.0 | 0.7.0 branch | Change |
| --- | --- | --- | --- | --- |
| tern-all-panels | first paint / refresh, new data (without decode) | 16.1 / 10.5 | 15.2 / 10.6 | flat |
| tern-panels | refresh, new data (without decode) | 3.31 | 4.29 | +29%: null insertion at gaps (`ts_data.insertNulls`, `nullThreshold`), Grafana parity |
| tern-sql | first paint (without decode) | 1.07 | 1.21 | +13% (more panels drawn natively: 183 -> 225 nodes) |
| large, 60 x 50 x 1000 | refresh, new data (without decode) | 356 | 172 | -52% |
| | painted after each answer (without decode) | 518 | 179 | -65% |
| | retained growth per refresh | -15 KB | -8 KB | was +95,670 KB before the leak fix |
| tern-all-panels | retained growth per refresh | -10 KB | -10 KB | was +238 KB before the leak fix |
| timeseries-window-3y | render | 13.9 | 7.0 | -50% (was +50% before the fix) |
| timezone-table-10k | render, UTC / New York | 0.95 / - | 1.15 / 1.09-1.24 | +25% (was +55%) |
| timezone-timeseries-10k | render, UTC / New York | 0.94-1.19 / - | 0.87-0.94 / 0.87-0.95 | flat; the per-value offset costs nothing measurable |
| Query, 7 d, 20 x 11000 | refresh (without decode) | 18.3 | 21.3 | +17%, within this session's noise |
| panel cursor | cursor move | 0.084 | 0.097-0.12 | +0.02-0.03 ms |

Compat contradicts itself between pairs (100 dashboards +49-73% slower, 1000 dashboards 11% faster), so it reads as
noise here. The Logs tail poll read +73-86% in two 20-iteration pairs taken beside other runs; with 60 iterations
per tree in two interleaved pairs it is 1.66 / 1.69 ms (0.6.0) against 1.48 / 1.60 ms (0.5.0) without decode,
minimums, medians crossing over (3.18 / 3.03 against 2.17 / 3.58), and `make bench-profile` on both trees shows the
same distribution (trace id regex and `logs/view` rows on top; `time/range.formatMs` 0.95% against 0.81% of samples).
No regression: the Logs block's modules did not change since 0.5.0 and nothing on its path got slower.

New paths (no 0.5.0 counterpart):

| Scenario | Metric | 0.7.0 branch |
| --- | --- | --- |
| alert-states-adhoc vs alert-states-plain | first paint without decode | 56 vs 31 (each layer answer redraws the 12 charts its marks change; the profile is SVG rendering, annotation drawing itself is under 1 ms) |
| | refresh, new data without decode | 30 vs 27 |
| | refresh, same answer | 0.90 vs 0.35 |
| tern-s4-json | first paint / refresh without decode | 1.6 / 0.9 |
| dynamictext-50 | panel 1 / panel 2 render | 2.4 / 2.6 |
| zabbix-problems-500 | datasource job / render | 0.76 / 0.77 |
| json-api-2000 | datasource job, panel 6 / 7 | 12-15 (17-22 before the parser fix) |

### Fixes in this round

Output is unchanged in each case (specs pass; equivalence checked over the formats and instants listed).

- Memory leak, `panels/timeseries` (fixed by its owner on this report): the inserted-nulls cache is weak-keyed by the
  time column, but when nothing was inserted its entry stored that same column, and Luau weak tables are not
  ephemerons (verified: entries whose value references the key survive collection). Every time column ever rendered
  stayed live with its value columns: +95.7 MB per refresh on the large dashboard, +238 KB on tern-all-panels; now
  -8 and -10 KB (flat).
- Windowed time series, `render/ts_data` + `render/svg_timeseries` (fixed by their owner): the window cut defeated
  `ownValues`' fast path, so every render hashed all source samples (26k per series) and rescanned their order.
  `Data.window` now reports the order it checked and the fast path covers cuts of untransformed series: 13.9 ms
  (0.5.0) -> 14-15 ms (0.6.0) -> 7.0 ms.
- Date units, `panels/fielddisplay` and `panels/clock_format`: 0.6.0 formats table and stat times through moment
  patterns (`ClockFormat.format`) per value and, for every value, formatted the value and `now` again to decide
  "today" even for units without a today pattern. The today check now runs only for units that have one and keeps
  the current day per `now` and zone; formats made only of numeric tokens and literals (Grafana's date units)
  compile once to a single `string.format`. 10k ISO times: 14 -> 4 ms (`--codegen`), 88 -> 8 ms (interpreter);
  table render 1.46 -> 1.15 ms.
- JSON API documents, `datasources/jsonpath`: the order-keeping JSON parser dispatches on bytes, returns strings
  without escapes by one `string.sub`, skips whitespace without a pattern call when there is none, and allocates
  the JavaScript key reordering only for objects with array-index keys. 570 KB pretty-printed document:
  17 -> 9.5 ms.
- `panels/charts` `sortByTime`: one read per sample in the already-sorted check.

Left as is: the table panel is still +25% over 0.5.0 after these fixes (content-sized columns, pagination and data
links, all new behavior); tern-panels' +1 ms is Grafana's null insertion at gaps.

## 0.7.0 against 0.5.0

2026-11-11, 19:11-19:20Z, Apple M5, luau `--codegen`, load average 5-10. 0.5.0: `git archive v0.5.0` in a temporary
directory with this harness and fixtures, scenarios whose module 0.5.0 lacks skipped. 0.7.0: the release candidate
with the fixes below. Two interleaved rounds of each tree at the default iterations; every number is the lower of the
two medians, in ms without decode unless noted. A 0.5.0 report taken earlier the same day under heavy load read
40-80% slower for code that did not change, so only same-session pairs are compared here.

| Scenario | Metric | 0.5.0 | 0.7.0 | Change | Why |
| --- | --- | --- | --- | --- | --- |
| large, 60 x 50 x 1000 | refresh, new data | 298 | 505 | +70% | 0.7.0 draws all 50 series of each panel, 0.5.0 drew 10 (below) |
| | first paint | 321 | 562 | +75% | as above |
| | refresh, same answer | 1.58 | 3.03 | +1.5 ms | the host's asset walk visits 4.4 times the view nodes |
| | retained when open | 96-101 MB | 103-108 MB | +7 MB | the 50-row legends; the raw answers kept (94 MiB) are the same |
| | view nodes | 6325 | 27928 | +342% | a table legend row is 9 nodes, 50 rows per panel |
| tern-s4-json | first paint / refresh | 0.155 / 0.077 | 1.63 / 0.895 | new work | 0.5.0 drew none of its panels (JSON API datasource unsupported, a request unanswered): 0 SVGs and 43 nodes against 7 and 265 |
| alert-states-adhoc | refresh, same answer (with decode) | 0.326 | 0.807 (2.47) | new work | 0.5.0 has no annotation layers or alert states; 0.7.0 asks for both again on a refresh, as Grafana does, and decodes and parses their answers (300 annotations) |
| alert-states-plain | refresh, same answer | 0.266 | 0.322 | +0.06 ms | |
| IRM poll | cold / warm | 0.044 / 0.043 | 0.044 / 0.042 | flat | the IRM modules did not change; a +33% in an earlier pair was load |
| tern-all-panels | first paint / refresh | 13.3 / 9.93 | 15.7 / 11.4 | +18% / +15% | |
| tern-panels | refresh | 3.03 | 4.57 | +51% | null insertion at gaps and every series drawn (largest SVG 17.8 -> 38.3 KB) |
| tern-sql | refresh | 0.645 | 0.484 | -25% | |
| timeseries-window-3y | render | 7.29 | 3.63 | -50% | |
| timezone-table-10k | render, UTC | 0.954 | 1.61 | +69% | not investigated in this round (1.15 in the first round) |
| Query, 7 d, 20 x 11000 | refresh | 16.4 | 18.6 | +13% | |
| Logs, 5000 lines | tail poll | 1.43 | 1.41 | flat | |
| Compat, 100 dashboards | scan / one paint | 15.8 / 6.68 | 20.2 / 8.41 | +28% / +26% | not investigated in this round |
| panel cursor | cursor move | 0.074 | 0.108 | +0.03 ms | |
| Window | all modules | 2.67 MB, 66 ms compile | 3.35 MB, 83 ms | +25% | entry unchanged: 23.4 KB in 9 modules |

The large dashboard's refresh cost is drawing five times the series. Answered with 10 series per panel, both trees
draw everything and 0.7.0 is faster: refresh 241-256 ms (0.5.0) against 193-197 ms (0.7.0), two pairs. In
`make bench-profile` (interpreter) the 0.7.0 time series view took 44 s of samples against 17.6 s, and the growth is
per series: the legend reducers 1.4 -> 6.9 s (five times the calls), LTTB 2.0 -> 7.2 s, the y range over the samples
in view 0 -> 4.7 s (0.5.0 read it off the whole series' min and max), Grafana's null insertion 0 -> 3.4 s (the
synthetic series start 7 s after the range, more than the 3.6 s interval, so every series gets a null there and a
copy), the order checks of `sortByTime` and `Data.window` 0.3 -> 2.4 s.

Legends stay complete, as in Grafana: VizLayout renders every row of a bottom legend in a ScrollContainer capped at
35% of the viz, which the `tgp-lgcap-*` classes reproduce. Tern does not tell a plugin a view's scroll position, so a
virtualized legend could not follow the scroll. The 50-row legends cost about 7 MB of the large dashboard's heap and
the 1.5 ms of its same-answer refresh; writing value cells as their div's text would take a table row from 9 nodes to
6, a change to check against Grafana's render first.

### Fixes in this round

- Memory, `panels/timeseries`: the inserted-nulls cache was weak-keyed by time column, and an entry lives as long
  as its column, which the panel's data holds: every series drawn with a null inserted kept a filled copy of its
  times and values, as long as the dashboard was open. The large dashboard held 200 MB (289 MiB with the raw answers
  Tern keeps, over the 256 MiB heap); 0.5.0 held 100 MB. The filled columns are now kept with the render memo of
  the panel (four panels, the expanded one among them), so a cursor move still redraws without inserting again:
  103 MB (195 MiB with the answers). `dashboard/large-60x50x1000` fails over 224 MiB, and a time series spec fails
  when drawing 64 panels keeps more than half their samples' size (0.7.0 before the fix: 2.4 times).
- `render/svg_timeseries` y range of a windowed series and `render/series` calcs: the finite-number check and the
  min/max are inlined (two function calls per sample before). Large dashboard, same session: refresh 579-580 ->
  509-522 ms, first paint 623-659 -> 555-563 ms.
