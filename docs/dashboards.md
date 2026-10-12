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
| `enter` | expand the focused panel (again or `escape` to go back); with an exemplar selected, open its trace | with an exemplar selected, open its trace |
| left/right while expanded | move the keyboard cursor; the legend shows values at it (`shift` moves 10 points) | same |
| `x` while expanded | select the exemplar nearest the cursor of a time series panel; again, the next nearest (`escape` drops it) | same |
| `L` | open the Logs block for the focused panel's series over the same range | same |
| `S` | sync the time range and cursor with other synced blocks on or off | same |
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
   bar gauge, table, text, logs, the clock panel; see [Native panels](#native-panels)) and every visible query
   runs on a Prometheus or Loki datasource. Queries go to Grafana's `/api/ds/query`, one request per panel, so they
   run with your Grafana user's permissions. Legacy Angular `graph` and `singlestat` panels are migrated to time
   series and stat with Grafana's own migration first, as Grafana does when it loads them.
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
| `panel type <type> is not rendered natively` | a panel type Tern does not draw (yet) |
| `graph with xaxis.mode series migrates to barchart...` | a legacy graph Grafana turns into another panel type |
| `<type> queries are not run natively` | a target on a Tempo, SQL, CloudWatch or other non-Prometheus/Loki datasource |
| `reuses another panel's query (-- Dashboard --)` | the panel shows another panel's results |
| `datasource ${x} is not resolved` | the panel's datasource variable has no value |
| `library panel could not be loaded` | the library element is missing or not readable |
| `Grafana has no image renderer` | appended when rung 2 is not available either |

Panels in collapsed rows are not queried until the row is expanded.

## Native panels

Native panels follow Grafana's own rendering code; the notes below cover what a panel shows when it differs from
the obvious.

- **No data.** A panel whose queries return nothing (or that has no query at all) shows Grafana's no-data text:
  the field defaults' `noValue`, else "No data". Stat, gauge and bar gauge show one placeholder value
  (Grafana's `createNoValuesFieldDisplay`): its text is `noValue`, its color the base threshold step and its
  numeric value 0, never the `noValue` text, so a gauge's bar starts at the minimum (or at the `neutral` value,
  below). A Prometheus target without an expression is not sent, as in Grafana.
- **Gauge.** Grafana 12 with the `newGauge` feature toggle (read from Grafana's frontend settings; on in Grafana
  Cloud) draws the radial gauge: `shape` gauge (a 220 degree arc) or circle, `barWidthFactor`, `barShape`
  rounded, `segmentCount`/`segmentSpacing`, `neutral` (the bar runs between the neutral value and the value,
  clamped to min..max), `endpointMarker` point, `effects.gradient` (the bar shows the threshold colors it passes
  through, one band per step, where Grafana blends them), `showThresholdMarkers` (an outer ring of threshold bands),
  `showThresholdLabels` (min, each step, max and the neutral value around the arc), `sparkline`, `textMode` and the
  text sizes. A gauge saved before the new gauge gets no gradient or sparkline, as Grafana's migration decides.
  Without the toggle (Grafana 11, Grafana 12 default) it is the classic 270 degree gauge with the value in its
  threshold color. Gauges are SVG pictures sized from the panel's grid size; colors follow the Tern theme.
  `effects.barGlow`/`centerGlow` and the `glow` endpoint marker are not drawn.
- **Panel time options.** "Relative time" (`timeFrom`) and "Time shift" (`timeShift`) change the range the
  panel queries, as Grafana's panel time range does (a relative time only applies when the dashboard range is
  relative), and the panel header shows Grafana's info ("Last 1 hour", "timeshift -1h") unless "Hide time info"
  (`hideTimeOverride`) is set. `maxDataPoints` and the minimum `interval` set the query resolution.
- **Metadata.** A panel description shows as an `i` marker (hover shows the text; the expanded panel shows it in
  full), panel links as chips that open in the browser pane (variables and `${__url_time_range}` filled in; a
  path-only link opens on your Grafana), and transparent panels have no card background or border.
- **Panels without queries.** Text and clock panels in input mode never query. Panel types that read Grafana's
  API (dashboard and alert lists, annotations) fetch it from the dashboard's Grafana with your credentials; news
  feeds are fetched from their own URL without credentials.
- **Live panels.** Clocks redraw every second on one shared timer, only while they are shown (not inside a
  collapsed row, and only the expanded panel when one is expanded); a redraw never re-runs a query.

### Clock panels (grafana-clock-panel)

Tern draws `grafana-clock-panel` itself, following the plugin's 2.1.8 behavior, and redraws it every second
(`refresh` "Every second") or only with the dashboard (`refresh` "With the dashboard") without re-running queries.

- **Modes.** Time (24 hour, 12 hour, or a custom moment format), countdown to `endCountdownTime` and countup from
  `beginCountupTime`. The countdown text is the plugin's own, for example
  `2 years, 5 months, 16 days, 4 hours, 15 minutes, 10 seconds`: once a larger unit shows, every smaller one shows,
  and months are moment's average months (30.44 days), not calendar months. A `customFormat` of `auto` or a
  moment-duration-format template (`hh:mm:ss`, `d [days] h [hours]`) formats the same way Grafana does. Past the
  end time the panel shows `endText` (countup before its start: `beginText`).
- **Sources.** An input time (dashboard variables interpolated) or a query: the field named by `queryField`, reduced
  by `queryCalculation` (Last, Last *, First, First *, Min, Max, Min Future, Max Past), with the description from
  the description query field on the same row. A clock only runs its query when the active mode's source is a
  query. `noValueText` and `invalidValueText` show for a missing or unreadable time.
- **Date, timezone and description.** `dateFormat` uses moment's tokens in English (`dateSettings.locale` is
  ignored). Timezones: UTC and GMT names and `Etc/GMT+N` are exact; common IANA zones (the Americas, Europe, Africa,
  Asia, Australia, New Zealand) follow their current offset and daylight saving rule; any other IANA name uses the
  dashboard's offset when it is the dashboard timezone, otherwise your local offset. "Same as dashboard" uses the
  dashboard's timezone; the default (browser time) uses your local offset, and its zone name shows as "Local".
- **Style.** Font sizes (snapped to the nearest of 8 to 256 px), bold, monospace and Grafana's named background
  colors map to classes; `transparent` and an empty background use the panel background.
- **Not native.** The clock panel 3.x `digital` style falls back to the Grafana render or browser rung
  ("the digital clock style (clock panel 3.x) is not rendered natively").

## Refresh and time range

The range starts at the dashboard's own (`time` in its JSON) unless the link names one. Auto-refresh follows the
dashboard's `refresh` interval but never runs more often than `dashboard.min_refresh` (default 30 s); `a` pauses it.
A refresh re-runs every panel query and re-renders PNG panels. Times are shown and computed in UTC.

With `S` the block joins the shared time range (header shows `synced`, saved with the block): range keys publish
the range, cursor moves the cursor, and every 2 seconds the block adopts a newer range or cursor another synced
Query, Dashboard, Panel, Logs or Trace block published; a new range re-runs the panel queries. See
[query.md](query.md#shared-time) for the record and its rules.

## Exemplars and jumps

Time series panels ask their Prometheus range targets for exemplars (`exemplar: true` in `/api/ds/query`) while
config `query.exemplars` is on (the default), whatever the dashboard JSON says; every other panel and every target
with `query.exemplars` off asks for none. Exemplars are drawn as diamonds in the panel's chart (at most 200, thinned
evenly over time) and never count as a series. In the expanded panel (or the Panel block), `x` selects the exemplar
nearest the cursor and moves the cursor onto it; under the legend the panel shows its time, value, trace id and
labels, and `enter` opens its trace in the Trace block (`trace_id`, `traceID`, `traceId` or
`query.exemplar_trace_label`).

`L` opens `tern-grafana://logs` with the focused panel's range and a LogQL selector from the labels all its series
share (with an exemplar selected, its labels), kept to `logs.correlate_labels`; the details are in
[query.md](query.md#jumps-to-logs-and-traces).

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
