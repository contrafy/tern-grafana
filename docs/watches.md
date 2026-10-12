# Threshold watches

Personal PromQL alerts that Tern evaluates itself, for checks you do not want to
deploy as alerting rules on a server. The host half polls each watch on its own
interval, tracks it through `ok`, `pending` and `firing` the way a Prometheus
alerting rule's `for` does, shows firing watches in the status line and toasts
when a watch starts firing or resolves.

## Configuration

`watches` is a list in the config file (`$XDG_CONFIG_HOME/tern-grafana/config.json`):

```json
{
  "watches": [
    {
      "name": "api-errors",
      "context": "prod",
      "expr": "sum(rate(http_requests_total{code=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m]))",
      "op": ">",
      "threshold": 0.05,
      "for": "5m",
      "severity": "critical",
      "interval": "30s"
    },
    { "name": "scrape-down", "expr": "up", "op": "==", "threshold": 0 }
  ]
}
```

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | string, required | | Unique name, at most 64 characters; shown in toasts and the status line. |
| `context` | string | host default | Context the query runs in. Without it the host's default context (see docs/hosts.md, then `default_context`) applies at each poll. |
| `expr` | string, required | | PromQL instant query. |
| `op` | string, required | | One of `>`, `>=`, `<`, `<=`, `==`, `!=`. |
| `threshold` | number, required | | Compared with every series' sample: `sample op threshold`. |
| `for` | duration | `"0s"` | How long the condition must hold on every evaluation before the watch fires; until then it is pending. |
| `severity` | string | `"warning"` | `critical`, `error`, `warning` or `info`: the segment's tone and the toast level. |
| `interval` | duration | `"60s"` | Time between evaluations; at least `15s`. |

Durations use Prometheus syntax (`30s`, `5m`, `1h30m`). At most 32 watches are
polled. A watch with a bad key, an unknown context or a bad value is skipped and
the problem logged with its path (for example `watches[2].op`); the others still run.

## Evaluation

- The query is an instant query through the context's metrics route (Prometheus
  direct or Grafana `/api/ds/query`, docs/configuration.md).
- The condition holds when at least one series' sample crosses the threshold.
- No data (an empty result) does not hold: a firing watch resolves and the summary
  records `no_data`. Write `absent(...)` when missing data should fire.
- NaN samples never cross a threshold, with any operator.
- A failed query (network, auth, timeout, query error) changes nothing: a firing
  watch keeps firing and a pending watch keeps its `for` timer; the segment shows `?`.
- Changing a watch's context, expression, operator, threshold or `for` starts it
  over; a host restart resumes recent state from kv without re-announcing.

## Status line and toasts

The segment shows `watch <name>` when one watch fires, `<n> watches` when several
do (toned by the worst severity), `<n> pending` (muted) while watches are only
pending, and nothing while all are ok. `?` marks failing evaluations or a poller
that stopped. Clicking it (or the palette command "Grafana: Watches") opens the
most urgent watch's query in a Query block. It is shown only while Tern's status
bar is on.

Every window toasts a watch that starts firing and a firing watch that resolves,
once across all windows. Pending is not announced. Transitions that happened while
Tern was closed are recorded without a toast.

## Stored data

kv `tern-grafana.watches.summary` holds, per watch: name, context, expression,
operator, threshold, severity, status, times, series counts, the reported value
and an error kind. kv `tern-grafana.watches.notified` holds each watch's last
announced status. Neither ever holds server messages or credentials.
