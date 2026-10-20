# Draft issue for Stencil: plugin blobs are never evicted from Tern's blob cache

Status: draft, not filed. Written from tern-grafana's measurements (docs/performance.md); contains no private data.

## Summary

Every distinct image a plugin block sends with `cx:blob(bytes, mime)` becomes a file in
`~/Library/Caches/Tern/blobs/<sha256>`, and Tern never removes those files: not while the block lives, not when the
image is replaced, not when the block closes, not on a plugin reload and not on a window restart. A plugin that
redraws a chart on a timer (a dashboard with auto-refresh) grows the cache without bound. The plugin cannot free a
blob, cannot ask how large the cache is, and must not touch the directory itself.

## Environment

- Tern 0.8.3 (e2b8656) on macOS 27 (arm64); first seen on Tern 0.7.0 (200 swaps of one image: 200 files, none
  removed five minutes later).
- A plugin block that shows SVG charts in `image` nodes (`{k = "image", p = {blob = id}}`) and replaces them when its
  data changes.

## Steps to reproduce

1. Run Tern with an isolated `HOME` so the cache starts empty (`TERN_BLOB_DIR` is not honored as an input).
2. In a block, every 10 seconds build a small SVG whose text includes the current time, call
   `cx:blob(svg, "image/svg+xml")`, put the id in an `image` node and `cx:render()`.
3. Count files and bytes in `$HOME/Library/Caches/Tern/blobs` every minute for 20 minutes; close the block; reload
   the plugin (`tern plugin reload`); quit and restart Tern; count again.

Expected: the cache holds roughly the images on screen (or is bounded by size/age), and closing the block or
restarting releases what is no longer shown.

Actual: the count grows by one file per call with new bytes (6 per minute here) and nothing is ever removed.

## Measurements (Tern 0.8.3)

Two Grafana dashboards with 30 s auto-refresh (one in a background tab) in one window, sampled every 60 s for
24 minutes, before the plugin reduced what it sends:

| | files | bytes |
| --- | --- | --- |
| Start | 107 | 4.5 MB |
| After 24 min | 1525 | 78.6 MB |
| Rate | 58-59 per minute (about 3,500 per hour) | 3.1 MB per minute (about 185 MB per hour) |
| Files removed in any sample | 0 | |
| Plugin reload | +16 files, 0 removed | |
| All blocks closed, 2 minutes later | 2257 before, 2257 after | 113 MB kept |
| Window quit and restarted | 2257 before, 2257 a minute later | |

A single chart refreshing every 10 s (31.5 KB per image) adds 6 files and 189 KB per minute, about 11 MB per hour.
After the plugin's own mitigations (skip redraws of unchanged data, pause background tabs) the same session still
grows by about 38 MB per hour, because a chart whose data changed is a new image by definition.

The window also logs `WARN stencil_term: cannot cache surface blob path=.../blobs/<sha> error=No such file or
directory` while images are replaced quickly (234 times in the session above); the display is not affected.

## Why the plugin cannot fix this

- Blob ids are content hashes, so identical bytes already share a file; the plugin reuses ids for unchanged images
  and no longer redraws unchanged data. What remains is genuinely new pictures.
- There is no API to release a blob, to replace one in place, or to read the cache size.
- Deleting files in the cache from the plugin would race the window, which may still be showing them.

## Proposals (any one would do)

1. **Reference-counted lifetime.** A blob is owned by the block (pane) that sent it. When no live surface node of
   that pane references the id any more (after a render that dropped it, or when the block closes), the file may
   be deleted, optionally after a grace period for undo or quick back-and-forth.
2. **Explicit release.** `cx:free_blob(id)` (or `cx:blob(bytes, mime, {replaces = old_id})`) lets a block say that
   an image is no longer needed; Tern deletes the file once no surface shows it.
3. **Bounded cache.** An LRU over the blob directory with a size cap (for example 256 MB) and an age limit, never
   evicting an id that a mounted surface references; evict on startup too, so a restart cleans up after a crash.
4. **Session-scoped blobs.** A per-session or per-window blob directory removed when the session ends, with
   persistent blobs as an opt-in for restored blocks.

Also helpful: document blob lifetime next to `BlockCx:blob` in `tern.d.luau`, and honor `TERN_BLOB_DIR` as an input
so tests can isolate the cache without overriding `HOME`.
