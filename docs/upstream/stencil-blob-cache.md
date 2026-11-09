# Draft issue for Stencil: the blob cache is only trimmed when the daemon starts

Status: draft, not filed. Written from tern-grafana's measurements (docs/performance.md); contains no private data.
Paste everything below the line.

---

**Title:** Plugin blobs are never evicted while the daemon runs; no way for a block to release a blob

## Summary

Every distinct image a plugin block sends with `cx:blob(bytes, mime)` becomes a file in
`~/Library/Caches/Tern/blobs/<sha256>`. Tern 0.9.13 trims that directory to 1 GiB, least recently used first, but
only when the daemon starts (as the Limits page says: "Blobs kept on disk: 1 GiB; the least recently shown go when the
daemon starts"). While the daemon runs nothing is removed: not when an image is replaced, not when the block closes,
not when the cache is already over 1 GiB. A plugin that redraws charts on a timer (a dashboard with auto-refresh)
therefore grows the cache for as long as the daemon lives, which on a laptop can be weeks. The plugin cannot release
a blob, cannot read the cache size, and must not touch the directory itself.

## Environment

- Tern 0.9.13 (8c6dfbd), macOS 27 (arm64), Apple M5. Same growth first seen on Tern 0.7.0 and 0.8.3 (no eviction
  at all on those).
- A plugin block that shows SVG charts in `image` nodes (`{k = "image", p = {blob = id}}`) and replaces them when its
  data changes.
- Tern run with an isolated `HOME`, so the cache directory starts empty and only this test writes to it.

## Steps to reproduce

1. Start Tern with an isolated `HOME` (the cache is `$HOME/Library/Caches/Tern/blobs`).
2. In a plugin block, every second build an SVG of about 100 KB whose text includes a counter, call
   `cx:blob(svg, "image/svg+xml")`, put the id in an `image` node and `cx:render()`.
3. Count files and bytes in the cache every 10 seconds for a few minutes; close the block; count again.
4. Quit Tern (window and daemon) and start it again; count again.

To see the cap in step 3 without waiting hours, fill the cache to just over 1 GiB first (step 1b below).

1b. With Tern stopped, write 1100 files of 1 MiB random bytes into the cache, each named by the SHA-256 of its bytes,
    with modification times spread over the last 30 days. Start Tern and count.

Expected: the cache stays bounded while Tern runs (or a block can release images it no longer shows), and closing a
block releases what only it showed.

Actual: the cap is applied at daemon start only; in between, every new image is a new file kept until the next start.

## Measurements (Tern 0.9.13)

Cap at daemon start (step 1b):

| | files | bytes |
| --- | --- | --- |
| Before start (1100 prefilled + 3 real blobs) | 1103 | 1,153,958,596 |
| After start | 1026 | 1,073,218,244 (under 1 GiB = 1,073,741,824) |
| Removed | the 77 oldest by modification time | |

No eviction while running (steps 2 and 3, starting from the capped cache above):

| | files | bytes |
| --- | --- | --- |
| Block start | 1026 | 1,073,218,244 |
| After 100 s (100 images of 100 KB) | 1126 | 1,083,234,336 (10 MB over the cap) |
| Removed in any 10 s sample | 0 | |
| Block closed | 1126 | unchanged |
| Tern quit and started again | 1116 | 1,072,748,576 (the 10 oldest removed) |

A real workload: two Grafana dashboards with 30 s auto-refresh (one in a background tab) and a query chart, sampled
every 60 s for 11 minutes, after the plugin already skips unchanged images and pauses background tabs: 12 new files
per minute (about 720 per hour), 0 removed. The same layout on Tern 0.8.3 before those plugin mitigations: 59 files
(3.1 MB) per minute, about 185 MB per hour. A single chart refreshing every 10 s through Prometheus's API adds
6 files per minute regardless, because each answer ends at the current time and is a new picture.

## Why the plugin cannot fix this

- Blob ids are content hashes, so identical bytes already share a file; the plugin reuses ids for unchanged images
  and does not redraw unchanged data. What remains is genuinely new pictures.
- There is no API to release a blob, to replace one in place, or to read the cache size (`BlockCx` has only
  `blob(bytes, mime)`; tern-sdk `plugins/tern.d.luau` at 0479f70).
- Deleting files from the plugin would race the window, which may still be showing them, and the cache is shared by
  every plugin and pane.

## Proposals (any one would do)

1. **Apply the existing cap while running.** Run the same least-recently-shown trim when a write takes the cache over
   1 GiB (or on a timer), never removing an id a mounted surface references.
2. **Explicit release.** `cx:free_blob(id)` (or `cx:blob(bytes, mime, {replaces = old_id})`) lets a block say that an
   image is no longer needed; Tern deletes the file once no surface shows it.
3. **Reference-counted lifetime.** A blob sent by a block (pane) and no longer referenced by any surface node of that
   pane, after a render that dropped it or when the block closes, may be deleted, optionally after a grace period.
4. **Per-plugin quota.** A smaller cap per plugin id so one plugin's redraws cannot push out other plugins' and Tern's
   own images.

Also helpful: document blob lifetime and the 1 GiB start-up trim next to `BlockCx:blob` in `tern.d.luau` (the Limits
page is the only place that mentions it).
