# Compatibility report

The Compatibility block ("Grafana: Compatibility" in the palette) scans every dashboard of a context and shows
which rung of the [ladder](dashboards.md#how-panels-are-shown-the-ladder) each panel would take in the Dashboard
block (native, Grafana PNG or browser) and why, with the causes counted across the whole stack. Use it to see how
much of a Grafana instance Tern draws natively and what keeps the rest on the ladder.

It needs a context with a `grafana` endpoint (see [configuration.md](configuration.md)). The scan only reads
(`GET` requests with the context's credentials): it never changes anything in Grafana.

## What it does

1. Reads Grafana's frontend settings (`/api/frontend/settings`: the image renderer and the datasources your
   Grafana user can query) and lists the dashboards (`/api/search?type=dash-db`, 1000 per page) up to
   `compat.max_dashboards`.
2. Loads the dashboards four at a time (`/api/dashboards/uid/<uid>`), with their library panels
   (`/api/library-elements/<uid>`, each element once per scan however many dashboards use it).
3. Decides every panel with the Dashboard block's own code: the same legacy-panel migration, panel registry
   checks, datasource resolution and renderer availability, so a panel's rung and reason here are the ones the
   Dashboard block shows on it.

Differences from an open Dashboard block, by design:

- Panels in collapsed rows are included (the Dashboard block decides them when the row is expanded).
- A repeated panel, and the panels of a repeated row, count once: the first copy, with the first repeat value
  in scope, marked "repeats by $var".
- Query variables are not fetched; their saved selection is used. Datasource variables are resolved from the
  frontend settings as in the Dashboard block. A panel whose datasource comes from a query variable may
  therefore be judged on the saved value rather than on the current options.
- Each panel shows the first reason it is not native. A panel can have more than one (two unsupported
  transformations, say); the second shows once the first is fixed.

A block opened from the palette scans right away. A block Tern restores after a restart waits for `r`, so a
large stack is not rescanned on every start.

## The view

- The header names the context (click another to scan it), Grafana's version and whether it has an image
  renderer (with one, non-native panels get a Grafana PNG; without, they open in the browser).
- The progress line counts dashboards listed, loaded and loading; when the scan stopped at the cap it says so.
- The totals: panels and dashboards, native / Grafana PNG / browser with percentages, and dashboards that could
  not be loaded (shown with the reason on their row).
- "Not native, by reason": every cause with the number of panels and dashboards it affects and the panel types
  involved, most panels first. Names that vary (a datasource uid, a variable) are generalized, so
  `datasource ${ds} is not resolved` and `datasource $cluster is not resolved` count as one cause.
- Every dashboard with its non-native panels (all panels with `n`): rung, title, type, reason, and where the
  panel sits (row, collapsed row, repeat, library panel).

## Keys

| Key | Action |
| --- | --- |
| up/down, `j`/`k`, home/end, page up/down | move the selection |
| `enter` or click | open the selected dashboard, or the selected panel as its own Panel block |
| `d` | open the selected row's dashboard (a panel row's panel expanded) |
| `/` | filter by dashboard title, folder or uid, or panel title, type, rung, reason or row; `enter` applies, `escape` clears |
| `n` | show or hide native panels |
| `m` | copy the whole report as Markdown |
| `r` | rescan |
| `c` / `C` | next / previous context with a Grafana endpoint |

The list shows at most 600 rows; filter to narrow it. The Markdown report (`m`, or "Copy as Markdown") always
holds everything: the totals, the reason table, the native panel types and one table per dashboard. It contains
dashboard and panel titles and uids, never a URL, token or header.

## Configuration

Optional `compat` section of the config file:

```json
"compat": { "max_dashboards": 500 }
```

| Field | Default | Meaning |
| --- | --- | --- |
| `max_dashboards` | `500` | At most this many dashboards are scanned, in search order (1 to 10000). |
