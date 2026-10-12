# Carly

Tern's assistant, Carly, can query your Grafana and Prometheus-compatible backends through Tern Grafana without a
browser and without seeing a credential. The plugin adds four functions to Carly's Lua tool and one line of request
context. Nothing needs configuring: every context in [configuration.md](configuration.md) is available.

## Exports

Carly calls them as `await(plugins["tern-grafana"].<name>(...))`; `help("plugins.tern-grafana")` shows the
signatures. `context` is optional everywhere and defaults to `default_context`.

| Export | Arguments | Answer |
| --- | --- | --- |
| `promql` | `expr`, `range?`, `context?` | One summary per series: `name`, `labels`, `points`, `first`, `last`, `last_at`, `min`, `max`, `avg` and a 12-sample `trend` (range queries), largest last value first, at most 20 series (`omitted` counts the rest). Without `range` it is an instant query at now. `$__interval`, `$__rate_interval` and `$__range` are filled in. |
| `alerts` | `context?` | `counts` of firing, pending, silenced and inhibited alerts, and the firing and pending alerts (worst severity first, at most 50) with `name`, `state`, `severity`, `summary`, `since`, `labels` (no internal ones), `runbook`, `dashboard` and `source` links and the `fingerprint`. |
| `find_dashboard` | `query`, `context?` | Matching Grafana dashboards (at most 20): `uid`, `title`, `folder`, `tags`, `url` (the Grafana page) and `link` (`tern-grafana://dashboard?...`, which `cx:open` turns into the native dashboard block). `""` lists dashboards. |
| `logs` | `expr`, `range?`, `context?` | A LogQL log query answers the newest lines (at most 100, each cut to 300 characters) as `{t, level, line, s}`, where `s` indexes `streams` (label sets, at most 20; `0` means not listed). A metric query answers series summaries like `promql`. `range` defaults to `"1h"`. |

`range` is a duration back from now (`"15m"`, `"1h"`), a Grafana start time (`"now-6h"`, an absolute time) or
`{from = "now-2h", to = "now-1h"}`.

Every answer is a summary, never raw samples, and is cut to 12 KiB (Carly refuses values over 16 KiB); `omitted`
says how many series, alerts, dashboards or lines were left out. A response body over 2 MiB is refused with a hint
to aggregate (`sum by`, `topk`) or shorten the range, because the window half has a 50 ms budget per call.

Errors are plain messages Carly can act on, for example `no context named "prod" (contexts: lab, staging)`,
`range must be a string or {from, to}` or the server's own PromQL parse error.

Example, from Carly's Lua tool:

```lua
local r = await(plugins["tern-grafana"].promql("sum by (code) (rate(http_requests_total[$__rate_interval]))", "1h"))
return r.series[1]
```

## Request context

Each question to Carly carries one line (at most 400 characters) from the alert summary the background poll keeps
(see [alerts.md](alerts.md)), for example:

```
Tern Grafana alerts (as of 26s ago): prod: 3 firing (1 critical, 2 warning), 1 pending; lab: 0 firing. Details: plugins["tern-grafana"].alerts(context)
```

Contexts with firing alerts come first; a failed poll reads `unknown (poll failed: auth)`, never "0 firing"; a
summary the poll stopped updating is marked `stale`. With the poll off (`alerts.poll_s = 0`) there is no line.

## Credentials

The exports run in Tern's window half and send their requests the same way the blocks do: the token or password is
resolved from `token_cmd` / `password_cmd` (run as a process), the environment variable or the 0600 file, kept only
in that window's memory for five minutes, and sent with `tern.fetch` (or curl for contexts with TLS options). Carly
never receives a credential, a header value or a credential source: answers hold names, values and http(s) URLs
built from the endpoints' `url`s, which cannot carry userinfo. Requests run on the machine of the Tern window, with
its environment and config file.
