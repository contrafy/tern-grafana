# Dashboards

The Dashboard block shows a Grafana dashboard inside Tern: its rows and panels laid out as in Grafana, its
variables with a picker, its time range and auto-refresh. The Panel block shows one panel of a dashboard on its
own. Both need a context with a `grafana` endpoint (see [configuration.md](configuration.md)).

## Opening a dashboard

- **Palette:** run the "Tern Grafana Dashboard" block. Without a dashboard it opens a search picker over the
  dashboards your Grafana user can see (`/api/search`); type to filter, `enter` opens the highlighted one.
  Inside an open dashboard, `/` opens the same picker.
- **Grafana links:** clicking a Grafana URL under a configured Grafana base URL (`url`, or `browser_url` when set),
  in terminal output or anywhere Tern routes links, opens it natively:
  - `/d/<uid>/<slug>?from=...&to=...&var-x=...` opens the Dashboard block with that range and those variable
    values; `viewPanel=<id>` (or Grafana 11+ `viewPanel=panel-<id>`) opens it with that panel expanded.
  - `/d-solo/<uid>/<slug>?panelId=<id>` opens the Panel block.
  - Grafana pages Tern has no native view for open in a Tern browser pane.
- **Plugin links:** `tern-grafana://dashboard?context=<ctx>&uid=<uid>[&from=&to=][&panel=<id>][&var-<name>=<value>...]`
  and `tern-grafana://panel?context=<ctx>&uid=<uid>&panel=<id>[...]`. A variable may repeat (`var-job=a&var-job=b`);
  `var-job=$__all` selects All. Links never carry credentials.

The block remembers its dashboard, range, variables and expanded panel across Tern restarts.

## Keys

| Key | Dashboard block | Panel block |
| --- | --- | --- |
| arrows | move focus to the panel in that direction | left/right move the cursor |
| `tab`, `shift+tab` | next / previous panel in reading order | |
| `enter` | expand the focused panel (again or `escape` to go back) | |
| left/right while expanded | move the keyboard cursor; the legend shows values at it (`shift` moves 10 points) | same |
| `1` ... `9` | last 5m, 15m, 1h, 3h, 6h, 12h, 24h, 2d, 7d | same |
| `[` `]` | shift the range back / forward by half its span | same |
| `-` `+` | zoom out / in | same |
| `0` | the dashboard's own range | same |
| `r` | refresh now | same |
| `a` | pause / resume auto-refresh | same |
| `v` | variable picker | |
| `/` | open another dashboard | |
| `o` | open the focused panel's solo page in a browser pane | open the panel in a browser pane |
| `O` | open the dashboard in a browser pane | same |
| `y` | copy the Grafana URL of what is shown | same |
| `l` | show or hide labels on the focused logs panel (starts from the panel's own "Unique labels" setting) | same, for a logs panel |
| `p` | pin the focused panel as its own Panel block | |
| `c` / `C` | collapse the focused panel's row / expand every row | |

Moving the focus scrolls the focused panel into view; the mouse wheel scrolls the dashboard. In the grid each panel
is cut at its Grafana height (a long logs panel or legend shows its first lines); expand it with `enter` to see all
of it. Clicking a panel focuses it, double-clicking expands it, clicking a row header collapses or expands the row, and
clicking a variable chip opens its picker.

## Variables

Variables appear as chips under the title (hidden ones and constants are not shown). In a picker, typing filters
the values; for a multi-value variable `space` or a click toggles a value and `enter` applies the selection
(`escape` applies it too). Text panels interpolate variables into their content. Picking a value re-runs only the variables that depend on it and the panels whose
queries change.

| Type | Supported |
| --- | --- |
| Query (Prometheus) | `label_values(metric_or_selector, label)`, `label_values(label)`, `label_names()`, `metrics(regex)`, `query_result(expr)`; the variable's regex (a capture group or named groups `text`/`value` pick the value, as in Grafana), sort modes, multi-value, include All with or without a custom all value, refresh on load or on time range change |
| Custom | comma-separated values, `\,` for a literal comma, `text : value` pairs |
| Constant | used in queries, not shown |
| Interval | the listed values and `auto` (computed from the range with the variable's step count and minimum) |
| Datasource | the datasources of that type your Grafana user can query, filtered by the regex |
| Textbox | type a value and press `enter` |

Variables are resolved in dependency order: a variable that references another (`label_values(up{job=~"$job"},
instance)`, a query on datasource `${ds}`) waits for it and is refreshed when it changes. Query variables of other
datasource types (Loki, Tempo, SQL, ...) and ad hoc filters show as not supported, and panels referencing them keep
the reference as written.

Interpolation follows Grafana: `$x`, `${x}`, `${x:format}` and `[[x]]` with the formats `regex`, `pipe`, `csv`,
`json`, `glob`, `raw`, `text`, `queryparam`, `singlequote`, `doublequote`, `sqlstring`, `lucene` and
`percentencode`. Without a format, Prometheus and Loki queries get the datasource's own escaping (multi-value and
include-All variables become an escaped regex alternation). Built-ins: `$__interval`, `$__interval_ms`, `$__range`,
`$__range_s`, `$__range_ms`, `$__from`/`$__to` (with `:date`, `:date:iso`, `:date:seconds`), `$__dashboard`,
`${__dashboard.uid}`, `$__org`, `${__user.login}`; `$__rate_interval` is computed by Grafana itself, which knows the datasource's scrape interval.

Repeated panels and rows are laid out as Grafana does: one copy per selected value, `maxPerRow` copies per line
(default 4), and each copy queries its own value.

## How panels are shown: the ladder

Each panel takes the first rung that works and says why it is not on a higher one:

1. **Native.** Tern draws the panel itself when its type and options are supported (time series, stat, gauge,
   bar gauge, table, text, logs) and every visible query runs on a Prometheus or Loki datasource. Queries go to
   Grafana's `/api/ds/query`, one request per panel, so they run with your Grafana user's permissions.
2. **Grafana render.** Otherwise, if your Grafana has the image renderer (`rendererAvailable` in Grafana's
   frontend settings), Tern shows a PNG Grafana renders for the panel. A render takes a few seconds, so the panel
   shows "Rendering in Grafana..." first and keeps the previous picture during refreshes; renders are cached per
   panel, range, size and variable values. Panels are rendered one at a time, and when the renderer answers that it
   is busy (HTTP 429 or 503) Tern waits and tries again (5 s, doubling up to 1 min).
3. **Browser.** Otherwise the panel shows the reason and an "Open in browser" action (`o`), which opens Grafana's
   solo panel page in a Tern browser pane with your own Grafana login.

Typical reasons:

| Reason | Meaning |
| --- | --- |
| `<type> panels are not rendered natively yet` | heatmap, state-timeline, traces, node graph and other panel types |
| `<type> queries are not run natively` | a target on a Tempo, SQL, CloudWatch or other non-Prometheus/Loki datasource |
| `reuses another panel's query (-- Dashboard --)` | the panel shows another panel's results |
| `datasource ${x} is not resolved` | the panel's datasource variable has no value |
| `library panel could not be loaded` | the library element is missing or not readable |
| `Grafana has no image renderer` | appended when rung 2 is not available either |

Panels in collapsed rows are not queried until the row is expanded.

## Refresh and time range

The range starts at the dashboard's own (`time` in its JSON) unless the link names one. Auto-refresh follows the
dashboard's `refresh` interval but never runs more often than `dashboard.min_refresh` (default 30 s); `a` pauses it.
A refresh re-runs every panel query and re-renders PNG panels. Times are shown and computed in UTC.

## Configuration

Optional `dashboard` section of the config file:

```json
"dashboard": { "max_points": 600, "min_refresh": "30s", "render_theme": "dark" }
```

| Field | Default | Meaning |
| --- | --- | --- |
| `max_points` | `600` | maxDataPoints for panels that set none (Tern blocks have no pane width to derive it from). 10 to 11000. |
| `min_refresh` | `"30s"` | Shortest auto-refresh interval, as a duration (`"1m"`) or seconds. |
| `render_theme` | `"dark"` | Theme of panels rendered by Grafana's image renderer: `"dark"` or `"light"`. |
