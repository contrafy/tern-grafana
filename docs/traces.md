# Traces

The trace block shows one Tempo trace as a waterfall and searches traces with TraceQL. Open it with a link:

- `tern-grafana://trace?context=lab&id=82c9f1c2bda850d878e52762cc0816` opens that trace. `span=<16 hex>` also
  selects that span and opens its detail.
- `tern-grafana://trace?context=lab&q=%7Bstatus%3Derror%7D&from=now-6h&to=now` opens the Search tab on that query
  and range. Without `id` the block opens on Search and runs `q` (default `{}`, every trace).

Trace ids are up to 32 hex digits; leading zeros may be dropped (`82c9f1...` and `0082c9f1...` are the same trace).
`context` defaults to `default_context`.

## Where the data comes from

The block follows the `traces` routing in [configuration.md](configuration.md):

| Context has | Trace by id | TraceQL search | Tag suggestions |
|---|---|---|---|
| `tempo` endpoint | `GET /api/traces/<id>` | `GET /api/search?q=&limit=&start=&end=` | `GET /api/v2/search/tags`, `/api/v2/search/tag/<tag>/values` |
| `grafana` with `datasources.tempo` | `POST /api/ds/query` (`queryType: traceId`) | `POST /api/ds/query` (`queryType: traceql`, `tableType: traces`) | the same Tempo paths through `/api/datasources/proxy/uid/<uid>` |

Grafana 11.6's Tempo plugin answers every TraceQL search through `/api/ds/query` with HTTP 500 ("An error occurred
within the plugin") while the datasource proxy works. When `/api/ds/query` fails with a 5xx for a trace or a
search, the block repeats that read once through the datasource proxy (`/api/datasources/proxy/uid/<uid>/api/...`),
says so in a note, and keeps using the proxy for that kind of request until the context changes. Grafana 12 also
wraps Tempo's 400 for an invalid TraceQL query in an HTTP 500 ("failed to execute search query status: 400 Bad
Request"); the proxy retry then shows Tempo's own parse error. A 4xx from `/api/ds/query` (a missing trace) is shown
as is.

Supported: Tempo 2.x directly, or through Grafana 11 and 12. Traces arrive as OTLP JSON from Tempo (base64 or hex
ids, nanosecond times as decimal strings, `scopeSpans` or the older `instrumentationLibrarySpans`) or as Grafana's
Trace data frame; both read the same.

## Trace tab

- A summary: root service and operation, duration, span, service and error counts, start time (UTC), trace id.
- A legend with one color per service (span count, error count).
- The waterfall: one row per span with its service and name indented by depth, its duration, and a bar placed at
  its offset and width as fractions of the trace. Error spans are red with an outlined bar. Durations of spans on
  the critical path are bright, the others dim.
- `enter` (or a second click) opens the selected span's detail under its row: service, operation, span id, parent,
  kind, status and message, start offset, duration, self time (time not covered by any child), its own time on the
  critical path, clock-skew shift, instrumentation scope, attributes, events (offset, name, attributes), links (a
  click opens the linked trace in a new block) and resource attributes (folded).

How imperfect traces are shown:

- **Missing parents.** A span whose parent id is not in the trace (not sampled, dropped, or not yet flushed) is
  shown as an extra root marked "parent missing"; the summary counts them.
- **Clock skew.** A child recorded by another service or host that starts before its parent is shifted into the
  parent (centred when it fits, start-aligned otherwise), with its same-clock descendants; the detail shows the
  shift and the summary counts shifted spans. A child that ends after its parent is left alone: that is
  asynchronous work, not skew.
- **Duplicates and cycles.** A repeated span id is dropped (counted); a parent cycle is cut and its spans shown as
  roots.
- **Large traces.** At most 1000 rows are drawn; fold subtrees to reach the rest (a note says how many are hidden).

The critical path follows Jaeger's rule: from the end of the root, repeatedly step into the child that finished
last before the current point; the gaps are the parent's own time.

## Search tab

The TraceQL line (`/` edits, `enter` runs; Tempo's own parse error is shown on a bad query), the range and limit,
and the traces Tempo returned, newest first: start time, root service and operation, duration, spans matched, error
count and the trace id. The error count comes from Tempo's per-service stats, which only the Tempo API answer
carries (direct or through the proxy); Grafana's Traces frame has none. Tempo returns the first `search_limit`
matches it finds, not necessarily the newest. Below the query, chips list the resource and span tags Tempo knows
(plus `name`, `status`, `kind`); clicking one lists its values, and clicking a value adds `<tag> = "<value>"` to the
last selector of the query (or starts `{ ... }`) and searches.

`enter` opens the selected trace in this block's Trace tab; `o` opens it in a new block. Range keys work as in the
Query block. Nothing refreshes on a timer.

## Keys

| Key | Trace tab | Search tab |
|---|---|---|
| `tab` | switch to Search | switch to Trace |
| `j` / `k`, arrows | move | move |
| `g` / `G`, `home` / `end` | first / last | first / last |
| `pageup` / `pagedown` | move 10 | |
| `h` / `left` | fold, or go to the parent | |
| `l` / `right` | unfold, or go to the first child | |
| `space` (double-click) | fold or unfold | |
| `enter` (click) | span detail | open the trace here |
| `o` | | open the trace in a new block |
| `e` / `E` | next / previous error span | |
| `p` | parent span | |
| `/` (`i`) | type a trace id | edit the TraceQL query |
| `1`-`9`, `[` `]`, `-` `+` | | range: quick ranges, shift, zoom |
| `y` / `Y` | copy span id / trace id | |
| `r` | reload the trace | search again |
| `c` / `C` | next / previous context | next / previous context |
| `esc` | close the detail | |

## Configuration

Optional `trace` section (see [configuration.md](configuration.md)):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `search_limit` | integer 1-1000 | `20` | Traces one search returns |
| `range` | relative time string | `"now-1h"` | Start of the search range; it ends at `now` |

```json
{ "trace": { "search_limit": 50, "range": "now-6h" } }
```

A bad value falls back to its default and the block shows the problem.

Saved state (the block's restore data) holds the context, tab, trace id, query and range: never span data.
