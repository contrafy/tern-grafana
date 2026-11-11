# Draft issue for Stencil: the blob cache is only trimmed when the daemon starts

Status: draft, not filed. Written from tern-grafana's measurements (docs/performance.md); contains no private data.
Paste everything below the line.

---

**Title:** Plugin blobs are never evicted while the daemon runs; no way for a block to release a blob

**Tern version:** 0.9.16 (41a10a5). Also seen on 0.9.13 (8c6dfbd), and on 0.7.0 and 0.8.3, which never evicted at all.

## Summary

Every distinct image a plugin block sends with `cx:blob(bytes, mime)` becomes a file in
`~/Library/Caches/Tern/blobs/<sha256>`. Tern trims that directory to 1 GiB, least recently used first, but only
when the daemon starts. While the daemon runs nothing is removed: not when an image is replaced, not when the block
closes, not when the cache is already over 1 GiB. A plugin that redraws charts on a timer (a dashboard with
auto-refresh) therefore grows the cache for as long as the daemon lives, which on a laptop can be weeks. The plugin
cannot release a blob, cannot read the cache size, and must not touch the directory itself.

The 1 GiB start-up trim was described on the Limits page in 0.9.13 ("Blobs kept on disk: 1 GiB; the least recently
shown go when the daemon starts"); the 0.9.16 Limits page no longer mentions blobs at all, and the `image` element
page only says an id keeps working "while Tern's blob cache keeps the bytes". The behavior is unchanged.

## Environment

- Tern 0.9.16 (41a10a5), macOS 27 (arm64), Apple M5.
- A plugin block that shows SVG charts in `image` nodes (`{k = "image", p = {blob = id}}`) and replaces them when its
  data changes.
- Tern run with an isolated `HOME` (and `CFFIXED_USER_HOME`), so the cache directory belongs to this test only.

## Steps to reproduce

1. With Tern stopped, fill the isolated cache to just over 1 GiB: 1100 files of 1 MiB random bytes, each named by
   the SHA-256 of its bytes, modification times spread over the last 30 days.
2. Start Tern; count files and bytes in `$HOME/Library/Caches/Tern/blobs`.
3. In a plugin block, every second build an SVG of about 100 KB whose content includes a counter, call
   `cx:blob(svg, "image/svg+xml")`, put the id in an `image` node and `cx:render()`. Count every 10 seconds for
   100 seconds.
4. Close the block; count again after a minute.
5. Quit Tern (window and daemon) and start it again; count again.

Expected: the cache stays bounded while Tern runs (or a block can release images it no longer shows), and closing a
block releases what only it showed.

Actual: the cap is applied at daemon start only; in between, every new image is a new file kept until the next
start.

## Measurements (Tern 0.9.16)

| Step | files | bytes |
| --- | --- | --- |
| 1. Prefilled (1100 + 14 real blobs) | 1114 | 1,153,961,123 |
| 2. After daemon start | 1037 | 1,073,220,771 (under 1 GiB = 1,073,741,824; the 77 oldest removed) |
| 3. Block adding a 100 KB image per second, after 92 s | 1128 | 1,082,323,219 (10 to 11 files added per 10 s sample) |
| 3. Files removed in any 10 s sample | 0 | |
| 4. Block closed, 60 s later | 1132 | 1,082,723,327 (unchanged since the close) |
| 5. Quit and start again | 1123 | 1,073,286,143 (the 9 oldest removed) |

A real workload (tern-grafana: one dashboard with 30 s auto-refresh and a query chart shown, a second dashboard in a
background tab), after the plugin already skips unchanged images and pauses background tabs, on Tern 0.9.16: 15 new
files (0.47 MB) per minute in every one-minute sample for 5 minutes, 0 removed, and 0 in 3 minutes with every block
behind another tab. The same layout on Tern 0.8.3 before those plugin mitigations: 59 files (3.1 MB) per minute, about
185 MB per hour. A single chart refreshing every 10 s through Prometheus's API adds 6 files per minute regardless,
because each answer ends at the current time and is a new picture.

## What the plugin does today

- Reuses a blob id when the bytes did not change (ids are content hashes, so identical bytes share one file), and
  memoizes views so re-renders for unrelated reasons send nothing.
- Does not redraw a chart whose answer is byte-identical, snaps a "now"-ending time axis to the query step, and
  draws a refreshing panel once per refresh instead of twice.
- Pauses refreshes of blocks in background tabs (from window focus/pane events written to kv), because there is no
  visibility signal for a block.
- Draws the keyboard cursor and hover targets as `image` overlay children, so moving them sends no new bytes.
- Keeps SVGs small (relative path data, LTTB downsampling under the 256 KiB SVG cap).

What remains is genuinely new pictures, and those can only be reclaimed by Tern.

## Why the plugin cannot fix this

- There is no API to release a blob, to replace one in place, or to read the cache size (`BlockCx` has only
  `blob(bytes, mime)`; tern-sdk `plugins/tern.d.luau` at ba85dce, the typings `tern plugin types` writes on 0.9.16).
- Deleting files from the plugin would race the window, which may still be showing them, and the cache is shared by
  every plugin and pane.

## Proposed API (any one would do)

1. **Apply the existing cap while running.** Run the same least-recently-shown trim when a write takes the cache over
   1 GiB (or on a timer), never removing an id a mounted surface references. No plugin API change.
2. **Explicit release.** `cx:free_blob(id)`, or `cx:blob(bytes, mime, {replaces = old_id})`, lets a block say an image
   is no longer needed; Tern deletes the file once no surface shows it.
3. **Reference-counted lifetime.** A blob sent by a block and no longer referenced by any surface node of that pane,
   after a render that dropped it or when the block closes, may be deleted, optionally after a grace period.
4. **Per-plugin quota.** A smaller cap per plugin id so one plugin's redraws cannot push out other plugins' and Tern's
   own images.

Also helpful: document blob lifetime and the start-up trim next to `BlockCx:blob` in `tern.d.luau` and restore it on
the Limits page.

## Impact

- Disk: a dashboard user with auto-refresh writes about 900 files (28 MB) per hour for one shown dashboard and a query chart
  even after every client-side mitigation; a long-lived daemon accumulates this without bound until restart.
- Any plugin that animates or refreshes images (charts, previews, status pictures) has the same problem, and the
  1 GiB start-up cap then evicts other plugins' and Tern's own images first.
- Plugins are pushed to cut refresh rates or fidelity to save disk, which is a product trade-off Tern could make
  unnecessary.
