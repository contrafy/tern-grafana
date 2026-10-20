# Query block

The Query block (`tern-grafana.query`) is a PromQL scratchpad: write a query, see it as a chart or a table, step a
cursor through the samples, and change the range from the keyboard. It reads metrics from one context at a time,
through the context's direct Prometheus-compatible endpoint or through Grafana (see
[configuration.md](configuration.md#routing)).

## Opening it

- **Palette:** the "Grafana: Query" command opens an empty block beside the focused pane on the default context, with the input
  focused.
- **Link:** opening `tern-grafana://query?...` (from a terminal, a note, another block) opens the block on that
  query. Parameters:

  | Parameter | Meaning |
  | --- | --- |
  | `context` | Context name. Default: `default_context`, else the first context by name. |
  | `expr` | The PromQL expression. Without it the block opens in the input. |
  | `from`, `to` | Grafana times (`now-6h`, `now`, epoch seconds or milliseconds, ISO dates). Default: `query.default_range` to `now`. |
  | `mode` | `graph` (range query, default) or `table` (instant query at the end of the range). |
  | `ds` | A Grafana datasource uid. When set and the context has Grafana, the query goes to that datasource even if the context also has a direct endpoint. |

  Example: `tern-grafana://query?context=lab&expr=rate(node_cpu_seconds_total%5B5m%5D)&from=now-6h&to=now`
- **Grafana Explore URL:** clicking an Explore link under a configured Grafana base URL (`/explore?schemaVersion=1&panes=...`)
  whose datasource is the context's Prometheus datasource opens the same query here.

Links never carry credentials; a link with a credential-like parameter is refused.

## Layout

- **Header:** context, range ("Last 1 hour"), the step the query used (or "instant"), the mode, `auto 30s` while
  auto-refresh is on, a spinner while a query runs, and the number of warnings.
- **Input:** the PromQL expression. Under it, while you type, suggestions for what the caret is in:
  - metric names, functions, aggregations and keywords at an expression position;
  - label names inside `{...}` (only the labels of the metric before the braces) and in `by (...)`,
    `without (...)`, `on (...)`, `ignoring (...)`, `group_left (...)`, `group_right (...)`;
  - label values inside a matcher's quotes (`job="...`, `mode=~"...`), escaped for the operator, so a value
    picked for `=~` matches literally;
  - durations and Grafana's `$__rate_interval`, `$__interval`, `$__range` inside `[...]`.

  Lists are fetched from the server the first time they are needed (label names `/api/v1/labels`, values
  `/api/v1/label/<name>/values`, metric help `/api/v1/metadata`, through Grafana's datasource proxy for Grafana
  contexts) and cached per context for 5 minutes (30 seconds after an error).
- **Result:**
  - graph mode: a chart (series beyond the chart limit are counted under the legend) with a legend; with the
    cursor on, the legend shows each series' value at the cursor time;
  - table mode: one row per series with its labels and value;
  - a failed query shows a card with the server's message (for example
    `parse error: unclosed left parenthesis`), and the kind of failure (query error, authentication, network,
    timeout, configuration).
- Server warnings (Prometheus `warnings` and `infos`) and problems in the `query` config section are listed above
  the result.

Grafana's macros work in queries: `$__interval`, `$__interval_ms`, `$__range`, `$__range_s`, `$__range_ms`,
`$__rate_interval` and `$__rate_interval_ms` are expanded before the query is sent, as Grafana computes them for
the range and step.

## Keys

In the input:

| Key | Does |
| --- | --- |
| text, `paste` | Insert at the caret (line breaks become spaces) |
| `left` / `right`, `alt`+`left` / `alt`+`right` | Move by character / word |
| `home` / `end`, `ctrl`+`a` / `ctrl`+`e` | Start / end of the line |
| `backspace`, `delete`, `ctrl`+`w`, `ctrl`+`u`, `ctrl`+`k` | Delete back, forward, word back, to start, to end |
| `up` / `down` | Move through the suggestions |
| `tab` | Accept the selected suggestion (the first when none is selected) |
| `enter` | Accept the suggestion moved to with `up`/`down`; otherwise run the query |
| `ctrl`+`space` | Show suggestions even with nothing typed |
| `escape` | Leave the input (the keys below work again) |

Outside the input:

| Key | Does |
| --- | --- |
| `/`, `i` | Edit the query |
| `g` / `t` | Graph (range query) / table (instant query at the end of the range) |
| `left` / `right` | Move the chart cursor one sample; with `shift`, ten |
| `[` / `]` | Shift the range back / forward by half its span |
| `-` / `+` | Zoom out (twice the span) / in (half the span) |
| `1` .. `9` | Last 5m, 15m, 1h, 3h, 6h, 12h, 24h, 2d, 7d |
| `r` | Run again |
| `a` | Auto-refresh on or off (every `query.refresh`) |
| `c` | Next context (by name) |
| `h` | History: type to filter, `up`/`down`, `enter` runs, `escape` closes |
| `y` | Copy the query |
| `o` | Open the query in Grafana Explore in a Tern browser pane (contexts with Grafana only) |
| `x` | Select the exemplar nearest the cursor; again, the next nearest (graph mode) |
| `enter` | With an exemplar selected: open its trace in the Trace block |
| `L` | Open the Logs block for the series' labels over the same range (see [Jumps to logs and traces](#jumps-to-logs-and-traces)) |
| `S` | Sync the time range and cursor with other synced blocks on or off (see [Shared time](#shared-time)) |
| `?` | Help |
| `q`, `escape` | Close the block (`escape` first closes help or history, or drops the exemplar selection) |

Zooming a "last N" range keeps it ending at now (`now-1h` becomes `now-2h` or `now-30m`), so auto-refresh keeps
following the present; zooming any other range, and every shift, gives absolute times, as in Grafana.

## Exemplars

A range query also asks for exemplars (with `query.exemplars` on, the default): `/api/v1/query_exemplars` over the
same range for a direct endpoint, or `exemplar: true` in Grafana's `/api/ds/query` (Prometheus datasources). They are
drawn as small diamonds (class `tg-exemplar`) in the chart at their time and value, part of the same SVG; at most
200 are drawn, thinned evenly over time, and the header counts them ("120 exemplars", plus how many were not drawn).
A Prometheus without exemplar storage simply returns none; a failed exemplar request is listed as a warning and the
chart still shows.

`x` selects the exemplar nearest the cursor (the end of the range without a cursor) and moves the cursor onto it;
pressing `x` again walks outwards to the next nearest. Under the legend the block shows the exemplar's time, value,
trace id and other labels. `enter` opens `tern-grafana://trace?context=<context>&id=<trace id>` when the exemplar has
a trace id in `query.exemplar_trace_label` (when set) or `trace_id`, `traceID` or `traceId`; the Trace block reads it
from the context's Tempo. Moving the cursor or `escape` drops the selection.

## Jumps to logs and traces

`L` opens `tern-grafana://logs?context=<context>&expr=<selector>&from=<from>&to=<to>`: a LogQL stream selector built
from the labels every series on screen shares (with an exemplar selected, the labels of the exemplar and its
series), kept to `logs.correlate_labels` in that list's order (default `job`, `namespace`, `pod`, `container`,
`service`, `service_name`, `app`, `instance`; see [logs.md](logs.md)). For example
`rate(node_cpu_seconds_total[1m])` on one node opens `{job="node",instance="node-exporter:9100"}`. When the series
share none of those labels the block says so instead of opening an unfiltered query.

## Shared time

`S` turns time sync on for the block (off by default; a `synced` badge shows in the header, and the setting is saved).
Synced blocks (Query, Dashboard and Panel, Logs, Trace search) share one range and cursor through kv key
`tern-grafana.time.shared` (`{from, to, cursor_ms, origin, seq}`: Grafana range strings, the cursor time, the
writing block and a sequence number; nothing else):

- a range change (quick ranges, `[`/`]`, `-`/`+`) and a cursor move publish;
- every 2 seconds, while synced, the block reads the record and adopts a newer one written by another block: a new
  range re-runs the query, a cursor only moves the overlay (no new chart);
- a block ignores its own writes and records older than the newest it has seen;
- turning sync on adopts the range other synced blocks share, or publishes this block's own when none does.

## Config keys

In the `query` section of the config file:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `query.default_range` | string | `"now-1h"` | Start of the range for a query opened without one (the end is `now`). Any Grafana time. |
| `query.max_points` | number | `600` | Points per series a range query asks for, 10 to 11000. The step is Grafana's: range / max points, rounded, at least 15s. Tern blocks report a fixed 80-column size, so this is not derived from the pane. |
| `query.refresh` | string | `"30s"` | Auto-refresh interval used by `a`, at least `5s`. Auto-refresh is off when a block opens, pauses while the block's tab is in the background (it runs within a second of the tab being shown), and keeps the drawn chart when an answer is byte-identical to the last ([performance.md](performance.md)). |
| `query.exemplars` | boolean | `true` | Fetch and draw exemplars with range queries, in the Query block and in dashboard time series panels. |
| `query.exemplar_trace_label` | string | none | Exemplar label holding the trace id, tried before `trace_id`, `traceID` and `traceId`. |

A bad value is reported as a warning in the block and its default is used.

## History and saved state

Each run from the input or the history picker records the expression in kv key `tern-grafana.query.history`: the
last 100 distinct expressions per context, newest first, shared by all Query blocks. No results are stored.

A block saves only its link (context, expression, range, mode, datasource), the cursor time and whether time sync is
on, so it reopens on the same query after a restart and runs it again. Results, exemplars, tokens and credentials are
never saved.
