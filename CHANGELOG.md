# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (pre-1.0: minor
versions may break).

## [Unreleased]

## [0.7.0] - 2026-11-11

### Added

- Dashboard links (`dashboard.links`) show after the variables: link
  buttons open in the browser pane with the variables, time range and
  variable values Grafana adds, and "dashboards" links list the dashboards
  with their tags (as a dropdown or one chip each) and open them natively.
- Verified on Tern 0.9.16; the SDK typings are pinned to its release.
- `make test` runs every spec twice: interpreted, and compiled to native code
  with the Luau version Tern embeds, as release Tern runs plugins. Tern
  0.9.16's Luau 0.740 miscompiled a gauge gradient loop into an endless one
  (the plugin ran out of memory and every dashboard block failed); the loop
  is rewritten and the miscompile is recorded in the capability matrix.

### Changed

- Dev stack: the Grafana 13 server runs 13.3.1 (digest pinned, with
  `table.autoColumnWidths` on) and its fixtures are re-recorded; the APIs the
  plugin reads were checked against Grafana Cloud's 13.4 and answer with the
  same shapes. Fixture capture refuses to record the imported public
  dashboards.
- Dashboard panels ask for as many points as Grafana asks for them: the
  panel's `maxDataPoints`, else its width in px (its grid columns over the
  block's width), else 500, and one `intervalMs` for every target with the
  panel's min interval, else its datasource's (Prometheus `timeInterval` or
  15s, SQL 1m), as the low limit. Prometheus and Loki targets leave
  `$__interval` to Grafana's backend. A resize re-queries nothing; the next
  query takes the new width. The `dashboard.max_points` setting is gone
  (a leftover key is ignored).

### Fixed

- Stat sparklines are drawn as Grafana's: a line over a light fill in the
  value's color behind the value, as tall as the room the text leaves,
  instead of a strip of bars under it. A sample alone between gaps draws
  nothing and a flat series lies on the bottom edge (old singlestats on
  9578 and 3662), and a stat too short for Grafana's chart (a 3-row stat
  such as 17781's Panics) shows its value alone, at Grafana's size.
- A value that is NaN prints `NaN`, as Grafana does, instead of `nan`.
- An empty cell in a color-background table column is filled to the row's
  height in the column's base color, instead of a thin strip.
- A circular gauge's threshold labels at twelve o'clock stand side by side
  ("1" and "0" read "10", as in Grafana) instead of one over the other, and
  an arc's end labels keep inside its ends.
- A radial gauge's sparkline is a smoothed line, as Grafana draws it, and
  marks the reduced sample (for example the last one) with a point, as
  Grafana 12.4 and 13 do.
- Time series match Grafana on old public dashboards: series past the tenth
  take the rest of Grafana's classic palette (11074's transmit series are
  purple, not yellow again); table legends keep series names whole and
  scroll sideways; a chart whose samples are all NaN draws no y axis; a lone
  sample between gaps is not drawn as a dot unless points are on; a graph
  with both y axes hidden hides its time axis too (13639 log volume).
- Logs panels saved without `showTime` or `wrapLogMessage` show no time and
  do not wrap, Grafana's defaults.
- Dashboard panels keep their gridPos widths: narrow panels (2-column
  stats) no longer wrap their band onto extra rows, and a repeat's
  half-empty last row has panels as wide as a full row's. Panels stack at
  the full width only below Grafana's 769 px breakpoint.
- Text in canvas, flame graph, geomap, heatmap, node graph and state timeline
  panels sits where Grafana draws it: Tern's SVG ignores dominant-baseline,
  so the labels were about a third of an em too high; their baseline is now
  placed by hand.
- List legends label each value with its calc, as Grafana does
  ("CPU Cores Last *: 10"), and leave that room when sizing the chart.
- Dashboards saved by older Grafanas open as Grafana shows them: Grafana's
  schema migration runs on load. Pre-Grafana 5 dashboards (top-level `rows`:
  Prometheus 2.0 overview, Docker, Kubernetes cluster, Grafana internals, the
  Loki and Tempo mixins) drew nothing and counted as "native 0"; they now get
  Grafana's rows and grid positions (checked against Grafana 12.4's own
  migration of 36 public dashboards). Leftover copies of repeated panels are
  dropped (9578 Alertmanager's collapsed rows held 69), old `table` panels
  with styles migrate as `table-old`, old panel links, value mappings and
  variable flags are upgraded. The compatibility scan names a dashboard without
  panels instead of reporting "native 0".
- An old table style's hidden column (`custom.hideFrom.viz`) is hidden again:
  dotted `custom.*` override ids set nested options as in Grafana.
- A time series whose series are all hidden from the legend (graph
  `hideZero`/`hideEmpty`) draws no legend, as Grafana's.
- Stat sparklines follow Grafana's: a flat series lies at the bottom of its
  range instead of filling it, and the sparkline spans the panel's time range
  with gaps where samples are missing.
- Time series draw every series, as Grafana does: they share the 256 KiB
  byte budget with fewer samples each, and only series that would not fit even
  at 3 samples are left out ("N more series not shown (chart size limit)").
  Panels with more than 10 series lost their later ones (1860 Network Traffic
  Basic dropped every Tx series, along with their negative-Y override).
- A `custom.stacking` override with `group: false` stacks the series alone, as
  Grafana keys the group (1860 Memory Basic: Total no longer sits on top).
- Stacked y axes range over the stack's values, not the base it fills down
  to (a stacked constant 4 reads 0..8 as in Grafana).
- Dashboard time series space y ticks for the plot height Grafana gives the
  panel (15 px under 150 px), so a 7-row panel shows Grafana's tick count.
- A long bottom legend in a dashboard card is cut at 35% of the panel and
  scrolls, as Grafana's VizLayout does.
- Tables with several frames show one at a time with Grafana's frame selector
  (`options.frameIndex`, previous/next) instead of "N more frames", and draw
  up to 48 columns (was 16).
- Time series bars are as wide as Grafana draws them: uPlot's column is the
  distance between a series' two closest samples, so per-minute counts over
  hours are hairline bars, and an outline that would take half a bar is
  dropped.
- Table columns follow the server's `table.autoColumnWidths` flag, read from
  Grafana's OpenFeature endpoint as its frontend reads it: on (Grafana Cloud),
  columns fit their content and a gauge column takes Grafana's 150 px instead
  of 228; off (the default), the columns share the panel width, at least
  150 px or their minimum width each.
- An expanded dynamic text panel takes Grafana's full panel height (the plugin
  has no panel padding).
- Pie chart gradients no longer show bands: a slice is drawn with one band per
  color level of Grafana's radial gradient instead of 8 flat rings, and a pie
  of hundreds of slices stays under the SVG size cap.
- Time series render faster when a series has samples outside the range, and
  re-rendered time columns are no longer kept in memory.
- A dashboard no longer keeps the null-filled copy of every time series it
  drew (Grafana inserts nulls at gaps and at the range's ends): only the few
  panels a redraw reuses keep theirs. A dashboard of 60 panels of 50 series
  x 1000 points held twice its data, 290 MiB with its raw answers, over the
  plugin's 256 MiB heap; it holds 195 MiB again, as 0.5.0 did.
- Prometheus query variables whose query is a series selector or any other
  expression (`up{job=~"$jobs"}` with a regex picking the instance) resolve
  as Grafana's classic query does, from the series it matches; they were
  unsupported and left every panel using them without data.
  `label_names(metric)` lists the label names of the matching metrics,
  `metrics(regex)` filters as the Grafana version does, `$__interval` in a
  variable query is the datasource's scrape interval, and the empty forms
  (`label_values()`, ...) answer no values instead of an error.
- Loki query variables resolve: the query editor's label names and label
  values (with a stream selector) and the legacy `label_values(...)` and
  `label_names()` strings, as Grafana's Loki datasource lists them.
- A query variable whose datasource is given by name (`"Loki"`) asks that
  datasource instead of a uid of the same text.
- Loki queries keep a plain variable value as written (Grafana 11.6 and later
  no longer double its backslashes) and no longer escape quotes in
  multi-value variables.
- A text panel saved with a datasource that does not resolve draws natively
  instead of going to the image renderer: panels that run no queries ignore
  their datasource, as in Grafana.
- Transformations saved without some options take Grafana's defaults: an
  empty "Add field from calculation" sums each row into `Total` (was `math`;
  Loki metrics dashboard 17781), an empty reduce takes Max.
- A query that returns no series reaches the panel's transformations as
  Grafana's empty frame, so a stat that adds a calculated field to it shows a
  blank value, as Grafana does, instead of a large "No data".
- Queries saved without a refId get A, B, ... on load, as Grafana's panel
  model gives them: the node-exporter mixin's Disk Space Usage table (two
  table-format queries grouped by `Value #A` and `Value #B`) showed
  "No data".

## [0.6.0] - 2026-11-10

### Added

- Ad hoc filter variables: a picker to add, edit and remove filters with keys
  and values from the datasource, applied to Prometheus and Loki queries the
  way Grafana rewrites them, `${filter}` for datasources that read it (such as
  the cardinality datasource), and `var-<name>` in links and saved state.
- Panel alert state: a heart in the header of a panel linked to a Grafana
  alert rule (firing, pending or normal), and the dashboard's annotation
  layers (Annotations & Alerts with alert state history, and Prometheus
  annotation queries) drawn on time series as in Grafana.
- Table pagination with Grafana's page size, data links in table cells, and
  columns sized by `custom.width` and `custom.minWidth`.
- Grafana Incident panels and their labels, severities and statuses query
  variables run natively; picked values are formatted as the server's Grafana
  version formats them, so a dashboard that errors in Grafana errors the same
  way in Tern.
- The dynamic text panel (`marcusolsson-dynamictext-panel`) draws natively:
  Handlebars templates over rows (every row, all rows, data), its built-in
  helpers, sanitized HTML as native elements and inline styles compiled to a
  generated stylesheet. Panels with their own JavaScript (helpers,
  afterRender) or templates and styles loaded from URLs stay on Grafana's
  renderer.
- The treemap panel (`marcusolsson-treemap-panel`) draws natively with
  d3-hierarchy's tilings, its paddings, grouping, labels and data links.
- Datasource plugins that Grafana runs in the browser get one module contract
  (`plugin/lib/datasources`): target blockers, shaping, post-processing,
  multi-step request jobs, query variables and custom variable formatting.

- Grafana Cloud cardinality management panels run natively: the
  `grafanacloud-cardinality-datasource` frontend (2.6.1) is ported, with the
  same Mimir cardinality API requests through the target Prometheus
  datasource's proxy, the same frames (gradient gauge percentage columns),
  metric usage with dashboard and alert rule titles, the Used column, its
  three query variable kinds and its error texts. See docs/dashboards.md,
  Datasource plugins.
- JSON API panels (`marcusolsson-json-datasource`) run natively: the plugin's
  1.3.23 frontend is ported, with the same requests through the datasource
  proxy (urlPath, params and headers with variables and the epoch/ISO
  macros, `jsonData.queryParams`, POST bodies), JSONPath as jsonpath-plus
  evaluates it, the plugin's field type detection and parsing, group-by and
  metric fields, its query variables and Grafana's error texts. JSONata
  fields stay on the ladder. The API keys datasources keep in queryParams
  never reach logs, saved state, compat output or error texts. See
  docs/dashboards.md, Datasource plugins.
- Zabbix panels (`alexanderzobnin-zabbix-datasource` 6.10.2) run natively:
  metrics and item id targets through `/api/ds/query` with the plugin's
  browser post-processing (Alias functions, Zabbix units, the wide merge),
  trigger counts and problems as the plugin's Zabbix API calls, and the
  Problems panel (`alexanderzobnin-zabbix-triggers-panel`) read-only in table
  and list layouts. IT services, text and user macro queries, trigger counts
  by items and direct database connections stay on the ladder. See
  docs/dashboards.md, Datasource plugins.

### Fixed

- Every absolute time on a native panel (axes, legends, cursor read-outs,
  table time cells, stat time values) is formatted in the dashboard's time
  zone (browser, utc or an IANA zone, per value across DST); they were UTC.
- Grid cards take exactly their panel's grid height, and every chart sizes to
  the card body it is given, so titles stay visible and charts are no longer
  cut at the bottom; stats center their value as Grafana's BigValue does.
- Panel titles show "All" for a variable's custom all value; descriptions and
  links sit in the card head as in Grafana.
- Bar gauges, bar charts and gauges draw Grafana's exact per-row and
  threshold colors, thick bars with large values, rounded bar ends and the
  full threshold ring; bar chart time labels use Grafana's format.
- Time series range their y axis over the samples in view and draw one sample
  beyond each edge cut at the plot, like uPlot, so a query returning years of
  history no longer flattens the line; frames are drawn in time order; axes
  with decimals 0 label only whole ticks.
- Dynamic text and text panels use Grafana's body and heading styles and
  unitless line heights; positioned and stacked content no longer overlaps.
- Pie chart slices are filled with Grafana's exact radial gradient of their
  color in each theme: a fixed blue-gray such as Zabbix's 'Not Classified'
  no longer turns pale green with a purple rim in Tern's light theme.
- Table panel columns are as wide as their content and a table wider than its
  card scrolls sideways, as in Grafana 13, instead of squeezing every auto
  column to an ellipsis; tables without fixed-width columns spread over the
  card's leftover width.
- Named Grafana colors and the classic palette take Grafana's light-theme
  shades in Tern's light theme on every native panel; exact hex colors keep
  their value.
- Axis tick labels pick decimals per tick like Grafana ("1 kW, 1.50 kW"), and
  date units follow Grafana: `time:<pattern>` uses the pattern,
  `dateTimeFromNow` shows relative time, the "no date if today" units drop
  today's date.
- Text panels keep inline styles Grafana's sanitizer allows (gradients,
  colors, alignment, sizes), so styled HTML buttons draw as in Grafana.
- Time series lines break where samples are missing, as in Grafana: the
  panel inserts nulls where samples are further apart than `insertNulls`, or
  than the time field's interval (the Prometheus step) when it is off, instead
  of joining every gap with a straight line.
- A table that a transformation such as `filterByValue` leaves with columns and
  no rows keeps its header over Grafana 13's "No rows" (or the `noValue`
  text) instead of "No data".
- Treemap tiles take Grafana's saturated colors (threshold, fixed, mapping and
  continuous scheme colors, per light and dark theme) instead of Tern's muted
  status tones.
- Text panels render the HTML Grafana renders instead of showing raw tags:
  HTML mode and the HTML blocks of markdown mode (such as `<div>` wrappers)
  draw headings, paragraphs, lists, tables, emphasis and links natively after
  Grafana's sanitizing (disallowed tags such as `<script>` show as plain
  text, as in Grafana), and inline `<a>`, `<b>`, `<i>`, `<code>`, `<br>` and
  `<img>` in Markdown become Markdown. Rooted link and image paths (including
  Markdown links like `[IRM](/a/grafana-irm-app)`) open on the dashboard's
  Grafana; images load when Tern can fetch them, else show their alt text.
- Every unit of Grafana's catalog formats like Grafana. Data units with a
  starting prefix (`kbytes`..`pbytes`, `deckbytes`..`decpbytes`, `KiBs`,
  `Mbits`, ...) scale both ways, so 0.0597 `gbytes` reads "61.1 MiB" instead
  of "0.0597 gbytes"; energy, mass, length, pressure, radiation, hash rate,
  currency (including suffix currencies such as `currencySEK`), throughput,
  `hex`, `sci`, `ordinal`, `clockms`/`clocks`, `timeticks` and the `si:`,
  `count:`, `currency:` (and `currency:financial:`) and `bool:` ids no longer
  print the raw unit id. Time series axes in IEC units step in powers of 2,
  as Grafana's do (0, 8, 16 ... 48 GiB).
- Table gauge cells (`custom.cellOptions.type` `gauge`, by default or by
  override) draw Grafana's bar gauge with the value after it instead of
  "...": gradient and lcd bars run through the threshold colors (or the
  continuous scheme), `valueDisplayMode` text (the default), color and
  hidden apply. color-background cells are filled with the solid or gradient
  color like Grafana's (`mode` basic/gradient, `applyToRow` fills the row);
  a legacy `displayMode` wins over `cellOptions` as in Grafana. Pill,
  markdown and json-view cells are drawn natively; data-links, actions and
  custom cells now go to Grafana's renderer with their reason, as sparkline
  and image cells already did. A gauge column keeps room for its longest
  value (as Grafana's alignment factor does) and the bar's minimum, so a
  narrow pane shrinks the bar and the text columns instead of cutting "100%"
  to "10" over the next column; values line up down the column.
- Stat `colorMode` `background` fills the tile with Grafana's saturated
  gradient of the value's color and `background_solid` with the solid color,
  with white or dark text as Grafana picks it, instead of a pale tint; fixed
  colors (such as `blue` or `purple`) keep their Grafana color instead of
  turning grey or beige, in the shade Grafana uses for Tern's light or dark
  theme. `wideLayout: false` stacks name and value as in Grafana.
- Stat values are no longer cut off at the right in narrow cards ("40239",
  "$0"), and a long field name next to a value no longer squeezes the value
  away.
- Untitled panels have no "Panel N" header, and their stats show the field
  name above the value like Grafana. Multi-value stat names wrap in full
  instead of being truncated.
- Short stat panels with a description (such as the 6x3 tiles of Grafana
  Cloud's cardinality dashboards) draw their value at least a line tall
  instead of a 5x4 px dash: the value gets the room left under the card's
  head and chip lines, a sparkline that would leave it less than a line is
  left out, and description and link chips keep to one line in a capped
  card.
- Query variables whose datasource query is an object wait for every
  variable it references, as in Grafana; a hidden variable no longer runs
  first with an unresolved `${label}` and leaves its repeated panels empty.

## [0.5.0] - 2026-11-09

### Added

- Time series `custom.gradientMode` `hue` and `scheme` are drawn natively
  again, as Grafana's gradient fills (hue shift, threshold steps as hard
  edges, continuous schemes); 0.4.0 sent these panels to Grafana's renderer.

- Grafana 13 is supported and verified: the dev stack runs Grafana 13.3 next to
  11.6 and 12.4, with recorded fixtures every per-version spec reads.
  Dashboards saved with 13's new layouts (schema v2: tabs, auto grid, rows)
  open natively through the same API. Tempo 3.x is verified next to 2.10.
- Verified on Tern 0.9.13: the end-to-end suite passes and every Tern fact the
  plugin relies on was re-checked (docs/sdk-capability-matrix.md); the dev
  typings are pinned to the matching tern-sdk. docs/performance.md and the
  blob-cache issue draft are re-measured on 0.9.13, which trims its image
  cache to 1 GiB at daemon start but still never while running.

### Changed

- Performance round, with no change to config, saved state or behavior.
  Measured with the new benchmark harness (`make bench`, docs/benchmarks.md)
  against 0.4.0, CPU times without JSON decoding:
  - time series SVGs are 35-40% smaller (relative path data), so the image
    cache grows that much slower; a 60-panel dashboard refreshes about 60%
    faster and Tern All Panels about 30% faster;
  - a Query block refresh over 7 days is about 34% faster;
  - a Loki tail poll of 5000 lines takes about 2 ms instead of 14 ms (new
    lines are merged, unchanged rows reused);
  - the compatibility scan is linear in the number of dashboards;
  - blocks and lenses load their code on first open, and updates that change
    nothing skip the repaint and save;
  - settings edits update in place (key handling about 10-100x faster).
- Cleanup: shared helpers replace about 25 duplicated groups, the dashboard
  state machine and the large render and panel modules are split, and the
  architecture doc's module map is rewritten.

### Fixed

- Gauges on Grafana 13 draw as its radial gauge (shape, segments, sparkline,
  effects): 13 dropped the `newGauge` toggle and always draws the new gauge,
  so the plugin no longer falls back to the old gauge there.
- A fixed-color (for example purple) or continuous-scheme time series and its
  legend swatch are drawn in Grafana's color instead of a theme tone.
- The IRM test fixtures no longer carry raw alert-group numbers and alert
  values from the capture; the scrub renumbers ids and fails on any raw value.

## [0.4.0] - 2026-10-20

### Added

- Panels on backend datasource plugins run natively: PostgreSQL, MySQL,
  MSSQL, Elasticsearch, Infinity (backend parsers), Grafana Incident and any
  plugin with a backend, each target sent as its datasource's frontend sends
  it (SQL-quoted variables, Lucene formatting, every string interpolated).
  Server-side expressions run (with the hidden queries they read), and
  `-- Dashboard --` panels show their source panel's results (with its
  transformations when asked), querying the source when it is not on screen.
  Legacy `table-old` panels migrate to table as in Grafana. Datasources whose
  frontends query in the browser (JSON API, cardinality, Zabbix, Graphite,
  InfluxDB, Infinity frontend parsers, Incident queries with variables) keep
  a precise ladder reason. Dev stack: a seeded PostgreSQL and dashboard
  `tern-sql`. See docs/dashboards.md, the ladder.

- Panel transformations drawn natively: add field from calculation, join by
  field (and seriesToColumns), labels to fields, merge, convert field type,
  format time, sort by, filter data by values, extract fields, reduce, rows to
  fields, config from query results, group by, grouping to matrix, limit,
  prepare time series, rename by regex and series to rows, ported from
  Grafana 13 with its own test cases;
  transformation options see dashboard variables. See docs/dashboards.md,
  Transformations.

- **Grafana: Compatibility** scans every dashboard a context can see and
  lists, per panel, whether it is drawn natively, by Grafana's renderer or in
  a browser pane and why, with counts grouped by reason; filter, open a
  dashboard or panel, copy the report as Markdown (`compat.max_dashboards`).
  See docs/compat.md.

- Display names using `${__field.name}`, `${__field.displayName}`,
  `${__field.labels.<key>}`, `${__field.labels}` or `${__series.name}` resolve
  per field in legends, table headers and stat or gauge titles, and dashboard
  variables apply to display names.

- Grafana IRM: **Grafana: On-call** (OnCall alert groups with acknowledge,
  unacknowledge, resolve, unresolve and silence; schedules with who is on call
  now and next) and **Grafana: Incidents** (open incidents, detail and
  timeline; declare, change status or severity, add a note). Every write is
  previewed, attributed to the service account and sent only on confirmation.
  A status segment (`IRM: you are on call until 22:00, 2 alert groups,
  1 incident`) from a background poll (`irm.poll_s`, `irm.contexts`,
  `irm.names`, `irm.user`: your email, to recognize you among on-call users).
  See docs/irm.md.

- Image-cache economy: Tern keeps every distinct chart image a block sends for
  the whole session (measured: about 180 MB/h for two auto-refreshing
  dashboards), so auto-refresh now pauses in background tabs (window module
  `visibility_window.luau`, kv key `visible_panes`), byte-identical answers
  are not redrawn, a refreshing panel keeps its picture on its own axis (one
  image per refresh instead of two), ranges ending at now are drawn on the
  query interval, and panels behind an expanded one wait until shown. Numbers
  before and after in docs/performance.md; an upstream issue draft in
  docs/upstream/stencil-blob-cache.md.

- Time series panels with several y axes draw natively: series are grouped
  into scales as Grafana groups them (unit, bounds, soft bounds, placement,
  label, distribution), so a per-series unit override gets its own axis on the
  right with its own ticks; legends and the cursor read each series in its own
  unit. Also drawn: `axisPlacement`, `axisLabel`, `axisSoftMin`/`axisSoftMax`,
  `axisCenteredZero`, `axisGridShow`, log and symlog scales, stacking per
  scale and `stacking.group`, the `negative-Y` and `constant` transforms, and
  `hideFrom.legend`/`hideFrom.tooltip`. Field overrides can match by value
  (`byValue`) in every panel type.

### Changed

- Time series panels draw each series with its own field config (line width,
  dash and dot styles, step and smooth interpolation, fill opacity and opacity
  gradient, points, span nulls, fill below another series, bar width and
  alignment), range value axes as Grafana does (headroom above the data, an
  all-zero series on the floor of 0..100), and color series in Grafana's
  palette order. Chart series colors are now the first ten colors of
  Grafana's classic palette. `gradientMode` hue and by-value scheme stay on
  the PNG rung with that reason.

### Fixed

- The window half loads in about 2 ms instead of 26-40 ms: under load it
  could exceed Tern's 50 ms window budget (`load exceeded 50 ms`), which
  disabled link routes, palette commands, status segments and Carly. Window
  modules now load their lib stacks on first use, the status segments load in
  timer ticks after the entry, and `make check` guards the load size
  (`make window-load`). See docs/architecture.md, Window load budget.

- Stat values are sized like Grafana's BigValue for the panel and kept
  within the card on one line; they had a fixed size, so large panels looked
  empty and long values could wrap.

- A `query_result()` variable whose query returns a scalar expands to the
  value, as in Grafana, instead of the raw row text that broke the PromQL
  using it.

- The "Copy matchers", "Copy prompt" and "Copy YAML" buttons copied their own
  label: Tern handles a click action named `copy` itself. They now use their
  own action names.

## [0.3.0] - 2026-10-12

### Added

- Native rendering for every core Grafana panel type: pie chart, bar chart,
  histogram, trend, XY chart, candlestick, heatmap, state timeline, status
  history, flame graph, traces, node graph, geomap (markers over an outline
  basemap), canvas, alert list, annotation list, dashboard list and news, plus
  legacy graph and singlestat through Grafana's own migration.
- Native `grafana-clock-panel`: time, countdown and countup, 12/24 hour and
  custom formats, time zones, descriptions, query-driven countdowns; it ticks
  every second without re-querying.
- Grafana 12.4's radial gauge (shape, segments, neutral point, sparkline,
  threshold markers and labels) drawn as SVG.
- Panel configuration honored: `noValue` exactly as Grafana applies it (with
  the gauge's neutral point, a panel with no query shows its configured value),
  relative time and time shift overrides with Grafana's header badge,
  descriptions as an info marker, panel links, transparent panels, and every
  card capped at its Grafana height.

### Changed

- Dashboard bands wrap on narrow panes the way Grafana stacks panels on narrow
  screens, and gauges scale to the space they get.

## [0.2.0] - 2026-10-12

### Added

- **Connect Grafana** in the Settings block (first starter, `c`): paste a Grafana
  or Grafana Cloud URL and a service account token; the token is tested first,
  datasources are discovered automatically, then the token is stored and the
  context written. **Update token** rotates it; removing a context offers to
  delete the stored token.
- OS keychain credentials: `token_keychain` / `password_keychain` read from the
  macOS keychain or the Linux Secret Service (service `tern-grafana`). Tokens are
  written over stdin, never on a command line.
- `token_env` also finds variables exported in your login shell, so they work
  when Tern is opened from the Dock or Finder.

### Changed

- Credential problems are one actionable line (for example "No token stored for
  cloud in the macOS keychain; open Grafana: Settings and use Connect or Update
  token", or "the 1Password CLI (op) is not installed"); Lua tracebacks go to
  Tern's log, never to the screen.
- No starter template uses the 1Password CLI anymore; `token_cmd` and
  `token_file` remain as advanced options for password managers.

## [0.1.1] - 2026-10-12

### Fixed

- Settings: choosing the Grafana Cloud (or any) starter template no longer fails
  with "table has a protected metatable". Tern tags decoded JSON arrays with a
  protected metatable, which `table.clone` refuses; every copy of decoded data
  now avoids it, and the test suite decodes JSON the same way Tern does.
- Config and `token_file`/`password_file` paths that are symlinks (stow, chezmoi,
  home-manager, sops-nix) are read; Settings refuses to overwrite a symlinked
  config and says to edit its target.
- Deploy annotations redact more secrets before posting: tokens in URL query
  strings, URL userinfo (passwords containing `@`), auth, token, cookie and key
  headers, `-u user:pass`, `--oauth2-bearer`, and `--set` values under secret keys.
- Investigate works for blocks on remote hosts: the prompt travels in the link
  instead of the local key-value store, and only a preview opened in this window
  can start the agent.
- Explanations such as "Cannot open logs" are shown; they used a toast level
  Tern does not accept.
- Times stay on the wall clock after the machine sleeps (alert staleness, watch
  toasts, Investigate expiry, silence and annotation times).
- Carly answers encode empty lists as `[]`, and large answers are refused
  earlier (512 KiB) so they stay within the window's time budget.

### Changed

- Alert fingerprints are computed without per-byte allocation.

## [0.1.0] - 2026-10-12

### Added

- Contexts and auth: one config file describing Grafana and direct Prometheus,
  Alertmanager, Loki and Tempo endpoints per context; credentials from
  `token_cmd`, an environment variable or a `0600` file; bearer, basic and extra
  headers (such as `X-Scope-OrgID`); the whole file is validated with every
  problem reported at once.
- Settings block ("Grafana: Settings"): edit the config safely and test each endpoint.
- TLS options (custom CA, mutual TLS, insecure) via a `curl` transport fallback.
- Grafana unit formatting and thresholds mapped to Tern tones.
- Grafana time ranges (`now-6h`, absolute times) and step math (`$__interval`,
  `$__rate_interval`, `$__range`) with LTTB downsampling.
- Query block ("Grafana: Query"): PromQL scratchpad with metric and label
  autocomplete, range picker, native time series graph with a keyboard cursor and
  legend read-out, table/instant view, auto-refresh and query history.
- `query` config section: `default_range`, `max_points`, `refresh`.
- Grafana URL routing: Explore links open the Query block; Grafana pages without a
  native view open in a Tern browser pane.
- Lens: `promtool query instant|range` output rendered as a native graph or table.
- Dashboard block ("Grafana: Dashboard"): search and open Grafana dashboards with
  their grid layout, rows, variables and picker, time range and auto-refresh.
  Panels are drawn natively (time series, stat, gauge, bar gauge, table, text,
  logs), else as a PNG from Grafana's image renderer when available, else with an
  action to open them in a Tern browser pane.
- Panel block: pin one dashboard panel as its own block.
- Grafana `/d/` and `/d-solo/` links open the Dashboard and Panel blocks; alert
  list and alert rule links open the alerts inbox.
- Alerts inbox ("Grafana: Alerts"): firing, pending and silenced alerts from
  Grafana unified alerting, Alertmanager v2 or Prometheus, grouped by labels, with
  runbook and dashboard links from annotations.
- Status-line segment with firing counts per context, toned by severity; clicking
  it opens the inbox. Visible while Tern's status bar is on.
- `dashboard` config section (`max_points`, `min_refresh`, `render_theme`) and
  `alerts` config section (`contexts`, `group_by`, `poll_s`, `toasts`,
  `toast_severities`).
- Opt-in toasts when alerts start firing in a polled context (`alerts.toasts`),
  filtered by severity and announced once across windows.
- Silences block ("Grafana: Silences", or `s` on an alert): create a silence
  prefilled from an alert with a preview of the alerts it covers, list and expire
  silences, on Alertmanager v2 or Grafana's Alertmanager. Every write is shown on a
  confirmation panel and sent only after you confirm.
- Rules view (`v` in the alerts inbox): Grafana-managed and Prometheus alerting and
  recording rules with status, health, last evaluation, last error and query.
- Ops block ("Grafana: Ops"): Prometheus targets health, TSDB cardinality, and
  build, runtime, config and flags info, directly or through Grafana's datasource
  proxy.
- Lenses: `promtool check rules|config` and `promtool test rules`; `curl` against
  `/api/v1/query*` and `/api/ds/query`; `amtool alert` and `amtool silence`;
  `logcli query`.
- Logs block ("Grafana: Logs"): LogQL against Loki directly or through Grafana,
  with label, value and pipeline suggestions, colored levels, volume bars per
  level, a polling tail, and label, metadata and parsed-field chips that filter
  the query. Grafana Explore links on a Loki datasource open it. `logs` config
  section: `default_range`, `limit`, `tail_interval`, `volume`.
- Trace block ("Grafana: Trace"): a Tempo trace as a waterfall with per-service
  colors, error spans, the critical path, folding and span detail (attributes,
  events, links, resource), tolerant of missing parents, clock skew and duplicate
  spans; TraceQL search with tag and value chips. Tempo directly or through
  Grafana. `trace` config section: `search_limit`, `range`.
- Deploy annotations: finished deploy commands (helm, kubectl, terraform, tofu,
  argocd, flux, or your own patterns) post a Grafana annotation after you approve
  it per context (Always, Once or Never). Off until `annotations.enabled`.
- Deploy impact watch: a card beside the terminal comparing configured or guessed
  signals before and after a deploy. Off until `impact.enabled`.
- Carly: functions to run PromQL, list alerts, find dashboards and query logs, and
  a firing-alerts summary in Carly's request context.
- Investigate: open an agent on an alert with its labels, query, recent values and
  runbook in a prompt you preview first. `investigate` config section: `range`.
- Personal PromQL threshold watches (`watches`) polled in the background, shown in
  the status line and as toasts.
- Per-host default contexts (`hosts`): map hostnames or globs to the context used
  on that machine.
- Exemplars on Query graphs and dashboard time series: `x` selects the nearest,
  `enter` opens its trace. `query` config keys `exemplars` and
  `exemplar_trace_label`.
- Jumps between signals: metrics to logs (`L` in the Query block and dashboard
  panels), logs to metrics (`M`), logs to trace (`T` or a line's `trace` chip)
  and a span to its logs (`L`). Config keys `logs.correlate_labels`,
  `logs.trace_id_pattern` and `trace.logs_query`.
- Shared time range and cursor (`S`) across Query, Dashboard, Panel, Logs and
  Trace search blocks.
- `logcli query` lens: open the same query in the Logs block.
- Project scaffold: `plugin.toml` at the repository root, sources under `plugin/`,
  pinned repo-local tooling (`make bootstrap`), formatting, lint, typecheck and
  unit test runner (`make check`), CI.
- Repository docs: README with roadmap, contributing guide, security policy,
  code of conduct, support, issue and pull request templates.
- Docker dev stack in `dev/` (Grafana 11 and 12, Prometheus 2.53 and 3,
  Alertmanager, Loki, Tempo, image renderer) and fixtures recorded from it.
- SDK capability matrix and architecture contract.

[Unreleased]: https://github.com/contrafy/tern-grafana/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/contrafy/tern-grafana/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/contrafy/tern-grafana/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/contrafy/tern-grafana/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/contrafy/tern-grafana/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/contrafy/tern-grafana/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/contrafy/tern-grafana/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/contrafy/tern-grafana/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/contrafy/tern-grafana/releases/tag/v0.1.0
