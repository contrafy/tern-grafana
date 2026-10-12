# Deploy annotations and impact watch

Tern Grafana can notice deploy commands you run in a Tern terminal and

- post a Grafana annotation for each one, after you approved it for that context, and
- open an impact watch beside the terminal that compares a few signals before and after the deploy.

Both are off until you turn them on in the config file (`annotations.enabled`, `impact.enabled`).

## Which commands count

A finished command line counts when one of its simple commands matches a pattern. The defaults are:

| Pattern | Kind (also an annotation tag) |
| --- | --- |
| `helm upgrade`, `helm install` | `helm-upgrade`, `helm-install` |
| `kubectl apply` | `kubectl-apply` |
| `kubectl rollout restart\|undo` | `kubectl-rollout-restart`, `kubectl-rollout-undo` |
| `kubectl set image` | `kubectl-set-image` |
| `terraform apply`, `tofu apply` | `terraform-apply`, `tofu-apply` |
| `argocd app sync` | `argocd-app-sync` |
| `flux reconcile` | `flux-reconcile` |

How a line is read:

- It is split into simple commands at `;`, `&&`, `||`, `|`, `&` and parentheses; the first one that matches wins
  (`cd infra && terraform apply | tee log` matches).
- Leading assignments and wrappers are skipped: `FOO=1 helm upgrade ...`, `env`, `sudo`, `doas`, `command`, `exec`,
  `time`, `nohup`, `nice`, `timeout 5m`, `noglob`. The program is compared by basename (`/usr/local/bin/helm`).
- The words after the program are its subcommand words, with flags, the values of common global flags
  (`-n`, `--namespace`, `--context`, `--kube-context`, `--kubeconfig`, `-f`, `--set`, ...) and redirections skipped,
  so `kubectl --context prod -n shop apply -f x.yaml` is a `kubectl apply`.
- Tern reports the line as typed: aliases are not expanded. Add a pattern for an alias you use (`"k apply"`).

`annotations.patterns` replaces the defaults; it is also what triggers the impact watch. A pattern is the program
followed by subcommand words; `|` separates alternatives of one word (`"make deploy|release"`).

Namespace and service are read from the command where it names them: `-n`/`--namespace`/`--namespace=` (and
`-nshop` for kubectl, helm, flux, argocd), the helm release (`helm upgrade web ./chart`), the kubectl resource
name (`deployment/web` or `deployment web`), the Argo CD application, and the Flux object name.

## Annotations

When a matching command finishes (exit 0 by default; `annotations.on = "always"` takes any status) in a context
that has a Grafana endpoint:

1. The first time for a context, an approve block opens beside the terminal. It shows exactly what will be posted
   (text, tags, start and end time, which Grafana, dashboard/panel or organization-wide) and offers:
   - **Always**: post it, and post later deploys in this context without asking.
   - **Once**: post it, ask again next time.
   - **Never**: post nothing, and never ask again in this context.
   - **Dismiss** (esc): post nothing, decide later.

   The block may take focus while you are still typing, so no single ordinary key decides: arrows or tab pick a
   choice and only `y` confirms it (enter does not); the buttons decide on click.
2. Contexts approved "always" are annotated right away; a toast says whether it worked. A failed post is reported
   (toast or in the block) and never retried by itself.

The annotation is `POST /api/annotations` (Grafana 11 and 12) with:

| Field | Value |
| --- | --- |
| `time`, `timeEnd` | When the command started and finished (epoch ms). |
| `tags` | `annotations.tags` (default `["tern", "deploy"]`) plus the kind, e.g. `helm-upgrade`. |
| `text` | The command line with secrets redacted, then how it ended and where: `succeeded after 1m 01s, dir shop-deploy, git abc1234, by ahmad`. |
| `dashboardUID`, `panelId` | Only when `annotations.dashboard_uid` (and `panel_id`) are set; otherwise the annotation is organization-wide. |

The git short SHA comes from `git -C <cwd> rev-parse --short HEAD` (no shell, 2 s limit) when the command ran in a
repository. The user is the login name on the machine that ran the command. The Grafana token needs permission to
create annotations (Editor or a service account with `annotations:create`).

### Redaction

Before the line is shown or posted, values that look like credentials become `***`, in every command of a compound
line (`a && b`, `a; b`, `a | b`). The rules err towards hiding too much:

- values of flags whose name contains `pass` (`password`, `passwd`, `passphrase`), `pwd`, `token`, `secret`, `auth`,
  `bearer`, `cookie`, `signature`, `apikey`/`api-key`/`api_key`, `credential`, `private-key`, `access-key`, or
  ends in `-key`/`_key` (`--password x`, `--auth-token=x`, `--oauth2-bearer x`, `--token-file x`);
- assignments, `key=value` lists and URL query parameters whose key matches the same words or contains `key`
  (`GH_TOKEN=...`, `AWS_SECRET_ACCESS_KEY=...`, `--set image.tag=2,db.pass=...`, `-var 'db_password=...'`,
  `https://h/x?a=1&token=...`, `?sig=...`, `-d 'user=a&password=...'`);
- URL userinfo (`oci://user:***@registry/...`, `https://***@github.com/...`; an `@` inside the password is hidden
  with it);
- the password of `-u`/`--user`/`--proxy-user user:pass` (`curl -u admin:***`);
- header values whose name matches those words or contains `key` (`Authorization:`, `Proxy-Authorization:`,
  `Cookie:`, `X-Api-Key:`), and the word after `Bearer`/`Basic`.

Only the redacted words change; the rest of the line stays as typed. Redaction is a safety net, not a guarantee: a
secret passed positionally or through an unusual flag name is not recognized, so prefer env files and secret
stores over secrets on the command line.

### Where things are kept

- Remembered decisions: kv `tern-grafana.annotations.approval`, `{ "<context>": "always" | "never" }` (no
  secrets). Open `tern-grafana://annotate` (no `id`) to see them and forget one (`x`), after which the next deploy
  in that context asks again.
- A draft waiting for a decision lives only in the host's memory for up to an hour; the approve block's link holds
  just a random id. After a Tern restart the block says the request is gone and posts nothing; nothing is ever
  posted when a block is restored.
- The log gets one line per decision (`action`, `outcome`, `context`, `choice`, `id`, `status`), never the text.

## Impact watch

With `impact.enabled`, a matching command that finished (exit 0 by default, `impact.on`) opens an impact block
beside the terminal for the context's metrics (`impact.context`, else the default context). For each signal it shows
the mean over the window before the command started next to the mean over the same window after it finished, a
spark of each side on one scale, and the change in percent. It re-queries every `window / 15` (15 s to 60 s) until
the after window is over, then shows the final comparison.

Tones: a change under 5% is flat (green); a change the good way is green; the bad way is yellow under 25% and red
from 25% (or from zero, e.g. errors appearing); signals with `"bad": "none"` show any change in blue.

Signals:

- **Configured** (`impact.signals`) win. Placeholders `{{namespace}}`, `{{service}}` and `{{cwd_basename}}` are
  filled from the command (see above) and its directory; a signal whose placeholder cannot be filled is listed as
  skipped with the reason, never queried half-filled.
- **Guessed** otherwise, and badged "guessed": the server's metric names are probed for a request counter
  (`http_requests_total`, else `*http*_requests_total`, else `*_requests_total`) with a status label (`code`,
  `status`, `status_code`, ...), and a latency histogram (`<prefix>_request_duration_seconds_bucket`, else
  `http_request_duration_seconds_bucket`). The guesses are request rate, 5xx ratio and p95 latency, scoped by
  `namespace` and `service`/`app` labels only when the counter has them.

Keys: up/down select a signal, enter opens it in the Query block over both windows, `r` re-queries.

## Configuration

```json
"annotations": {
  "enabled": true,
  "on": "success",
  "tags": ["tern", "deploy"],
  "patterns": ["helm upgrade", "kubectl apply", "kubectl rollout restart|undo", "terraform apply"],
  "context": "prod",
  "dashboard_uid": "service-overview",
  "panel_id": 4
},
"impact": {
  "enabled": true,
  "window": "15m",
  "on": "success",
  "signals": {
    "prod": [
      { "name": "5xx ratio", "expr": "sum(rate(http_requests_total{namespace=\"{{namespace}}\",code=~\"5..\"}[1m])) / sum(rate(http_requests_total{namespace=\"{{namespace}}\"}[1m]))", "unit": "percentunit", "bad": "up" },
      { "name": "p95", "expr": "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{service=\"{{service}}\"}[1m])))", "unit": "s" }
    ],
    "*": [{ "name": "requests", "expr": "sum(rate(http_requests_total[1m]))", "unit": "reqps", "bad": "down" }]
  }
}
```

`annotations`:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `false` | Post annotations for matching commands (after approval per context). |
| `on` | `"success"` or `"always"` | `"success"` | Annotate only commands that exited 0, or any finished command. |
| `patterns` | list of strings | the defaults above | Commands that count as deploys (also for the impact watch); replaces the defaults. At most 64. |
| `tags` | list of strings | `["tern", "deploy"]` | Tags on every annotation; the command kind is added. At most 16. |
| `context` | string | `default_context` (the host's, see `hosts`) | Context whose Grafana gets the annotations; it needs a `grafana` endpoint. |
| `dashboard_uid` | string | none | Attach annotations to this dashboard instead of the whole organization. |
| `panel_id` | whole number | none | With `dashboard_uid`: attach to this panel. |

`impact`:

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | boolean | `false` | Open an impact watch after matching commands. |
| `window` | duration string | `"15m"` | Length of the before and the after window, from `"1m"` to `"6h"`. |
| `on` | `"success"` or `"always"` | `"success"` | Watch only commands that exited 0, or any finished command. |
| `context` | string | `default_context` | Context whose metrics are queried. |
| `signals` | list, or object of context name (or `"*"`) to list | none (guess) | Signals to compare; a context without its own list uses `"*"`, and without either the signals are guessed. At most 12 per list. |

A signal is `{ "name": string, "expr": string, "unit": string?, "bad": "up" | "down" | "none" }`: `unit` is a
Grafana unit id (`s`, `percentunit`, `reqps`, ...), `bad` is the direction that is a regression (default `"up"`).
Unknown keys and bad values are reported as problems and fall back to their defaults.
