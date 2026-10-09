# Query block

The Query block (`tern-grafana.query`) is a PromQL scratchpad: write a query, see it as a chart or a table, step a
cursor through the samples, and change the range from the keyboard. It reads metrics from one context at a time,
through the context's direct Prometheus-compatible endpoint or through Grafana (see
[configuration.md](configuration.md#routing)).

## Opening it

- **Palette:** the "Tern Grafana Query" block entry opens an empty block on the default context, with the input
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
| `?` | Help |
| `q`, `escape` | Close the block (`escape` first closes help or history) |

Zooming a "last N" range keeps it ending at now (`now-1h` becomes `now-2h` or `now-30m`), so auto-refresh keeps
following the present; zooming any other range, and every shift, gives absolute times, as in Grafana.

## Config keys

In the `query` section of the config file:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `query.default_range` | string | `"now-1h"` | Start of the range for a query opened without one (the end is `now`). Any Grafana time. |
| `query.max_points` | number | `600` | Points per series a range query asks for, 10 to 11000. The step is Grafana's: range / max points, rounded, at least 15s. Tern blocks report a fixed 80-column size, so this is not derived from the pane. |
| `query.refresh` | string | `"30s"` | Auto-refresh interval used by `a`, at least `5s`. Auto-refresh is off when a block opens. |

A bad value is reported as a warning in the block and its default is used.

## History and saved state

Each run from the input or the history picker records the expression in kv key `tern-grafana.query.history`: the
last 100 distinct expressions per context, newest first, shared by all Query blocks. No results are stored.

A block saves only its link (context, expression, range, mode, datasource) and the cursor time, so it reopens on
the same query after a restart and runs it again. Results, tokens and credentials are never saved.
