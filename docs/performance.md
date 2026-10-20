# Performance: Tern's image cache

Charts reach Tern as SVG (or PNG) bytes sent with `cx:blob`; Tern writes every distinct image to
`~/Library/Caches/Tern/blobs/<sha256>` and, as measured below, never removes one during a session, on a plugin
reload, when a block closes or when the window restarts. So every redraw that produces new bytes costs disk for good.
This page records how fast the cache grew in a long session, what the plugin does about it, and what it cannot do
(an upstream issue draft is in [upstream/stencil-blob-cache.md](upstream/stencil-blob-cache.md)). The plugin never
deletes or edits files in Tern's cache.

## How it was measured

- Tern 0.8.3 (e2b8656), macOS arm64, an isolated sandbox (`scripts/dev-tern.sh`; `HOME` points into the sandbox, so
  the blob directory is `<sandbox>/home/Library/Caches/Tern/blobs` and starts empty). The dev stack: Grafana 12,
  Prometheus 3 (`dev/`).
- `scripts/measure-blobs.sh -i 60 -l LABEL DIR` sampled file count, bytes, files added and files removed every
  minute. A measurement-only copy of the package logged every `cx:blob` call (pane, asset key, bytes) to attribute
  blobs to panels; that logging is not part of the plugin.
- Layout: tab 1 shown with a shell, **Tern Panels** (`tern-panels`, 1 h, refresh 30 s: 4 time series, heatmap,
  state timeline, SVG gauge, plus native stats, bar gauge, table, text, logs) and a Query block; tab 2 in the
  background with **Tern All Panels** (`tern-all-panels`, 1 h, refresh 30 s, every core panel type). Dashboards
  refresh at their own 30 s (`dashboard.min_refresh` only sets a floor).
- The Query block (`rate(node_cpu_seconds_total[1m])`, 1 h, step 15 s, 8 series, 31.5 KB per chart, direct
  Prometheus) was measured separately with 10 s auto-refresh (`query.refresh: "10s"`), because auto-refresh is not
  saved and the plugin reload between runs turned it off in the main layout.

## Long session, before and after

24 minutes each, same layout, 60 s samples:

| | Before | After |
| --- | --- | --- |
| Files added | 1418 (107 to 1525) | 283 (1570 to 1853) |
| Bytes added | 74.1 MB | 15.1 MB |
| Per minute | 58.9 files, 3.08 MB | 11.8 files, 0.63 MB |
| Per hour (extrapolated) | about 3,530 files, 185 MB | about 710 files, 38 MB |
| Files removed by Tern in any sample | 0 | 0 |

Per block, blobs per 30 s refresh:

| Block | Before | After |
| --- | --- | --- |
| Tern Panels, shown, 1 h | 10.1 | 6.1 (one per panel whose data changed) |
| Tern All Panels, background tab | 19.3 | 0 |
| Tern All Panels, shown, 1 h (5 min) | 19.3 | 11 |
| Tern Panels, shown, 24 h (step 2 min) | 7.0 (14 files per minute, 4 min) | about 2 (3.8 files per minute, 10 min) |

Query block, 10 s auto-refresh (10 min shown, then 5 min in a background tab):

| | Before | After |
| --- | --- | --- |
| Shown | 6 files, 189 KB per minute (11.3 MB per hour) | 6 files, 189 KB per minute |
| Background tab | same as shown (no visibility check) | 0 files in 5 minutes; refreshed about 1 s after the tab was shown |

The shown Query block does not improve: a direct Prometheus range query ends at the exact current time, so every
answer has new timestamps and is a new picture. Through Grafana, which aligns a range to its step, an answer inside
one step is byte-identical and keeps the drawn chart.

## Blobs per refresh, by panel type

Before the mitigations, per refresh of one panel (Tern All Panels and Tern Panels, 48 refreshes), and bytes per blob:

| Panel type | Blobs per refresh | Bytes per blob |
| --- | --- | --- |
| Time series (7 panels) | 2 | 3.7 to 140 KB, mean 74 KB |
| Graph (legacy, drawn as a time series) | 2 | 107 KB |
| Heatmap (2) | 2 | 45 KB |
| Candlestick | 2 | 16.5 KB |
| Status history | 1.3 | 31 KB |
| State timeline (2) | 1 | 3.1 KB |
| Histogram | 1 | 2.4 KB |
| Gauge, SVG (5) | 1 when its value changed (3 panels), else 0 | 0.7 to 21 KB |
| Pie chart, bar chart, trend, XY chart, flame graph, node graph, geomap, canvas | 0 after the first draw (same bytes, same id) | 0.7 to 27 KB |
| Stat, bar gauge, table, text, logs, clock, alert/annotation/dashboard lists, news | none: native Tern kinds | |

Time-axis panels made two blobs per refresh: the refresh resolved the new range at once, so the panel was redrawn
with its old data on the new axis while the query ran, then again when the answer arrived. After the mitigations a
panel makes one blob per refresh when its data changed and none when it did not (at 24 h the time series, heatmap
and state timeline were redrawn 4 times in 19 refreshes, once per 2-minute step).

## Eviction

Tern never removed a file:

- 0 files removed in every one-minute sample of every run above (about 90 minutes of sampling in total).
- Plugin reload (`tern plugin reload`, restored blocks re-run `init`): 1554 files before, 1570 after (the restored
  dashboards drew once more), none removed.
- All blocks closed: 2257 files (113 MB) when closed and still 2257 two minutes later.
- Window quit and started again (with the blocks closed, so nothing new was drawn): 2257 files before, 2257 a
  minute after the restart.

Earlier (Tern 0.7.0, docs/sdk-capability-matrix.md row "Blob growth"): 200 swaps of one image made 200 files, none
removed five minutes later. Tern also logs `WARN stencil_term: cannot cache surface blob ... No such file or
directory` while images are replaced quickly (234 times in the main session); the display is not affected.

## What the plugin does

- **Same bytes, same blob.** `plugin/blob_host.luau` and `lib/render/blob_cache.luau` reuse a block's blob id for
  unchanged bytes (string comparison per asset key, then an FNV-1a content hash), and dashboard panel views are
  memoized, so a re-render for an unrelated reason (focus move, cursor, spinner, clock tick) sends nothing. Measured
  end to end: the eight static panel types above minted once in 48 refreshes. Blob ids are SHA-256 content hashes,
  so identical bytes from two blocks share one file.
- **Draw data on its own range.** A dashboard panel keeps drawing its data over the range that data was asked for
  until the refreshed answer arrives (`PanelState.drawn`, `lib/dashboard/state.luau`): one blob per refresh instead
  of two.
- **Identical answers are not redrawn.** When a refreshed answer is byte-identical to the last one for the same
  query, the dashboard keeps the parsed data (whose identity keys the view memo) and the Query block keeps its drawn
  chart. Grafana aligns a range query to its step, so this happens whenever the refresh interval is shorter than the
  step (ranges of about 5 h and more at the default 600 points).
- **Quantized time axis.** A panel range ending at now is drawn with its end snapped down to the query interval
  (`lib/render/redraw.luau`, `State.drawRange`), so two refreshes inside one step draw identical bytes even though
  "now" moved; the shift is under one step, a few pixels at most. Absolute ranges are never moved.
- **Background tabs pause.** The window half (`plugin/visibility_window.luau`) writes to kv `visible_panes` which
  panes the active tab shows (tiled leaves, only the focused pane when zoomed, floating blocks), on focus, pane and
  tab events and every 2 s, writing only on change. A dashboard or Query block whose auto-refresh tick finds its pane
  known and not shown skips the refresh (no query, render, PNG render or blob) and looks again every second; it
  refreshes within a second of being shown. The clock panel's per-second redraw pauses too. A pane the record does
  not know (opened since, or in another window) counts as shown.
- **Panels behind the expanded view wait.** With a panel expanded (`enter`), only that panel is refreshed; the
  others refresh when the grid is shown again. Collapsed rows were already never queried.
- **Cursor and hover are overlays.** The keyboard cursor and the hover columns are `image` children, not part of the
  SVG, so moving them sends no new bytes (docs/sdk-capability-matrix.md row "Overlay cursor").

## What it cannot do

- **Off-screen panels inside a shown dashboard.** Tern exposes no scroll or viewport signal for nodes inside a block
  (no event; window `PaneInfo` has only `focused`, `floating` and `parked`; `cx.session:view` is per pane), so panels
  scrolled out of view refresh at the dashboard's rate.
- **A window in the background or minimized.** No signal either; its active tab counts as shown.
- **New data.** A chart whose data changed is a new picture; the remaining growth (about 38 MB per hour for the
  layout above, about 11 MB per hour for one Query block on a 10 s refresh) needs eviction in Tern.

A background block's one-second visibility check is a timer tick and a re-render that hits the view memo; it sends
no request and no blob.

## Reproducing

```sh
export TG_TERN_SANDBOX=/tmp/tg-tern-perf
sh scripts/dev-tern.sh start            # in its own terminal
sh scripts/dev-tern.sh link
# open the dashboards (palette "Grafana: Dashboard"), a Query block with `a`
sh scripts/measure-blobs.sh -i 60 -d 1200 -l run "$TG_TERN_SANDBOX/home/Library/Caches/Tern/blobs"
sh scripts/dev-tern.sh clean
```
