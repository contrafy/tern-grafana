# Logs block

The Logs block (`tern-grafana.logs`) runs LogQL against one context's logs: Loki directly, or Grafana's Loki
datasource through `/api/ds/query` (see [configuration.md](configuration.md#routing)). Log lines are native text
rows, newest first, with the level as a colored tag; volume bars over the lines count lines per level; a polling
tail follows new lines; a line's detail lists its labels, structured metadata and parsed fields as chips that add
or remove a filter in the query.

## Opening it

- **Link:** `tern-grafana://logs?...` opens the block on that query. Parameters:

  | Parameter | Meaning |
  | --- | --- |
  | `context` | Context name. Default: `default_context`, else the first context by name. |
  | `expr` | The LogQL query. Without it the block opens in the input. |
  | `from`, `to` | Grafana times (`now-1h`, `now`, epoch seconds or milliseconds, ISO dates). Default: `logs.default_range` to `now`. |
  | `ds` | A Grafana datasource uid. When set and the context has Grafana, the query goes to that datasource even if the context also has a direct Loki endpoint. |

  Example: `tern-grafana://logs?context=lab&expr=%7Bjob%3D%22loggen%22%7D&from=now-15m`
- **Grafana Explore URL:** an Explore link under a configured Grafana base URL whose datasource is the context's
  Loki datasource (`grafana.datasources.loki`) opens the same query here.

Links never carry credentials.

## Layout

- **Header:** context, range, `tail 2s` while tailing (click to stop), the number of lines (`(limit)` when the
  query hit `logs.limit`, `N new` lines received by the tail), a spinner while a request runs, and the number of
  warnings.
- **Input:** the LogQL query. While you type, suggestions for what the caret is in: label names inside `{...}`,
  label values inside a matcher's quotes (or right after `=`, `!=`, `=~`, `!~`), and parser and formatting stages
  after `|` (`json`, `logfmt`, `pattern`, `regexp`, `line_format`, ...). Label lists come from Loki's
  `/loki/api/v1/labels` and `/loki/api/v1/label/<name>/values` (through Grafana's datasource proxy for Grafana
  contexts), over the block's range, cached per context for 5 minutes (30 seconds after an error).
- **Volume:** bars counting lines per bucket (about 60 buckets over the range; hover a bar for its time and
  per-level counts), from the metric query
  `sum by (level, detected_level) (count_over_time(<query> [<bucket>]))`. Under it, one chip per level present in
  the lines with its count; clicking a chip filters the query to that level (again removes the filter).
- **Lines:** time (with milliseconds), level, the stream labels that differ between the lines shown (labels shared
  by every line are left out), and the line. The left edge is colored by level: critical accent, error red,
  warning yellow, info green, debug and trace gray-blue, unknown muted.
- **Detail** (enter, or click a line): the whole line wrapped, then its chips in three groups:
  - **Labels:** the stream (indexed) labels;
  - **Structured metadata:** for example Loki's `detected_level`;
  - **Parsed fields:** labels a parser stage (`| json`, `| logfmt`, ...) extracted.

  Clicking a chip (or `f`) filters for that value, its `-` chip (or `x`) filters it out; clicking again removes
  the filter, and the opposite chip flips it. A stream label goes into the stream selector
  (`{app="checkout", env!="dev"}`); structured metadata and parsed fields become a label filter stage at the end
  (`| logfmt | detected_level = "info"`), which is where those labels exist. The query runs again after each
  change.
- **Metric queries** (anything that does not start with a `{...}` selector, such as
  `sum by (level) (count_over_time({job="api"}[1m]))`) show a chart instead of lines.

Levels are read as Grafana does: Loki's `detected_level`, else a `level` label, else the first level word in the
line (`error`, `warn`, `info`, ...).

Direct Loki queries ask for categorized labels (`X-Loki-Response-Encoding-Flags: categorize-labels`, Loki 3), so
stream labels, structured metadata and parsed fields stay apart as they do through Grafana. A server that does not
categorize returns every label as a stream label; filtering on a parsed one then needs editing the query by hand.

## Tail

`t` turns the tail on: the range becomes live (an absolute range keeps its span and ends at `now`), and every
`logs.tail_interval` the block asks Loki for the lines since a little before the newest line shown (twice the
interval, at least 5 seconds), so lines ingested late are not missed. Each line is identified by its nanosecond
timestamp and a hash of its stream labels and text: lines received again by an overlapping poll are shown once,
while two streams logging the same text in the same instant both show. New lines appear on top; the selected line
stays selected; past `logs.limit` lines the oldest drop. The volume bars refresh at most every 10 seconds while
tailing. Changing the range to an absolute one stops the tail.

## Keys

In the input:

| Key | Action |
| --- | --- |
| enter | Run the query (or accept the highlighted suggestion) |
| tab | Accept the highlighted (or first) suggestion |
| up, down | Move through suggestions |
| ctrl+space | Show suggestions |
| esc | Leave the input |

Elsewhere:

| Key | Action |
| --- | --- |
| `/`, `i` | Edit the query |
| `j`, `k`, up, down | Select a line (pageup, pagedown: 20 lines) |
| `g`, `G`, home, end | First or last line |
| enter, space | Open or close the selected line's detail |
| left, right | Select a chip in the open detail |
| `f`, `x` | Filter for / filter out the selected chip |
| `t` | Tail on or off |
| `v` | Volume bars on or off |
| `[`, `]` | Shift the range back or forward by half its span |
| `-`, `+` | Zoom out or in |
| `1` .. `9` | Last 5m, 15m, 1h, 3h, 6h, 12h, 24h, 2d, 7d |
| `r` | Run again |
| `c` | Next context |
| `y` | Copy the selected line (the query when no line is selected) |
| `o` | Open the query in Grafana Explore (needs `grafana.datasources.loki`) |
| `?` | Help |
| `q`, esc | Close (esc closes the detail first) |

## Configuration

Defaults for the Logs block, in the `logs` section of the config file:

```json
"logs": {
  "default_range": "now-1h",
  "limit": 500,
  "tail_interval": "2s",
  "volume": true
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `default_range` | string | `"now-1h"` | Start of the range for a query opened without one (the end is `now`). Any Grafana time. |
| `limit` | number | `500` | Most lines a query returns and the tail keeps, a whole number from 1 to 5000. |
| `tail_interval` | string | `"2s"` | Tail polling interval, a duration from `1s` to `1m`. |
| `volume` | boolean | `true` | Show the volume bars when the block opens (`v` toggles them; the choice is saved with the block). |

Unknown keys and bad values in this section are reported in the block as warnings; a bad value falls back to its
default instead of breaking the block.

## Saved state

The block saves the link of what it shows (context, query, range, datasource) and the volume toggle. It never
saves log lines; the tail is off after a restore.
