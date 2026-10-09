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
| `s` | silence the alert: opens the silence block's form prefilled with its labels (see [Silences](#silences)) |
| `y` | copy the alert's matchers (`{alertname="...", ...}`) |
| `v` | switch to the rules view |

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

## Rules

Press `v` in the inbox (or open `tern-grafana://alerts?context=prod&view=rules`) for the context's alerting and
recording rules. Every rule source the context has is read:

| Context has | Requests |
|---|---|
| `grafana` | `GET /api/prometheus/grafana/api/v1/rules` (Grafana-managed rules) |
| `prometheus` endpoint | `GET /api/v1/rules` |
| `grafana` with `datasources.prometheus` and no `prometheus` endpoint | `GET /api/prometheus/<uid>/api/v1/rules` (the datasource's rules through Grafana) |

Rules are listed under their source and rule group in server order, one line each: status (`firing`, `pending`,
`inactive`, `paused`, or `recording`), health, name, alert count, time since the last evaluation and its duration. A
rule whose last evaluation failed shows its error under it; `p` shows only such rules. When one source fails the
others still show, with the failure above the list.

| Key | Action |
|---|---|
| `j` / `k`, arrows | move |
| `enter` / `space` | open or close the rule's details: query, last error, interval, `for`, labels, annotations |
| `q` | open the rule's query in the query block (Grafana 12 rules that query one datasource open on that datasource) |
| `a` | back to the inbox, filtered to this rule's alerts (silenced ones shown) |
| `p` | only rules whose evaluation fails |
| `/` | filter: the inbox syntax; matchers test the rule's labels and `alertname` (the rule name) |
| `r` | refresh now (also every `alerts.poll_s`, or 60 s) |
| `v` | back to the inbox |

## Silences

Silences live in their own block, `tern-grafana.silence`. `s` on an alert opens it with a new silence prefilled;
the link `tern-grafana://silence?context=prod` opens the list, `&matchers={alertname="X"}` a new silence with those
matchers, `&id=<silence id>` the list with that silence selected. A silence is written to the server the inbox reads
alerts from:

| Inbox source | Silences |
|---|---|
| `alertmanager` endpoint | `/api/v2/silences`, expire with `DELETE /api/v2/silence/<id>` |
| Grafana's proxy to the Alertmanager datasource | `/api/alertmanager/<uid>/api/v2/silences`, `DELETE .../silence/<id>` |
| Grafana-managed alerting | `/api/alertmanager/grafana/api/v2/silences`, `DELETE .../silence/<id>` |
| `prometheus` only | none: Prometheus has no silences |

### New silence

The form has the matchers (from an alert: one `name="value"` per label, internal labels left out except Grafana's
`__alert_rule_uid__`, which scopes the silence to the alert's rule), the duration (presets 1h, 2h, 4h, 1d, or custom
such as `90m` or `1d12h`, at most 366 days), a required comment and "created by" (default: your `USER`). Matchers use
Alertmanager's syntax: `name="value"`, `name!="value"`, `name=~"regex"`, `name!~"regex"`; regexes match the whole value
and a missing label is the empty string, exactly as Alertmanager matches. Under the form a preview lists the current
alerts the matchers cover. The form refuses what Alertmanager would refuse: no matchers, a bad label name or regex, or
only matchers that match the empty string (a silence of everything).

| Key | Action |
|---|---|
| `j` / `k`, `tab` | move between fields |
| `enter` / `space` | edit the field (matcher, comment, created by, custom duration); on the duration, next preset |
| `left` / `right` | previous / next duration |
| `a` | add a matcher |
| `x` / `delete` | remove the selected matcher |
| `S` | review the silence |
| `esc` | discard the draft and go back to the list |

### Confirmation

Nothing is written until you confirm. Reviewing (`S`, or "Create silence..." in the form) and expiring (`x` in the
list) only show a confirmation panel at the top of the block: the matchers, start and end, comment, the server, and
how many current alerts it covers (expiring: how many it mutes now, which notify again). Only `y` or the Confirm
button sends the request; `n`, `esc` or Cancel sends nothing. A failed request is shown with the server's reason and
never retried; the draft stays in the form. The block's saved state holds only the context and the expired toggle,
never a draft, and the Tern log gets one line per decision with the action, outcome, context, server kind, matcher
count, duration, silence id and HTTP status, never the comment or matcher values.

### List

Active silences first (ending soonest first), then pending, then expired (hidden until `m`). Each shows its matchers,
when it ends, how many current alerts it mutes, who created it and the comment.

| Key | Action |
|---|---|
| `j` / `k`, arrows | move |
| `x` | expire the selected silence (after confirmation) |
| `n` | new silence |
| `e` | new silence with the selected one's matchers |
| `m` | show or hide expired silences |
| `c` / `C` | next / previous context |
| `r` | refresh now (also every 60 s) |

In the inbox an alert a silence covers shows as `silenced` (press `m` to show muted alerts) with the silence id in its
details.

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

## Toasts

With `alerts.toasts` on, Tern shows a toast when alerts start firing in a polled context, for example
`prod: 2 alerts started firing` with `1 critical, 1 warning` below; critical and error toast as errors. Only the
severities in `alerts.toast_severities` count (`none` stands for alerts without a severity). Each poll is announced
once across all windows; alerts already firing on the first poll after Tern starts, after a gap of three poll
intervals (at least five minutes), or when toasts are turned on are not announced. A failed poll announces nothing.
The toast names no alerts because the kv summary it reads holds no labels; open the inbox to see them.

The announced fingerprints are kept in kv `tern-grafana.alerts.notified` (context names, times and fingerprints only).

## Configuration

```json
"alerts": {
  "contexts": ["prod", "staging"],
  "group_by": ["alertname", "cluster"],
  "poll_s": 60,
  "toasts": true,
  "toast_severities": ["critical", "error"]
}
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `contexts` | list of context names | `[default_context]` | Contexts the background poll watches (at most 16). |
| `group_by` | list of label names | `["alertname"]` | Labels the inbox groups by; `["..."]` puts every alert in its own group. |
| `poll_s` | whole seconds | `60` | Poll interval; values under 15 are raised to 15; `0` turns the poll and the status segment off. |
| `toasts` | boolean | `false` | Toast newly firing alerts of polled contexts (needs the poll). |
| `toast_severities` | list of `critical`, `error`, `warning`, `info`, `none` | `["critical", "error", "warning"]` | Severities that toast. |

A bad value falls back to its default.
