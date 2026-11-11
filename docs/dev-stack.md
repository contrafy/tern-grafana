# Dev stack

A local docker compose stack (`dev/compose.yml`, project `tern-grafana-dev`) with every backend the
plugin talks to, in the versions the plugin supports. It feeds two things: live development and e2e
runs against real servers, and the recorded fixtures in `tests/fixtures/` that unit tests parse.

Needs Docker with the compose v2 plugin, `curl` and `jq`. Nothing is installed on the host.

## Commands

| Command | What it does |
| --- | --- |
| `make stack-up` / `sh scripts/stack.sh up` | Start everything, wait until healthy, mint one Grafana service-account token per Grafana, seed a library panel and two annotations, and on Grafana 13 the schema v2 dashboard. Idempotent. |
| `make stack-down` / `sh scripts/stack.sh down` | Remove containers, their volumes and the tokens. |
| `sh scripts/stack.sh reset` | `down` then `up`: fresh Grafana databases and TSDBs. |
| `sh scripts/stack.sh status` | Container state, endpoint readiness, firing alert counts per server, log and trace presence. |
| `sh scripts/stack.sh smoke` | Fail unless every Prometheus, Alertmanager and Grafana has a firing alert, dashboards are provisioned, exemplars, logs and traces are queryable and the renderer answers (retries up to `STACK_WAIT_SECS`, default 240). Used by CI after `up`. |
| `make fixtures-capture` / `sh scripts/stack.sh capture` | Record fixtures (see below). |
| `sh scripts/stack.sh zabbix` | Start the opt-in Zabbix 7.0 profile and seed it with `dev/zabbix/bootstrap.sh` (idempotent; `down` removes it too). |
| `sh scripts/stack.sh token-path grafana12` | Print the token file path (never the token). |
| `make fixtures` / `sh scripts/fixtures/embed.sh` | Embed `tests/fixtures/**` into the gitignored `tests/fixtures/generated.luau` for specs. |
| `python3 scripts/fake-irm/server.py [PORT] [UPSTREAM]` | A fake Grafana IRM (default `127.0.0.1:13900`) serving the scrubbed `tests/fixtures/irm/` captures, dates moved to today, on the IRM paths (settings, OnCall `/oncall/api/v1/*`, Incident RPCs); every other request is proxied to UPSTREAM (default Grafana 12). |
| | Point a context's `grafana.url` at it with the grafana12 token for IRM screenshots and manual checks; it refuses writes. |

## Services

All published ports bind to `127.0.0.1`.

| Service | Image (pinned) | Host port | Notes |
| --- | --- | --- | --- |
| grafana12 | `grafana/grafana:12.4.12` | 3000 | Uses the image renderer. Feature toggle `newGauge` on (the 12.4 gauge: shape, segments, sparkline, effects). |
| grafana11 | `grafana/grafana:11.6.16` | 3011 | Deliberately without a renderer, so the "no renderer" path is real. |
| grafana13 | `grafana/grafana:13.3.1` (digest pinned) | 3013 | Uses the image renderer (with a local renderer token: 13 refuses the default one). New gauge and new dashboard layouts are on by default; feature toggle `table.autoColumnWidths` on (Grafana Cloud sizes table columns to their content). The latest stable 13.x (no 13.4 image is published yet; see "Grafana 13.4" below). |
| renderer | `grafana/grafana-image-renderer:v5.12.7` | internal 8081 | Grafana 12 and 13; accepts the default token (12) and `tern-dev-renderer` (13). |
| prometheus3 | `quay.io/prometheus/prometheus:v3.15.0` | 9090 | Exemplar storage, remote-write receiver. |
| prometheus2 | `quay.io/prometheus/prometheus:v2.53.5` | 9091 | 2.53 LTS, same config and rules as prometheus3. |
| alertmanager | `quay.io/prometheus/alertmanager:v0.34.1` | 9093 | Receives from both Prometheus servers and every Grafana. |
| loki | `grafana/loki:3.7.8` | 3100 | Volume API enabled. |
| tempo | `grafana/tempo:3.1.1` | 3200 | Single binary (live store, backend worker; no ingester or compactor in 3.x); OTLP gRPC/HTTP internal (4317/4318); metrics generator on. |
| node-exporter | `quay.io/prometheus/node-exporter:v1.12.1` | internal | Scrape target. |
| postgres | `postgres:17.6-alpine` | internal 5432 | Seeded once from `dev/postgres/init.sql`; datasource `postgres` in every Grafana. |
| loggen | `quay.io/curl/curl:8.23.0` | none | `dev/generators/loggen.sh`: labeled logs every 2 s, plus one line per recent Tempo trace every 10 s. |
| tracegen-frontend, tracegen-payments | `ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.163.0` | none | OTLP traces; payments spans carry error status. |
| logcli | `grafana/logcli:3.7.8` | none | Profile `tools`; only used by `capture` via `docker compose run`. |
| jsonapi | `busybox:1.37.0-musl` (digest pinned) | internal 8080 | Static OpenWeatherMap-like documents from `dev/json/` for the JSON API datasources. |
| zabbix-server, zabbix-web, zabbix-agent | `zabbix/zabbix-{server-pgsql,web-nginx-pgsql,agent2}:alpine-7.0.32` (digests pinned) | web 18080 | Profile `zabbix`, opt-in: `sh scripts/stack.sh zabbix`. Database `zabbix` in the postgres service (created by the server image on first start). Admin / `zabbix`. |

promtool and amtool run from the prometheus and alertmanager images (`docker compose run --entrypoint`).

All three Grafanas install these pinned plugins at container start (`GF_INSTALL_PLUGINS`, so the first
start needs network): `grafana-clock-panel` 2.1.8, `marcusolsson-json-datasource` 1.3.23,
`marcusolsson-treemap-panel` 2.1.1 and `alexanderzobnin-zabbix-app` 6.10.2 (enabled by
`dev/grafana/provisioning/plugins/apps.yml`; bundles the Zabbix datasource and triggers panel).
`marcusolsson-dynamictext-panel` 6.3.1 is installed on Grafana 12 and 13 only: it requires Grafana
>= 12.3.0, so on Grafana 11 the dynamictext panels show "panel plugin not found". They also serve
`dev/grafana/news/feed.xml` same-origin at `/public/tern-news/feed.xml` for the news panel (no extra
container, no CORS).

Changing `GF_INSTALL_PLUGINS` recreates the Grafana containers, which wipes their databases: run
`sh scripts/stack.sh up` afterwards to re-mint the tokens and reseed.

### Section 4 datasources and dashboards

- JSON API: datasources `json-dallas`, `json-chicago`, `json-seattle` (`marcusolsson-json-datasource`,
  url `http://jsonapi:8080/data/2.5/weather-<city>.json`) and `json-api` (url `http://jsonapi:8080/data/2.5`,
  documents picked by urlPath: `weather-<city>.json`, `forecast.json`, `cities.json`). Each carries a fake
  `appid=tern-fake-appid-0123456789abcdef` (plus `lat`, `lon`, `units`) in non-secure
  `jsonData.queryParams`, the way the real API key sits there, so redaction of proxy URLs, errors and
  fixtures is exercised (httpd ignores the query string; the capture scrubs the appid to
  `redacted-appid`). Dashboard `tern-s4-json` (absolute range 2025-11-09 09:00 to 2025-11-10 00:00 UTC,
  query variable `city` from `cities.json` with text and value fields): 1-3 temperature gauges
  (`$.main.temp`, GET, empty urlPath), 4 a humidity gauge with a named field, 5 a stat on
  `/weather-${city}.json`, 6 a time series grouped by city (`experimentalGroupByField`, metric field,
  params with the epoch and ISO macros), 7 a table with an epoch-seconds time field, 8 a missing document
  (busybox's 404 page as the error). Fixtures `s4_json_*` (`capture_json_api`).
- Dashboard `tern-s4-dynamictext` (TestData CSV): 1 HTML editor, everyRow, `{{#if}}`/`{{else}}`,
  `{{{triple}}}` and data-URI SVG `<img>`; 2 markdown editor with `{{{review_rows}}}` HTML from the
  query and a `formatTime` transformation; 3 three stat cards with bars from 16 fields; 4 renderMode
  data with `afterRender` JavaScript, `externalStyles` and `styles` (stays on the ladder); 5 a count card
  (54px counts with `line-height:1`, a pill) and a rating trend row; 6 an alert card with 42px and 28px
  titles at `line-height` .9 and 1.02.
- Dashboard `tern-s4-treemap`: 1 TestData label cardinality (squarify, percentage thresholds, data
  links like the cardinality details treemap); 2 Prometheus instant table `count by (__name__)`;
  3 binary tiling grouped by a field.
- Zabbix: datasource `zabbix` (`alexanderzobnin-zabbix-datasource`, user login Admin) errors until the
  `zabbix` profile runs. `sh scripts/stack.sh zabbix` starts it and runs `dev/zabbix/bootstrap.sh`
  (idempotent, API at 127.0.0.1:18080): disables the image's own "Zabbix server" host, creates host
  group "Netbox Hosts", hosts `nni-edge-dfw` and `nni-edge-ord` polling the agent container with items
  `Interface eth0(NNI-ACME-<site>: ...): Bits received|sent` (bps, tag `description: NNI-ACME-...`),
  `CPU utilization` (%) and `Memory used` (B), four always-true triggers (severities 2..5, the two
  highest tagged `Priority: 1`) and acknowledges the warning problem. Dashboard `tern-s4-zabbix`
  (variable `DS_ZABBIX`): two transit timeseries (received, sent with `scale(-1)`, stacked, legend
  p95/max), CPU and memory panels for unit conversion, stat "Unacknowledged Problems" (triggers count,
  minSeverity 2, unacknowledged), piechart of six per-severity triggers counts, and the triggers
  (problems) panel with a `Priority:1` tag filter.
- Cardinality (`grafanacloud-cardinality-datasource`) is Grafana Cloud only; it has no dev install.

### What the data looks like

- Prometheus (both): scrapes itself, node-exporter, alertmanager, loki and tempo (not Grafana: its
  `grafana_authorization_*` metric names would trip the fixture leak check), plus
  job `down` (`node-exporter:9999`, a closed port: always `up == 0`). Rules (`dev/prometheus/rules/`):
  three recording rules; `tern:broken:many_to_many` (`broken.yml`), which loads but fails every evaluation (health
  `err`); alerts `TernAlwaysFiring` (firing), `TernTargetDown` (firing for the down target after 30 s),
  `TernPending` (`for: 8760h`, stays pending even on a stack that runs for days), `TernInactive` (never fires).
- Exemplars: Tempo's metrics generator turns the generated traces into `traces_spanmetrics_*` and
  `traces_service_graph_*` series and remote-writes them with exemplars (label `traceID`, real trace ids)
  to both Prometheus servers.
- Grafana (all three, provisioned identically from `dev/grafana/provisioning`): datasources with fixed uids
  `prom3`, `prom2`, `alertmanager`, `loki`, `tempo` (exemplars link to Tempo, Loki derived field
  `trace_id`, Tempo traces-to-logs/metrics). Folder `Tern Fixtures` (uid `tern-fixtures`) with
  dashboards `tern-panels` (every panel type, open and collapsed rows, a library panel, a Prometheus
  annotation query), `tern-variables` (datasource, chained `label_values` queries, `metrics()`,
  `query_result()`, custom multi-value with All, constant, interval, textbox, a repeated panel and a
  repeated row), `tern-observability` (exemplars, Loki logs and metrics, Tempo search and trace) and
  `tern-text-html` (text panels with inline HTML, HTML blocks in Markdown and HTML mode, as real dashboards
  write them).
  Datasource `testdata` (TestData) gives deterministic frames.
  Folder `Tern Alerts` holds Grafana-managed rules: `TernGrafanaAlwaysFiring` (firing, linked to
  `tern-panels` panel 2), `TernGrafanaTargetDown` (firing), `TernGrafanaPending` (pending),
  `TernGrafanaNormal` (normal). The default policy routes to contact point `dev-alertmanager`, the
  external Alertmanager, with a 1 m repeat interval: Grafana only re-sends on repeat, and the external
  Alertmanager resolves alerts whose `endsAt` passed. `up` seeds library panel `tern-lib-up`, two
  annotations tagged `tern-seed`, a third on `tern-all-panels` panel 1, and stars `tern-all-panels`
  for the service account. On Grafanas that store schema v2 dashboards (13), `up` also creates
  `dev/grafana/dashboards-v2/tern-v2-layouts.json` through `/apis/dashboard.grafana.app/v2`: tabs, an
  auto grid, an open and a collapsed row (file provisioning would hand it to 11 and 12 too).
- Dashboard `tern-all-panels` (`dev/grafana/dashboards/tern-all-panels.json`): one panel per core panel
  type plus the clock panel, with the configuration variants the native renderers must honor. Panel ids:

  | Ids | Panels |
  | --- | --- |
  | 1-4 | timeseries: description + links; `timeFrom` 30m + `timeShift` 1h; hidden `timeFrom` 2h + `maxDataPoints` 50 + `interval` 2m; `transparent` |
  | 5-6 | stat; stat with `noValue` on an empty result |
  | 7-10 | gauge on data; gauges with no targets and `noValue` "6" / "0" (12.4 options, neutral outside the range in 9); 12.4 segmented gauge with sparkline |
  | 11-12 | bargauge; bargauge with `noValue` |
  | 13-14 | table (links, cell coloring, organize transform); table with `noValue` (TestData `no_data_points`) |
  | 15-21 | text, logs (Loki), piechart, barchart, histogram, trend, xychart |
  | 22-25 | candlestick (OHLC + volume from Prometheus), heatmap (buckets), state-timeline, status-history |
  | 26-28 | flamegraph (TestData CSV nested set), traces (Tempo trace id from textbox variable `trace_id`), nodeGraph (CSV `nodes`/`edges` refIds) |
  | 29-34 | alertlist, annolist, dashlist, news, geomap, canvas |
  | 35-36 | legacy `graph` and `singlestat` (Grafana migrates them to timeseries/stat on load) |
  | 37-41 | clock: time 24 h Berlin; countdown to 2099-12-31 (input); countup since 2020-01-01; countdown from a query (`minFuture`); custom 12 h format, New York |
- Loki: job `loggen`, labels `app` (checkout, payments, frontend), `env`, `level` (debug, info, warn,
  error); bodies are logfmt, JSON and access-log shaped. Their `trace_id` values are random and do
  not exist in Tempo.
- Loki, correlated with Tempo: every 10 s loggen searches Tempo for traces from the last 2 minutes
  (the 5 most recent, plus up to 2 from `payments`) and pushes one line per trace, each trace once, to
  `{job="tracegen", service_name="<root service>", level="info"|"error"}`: `level=info msg="handled
  request" trace_id=<id> service=<svc>`. Payments traces get `level=error`. Every `trace_id` here
  resolves in Tempo (`/api/traces/<id>`), and Grafana's Loki derived field links it to the trace.
- Tempo: services `frontend` and `payments` (error status), 3 and 2 child spans.
- PostgreSQL (datasource uid `postgres`, type `grafana-postgresql-datasource`): table `services` (four
  rows: name, team, region, replicas, error_rate) and view `service_load` (per-minute `rps` per service
  over the last day, computed at query time, deterministic per minute). Dashboard `tern-sql`
  (`dev/grafana/dashboards/tern-sql.json`), with multi-value custom variables `service` and `team` and
  textbox `region`: 1 timeseries in `time_series` format (the backend turns the long rows wide), 2
  timeseries on a wide table, 3 stat per team (`IN ($team)`, `'$region'`), 4 table with an organize
  transform, 5 stat of a server-side math expression over a hidden SQL query, 6 `-- Dashboard --` table
  reusing panel 4 with its transformations, 7 timeseries on a long table (Grafana draws one zigzag
  series: its timeseries panel does not convert long to wide). Fixtures `ds_query_sql_<panel>` hold the
  request Grafana's frontend sends for each panel (written out in `capture_sql`).
  Adding it to a running stack without recreating the Grafanas: `docker compose -f dev/compose.yml up
  -d --wait --no-deps postgres`, then `POST /api/admin/provisioning/datasources/reload` and
  `.../dashboards/reload` on each Grafana.
- Dashboard `tern-cells` (`dev/grafana/dashboards/tern-cells.json`), TestData CSV tables for the table
  cell types: 1 battery status (the user dashboards' pattern: percentunit 0..1 gradient and basic gauge
  overrides, color-background by mapping), 2 gauge modes (gradient with valueDisplayMode color by default,
  lcd, hidden, continuous-GrYlRd), 3 pill, markdown, json-view, color-text and an applyToRow
  color-background, 4 the user's MDU battery table (a percentunit gauge column between long text
  columns), 5 and 6 a table a `filterByValue` leaves with fields and no rows (6 with `noValue`), 7 and 8
  Prometheus `node_load1` for 5 minutes in every 10 (time series: 7 breaks at the gaps, the time field's
  interval; 8 joins them, `insertNulls` 15m). Fixtures `ds_query_cells_<panel>` (`capture_cells`).
- Dashboard `tern-stat-fidelity` (`dev/grafana/dashboards/tern-stat-fidelity.json`), stat panels over
  constant PromQL (`vector(...)`) reproducing the user dashboards' patterns: untitled stats with fixed
  colors (green, dark-blue, blue, purple, dark-purple) in `background`/`background_solid`, explicit text
  sizes, two long-named values side by side, "40239" and "$0" in narrow cards, a light fixed color (dark
  text), a hex color, a fixed color in `colorMode` value and three threshold-colored values with long
  names; and short stats with a description: a 6x3 one over a TestData number without time (Grafana
  Cloud's cardinality tiles), a 6x4 one with a link and a sparkline, an untitled 12x4 named one.
  Fixtures `ds_query_stat_fidelity_<panel>` (`capture_stat_fidelity`).

### Server behavior the fixtures pin down

Observed on the pinned versions; the plugin must handle these, and the fixtures show each one.

- Grafana 11 without a renderer answers `/render/d-solo/...` with HTTP 200 and a PNG that says "No
  image renderer available/installed". Detect the renderer with `rendererAvailable` in
  `/api/frontend/settings` (false on 11 here, true on 12 and 13), never from the render status.
- Grafana trace by id through `/api/ds/query` needs `queryType: "traceId"`. TraceQL search through
  `/api/ds/query` works on Grafana 12 and 13 and fails with 500 on Grafana 11; the datasource proxy
  (`/api/datasources/proxy/uid/tempo/api/search`) works on all three.
- Grafana 13 stores dashboards saved with its new layouts as schema v2, and `/api/dashboards/uid/<uid>`
  still answers schema v1 for them: tabs and rows become rows in reading order, auto-grid panels get
  a `gridPos`, a collapsed row keeps its panels (`dashboard_tern_v2_layouts` next to the stored
  `dashboard_v2_tern_v2_layouts`). `meta.apiVersion` says `v0alpha1` either way.
- Grafana 13.3 drops the `newGauge` toggle from `featureToggles`: its gauge panel always draws the
  radial gauge, with the same options, defaults and migration as 12.4's toggled one. Grafana Cloud's
  13.4 lists it again (`newGauge: true`), which reads the same.
- Grafana 13.4 (no image is published yet; compared read-only against a Grafana Cloud stack on
  13.4.0) answers every API the plugin reads with the 13.3 shapes: frontend settings (datasources,
  `buildInfo`, `rendererAvailable`), `/api/search`, `/api/dashboards/uid` (schema v1 view of schema
  v2 dashboards, `meta.apiVersion` `v0alpha1`), `/api/ds/query` frames (Mimir adds
  `schema.meta.stats`), the Prometheus-style and Alertmanager alerting APIs, silences, annotations
  and the render API. Alert state-history annotations there carry `alertUID` and no `id` or `tags`.
- Tempo 3.1 answers the HTTP API like 2.10 (search, tags v1 and v2, trace v1 and v2 envelopes,
  TraceQL metrics, the empty-bodied 404 for a missing trace); only the order of scopes in
  `/api/v2/search/tags` differs.
- Tempo search may return trace ids without leading zeros (fewer than 32 hex digits); Tempo accepts
  them as given.
- Tempo exemplars carry the trace id in label `traceID`.
- `/api/v1/parse_query` exists on Prometheus 3 and is 404 on 2.53.
- Prometheus rule evaluation errors keep `health: "err"` with the message in `lastError`.
- TestData's `node_graph`, `trace`, `flame_graph` and `raw_frame` scenarios run in the browser only:
  `/api/ds/query` answers 500 for them. `tern-all-panels` uses `csv_content`, `random_walk` and
  `no_data_points`, which the backend serves, and real Tempo for the traces panel.
- A panel with an empty Prometheus/Loki expression (or no targets) sends no query; Grafana still
  draws it from `fieldConfig.defaults.noValue`.
- The Grafana 12 renderer leaves the traces panel loading (blank PNG) although the trace query
  succeeds; every other `tern-all-panels` panel renders.
- logcli 3.7.x reports an empty version string (`logcli --version`); its fixture directory uses the
  pinned image tag.

## Public dashboards

`scripts/public-dashboards.py` brings widely used public dashboards onto the dev Grafanas, to check the
Dashboard and Compatibility blocks against real-world JSON. They are fetched, never committed: their licenses
belong to their authors.

```sh
python3 scripts/public-dashboards.py fetch              # download into dev/grafana/public/ (gitignored)
python3 scripts/public-dashboards.py import [GRAFANA..] # into folder "Public" (uid public); default all three
python3 scripts/public-dashboards.py remove [GRAFANA..] # delete that folder again
```

- Sources are pinned in the script: grafana.com dashboards by revision (Node Exporter Full 1860, Node
  Exporter EN 11074, Prometheus 2.0 Overview 3662, cAdvisor 14282, Docker 193, Kubernetes 315, 13332,
  15761, Loki/logs 13639, 12611, 17781, Blackbox 7587, Alertmanager 9578, Grafana Internals 3590, Redis 763,
  PostgreSQL 9628, MySQL 7362, OpenTelemetry & Tempo 23242), the monitoring-mixins site by commit
  (kubernetes compute resources cluster/namespace/pod and API server, node-exporter, Prometheus,
  Alertmanager, Grafana, Loki) and tags of grafana/tempo (Tempo reads/writes) and grafana/grafana (devenv
  panel test dashboards on TestData).
- `fetch` rewrites what Grafana's import dialog would ask for: `${DS_*}` datasource inputs become the dev
  datasources (Prometheus 3, Loki, Tempo, Alertmanager, TestData, PostgreSQL), constant inputs take their
  default (a constant naming a datasource type becomes its dev uid), datasource variables select the dev
  datasource, and every dashboard gets the uid `pub-<file>`. Datasources the stack lacks (MySQL, Redis,
  ...) stay unresolved, as on a Grafana without them.
- `import` goes through the API (`POST /api/dashboards/db`), not file provisioning, so the Grafana
  containers need no extra mount. The dashboards live in the Grafana database: recreating a container drops
  them; rerun `import`.
- The e2e dashboard scenario searches the picker for "Tern " (every provisioned title starts with it, no public
  one does), so it passes with or without them. Fixture capture (`scripts/fixtures/capture.sh`) refuses to
  install a new or refreshed fixture that contains the Public folder (`"uid":"public"` or `"folderUid":"public"`,
  e.g. search and folder captures): run `remove` first, then `import` again after capturing.
- Legacy dashboards (schemaVersion below 16, top-level `rows`) are stored as uploaded; Grafana migrates them
  when it loads them (12 and 13 in the backend: `/apis/dashboard.grafana.app/v1beta1/...` answers the migrated
  model), and so does the plugin. `tern-legacy` reproduces one; capture records Grafana's migration of it
  (`dashboard_v1beta1_tern_legacy`, 12+) and its panels' queries.
- What they exposed is pinned by synthetic dashboards in `dev/grafana/dashboards/` (provisioned and captured
  like the others, so their fixtures are committed): `tern-pub-chrome` (schemaVersion 18 shape: annotation
  layers by `$ds` and by datasource name, horizontally repeated panels, links, a stat without data, a query
  error), `tern-pub-vars` (Prometheus series-query variables with a regex, Loki `label_values` variables with
  string, object and by-name datasources, a Loki logs panel, a text panel with an unresolved datasource;
  fixtures `ds_proxy_prom_series*`, `ds_proxy_loki_labels`, `ds_proxy_loki_label_values_*`),
  `tern-pub-gauges` (small bar gauges, two-row stats, a 13.0 gauge, stat sparklines over a series with gaps, on
  a 3-row stat and in a fixed color; `ds_query_pub_gauges_<panel>` from
  `capture_pub_gauges`), `tern-pub-ts` (five Prometheus time series and two tables, one on a TestData CSV;
  `ds_query_pub_ts_<panel>` from `capture_pub_ts`), `tern-pub-frames` (a calculateField saved with empty
  options, a query without series, table targets saved without a refId; `ds_query_pub_frames_<panel>` from
  `capture_pub_frames`) and `tern-legacy` (schemaVersion 14 with top-level rows, singlestat, graph and the
  old table).

## Credentials (local only)

- Grafana admin: `admin` / `tern-dev` (in `dev/compose.yml`). This is a throwaway password for a
  stack bound to localhost; never reuse it.
- `up` creates service account `tern-dev` (role Admin) in each Grafana and stores one token per Grafana
  in `.sandbox/stack/grafana12.token`, `grafana11.token` and `grafana13.token` (mode 0600, directory 0700, gitignored).
  Tokens are never printed; scripts hand them to curl on stdin (`curl -K -`), never as arguments.
  A lost or stale token file is replaced on the next `up`; `down` deletes them.
- Prometheus, Alertmanager, Loki and Tempo run without auth.
- State: containers keep data in their own volumes, removed by `down`. Nothing is written to the
  host outside `.sandbox/stack/` (and `dev/.data/` is reserved and gitignored for local state).

## Fixtures

`capture` waits until the stack shows the states worth recording (at least 5 minutes of Prometheus
history, firing and pending alerts, a failing rule, exemplars, logs and traces), then records:

```
tests/fixtures/<backend>/<version>/<name>.<ext>            response body; ext from Content-Type
tests/fixtures/<backend>/<version>/<name>.request.json     request body of POST captures
tests/fixtures/<backend>/<version>/<name>.txt / .stderr    CLI stdout / stderr (stderr only if non-empty)
tests/fixtures/MANIFEST.tsv                                one row per capture
```

`<backend>` is `prometheus`, `grafana`, `alertmanager`, `loki`, `tempo`, `promtool`, `amtool` or
`logcli`; `<version>` is what the server or CLI reports (without a leading `v`). MANIFEST columns:
`path`, `method` (`CLI` for tools), `url` (path and query as sent, or the CLI argv), `status` (HTTP
status or exit code), `captured_at` (UTC), `server_version`, `request` (request body file or `-`).

Bodies are stored as received (not reformatted), so specs parse exactly what the servers send. Error
responses are captured on purpose (for example Prometheus `query_error_parse` 400 and
`query_error_exec` 422, Grafana 11 `render_d_solo` without a renderer). Times are relative to the
capture, so specs must not assume fixed timestamps.

Secrets: before anything is written to `tests/fixtures`, bodies are scrubbed of `glsa_` tokens and
the run aborts if any token value, `authorization`, `bearer `, `set-cookie` or `grafana_session`
string remains. Prometheus drops Grafana's `grafana_authorization_*` metric families at scrape time
for the same reason. Check by hand with `grep -ri 'glsa_\|authorization\|bearer ' tests/fixtures`.

Specs read fixtures through `tests/lib/fixtures.luau` (`Fixtures.read(path)`, `Fixtures.list(prefix)`,
`Fixtures.has(path)`) after `make fixtures`.

### tern-all-panels fixtures

Per Grafana version, next to the generic ones: `dashboard_tern_all_panels.json`,
`frontend_settings_all_panels.json` (TestData, clock panel, and `newGauge` on 12; 13 has it built in),
`plugin_clock_panel.json`, `ds_query_all_panels_<panelId>.json` with its `.request.json` for every
panel that queries, `search_starred`, `search_recent`, `search_tag`, `search_query_tag`,
`annotations_annolist`, `annotations_annolist_dashboard`, `annotations_annolist_range`,
`alertlist_rules` and `news_feed.xml`. The request bodies come from `scripts/fixtures/panel_query.jq`,
which builds what Grafana's frontend sends: dashboard range with the panel's `timeFrom`/`timeShift`
applied as absolute epoch-ms strings, `maxDataPoints` from the panel or its width (gridPos.w * 80 px),
`intervalMs` from Grafana's `calculateInterval` with the panel `interval` or the datasource minimum
as the low limit, and `${trace_id}` set to a real Tempo trace.

### Adding a fixture

1. Add one line to the matching section of `scripts/fixtures/capture.sh`: `get NAME PATH?QUERY`,
   `req NAME METHOD PATH JSON_BODY` (POST/PUT/DELETE), `ds_query NAME QUERIES_JSON` for Grafana
   `/api/ds/query`, or `cli NAME SERVICE ENTRYPOINT ARGS...` for a CLI. URL-encode query values with
   `$(enc '...')`; use `$START`/`$END` (seconds) or `$NS_START`/`$NS_END` (Loki) for ranges.
2. If the fixture needs data the stack does not produce yet, change the generators, rules or
   provisioning under `dev/` and `sh scripts/stack.sh reset`.
3. `sh scripts/stack.sh capture`, then `make fixtures`, and commit the new files and `MANIFEST.tsv`.

Never hand-write a fixture that the stack can produce.

A plain `capture` never overwrites anything: it installs only fixtures whose file does not exist
yet (with their `.request.*` and `.stderr` companions) and adds their MANIFEST rows. Existing files
and rows stay byte-for-byte, because specs assert on their exact values. To re-record on purpose,
run `sh scripts/stack.sh capture --refresh 'PATTERN'`, where PATTERN is a shell glob over paths
relative to `tests/fixtures` (for example `'prometheus/3.15.0/query_range_*'`; with no pattern,
everything is refreshed). Then run `make fixtures test` and fix any spec that depended on the old
values.

### Upgrading a pinned version

Change the tag in `dev/compose.yml`, `sh scripts/stack.sh reset`, `capture`. The new version lands in
its own directory next to the old one (all new files, so a plain `capture` writes it); move specs
over, then delete the old directory and its MANIFEST rows when nothing references them.
