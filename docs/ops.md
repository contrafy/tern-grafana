# Ops

The ops block shows a Prometheus server's own health for one context: what it scrapes, how much it stores, and how
it runs. Open it with the palette command **Grafana: Ops** or a link such as
`tern-grafana://ops?context=prod&view=cardinality` (`view` is `targets`, `rules`, `cardinality` or `info`).

## Where the data comes from

The block follows the `metrics` routing in [configuration.md](configuration.md):

| Context has | Requests go to |
|---|---|
| `prometheus` endpoint | the server directly, e.g. `GET /api/v1/targets` |
| `grafana` with `datasources.prometheus` | Grafana's datasource proxy, e.g. `GET /api/datasources/proxy/uid/<uid>/api/v1/targets` |

| Tab | Endpoints |
|---|---|
| Targets | `/api/v1/targets` (active and dropped targets in one answer) |
| Rules | none: opens the Alerts block's Rules view (`tern-grafana://alerts?context=<ctx>&view=rules`) |
| Cardinality | `/api/v1/status/tsdb?limit=<N>` |
| Info | `/api/v1/status/buildinfo`, `/runtimeinfo`, `/flags`, `/config` |

Each tab loads the first time it shows; `r` reloads the current tab. The header names the server from its build
info (`Prometheus API 3.15.0`) and the route (`direct` or the Grafana datasource uid). Nothing refreshes on a timer.

Supported: Prometheus 2.53 and 3.x, directly or through Grafana 11 and 12. Prometheus-compatible stores that lack an
endpoint (Mimir and Cortex have no targets or TSDB status, Loki-style gateways answer `404 page not found`,
VictoriaMetrics answers `unsupported path requested`) show "unavailable" for that tab or card instead of an error;
the other tabs keep working. A JSON 404 (for example Grafana saying the datasource uid does not exist) is shown as an
error. After a failed reload the last good answer stays on screen next to the error.

## Targets

Counts of up, down and unknown active targets and of dropped targets (`droppedTargetCounts`, per pool), then one card
per scrape pool (job). Pools with a down target come first; inside a pool, down targets come first. A row shows
health, instance, time since the last scrape, scrape duration and the last scrape error; `enter` opens the scrape
URL, interval and timeout and the target labels. `d` lists dropped targets (pool and address, the first 200).

`/` filters with the alerts inbox syntax: free words match pool, instance, URL, error, health and label names and
values; `a=b`, `a!=b`, `a=~re`, `a!~re` test target labels plus `health` (and `job` = the pool name when a target
has no job label). `u` shows only targets that are not up.

## Cardinality

Head block statistics (series, label pairs, chunks, the head's time span) and four top-N lists: series by metric
name (with the share of all head series), distinct values by label name, series by `label=value` pair, and index
memory by label name. Only the first list is expanded by default; expand others by clicking their heading. `+`/`-`
step N through 5, 10, 20, 50, 100 (the server's default is 10).

`enter` (or a click) on an entry opens the Query block in table mode on a query that breaks it down further:

| List | Query |
|---|---|
| series by metric | `count by (job) ({__name__="<metric>"})` |
| values or memory by label | `count by (__name__) ({<label>=~".+"})` |
| series by pair | `count by (__name__) ({<label>="<value>"})` |

Classic label names stay unquoted (Prometheus 2.x rejects quoted names); UTF-8 names, which only exist on 3.x, are
quoted.

## Info

Build (version, revision, branch, build date, Go), runtime (start, hostname, working directory, last config reload
and whether it succeeded, retention, goroutines, GOMAXPROCS, GOMEMLIMIT, GOGC, corruptions), a configuration summary
(global scrape and evaluation intervals, external labels, scrape jobs, rule files, Alertmanager configs, remote write
and read counts, YAML size) and flags (a few key flags, then all flags behind a disclosure; `/` filters them).
`y` copies the configuration YAML as the server prints it (Prometheus replaces secrets with `<secret>`). The summary
never shows URLs.

## Keys

| Key | Action |
|---|---|
| `tab` / `shift-tab`, `1`-`4` | switch tab |
| `j` / `k`, arrows, `home` / `end` | move (Targets, Cardinality) |
| `enter` / `space` | Targets: expand a pool or target; Cardinality: open the breakdown query; Rules: open the Rules view |
| `/` | filter (Targets, Info flags); `esc` clears |
| `u` / `d` | Targets: unhealthy only / dropped list |
| `+` / `-` | Cardinality: top N |
| `y` | Info: copy the configuration YAML |
| `r` | reload the current tab |
| `c` / `C` | next / previous context |

The block saves its context, tab, filter, unhealthy-only toggle, top N and expanded lists; never server data.
