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
| Query (Grafana Incident) | `labels`, `severities`, `statuses` (listed through Grafana's `/api/ds/query`, as the plugin's frontend lists them; `roles` shows the plugin's error); regex, sort, multi-value and All as above |
| Query (JSON API) | the variable's JSON API query, run as its panels run (see [JSON API](#json-api-marcusolsson-json-datasource)); text from `experimentalVariableTextField`, value from `experimentalVariableValueField`, else the first field; regex, sort, multi-value and All as above |
| Custom | comma-separated values, `\,` for a literal comma, `text : value` pairs |
| Constant | used in queries, not shown |
| Interval | the listed values and `auto` (computed from the range with the variable's step count and minimum) |
| Datasource | the datasources of that type your Grafana user can query, filtered by the regex |
| Textbox | type a value and press `enter` |
| Ad hoc filters | see [Ad hoc filters](#ad-hoc-filters) |

Variables are resolved in dependency order: a variable that references another (`label_values(up{job=~"$job"},
instance)`, a query on datasource `${ds}`) waits for it and is refreshed when it changes. Query variables of other
datasource types (Loki, Tempo, SQL, ...) show as not supported, and panels referencing them keep the reference as
written.

### Ad hoc filters

An ad hoc filter variable's chip lists its filters (`job = prometheus, env =~ prod.*`, or "+ Add filter"). Its
picker lists the filters: `enter` on one edits it (key, operator, value; "Remove this filter" at the key step),
"+ Add filter" adds one and "Remove all filters" clears them; `escape` goes back a step. Keys and values come from
the variable's datasource as Grafana lists them: Prometheus `/api/v1/labels` and `/api/v1/label/<key>/values` over
the dashboard range, narrowed by the other filters and the metrics the dashboard's queries on that datasource
select (keys used by other filters are left out); Loki's labels narrowed by a stream selector of the other filters;
the variable's `defaultKeys` replace the key list. A typed key or value is offered when the variable allows custom
values (the default; without them the regex operators are not offered either). The one-of operators (`=|`, `!=|`)
are offered where the datasource plugin declares them (Prometheus); `space` toggles values and `enter` applies.
Every finished filter applies at once, refreshes the variables that reference it and re-runs the panels.

Applied as Grafana's dashboards apply them: a panel whose datasource (its own, else its first query's; never
`-- Mixed --`) is the variable's gets its filters. Prometheus adds each to every selector of the expression
(`rate(x[5m])` becomes `rate(x{job="prometheus"}[5m])`; an existing matcher with that label and value only gets the
operator replaced; regex values escaped as the datasource does; from Grafana 13 the one-of operators become regex
matchers). Loki adds them to the stream selectors, or, when every selector has a matcher and the query parses
labels, as label filters after the last parser, label filter or `label_format` of each expression; Grafana 12.1+
with Loki query splitting applies them twice to the range queries it splits, so a label filter shows twice, as in
Grafana's request. `${filter}` in a query or text reads the filter expression (`job="prometheus",env=~"prod\\.\\*"`),
which Grafana Cloud's cardinality datasource takes as its selector. Links carry the filters as
`var-filter=job|=|prometheus` (repeat it for several; `var-filter=` for none), and the block remembers them.

Grafana Incident query strings are interpolated as the plugin's frontend does: "All" with the custom all value
`$__all` goes in as `$__all` (the plugin's backend accepts it); picked values become filters, `label:'<v>'`,
`severity:'<v>'`, `status:<v>` or `role:<v>` joined by spaces (an empty result sends the target's
`originalQueryString`). Which filter depends on your Grafana version, because the plugin keys on what Grafana hands
its formatter: Grafana 12 and later (scenes dashboards) pass only the variable's name, so the filter follows the
name (`labels`, `severities`, `statuses`, `roles`; any other name gives `unsupported query name`, which the plugin's
backend rejects with "Invalid query string"); Grafana 11 passes the variable's query too, so its query type
(`labels`, `severities`, `statuses`) wins, then the name. Tern follows the server's version, so a panel that fails
in Grafana (for example a variable named `severity` with a value picked) fails the same way in Tern, with Grafana's
error.

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

1. **Native.** Tern draws the panel itself when its type and options are supported (every core Grafana panel
   type and the clock panel; see [Native panels](#native-panels)) and every query runs natively: Prometheus, Loki
   and TestData; Tempo for traces and table panels; Grafana Incident (with its query variables, see
   [Variables](#variables)); the frontend datasource plugins Tern ports (see [Datasource
   plugins](#datasource-plugins)); and any other datasource whose plugin has a backend (`meta.backend` in
   Grafana's frontend settings), such as PostgreSQL, MySQL, MSSQL, Elasticsearch or Infinity. Queries go to
   Grafana's `/api/ds/query`, one request per panel, so they run with your Grafana user's permissions (frontend
   plugins: their own requests through Grafana's datasource proxy). Each target is sent
   as the datasource's own frontend sends it: SQL targets as
   `rawSql` and `format` with SQL-quoted variables (a multi-value `$var` in `IN ($var)` becomes `'a','b'`;
   `$__timeFilter` and the other SQL macros stay for Grafana's backend), Elasticsearch's Lucene query with the
   `lucene` format, other plugins with every string field interpolated. Server-side expressions (`__expr__`) run
   too: the queries they read are sent even when hidden, and only the visible results are shown. A
   `-- Dashboard --` panel shows the results of the panel it names (with that panel's transformations when it
   says so), and Tern queries that source panel for it even when the source is off screen or on another rung.
   Legacy Angular `graph`, `singlestat` and `table-old` panels are migrated to time series, stat and table with
   Grafana's own migration first, as Grafana does when it loads them.
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
| `<type> queries are not run natively` | a datasource Tern cannot send queries to: not listed in Grafana's frontend settings, `-- Grafana --`, or Tempo outside traces/table panels |
| `<type> queries run in the browser (a frontend datasource plugin)` | the plugin has no backend: Grafana's frontend queries it |
| `JSON API JSONata expressions run in the browser`, `JSON API datasources with browser (direct) access are queried by the browser` | a JSON API field in the JSONata language (evaluated by the jsonata library in the browser), or a JSON API datasource Grafana does not proxy |
| `the cardinality target data source "<name>" uses browser (direct) access, ...` | a Grafana Cloud cardinality target Prometheus datasource with browser access: only the browser reaches it |
| `Zabbix ... are not reproduced`, `Zabbix reads history through a direct database connection ...` | Zabbix IT services, text and user macro queries, trigger counts by items, problems with item values at problem time and direct DB connections run only in Grafana's frontend (metrics, item ids, trigger counts and problems are native) |
| `Graphite queries are sent by the browser through the datasource proxy`, `InfluxDB queries are built in the browser` | these frontends do not use `/api/ds/query` for panels |
| `Infinity <type> queries with the <parser> parser run in the browser` | Infinity parses everything but its backend parsers (`backend`, `jq-backend`) in the frontend |
| `server-side expressions cannot read <type> queries (run in the browser)` | a panel whose expressions read a datasource Tern queries the way its browser frontend does |
| `the TestData scenario <s> runs in the browser only` | node_graph, trace, flame_graph and raw_frame are generated by Grafana's frontend |
| `reuses panel <id>, whose queries are not run natively: ...` | a `-- Dashboard --` panel whose source panel cannot be queried natively (also: `with its transformations: ...`, annotations, ad hoc filters, a loop) |
| `a -- Dashboard -- query among other queries is not run natively` | a mixed panel with a `-- Dashboard --` target |
| `datasource ${x} is not resolved` | the panel's datasource variable has no value |
| `transformation <id> [<option>] is not supported` | a transformation (or one of its options, such as a reducer or a date format) Tern does not apply |
| `library panel could not be loaded` | the library element is missing or not readable |
| `Grafana has no image renderer` | appended when rung 2 is not available either |

Panels in collapsed rows are not queried until the row is expanded.

## Native panels

Native panels follow Grafana's own rendering code; the notes below cover what a panel shows when it differs from
the obvious. In the grid every panel is cut at its Grafana height (gridPos rows); `enter` shows it whole.

| Panel type | Native | Limits (otherwise the ladder, with the reason) |
| --- | --- | --- |
| timeseries, legacy graph | yes | `scaleDistribution` ordinal; graph `xaxis.mode` series/histogram (Grafana migrates those to other panel types); see Time series axes below |
| stat, legacy singlestat | yes | reducers Tern cannot compute |
| gauge | yes | see Gauge below |
| bargauge | yes | `showUnfilled`, `sizing`/`minViz*`/`maxVizHeight` and the legend are not drawn |
| table | yes | sparkline, image, data-links, actions and custom cells |
| text, logs | yes | |
| piechart, barchart, histogram, trend, candlestick | yes | |
| xychart | yes | the options from before Grafana 11.3 (`seriesMapping`, `dims`) |
| heatmap | yes | a symlog y scale and log (non-linear) x buckets stay on the ladder |
| state-timeline, status-history | yes | |
| flamegraph, nodeGraph, traces | yes | traces queries Tempo (`traceId`) through Grafana |
| alertlist | yes | Grafana-managed rules, plus at most 8 datasource rule sources |
| annolist, dashlist | yes | tag or search filters with dashboard variables |
| news | yes | feed items without images; at most 100 items from a 2 MiB feed |
| geomap | yes | an outline basemap instead of raster tiles; only markers layers (other layer types and location modes stay on the ladder) |
| canvas | subset | background images, some element types and connection paths stay on the ladder |
| grafana-clock-panel | yes | the 3.x `digital` style; see Clock panels below |

- **Time series axes.** Series share a y axis when Grafana would put them on one scale: the same unit, min/max,
  soft min/max (`axisSoftMin`/`axisSoftMax`), axis placement, axis label and scale distribution. Any difference
  (typically a per-series unit override, or a legacy graph's right y axis) gives the series its own scale with its
  own ticks and unit: the first axis goes left, later ones right unless `axisPlacement` says otherwise, and a
  `hidden` placement keeps the scale without drawing its axis. `axisLabel`, `axisCenteredZero`, `axisGridShow`
  and log (base 2 or 10) and symlog scales are drawn; stacking is per scale and per `stacking.group`. The
  `negative-Y` transform draws a series below zero (its axis ticks read negative, as in Grafana) while the
  legend and the cursor read-out keep its own values; `constant` draws the series' first value across the range.
  Overrides may match fields by value (`byValue`: a reducer compared with `gt`, `gte`, `lt`, `lte`, `eq` or
  `neq`), in every panel type.
- **Time series drawing.** Every series is drawn with its own field config, from the defaults and overrides:
  `drawStyle` (line, bars, points), `lineWidth` (0 hides the line), `lineStyle` dash and dot, `lineInterpolation`
  (linear, smooth, step before/after), `fillOpacity` with `gradientMode` (see below), `showPoints` and
  `pointSize` (auto shows points when the samples are at least two point sizes apart), `insertNulls` (Grafana's
  null insertion: where samples are further apart than it, or than the time field's interval when it is off, as
  for Prometheus results, the line breaks; fields of one frame that disagree insert nothing, as in Grafana),
  `spanNulls` (true, or a gap in ms up to which the line is joined), `fillBelowTo` (the fill runs down to the
  named series, 35% by default) and the bar options (`barAlignment`, `barWidthFactor`, `barMaxWidth`). Value
  axes are ranged as Grafana ranges them (uPlot's padded range: headroom above the data, a flat zero series on
  the floor of 0..100, soft bounds and whole numbers with decimals 0). Series colors follow Grafana's classic
  palette in Grafana's order: the position counts every number field of the graphable frames, hidden series
  included. A fixed color, and a continuous scheme at the series' `seriesBy` value, color the series and its
  legend swatch in Grafana's color; the thresholds mode uses the step's theme tone, like threshold lines.
- **Time series gradients.** `gradientMode` opacity fades the fill to nothing at the bottom of the plot. `hue`
  colors line and fill from a lighter, hue-shifted top to a darker bottom of the series color (palette, fixed or
  by-value), as Grafana computes them per light and dark theme. `scheme` colors line and fill by value: threshold
  steps (absolute, or percentages of the data range or of the min/max and soft min/max when set) as hard color
  edges in their threshold tones (a transparent step leaves its band unpainted), and the continuous schemes and
  the classic palette spread over that range. With a fixed color or shades, `scheme` draws the plain color, as in
  Grafana. Gradient colors come from a fixed set of classes: Grafana's named colors, their hue variants, the
  classic palette and the continuous schemes match exactly, other colors take the nearest one; other palettes
  (color blind, categorical) draw the plain series color under `scheme`.
- **No data.** A panel whose queries return nothing (or that has no query at all) shows Grafana's no-data text:
  the field defaults' `noValue`, else "No data". Stat, gauge and bar gauge show one placeholder value
  (Grafana's `createNoValuesFieldDisplay`): its text is `noValue`, its color the base threshold step and its
  numeric value 0, never the `noValue` text, so a gauge's bar starts at the minimum (or at the `neutral` value,
  below). A Prometheus target without an expression is not sent, as in Grafana. A table whose frame has fields
  but no rows (say after `filterByValue`) keeps its header over Grafana 13's placeholder: `noValue`, else
  "No rows".
- **Stat.** `colorMode` `background` fills the value's tile with Grafana's gradient of its color (turned and
  darkened per BigValue, lightened in a light theme) and `background_solid` with the plain color, threshold,
  fixed (named or hex) and palette colors alike; named colors take the shade Grafana uses for Tern's current
  theme (dark-blue is #1F60C4 dark, #1250B0 light). Text on the fill is white or near-black by the color's
  brightness, as Grafana picks it. With a fixed color, palette or scheme, `colorMode` `value` draws the value in
  that exact color; threshold colors stay theme tones. A box wider than 2.5 times its height lays name and value
  side by side unless `wideLayout` is off, as in Grafana. Untitled panels have no header line (focus, expand and
  pin work as on any card), and their stats
  show each field's name above the value (`textMode` auto), as Grafana does. Values are drawn at the width of
  Tern's font, so they shrink to a narrow tile instead of being cut, and field names wrap in full; in a
  height-capped card a long name keeps to the lines left above the value. A short card (a 6x3 stat with a
  description, a 2-row stat) still draws its value at least a line tall within the room under its head line (a
  2-row tile drops its padding for it); a sparkline that would leave the value less than a line is left out, as
  Grafana drops the chart from a short stat. A `fixedColor` of `text` is Tern's own text color in both themes.
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
- **Metadata.** A panel description shows as an `i` marker and panel links as chips at the right end of the card's
  head line, as in Grafana's panel header (hover shows the description; the expanded panel shows it in full). Links
  open in the browser pane (variables and `${__url_time_range}` filled in; a path-only link opens on your Grafana).
  Panel titles keep to one line, cut short. Transparent panels have no card background or border.
- **Alert states.** A panel linked to Grafana-managed alert rules (rule annotations `__dashboardUid__` and
  `__panelId__`) shows Grafana's heart after its title: red and broken while a rule fires, yellow while one is
  pending, green otherwise (the most severe linked rule wins). As in Grafana, only while the range ends at `now`.
- **Annotations.** Time series draw the dashboard's enabled annotation layers as Grafana does: dashed lines, region
  fills between two dashed lines and markers under the plot. Grafana's built-in "Annotations & Alerts" layer
  (the dashboard's annotations and the alert state history of linked rules: pending yellow, alerting red, normal
  green) and Prometheus layers (samples above 0, merged into regions by the query step) run natively; layer panel
  filters and the panel's annotation line width and region opacity apply. Other layer types (tags, time regions,
  other datasources) are not drawn.
- **Panels without queries.** Text, dashboard list, annotation list, alert list, news and clock panels in input
  mode never query a datasource. Panel types that read Grafana's API fetch it from the dashboard's Grafana with
  your credentials (the news panel's relative feed URL included); feeds on other hosts are fetched from their own
  URL without credentials.
- **Text panels.** Markdown, HTML and code modes, variables filled in first. HTML is sanitized as Grafana does
  (js-xss's allow list plus iframe and button): allowed tags draw natively (headings, paragraphs, lists, tables,
  emphasis, code, `pre`, rules, links), tags outside the list (script, style, form, custom tags) show as plain
  text with their content, comments and event attributes are dropped, and links keep only http(s), mailto, tel
  and rooted paths, which open on your Grafana. In markdown mode, HTML blocks (a `<div>` wrapper, a lone tag line)
  draw the same way between the Markdown parts and inline tags become Markdown links and emphasis. Images load
  when Tern can fetch them (http(s) or rooted on the Grafana, shown at their natural size) and show their alt text
  otherwise; iframes, videos and audio show as a link to their source. Inline styles keep the declarations
  Grafana's sanitizer allows and draw like dynamic text's (below), over Grafana's body text and headings.
- **Live panels.** Clocks redraw every second on one shared timer, only while they are shown (not inside a
  collapsed row, and only the expanded panel when one is expanded); a redraw never re-runs a query.
- **Transformations.** Tern applies a panel's transformations in order, as Grafana 13 does (disabled ones
  skipped, a `byRefId` filter limiting one to its frames, dashboard variables filled into its options): organize,
  filter fields by name, filter by refId, add field from calculation (`calculateField`: row reductions, binary
  and unary operations, index, cumulative and window functions), join by field (`joinByField`/`seriesToColumns`:
  outer, inner, outer tabular), labels to fields, merge, convert field type (number, string, time, boolean, enum,
  other; time formats parsed like moment), format time, sort by, filter data by values, extract fields (JSON, key
  value pairs, delimiter, regex, auto), reduce, rows to fields, config from query results (`configFromData`:
  min, max, unit, decimals, display name, color, thresholds and value mappings from data), group by (every
  reducer; columns named like `Value (mean)`), limit (a number or a variable), rename by regex (`$1`
  replacements, `/.../g` for every match), series to rows (also an old table panel's "Time series to rows"),
  grouping to matrix (row, column and value fields; empty cells as empty, null, true, false or 0) and prepare
  time series (multi, long and wide, plus the deprecated many). Values follow JavaScript as Grafana's code does:
  in a calculation a null counts as 0 and a gap a join created as NaN. Other transformations (partition by
  values, ...) and filters other than `byRefId` keep the panel on the ladder.

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

### Dynamic text (marcusolsson-dynamictext-panel)

- **Template.** Handlebars 4 without partials: `{{x}}` escaped, `{{{x}}}` raw, comments, `~`, `if`/`else if`/
  `unless`/`each`/`with`, `this`, `../`, `@index`/`@key`/`@first`/`@last`/`@root`, subexpressions and the plugin's
  helpers (and, or, not, eq, unlessEq, gt, gte, lt, lte, contains, startsWith, endsWith, match, join, split,
  toFixed, json, date, variable, variableValue, fieldStatusColor). `match` takes JavaScript regexes without groups
  or lookarounds; others are a template error.
- **Data.** renderMode everyRow (one bordered block per row), allRows (`data`), data (`data` per frame); a field
  with a unit gives its formatted text, others the raw value; `status` adds `statusColor`; a frame without rows
  shows `defaultContent`. Dashboard variables reach the content only through the variable helpers, as in Grafana.
- **HTML and CSS.** markdown-it runs in inline mode when `wrap` is off, block mode otherwise; the result is
  sanitized like the text panel and drawn as elements. Inline `style` attributes compile to classes of
  `plugin/dynamictext.css`: exact colors (hex, rgb/hsl, named, transparent), lengths in px, %, em, rem, vh and vw
  to 0.01 below 10000, layout, flex, alignment, text, border, radius, overflow, z-index, opacity, the first
  box-shadow and linear-gradient with up to 3 stops (stop positions ignored, angle rounded to 5 degrees). Font
  weights round to 50, font families to sans-serif (Inter), serif or monospace; `position: fixed` draws as
  absolute; `fit-content` draws as `max-content` and font-size keywords (`small`, `x-large`, `smaller`, ...) as
  their browser-default px or em ratio, since Tern's stylesheet parser rejects those values. An element holds up
  to 10 lengths and 4 colors. What is not drawn (transforms, filters, `var()`, `calc()`, background images, and
  `text-indent`, `word-spacing` and `table-layout`, which Tern cannot style) is listed under the panel. Text starts
  from Grafana's body (Inter 14px, line height 22/14 as a ratio) and headings from its h1-h6 (size, weight 400,
  line height, 0.45em bottom margin), with inline styles over them; unitless line heights up to 3 are exact, larger
  ones and percentages draw as the element's em. data: images (SVG, PNG, JPEG, GIF, WebP up to 256 KiB) are drawn
  as images; a CSS width or height makes the picture fill that axis of its box (object-fit applies).
- **Panel `styles`.** Plain declarations style the panel; CSS with selectors is skipped and named under the panel
  (its selectors target Grafana's DOM).
- **Panel box.** As in the plugin, the content is a column as tall as the panel body (the card's height cap, or the
  panel's Grafana height when expanded) and scrolls inside it, so a template's `height: 100%` resolves against its
  row.
- **Not native.** `helpers` or `afterRender` JavaScript ("the panel runs its own JavaScript (...)"),
  `contentPartials` and `externalStyles` (templates or stylesheets from URLs) fall back to the Grafana render.

## Datasource plugins

Some datasource plugins do their work in Grafana's frontend (no backend, or results reshaped in the browser).
Tern ports that frontend code (`plugin/lib/datasources/`) and sends the same requests through Grafana, so their
panels and query variables are native.

### JSON API (marcusolsson-json-datasource)

Behavior of the plugin's 1.3.23 frontend, which fetches every target through the datasource proxy and builds the
frame itself:

- **Requests.** `GET` or `POST` (any other method fails with "Invalid method ..."). The URL is the datasource
  proxy path plus `urlPath` (runs of `/` collapsed), then the target's params (non-empty keys, in order, repeats
  allowed) and the datasource's `jsonData.queryParams`, each key and value `encodeURIComponent`'ed and ordered as
  a JavaScript object orders keys (numeric keys first). urlPath, params, headers, body, field names and paths take
  dashboard variables, then the macros `$__unixEpochFrom()`, `$__unixEpochTo()` (epoch seconds), `$__isoFrom()`
  and `$__isoTo()`. A URL with `/..` at the end, `/../`, `/..?` or a tab (after decoding) fails with "URL path
  contains unsafe characters", as in the plugin. Target headers are sent (an `Authorization` header as
  `X-DS-Authorization`, which Grafana's proxy passes on as `Authorization`); the body only with `POST`.
- **Fields.** JSONPath as jsonpath-plus 10.3.0 evaluates it without scripts: dot and bracket names, indexes, `*`,
  `..`, unions, slices (`[-1:]` is the last item; `[-1]` selects nothing), `length` of arrays and strings, `^`,
  `~`, `@string()` and the other type selectors; filters and script expressions fail with the library's "Eval
  [?(expr)] prevented in JSONPath expression." The field type is the one set, else detected as the plugin does:
  ISO 8601 date-times with an offset (`2025-11-09T12:00:00Z`) and `YYYY-MM-DD` dates are time, all numbers number,
  all booleans boolean, anything else (a number field with a null too) string. Time values parse as dayjs does
  (a date or a date-time without an offset is your local time; epoch numbers below 1e12 are seconds); a time
  dayjs cannot parse is empty. Fields of different lengths fail ("Fields have different lengths"). The field name
  is the one set, else the path's last part.
- **Frames.** One frame per target named after its refId, or with `experimentalGroupByField` one frame per value
  of that field (without it, named after the value); the `experimentalMetricField` field is shown under its
  frame's name. One failed target fails the panel (no frames), with Grafana's message: the response's `message`
  or `error`, else its text body, else `Query error: <status> <reason>`; an empty document is "Query returned
  empty data".
- **Variables.** A JSON API query variable runs its query the same way; see [Variables](#variables).
- **Not native.** Fields in the JSONata language (the jsonata library runs in the browser with dashboard
  variables bound) and datasources with browser (direct) access stay on the ladder. `cacheDurationSeconds` is not
  honored: Tern fetches on every refresh, at most every `dashboard.min_refresh`.
- **Secrets.** `jsonData.queryParams` often holds an API key (OpenWeatherMap's `appid`) and is part of every
  request URL. Tern never writes these URLs to logs, saved state or compat output, and removes query strings and
  the queryParams values from every error text.

### Grafana Cloud cardinality (grafanacloud-cardinality-datasource)

Behavior of the plugin's 2.6.1 frontend (the Cardinality management dashboards of Grafana Cloud):

- **Requests.** Every query asks the target Prometheus datasource (`targetDatasource`, a uid or name, usually
  `${datasource}`) through its datasource proxy: Mimir's `api/v1/cardinality/label_names` and `label_values`
  (`count_method=active`, parameters sorted, `label_names[]`), and for list variables `api/v1/label/__name__/values`
  or `api/v1/labels` over the last two hours (start and end rounded up to 15 minutes, limit 200).
- **Queries.** Totals (metrics, label names, series, label value pairs), the metrics and labels top tables, a
  metric's or label's details (with example values when `exampleCount` is set), subtotals, metric usage, and the
  three variable kinds (metric names, label names, a label's values). Combinations the plugin does not handle give
  an empty frame, as in Grafana.
- **Selectors.** The `${filter}` ad hoc filters (once Tern resolves ad hoc variables; nothing until then, as when
  Grafana leaves them unresolved), then the target's `selector` without its outer braces; details and series
  subtotals put `__name__='<metric>'` first.
- **Frames.** Field names, display names and config as the plugin builds them; the percentage columns of the top
  tables carry the legacy `custom.displayMode: gradient-gauge`, drawn as gradient gauge cells.
- **Usage data.** When the cardinality datasource's `unusedMetrics` uses `proxyType: insights` for the target
  datasource, metrics top adds a Used column from its `/unused` list (none when the list is empty or fails;
  "pending" while it is computed), and usage queries read `/usages/<metric>` and then each dashboard's title and
  each Grafana alert rule's group and title (empty for one that no longer exists).
- **Errors.** The plugin's own texts: "No target data source has been selected.", the target "could not be
  found", "is not compatible" (not Prometheus), "does not have a URL", "does not support Cardinality management"
  (the API answers 404), "Usage data only available for the metric instance of this stack", "No data found for
  stack". The first failing target fails the panel, as in Grafana.
- **Differences.** The plugin queues requests per target datasource and caches answers for 15 minutes; Tern sends
  a refresh's distinct requests at once and does not cache. The plugin's `datasources.cardinalityApiServerProxy`
  feature flag (off by default) is not followed.

### Zabbix (alexanderzobnin-zabbix-datasource) and its Problems panel

Behavior of the plugin's 6.10.2 frontend (alexanderzobnin-zabbix-app), which sends metrics to its backend and runs
trigger and problem queries itself against the Zabbix API:

- **Targets.** Every target is migrated to the plugin's schema 13 (old modes, `Metrics`, legacy trigger options and
  tag filters) and its filters, tags, problem tags and function parameters take dashboard variables in the plugin's
  format: values regex-escaped, several as `(a|b)`, item ids comma-joined, and a filter a variable changed that is
  no `/regex/` becomes `/^...$/`. `$__range`, `$__range_ms`, `$__range_s` and `$__range_series` are set as the
  plugin sets them. Hidden targets are not queried.
- **Metrics and item ids.** Sent to `/api/ds/query` as the plugin's frontend sends them; Zabbix functions such as
  `scale` run in the plugin's backend. On the answer, the Alias functions (`setAlias`, `replaceAlias`,
  `setAliasByRegex`, with the series' `$__zbx_host_name`, `$__zbx_item` and other scoped variables) rename the
  series, Zabbix units become Grafana units (`%` is percent with min 0 and max 100, `B` bytes, `Bps` binary bytes
  per second, `b` and `bps` bits, `uptime` a duration, ...), and series whose first two times agree are merged into
  one wide frame, as in Grafana. A failing target shows Grafana's error line, for example "A: request failed,
  status: 500 Internal Server Error" when the Zabbix API behind the backend fails.
- **Trigger counts and problems.** The plugin's Zabbix API calls (`apiinfo.version`, `hostgroup.get`, `host.get`,
  `problem.get`, `trigger.get`, `proxy.get`, `user.get`) go through the datasource's `resources/zabbix-api`
  route, with the parameters the plugin picks for the Zabbix version, and are filtered, joined and counted as it
  does. A trigger count is a frame `Count <refId>`; several targets share one wide frame (the piechart legend
  reads "Count High", ...). A failing call fails the panel with the Zabbix API's message.
- **Problems panel** (alexanderzobnin-zabbix-triggers-panel). Read-only, in table or list layout: the columns the
  panel's options turn on, problems filtered by acknowledgement and severity and sorted as the panel sorts them
  (both targets' problems are listed, so a problem two targets return appears twice, as in Grafana), severity cells
  in the severity color, tags as badges colored by tag name (the badges that do not fit end in an ellipsis), the
  first page of `pageSize` rows. Acknowledging, scripts, problem details, the timeline and paging are left to
  Grafana; `o` opens the dashboard there.
- **Not native.** IT services, text and user macro queries, trigger counts by items, problems with item values at
  problem time (`fetchHistoricalItemValue`), datasources reading history through a direct database connection,
  annotation queries, and Problems panels saved before the panel's React migration stay on the ladder with these
  reasons.
- **Timeouts.** Grafana waits as long as the Zabbix backend takes; Tern stops at the context's `timeout_ms`
  (default 15 s). Raise it for slow Zabbix servers and long ranges.

## Refresh and time range

The range starts at the dashboard's own (`time` in its JSON) unless the link names one. Auto-refresh follows the
dashboard's `refresh` interval but never runs more often than `dashboard.min_refresh` (default 30 s); `a` pauses it.
A refresh re-runs every panel query and re-renders PNG panels. Times are shown and computed in UTC.

Refreshes are frugal with Tern's image cache, which keeps every distinct chart for the session
([performance.md](performance.md)): an answer byte-identical to the last one is not redrawn; time series draw a range
ending at now with its end on the query interval, so a refresh inside one interval draws the same picture; a panel
keeps its previous picture on its own axis while the refresh runs; with a panel expanded, the others are not
refreshed until they are shown again; and while the block's tab is in the background, auto-refresh (and the clock's
redraw) pauses and catches up within a second of the tab being shown.

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
