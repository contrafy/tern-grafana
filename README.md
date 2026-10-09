# tern-grafana

**Tern Grafana** brings Grafana and Prometheus-compatible backends into
[Tern](https://stencil.so/tern) as native blocks: queries, dashboards,
alerts and silences rendered in the terminal, next to the commands that
changed them.

> Pre-release, in development. The foundation (M0) and query core (M1)
> milestones have landed; the [Roadmap](#roadmap) shows what is planned and what has landed.

## Why

Incidents start in the terminal: a deploy, a `kubectl apply`, a failing
command. Switching to a browser to check a graph, read an alert or add a
silence breaks that flow. tern-grafana aims to answer "what is it doing now?"
without leaving Tern, and to fall back to Grafana itself whenever a native view
cannot be faithful.

Planned design:

- **Two data planes, one model.** Talk to Grafana (`/api/ds/query`,
  datasource proxy, dashboards, alerting APIs) or directly to Prometheus-compatible
  servers, Alertmanager, Loki and Tempo. Both normalize to the same frame model.
- **Rendering ladder per panel.** Native view first; then a PNG from Grafana's
  image renderer when it is available; then the panel opened in a Tern browser pane.
- **Writes are explicit.** Creating or expiring silences and posting annotations
  are always previewed and confirmed.

## Compatibility

| Backend | Versions |
| --- | --- |
| Grafana | 11, 12 |
| Prometheus | 2.53 LTS, 3.x |
| Alertmanager | 0.27+ |
| Loki | 3.x |
| Tempo | 2.x |

Prometheus-compatible query APIs (Thanos, Mimir, Cortex, VictoriaMetrics) are
supported through the same Prometheus HTTP API, including tenant headers such as
`X-Scope-OrgID`.

## Install

```sh
tern plugin install github.com/contrafy/tern-grafana
```

For development, link a local checkout instead (see [CONTRIBUTING.md](CONTRIBUTING.md)):

```sh
tern plugin link /path/to/tern-grafana
```

## Credentials

Each context (a Grafana instance or a direct backend) resolves its credential
at request time from one of:

- `token_cmd`: an argv run without a shell, for example
  `["op", "read", "op://vault/grafana/token"]` or
  `["security", "find-generic-password", "-s", "grafana", "-w"]`;
- an environment variable;
- a file readable only by you (mode `0600`).

Auth can be a bearer token, basic auth, and extra headers. The plugin never
writes a credential to disk, Tern's key-value store, logs, block arguments or
saved state, and only talks to the URLs you configure. See
[SECURITY.md](SECURITY.md).

## Usage

What works today (M1):

1. **Configure a context.** Write `~/.config/tern-grafana/config.json` (see
   [Configuration](docs/configuration.md)), or open the Settings block from the
   palette with "Grafana: Settings" to edit it safely and test each endpoint
   ([Settings block](docs/settings.md)).

   ![Settings block testing endpoints](docs/screenshots/m1-settings-tests.png)

2. **Query.** "Grafana: Query" in the palette opens the Query block: a PromQL
   scratchpad with metric and label autocomplete, rendered natively as a time
   series graph or a table. Main keys: `g` / `t` graph or table, `left` / `right`
   move the cursor (the legend shows the values under it), `[` / `]` shift and
   `-` / `+` zoom the range, `1`..`9` pick a "last N" range, `a` auto-refresh,
   `h` history, `o` open in Grafana Explore. See [Query block](docs/query.md).

   ![Query block graph](docs/screenshots/m1-query-graph.png)
   ![Query block cursor read-out](docs/screenshots/m1-query-cursor.png)
   ![Query block table view](docs/screenshots/m1-query-table.png)

3. **Grafana links.** Clicking a Grafana Explore link under a configured Grafana
   base URL opens the query in the Query block. Dashboard, panel and alert links
   open in a Tern browser pane until the native dashboard block lands (M2).

4. **promtool lens.** Running `promtool query instant|range ...` renders the
   result as a native graph or table.

   ![promtool query lens](docs/screenshots/m1-promtool-lens.png)

## Roadmap

M0 (foundation: tooling, CI, docs, docker dev stack, recorded fixtures, SDK
capability spike) and M1 (query core) have landed.

| Milestone | ID | Feature | Status |
| --- | --- | --- | --- |
| M1 | A1 | Contexts, config and auth (token_cmd/env/file, bearer/basic/headers, tenant header) | landed (M1) |
| M1 | A2 | Settings block to edit config safely | landed (M1) |
| M1 | A3 | Transport: `tern.fetch`, with `curl` fallback for mTLS, custom CA and insecure TLS | landed (M1) |
| M1 | A4 | Grafana unit ids, value formatting, thresholds to Tern tones | landed (M1) |
| M1 | A5 | Time range and step math (`now-6h`, `$__interval`, `$__rate_interval`, `$__range`, LTTB downsampling) | landed (M1) |
| M1 | B1 | Query block: PromQL scratchpad, autocomplete, range picker, native time series, keyboard cursor, table/instant view, history | landed (M1) |
| M1 | B5 | Grafana URL routing (`/d/`, `/d-solo/`, `/explore`) with browser pane fallback | landed (M1) |
| M1 | E1 | Lens: `promtool query instant\|range` to native graph/table | landed (M1) |
| M2 | B2 | Dashboard block: search, load, grid layout, variables, refresh, native panels, per-panel fallback ladder | planned |
| M2 | B3 | Pin one panel as its own small block | planned |
| M2 | C1 | Alerts inbox: Grafana unified alerting and Alertmanager v2, grouping, runbook/dashboard links | planned |
| M2 | C2 | Status-line segment: firing counts per context, tone by severity | planned |
| M3 | C3 | Toasts on newly firing alerts (opt-in, deduped) | planned |
| M3 | C4 | Silences: create from alert with preview and confirm, list, expire | planned |
| M3 | C5 | Alert and recording rules view: health, last eval, last error, query preview | planned |
| M3 | D1 | Targets health (`/api/v1/targets`) | planned |
| M3 | D2 | Rules (`/api/v1/rules`) | planned |
| M3 | D3 | Cardinality (`/api/v1/status/tsdb`) | planned |
| M3 | D4 | Build, flags and runtime info | planned |
| M3 | E2 | Lens: `promtool check rules\|config`, `promtool test rules` | planned |
| M3 | E3 | Lens: `amtool alert\|silence query` | planned |
| M3 | E4 | Lens: `logcli query` | planned |
| M3 | E5 | Lens: `curl` against `/api/v1/query*` and `/api/ds/query` | planned |
| M4 | G1 | Deploy annotations from finished commands (opt-in, confirm on first use per context) | planned |
| M4 | G2 | Post-command impact watch: golden signals before/after | planned |
| M4 | G3 | Carly exports (promql, alerts, find_dashboard, logs) and firing summary context | planned |
| M4 | G4 | Investigate: open an agent with alert labels, query, recent values and runbook | planned |
| M5 | F1 | Loki logs block: LogQL, level colors, label chips, polling tail, volume bars | planned |
| M5 | F2 | Tempo trace waterfall | planned |
| M5 | F3 | Exemplars to trace | planned |
| M5 | F4 | Logs and metrics jumps | planned |
| M5 | B4 | Shared time range and cursor across blocks | planned |
| M5 | G5 | Personal PromQL threshold watches | planned |
| M5 | G6 | Per-remote-host default context | planned |
| M5 | - | Release v0.1.0 | planned |

## Documentation

- [Configuration](docs/configuration.md), [Settings block](docs/settings.md), [Query block](docs/query.md)
- [Architecture](docs/architecture.md)
- [SDK capability matrix](docs/sdk-capability-matrix.md)
- [Contributing](CONTRIBUTING.md), [Security](SECURITY.md), [Support](SUPPORT.md),
  [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE)
