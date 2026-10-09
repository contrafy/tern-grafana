# Dev stack

A local docker compose stack (`dev/compose.yml`, project `tern-grafana-dev`) with every backend the
plugin talks to, in the versions the plugin supports. It feeds two things: live development and e2e
runs against real servers, and the recorded fixtures in `tests/fixtures/` that unit tests parse.

Needs Docker with the compose v2 plugin, `curl` and `jq`. Nothing is installed on the host.

## Commands

| Command | What it does |
| --- | --- |
| `make stack-up` / `sh scripts/stack.sh up` | Start everything, wait until healthy, mint one Grafana service-account token per Grafana, seed a library panel and two annotations. Idempotent. |
| `make stack-down` / `sh scripts/stack.sh down` | Remove containers, their volumes and the tokens. |
| `sh scripts/stack.sh reset` | `down` then `up`: fresh Grafana databases and TSDBs. |
| `sh scripts/stack.sh status` | Container state, endpoint readiness, firing alert counts per server, log and trace presence. |
| `sh scripts/stack.sh smoke` | Fail unless every Prometheus, Alertmanager and Grafana has a firing alert, dashboards are provisioned, exemplars, logs and traces are queryable and the renderer answers (retries up to `STACK_WAIT_SECS`, default 240). Used by CI after `up`. |
| `make fixtures-capture` / `sh scripts/stack.sh capture` | Record fixtures (see below). |
| `sh scripts/stack.sh token-path grafana12` | Print the token file path (never the token). |
| `make fixtures` / `sh scripts/fixtures/embed.sh` | Embed `tests/fixtures/**` into the gitignored `tests/fixtures/generated.luau` for specs. |

## Services

All published ports bind to `127.0.0.1`.

| Service | Image (pinned) | Host port | Notes |
| --- | --- | --- | --- |
| grafana12 | `grafana/grafana:12.4.12` | 3000 | Uses the image renderer. |
| grafana11 | `grafana/grafana:11.6.16` | 3011 | Deliberately without a renderer, so the "no renderer" path is real. |
| renderer | `grafana/grafana-image-renderer:v5.12.6` | internal 8081 | Grafana 12 only. |
| prometheus3 | `prom/prometheus:v3.15.0` | 9090 | Exemplar storage, remote-write receiver. |
| prometheus2 | `prom/prometheus:v2.53.5` | 9091 | 2.53 LTS, same config and rules as prometheus3. |
| alertmanager | `prom/alertmanager:v0.34.1` | 9093 | Receives from both Prometheus servers and both Grafanas. |
| loki | `grafana/loki:3.7.8` | 3100 | Volume API enabled. |
| tempo | `grafana/tempo:2.10.8` | 3200 | OTLP gRPC/HTTP internal (4317/4318); metrics generator on. |
| node-exporter | `prom/node-exporter:v1.12.1` | internal | Scrape target. |
| loggen | `curlimages/curl:8.22.0` | none | `dev/generators/loggen.sh`: labeled logs every 2 s. |
| tracegen-frontend, tracegen-payments | `ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.162.0` | none | OTLP traces; payments spans carry error status. |
| logcli | `grafana/logcli:3.7.8` | none | Profile `tools`; only used by `capture` via `docker compose run`. |

promtool and amtool run from the prometheus and alertmanager images (`docker compose run --entrypoint`).

### What the data looks like

- Prometheus (both): scrapes itself, node-exporter, alertmanager, loki and tempo (not Grafana: its
  `grafana_authorization_*` metric names would trip the fixture leak check), plus
  job `down` (`node-exporter:9999`, a closed port: always `up == 0`). Rules (`dev/prometheus/rules/`):
  three recording rules; `tern:broken:many_to_many` (`broken.yml`), which loads but fails every evaluation (health
  `err`); alerts `TernAlwaysFiring` (firing), `TernTargetDown` (firing for the down target after 30 s),
  `TernPending` (`for: 24h`, stays pending), `TernInactive` (never fires).
- Exemplars: Tempo's metrics generator turns the generated traces into `traces_spanmetrics_*` and
  `traces_service_graph_*` series and remote-writes them with exemplars (label `traceID`, real trace ids)
  to both Prometheus servers.
- Grafana (both, provisioned identically from `dev/grafana/provisioning`): datasources with fixed uids
  `prom3`, `prom2`, `alertmanager`, `loki`, `tempo` (exemplars link to Tempo, Loki derived field
  `trace_id`, Tempo traces-to-logs/metrics). Folder `Tern Fixtures` (uid `tern-fixtures`) with
  dashboards `tern-panels` (every panel type, open and collapsed rows, a library panel, a Prometheus
  annotation query), `tern-variables` (datasource, chained `label_values` queries, `metrics()`,
  `query_result()`, custom multi-value with All, constant, interval, textbox, a repeated panel and a
  repeated row) and `tern-observability` (exemplars, Loki logs and metrics, Tempo search and trace).
  Folder `Tern Alerts` holds Grafana-managed rules: `TernGrafanaAlwaysFiring` (firing, linked to
  `tern-panels` panel 2), `TernGrafanaTargetDown` (firing), `TernGrafanaPending` (pending),
  `TernGrafanaNormal` (normal). The default policy routes to contact point `dev-alertmanager`, the
  external Alertmanager, with a 1 m repeat interval: Grafana only re-sends on repeat, and the external
  Alertmanager resolves alerts whose `endsAt` passed. `up` seeds library panel `tern-lib-up` and two
  annotations tagged `tern-seed`.
- Loki: job `loggen`, labels `app` (checkout, payments, frontend), `env`, `level` (debug, info, warn,
  error); bodies are logfmt, JSON and access-log shaped.
- Tempo: services `frontend` and `payments` (error status), 3 and 2 child spans.

### Server behavior the fixtures pin down

Observed on the pinned versions; the plugin must handle these, and the fixtures show each one.

- Grafana 11 without a renderer answers `/render/d-solo/...` with HTTP 200 and a PNG that says "No
  image renderer available/installed". Detect the renderer with `rendererAvailable` in
  `/api/frontend/settings` (false on 11 here, true on 12), never from the render status.
- Grafana trace by id through `/api/ds/query` needs `queryType: "traceId"`. TraceQL search through
  `/api/ds/query` works on Grafana 12 and fails with 500 on Grafana 11; the datasource proxy
  (`/api/datasources/proxy/uid/tempo/api/search`) works on both.
- Tempo search may return trace ids without leading zeros (fewer than 32 hex digits); Tempo accepts
  them as given.
- Tempo exemplars carry the trace id in label `traceID`.
- `/api/v1/parse_query` exists on Prometheus 3 and is 404 on 2.53.
- Prometheus rule evaluation errors keep `health: "err"` with the message in `lastError`.
- logcli 3.7.x reports an empty version string (`logcli --version`); its fixture directory uses the
  pinned image tag.

## Credentials (local only)

- Grafana admin: `admin` / `tern-dev` (in `dev/compose.yml`). This is a throwaway password for a
  stack bound to localhost; never reuse it.
- `up` creates service account `tern-dev` (role Admin) in each Grafana and stores one token per Grafana
  in `.sandbox/stack/grafana12.token` / `grafana11.token` (mode 0600, directory 0700, gitignored).
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

### Adding a fixture

1. Add one line to the matching section of `scripts/fixtures/capture.sh`: `get NAME PATH?QUERY`,
   `req NAME METHOD PATH JSON_BODY` (POST/PUT/DELETE), `ds_query NAME QUERIES_JSON` for Grafana
   `/api/ds/query`, or `cli NAME SERVICE ENTRYPOINT ARGS...` for a CLI. URL-encode query values with
   `$(enc '...')`; use `$START`/`$END` (seconds) or `$NS_START`/`$NS_END` (Loki) for ranges.
2. If the fixture needs data the stack does not produce yet, change the generators, rules or
   provisioning under `dev/` and `sh scripts/stack.sh reset`.
3. `sh scripts/stack.sh capture`, then `make fixtures`, and commit the new files and `MANIFEST.tsv`.

Never hand-write a fixture that the stack can produce. A capture replaces each
`<backend>/<version>` directory it records as a whole; other versions stay.

### Upgrading a pinned version

Change the tag in `dev/compose.yml`, `sh scripts/stack.sh reset`, `capture`. The new version lands in
its own directory next to the old one; move specs over, then delete the old directory and its
MANIFEST rows when nothing references them.
