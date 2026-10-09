# Alerts

Tern Grafana shows the alerts of a context in an inbox block and a firing count in Tern's status line.

## Where alerts come from

Each context's alerts are read from the first source it has, following the `alerts` routing in
[configuration.md](configuration.md):

| Context has | Requests | What you see |
|---|---|---|
| `alertmanager` endpoint | `GET /api/v2/alerts` | firing, silenced, inhibited |
| `grafana` with `datasources.alertmanager` | `GET /api/alertmanager/<uid>/api/v2/alerts` (Grafana's proxy to that Alertmanager) | firing, silenced, inhibited |
| `grafana` only | `GET /api/alertmanager/grafana/api/v2/alerts` and `GET /api/prometheus/grafana/api/v1/alerts` | firing, silenced, inhibited from Grafana's Alertmanager; pending from Grafana's rule evaluator |
| `prometheus` only | `GET /api/v1/alerts` | firing, pending (Prometheus has no silences) |

An Alertmanager never receives pending alerts, which is why Grafana-managed alerting is read from both sides. If the
rule evaluator fails, the inbox still shows the Alertmanager's alerts with a warning that pending alerts are missing.
Resolved alerts (an Alertmanager keeps them briefly) and inactive rules are not shown.

Supported: Grafana 11 and 12, Alertmanager 0.27+, Prometheus 2.53 and 3.x.

## The inbox

Open it with the palette command **Grafana: Alerts**, by clicking the status segment, or with a link such as
`tern-grafana://alerts?context=prod&filter=severity%3Dcritical`. `rule=<grafana rule uid>` shows one Grafana rule's
alerts.

Alerts are grouped by `alerts.group_by` labels and sorted so what needs attention comes first:

1. firing and pending above silenced and inhibited;
2. then by severity: `critical` > `error` > `warning` > `info` > none (from the `severity` label; `crit`, `fatal`,
   `page`, `err`, `warn`, `notice` are understood too);
3. then firing before pending, then newest first.

Silenced and inhibited alerts are hidden until you press `m`.

| Key | Action |
|---|---|
| `j` / `k`, arrows | move |
| `enter` / `space` | collapse or expand a group; open or close an alert's details |
| `/` | edit the filter (`enter` applies, `esc` cancels) |
| `esc` | close details, then clear the filter |
| `m` | show or hide silenced and inhibited alerts |
| `c` / `C` | next / previous context |
| `r` | refresh now (the inbox also refreshes every `alerts.poll_s`, or 60 s when polling is off) |
| `o` | open the runbook (`runbook_url` annotation) |
| `d` | open the dashboard: Grafana's `__dashboardUid__` / `__panelId__` open the native dashboard block on that panel; a `dashboard_url` annotation opens through link routing |
| `g` | open the source: a Prometheus generator URL opens the query block with the rule's expression; Grafana's rule page opens as is |
| `s` | open the silence page for the alert in Grafana or Alertmanager, prefilled with its labels (native silences arrive in a later release) |
| `y` | copy the alert's matchers (`{alertname="...", ...}`) |

The details show the state, severity, start, value, silences or inhibitions, receivers, labels and annotations.
Grafana's internal annotations (`__values__`, `__value_string__`, `__orgId__`, ...) and labels are hidden; the summary
line uses the `summary` annotation, else the first line of `description`, else the alert name.

### Filter

The filter takes free words and Alertmanager label matchers, separated by spaces or commas; all must match.

- `name=value`, `name!=value`: exact comparison. A missing label is the empty string, so `team=""` finds alerts
  without a `team` label.
- `name=~regex`, `name!~regex`: the regex must match the whole value, as in Alertmanager (`alertname=~Disk` does not
  match `DiskFull`; write `alertname=~Disk.*`).
- Values may be quoted (`grafana_folder="Tern Alerts"`); quote values that contain spaces, commas or braces. The braced
  form `{severity="critical", team="db"}` copied from Alertmanager works as is.
- Any other word matches case-insensitively against the summary, description, state, severity, label names and
  values.

## Status segment

A background poll reads the alerts of every context in `alerts.contexts` (default: `default_context`) every
`alerts.poll_s` seconds and writes a small summary to the plugin's kv store. The status line shows one segment per
context with firing alerts (`3 firing`, or `prod 3` when several contexts are polled), toned by the worst firing
severity: critical and error red, warning amber, info blue, no severity muted. With nothing firing it shows a muted
`alerts 0`. A `?` means the last poll of that context failed (the last known count stays) or the poll stopped
updating. Clicking a segment opens the inbox.

Status segments only show while Tern's status bar is on (toggle it with the `status_bar` action). The inbox works
without it.

The kv summary (`tern-grafana.alerts.summary`) holds only counts, severities, context names, error kinds and alert
fingerprints (label hashes, at most 64 per context). It never holds labels, annotations, URLs, server messages or
credentials.

## Configuration

```json
"alerts": {
  "contexts": ["prod", "staging"],
  "group_by": ["alertname", "cluster"],
  "poll_s": 60
}
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `contexts` | list of context names | `[default_context]` | Contexts the background poll watches (at most 16). |
| `group_by` | list of label names | `["alertname"]` | Labels the inbox groups by; `["..."]` puts every alert in its own group. |
| `poll_s` | whole seconds | `60` | Poll interval; values under 15 are raised to 15; `0` turns the poll and the status segment off. |

A bad value falls back to its default.
