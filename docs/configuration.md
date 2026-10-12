# Configuration

Tern Grafana reads one JSON file on the machine running Tern's host half:

```
$XDG_CONFIG_HOME/tern-grafana/config.json
```

or, when `XDG_CONFIG_HOME` is unset, `~/.config/tern-grafana/config.json`.

The file never contains secrets. It describes where each token or password comes from (a command, an environment
variable or a file), and the plugin resolves it on demand. Any literal `token` or `password` field is rejected.

## Validation

The whole file is checked when it is loaded. If anything is wrong, nothing from the file is used, and every problem
is reported at once with the JSON path of the offending field and how to fix it, for example:

```
contexts.lab.prometheus.url: must be an http(s) URL, got "localhost:9090"
contexts.lab.grafana.auth.token: secrets cannot be written in the config file; use token_cmd, token_env or token_file
contexts.lab.promethues: unknown field; expected one of alertmanager, grafana, loki, prometheus, tempo
```

Unknown fields are errors, so a misspelled key never silently falls back to a default. JSON `null` values are
treated as absent.

## Top level

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `version` | number | `1` | Schema version. Only `1` exists. |
| `default_context` | string | the only context, if there is exactly one | Context used when none is chosen. Must name a context in `contexts`. |
| `contexts` | object | required | Context name to context. At least one. |
| `query`, `dashboard`, `alerts`, `logs`, `trace`, `investigate`, `annotations`, `impact`, `watches`, `hosts` | object (`watches`: list) | none | Feature sections, each documented below. |

Context names may contain letters, digits, `.`, `_` and `-`.

## Contexts

A context is one environment (a lab, a cluster, a Grafana stack). It holds a `grafana` endpoint, direct endpoints,
or both:

| Field | Serves |
| --- | --- |
| `grafana` | dashboards, annotations, Grafana-managed alerts, and any signal routed through a Grafana datasource |
| `prometheus` | metrics (Prometheus, Thanos, Mimir, Cortex, VictoriaMetrics: anything speaking the Prometheus HTTP API) |
| `alertmanager` | alerts and silences (Alertmanager v2 API) |
| `loki` | logs |
| `tempo` | traces |

At least one endpoint is required.

### Routing

For each signal the plugin picks one endpoint:

| Signal | 1. Direct endpoint | 2. Through Grafana | Otherwise |
| --- | --- | --- | --- |
| metrics | `prometheus` | datasource `grafana.datasources.prometheus` | error |
| logs | `loki` | datasource `grafana.datasources.loki` | error |
| traces | `tempo` | datasource `grafana.datasources.tempo` | error |
| alerts | `alertmanager` | datasource `grafana.datasources.alertmanager`, else Grafana-managed alerting | error |
| dashboards, annotations | none | Grafana's own API | error |

A configured direct endpoint always wins. Through Grafana, a query only goes to the datasource uid you named; the
plugin never picks a datasource for you. When nothing can serve a signal, the error says what to add, for example
`context "lab" has no prometheus endpoint and grafana.datasources.prometheus is not set`.

## Endpoints

Every endpoint accepts:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `url` | string | required | `http://` or `https://` base URL, without credentials, query or fragment. A subpath is kept (`https://example.com/grafana`). Trailing slashes are ignored. |
| `auth` | object | `{"type": "none"}` | How to authenticate; see [Authentication](#authentication). |
| `headers` | object | `{}` | Extra request headers, for example `X-Scope-OrgID`. Values are strings without line breaks. `Authorization` is refused: use `auth`. |
| `path_prefix` | string | `""` | Path inserted between `url` and every API path, for example `/prometheus` for Mimir. Leading and trailing slashes do not matter. |
| `tls` | object | none | TLS options; see [TLS](#tls). |
| `timeout_ms` | integer | `15000` | Per-request timeout, 1 to 600000. |

The `grafana` endpoint also accepts:

| Field | Type | Meaning |
| --- | --- | --- |
| `org_id` | positive integer | Sent as `X-Grafana-Org-Id` on every Grafana request. |
| `datasources` | object | Datasource uid per signal: keys `prometheus`, `loki`, `tempo`, `alertmanager`. Find a uid in Grafana under Connections, Data sources (it is the last segment of the datasource's edit URL). |
| `browser_url` | string | Public URL to open in a browser pane and to recognize in links, when it differs from `url` (for example `url` is an internal address). |

## Authentication

`auth` is one of:

```json
{ "type": "none" }
{ "type": "bearer", "token_cmd": ["..."] }
{ "type": "basic", "username": "...", "password_cmd": ["..."] }
```

A bearer token comes from exactly one of `token_cmd`, `token_env` or `token_file`; a basic password from exactly one
of `password_cmd`, `password_env` or `password_file`. The basic `username` is not a secret and is written as is
(it may not contain `:`).

| Source | Value | Behavior |
| --- | --- | --- |
| `*_cmd` | array of strings | Runs the program directly (no shell) and uses its standard output. Allowed 30 s, so a password manager can prompt to unlock. A non-zero exit fails without showing the command's output, since it may contain the secret; run the command in a terminal to see why. |
| `*_env` | variable name | Reads the variable from the environment of the Tern process, not from your shell. Set it where Tern is started (login environment, launchd, systemd unit). |
| `*_file` | absolute path or `~/...` | Reads the file, at most 64 KiB. Keep it private: `chmod 600`. |

In every case trailing line breaks are removed; other whitespace is kept. The result must be a single line: output
with several lines or control characters is rejected.

### Examples

1Password CLI:

```json
"auth": { "type": "bearer", "token_cmd": ["op", "read", "op://Private/Grafana lab/credential"] }
```

macOS Keychain (store it once with
`security add-generic-password -a tern-grafana -s grafana-lab -w`):

```json
"auth": { "type": "bearer", "token_cmd": ["security", "find-generic-password", "-a", "tern-grafana", "-s", "grafana-lab", "-w"] }
```

`pass` (the password store). `pass show` prints the whole entry; when the entry has more than the password line, keep
only the first line:

```json
"auth": { "type": "bearer", "token_cmd": ["sh", "-c", "pass show grafana/lab | head -n 1"] }
```

Environment variable:

```json
"auth": { "type": "bearer", "token_env": "GRAFANA_TOKEN" }
```

File:

```json
"auth": { "type": "basic", "username": "admin", "password_file": "~/.config/tern-grafana/lab.password" }
```

### How secrets are handled

- Resolved only when a request needs one, in the host half of the plugin.
- Kept in memory for 5 minutes per context and endpoint, then resolved again. A `401` response drops the cached
  value immediately, so a rotated token is picked up on the next request.
- Never written to disk, Tern's key-value store, logs, block arguments, saved block state or URLs.
- When the curl transport is used, credentials reach curl on its standard input, never on its command line.

## TLS

```json
"tls": {
  "ca_file": "/etc/ssl/private-ca.pem",
  "cert_file": "~/.config/tern-grafana/client.pem",
  "key_file": "~/.config/tern-grafana/client-key.pem",
  "insecure": false
}
```

| Field | Meaning |
| --- | --- |
| `ca_file` | Trust this CA bundle (private or self-signed CA). |
| `cert_file` | Client certificate for mutual TLS. |
| `key_file` | Client key; requires `cert_file`. |
| `insecure` | `true` skips certificate verification. For local labs only. |

Paths are absolute or start with `~/`. Tern's built-in HTTP client has no TLS options, so setting any of these sends
that endpoint's requests through `curl` instead (it must be on the `PATH` of the Tern process). The user's
`~/.curlrc` is ignored. An all-default block (`insecure: false`, nothing else) changes nothing.

If a request fails with a certificate error such as `invalid peer certificate: UnknownIssuer`, set `ca_file`.

## Query

Defaults for the [Query block](query.md), in the `query` section:

```json
"query": {
  "default_range": "now-1h",
  "max_points": 600,
  "refresh": "30s"
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `default_range` | string | `"now-1h"` | Start of the range for a query opened without one (the end is `now`). Any Grafana time. |
| `max_points` | number | `600` | Points per series a range query asks for, a whole number from 10 to 11000; sets the step. Tern reports every block as 80x24, so this cannot be derived from the pane size. |
| `refresh` | string | `"30s"` | Auto-refresh interval used by the `a` toggle, a duration of at least `5s`. |

Unknown keys and bad values in this section are reported as problems; a bad value falls back to its default instead
of breaking the block.

## Dashboard

Settings for the [Dashboard and Panel blocks](dashboards.md), in the `dashboard` section:

```json
"dashboard": {
  "max_points": 600,
  "min_refresh": "30s",
  "render_theme": "dark"
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `max_points` | number | `600` | maxDataPoints for panels that set none, from 10 to 11000 (a fraction is rounded down). Tern blocks have no pane width to derive it from. |
| `min_refresh` | string or number | `"30s"` | Shortest auto-refresh interval: a duration such as `"1m"`, or a positive number of seconds. A dashboard whose own `refresh` is faster refreshes at this interval instead. |
| `render_theme` | string | `"dark"` | Theme of panels rendered by Grafana's image renderer: `"dark"` or `"light"`. |

A missing or invalid value uses its default.

## Alerts

Settings for the [alerts inbox, status segment and toasts](alerts.md), in the `alerts` section:

```json
"alerts": {
  "contexts": ["prod", "staging"],
  "group_by": ["alertname", "cluster"],
  "poll_s": 60,
  "toasts": true,
  "toast_severities": ["critical", "error"]
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `contexts` | list of strings | `[default_context]` (none when there is no default context) | Contexts the background poll watches. Each must name a context in `contexts`; unknown names are reported and skipped. At most 16 are polled. |
| `group_by` | list of strings | `["alertname"]` | Labels the inbox groups alerts by, at least one. `["..."]` puts every alert in its own group. |
| `poll_s` | number | `60` | Whole seconds between background polls. `0` turns the poll and the status segment off; values from 1 to 14 are reported and raised to 15. |
| `toasts` | boolean | `false` | Show a toast when alerts start firing in a polled context. Needs the poll (`poll_s` above 0). |
| `toast_severities` | list of strings | `["critical", "error", "warning"]` | Severities that toast: any of `critical`, `error`, `warning`, `info` and `none` (alerts without a severity), case-insensitive. An unknown severity is reported and the default list is used. |

Unknown keys and bad values in this section are reported as problems; a bad value falls back to its default.

## Logs

Defaults for the [Logs block](logs.md), in the `logs` section:

```json
"logs": {
  "default_range": "now-1h",
  "limit": 500,
  "tail_interval": "2s",
  "volume": true
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `default_range` | string | `"now-1h"` | Start of the range for a query opened without one (the end is `now`). Any Grafana time. |
| `limit` | number | `500` | Most lines a query (and the tail buffer) holds, a whole number from 1 to 5000. |
| `tail_interval` | string | `"2s"` | Tail polling interval, a duration from `1s` to `1m`. |
| `volume` | boolean | `true` | Show the volume bars above the lines. |

Unknown keys and bad values in this section are reported as problems; a bad value falls back to its default.

## Trace

Settings for the [trace block](traces.md), in the `trace` section:

```json
"trace": {
  "search_limit": 20,
  "range": "now-1h"
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `search_limit` | number | `20` | Traces one TraceQL search returns, a whole number from 1 to 1000. |
| `range` | string | `"now-1h"` | Start of the search range (the end is `now`). A relative Grafana time. |

Unknown keys and bad values in this section are reported as problems; a bad value falls back to its default.

## Investigate

Settings for [Investigate](investigate.md), in the `investigate` section:

```json
"investigate": { "range": "1h" }
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `range` | string | `"1h"` | How far back the alert preview fetches recent values of the alert's query, a duration from `1s` to `7d`. |

Unknown keys and bad values are reported as problems; a bad value falls back to its default.

## Annotations

[Deploy annotations](annotations.md), in the `annotations` section. Off until `enabled` is `true`:

```json
"annotations": {
  "enabled": true,
  "on": "success",
  "patterns": ["helm upgrade", "kubectl apply", "terraform apply"],
  "tags": ["tern", "deploy"],
  "context": "prod",
  "dashboard_uid": "abc123",
  "panel_id": 2
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `false` | Annotate finished commands that match `patterns`. A bad value keeps the feature off. |
| `on` | string | `"success"` | `"success"`: only commands that exit 0; `"always"`: any exit status. |
| `patterns` | list of strings | `helm upgrade`, `helm install`, `kubectl apply`, `kubectl rollout restart\|undo`, `kubectl set image`, `terraform apply`, `tofu apply`, `argocd app sync`, `flux reconcile` | Commands that count, at most 64 non-empty strings; see [Which commands count](annotations.md#which-commands-count). |
| `tags` | list of strings | `["tern", "deploy"]` | Tags on every annotation, at most 16 non-empty strings. |
| `context` | string | the default context | Context to annotate. Must name a context in `contexts`. |
| `dashboard_uid` | string | none | Attach annotations to this dashboard (letters, digits, `_`, `-`; at most 128 characters). Without it they are organization-wide. |
| `panel_id` | number | none | Attach to this panel, a positive whole number. Needs `dashboard_uid`. |

Unknown keys and bad values are reported as problems; a bad value falls back to its default.

## Impact

The [impact watch](annotations.md#impact-watch) after a deploy, in the `impact` section. Off until `enabled` is
`true`; triggered by the `annotations.patterns` commands:

```json
"impact": {
  "enabled": true,
  "on": "success",
  "window": "15m",
  "context": "prod",
  "signals": {
    "prod": [
      { "name": "errors", "expr": "sum(rate(http_requests_total{service=\"{{service}}\",code=~\"5..\"}[5m]))", "unit": "reqps", "bad": "up" }
    ]
  }
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `false` | Start an impact watch after a matching command. |
| `on` | string | `"success"` | `"success"` or `"always"`, as for annotations. |
| `window` | string | `"15m"` | Length of the before and the after window, a duration from `1m` to `6h`. |
| `context` | string | the default context | Context to query. Must name a context in `contexts`. |
| `signals` | list, or object | none | Signals to compare: one list for every context, or an object mapping a context name (or `"*"` for the rest) to its list. At most 12 per list. |

Each signal:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | string | required | Short label. |
| `expr` | string | required | PromQL. May use the placeholders `{{namespace}}`, `{{service}}` and `{{cwd_basename}}`; any other placeholder is an error. |
| `unit` | string | none | Grafana unit id, such as `s` or `percentunit`. |
| `bad` | string | `"up"` | Which direction is a regression: `"up"`, `"down"` or `"none"`. |

A signal with a problem is skipped and reported; the others still apply.

## Watches

Personal [threshold watches](watches.md), in the `watches` list:

```json
"watches": [
  { "name": "disk low", "context": "prod", "expr": "min(node_filesystem_avail_bytes / node_filesystem_size_bytes)", "op": "<", "threshold": 0.1, "for": "5m", "severity": "critical", "interval": "60s" }
]
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | string | required | Unique name, 1 to 64 characters. |
| `context` | string | the default context at poll time | Must name a context in `contexts`. |
| `expr` | string | required | PromQL expression, at most 8192 characters. |
| `op` | string | required | One of `>`, `>=`, `<`, `<=`, `==`, `!=`. |
| `threshold` | number | required | A finite number. |
| `for` | string | `"0s"` | How long the condition must hold before the watch fires, a duration. |
| `severity` | string | `"warning"` | `critical`, `error`, `warning` or `info`, case-insensitive. |
| `interval` | string | `"60s"` | Time between evaluations, a duration of at least `15s`. |

A watch with a problem is skipped and reported; the others still apply. A repeated name is skipped. At most 32
watches are polled.

## Hosts

[Per-host default contexts](hosts.md), in the `hosts` section: an object mapping a hostname or glob to a context
name.

```json
"hosts": {
  "laptop": "lab",
  "web-*": "prod"
}
```

Keys compare case-insensitively against the machine's full hostname and its first label. `*` matches any run of
characters, `?` exactly one. An exact name beats every glob; among globs the longest wins. Each key is at most 253
characters and at most 256 entries are read. An entry with an empty key, a value that is not a defined context name,
or a key repeating another in a different case is skipped and reported. The match takes the place of
`default_context`; a context named explicitly still wins.

## Examples

### Local lab: Grafana plus direct backends

```json
{
  "version": 1,
  "default_context": "lab",
  "contexts": {
    "lab": {
      "grafana": {
        "url": "http://localhost:3000",
        "auth": { "type": "bearer", "token_env": "GRAFANA_TOKEN" },
        "org_id": 1,
        "datasources": { "prometheus": "prom3", "loki": "loki", "tempo": "tempo" }
      },
      "prometheus": { "url": "http://localhost:9090" },
      "alertmanager": { "url": "http://localhost:9093" },
      "loki": { "url": "http://localhost:3100" },
      "tempo": { "url": "http://localhost:3200" }
    }
  }
}
```

### Grafana Cloud

Use a Grafana service account token for the stack. Direct Prometheus and Loki access uses basic auth: the username is
the instance (user) ID shown on the stack's details page, the password a Cloud access policy token.

```json
{
  "contexts": {
    "cloud": {
      "grafana": {
        "url": "https://example.grafana.net",
        "auth": { "type": "bearer", "token_cmd": ["op", "read", "op://Work/Grafana Cloud/service-account-token"] },
        "datasources": { "prometheus": "grafanacloud-prom", "loki": "grafanacloud-logs" }
      },
      "prometheus": {
        "url": "https://prometheus-prod-13-prod-us-east-0.grafana.net",
        "path_prefix": "/api/prom",
        "auth": {
          "type": "basic",
          "username": "123456",
          "password_cmd": ["op", "read", "op://Work/Grafana Cloud/access-policy-token"]
        }
      }
    }
  }
}
```

### Mimir with a tenant

```json
{
  "contexts": {
    "mimir": {
      "prometheus": {
        "url": "https://mimir.internal",
        "path_prefix": "/prometheus",
        "headers": { "X-Scope-OrgID": "team-a" }
      },
      "alertmanager": {
        "url": "https://mimir.internal",
        "path_prefix": "/alertmanager",
        "headers": { "X-Scope-OrgID": "team-a" }
      }
    }
  }
}
```

Several tenants can be queried together with `"X-Scope-OrgID": "team-a|team-b"` when the cluster allows it. Loki and
Tempo multi-tenant setups take the same header.

### Thanos

Thanos Query serves the Prometheus HTTP API at its root:

```json
{
  "contexts": {
    "thanos": {
      "prometheus": { "url": "https://thanos-query.internal:10902", "timeout_ms": 60000 },
      "alertmanager": { "url": "https://alertmanager.internal:9093" }
    }
  }
}
```

### VictoriaMetrics

Single-node VictoriaMetrics serves the Prometheus API at its root; a cluster serves it through `vmselect` under a
per-tenant prefix:

```json
{
  "contexts": {
    "vm-single": { "prometheus": { "url": "http://victoria:8428" } },
    "vm-cluster": { "prometheus": { "url": "http://vmselect:8481", "path_prefix": "/select/0/prometheus" } }
  }
}
```

### Private CA

```json
{
  "contexts": {
    "corp": {
      "prometheus": {
        "url": "https://prometheus.corp.example",
        "auth": { "type": "bearer", "token_file": "~/.config/tern-grafana/corp.token" },
        "tls": { "ca_file": "/etc/ssl/corp-root.pem" }
      }
    }
  }
}
```
