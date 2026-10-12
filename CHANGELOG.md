# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (pre-1.0: minor
versions may break).

## [Unreleased]

## [0.2.0] - 2026-10-12

### Added

- **Connect Grafana** in the Settings block (first starter, `c`): paste a Grafana
  or Grafana Cloud URL and a service account token; the token is tested first,
  datasources are discovered automatically, then the token is stored and the
  context written. **Update token** rotates it; removing a context offers to
  delete the stored token.
- OS keychain credentials: `token_keychain` / `password_keychain` read from the
  macOS keychain or the Linux Secret Service (service `tern-grafana`). Tokens are
  written over stdin, never on a command line.
- `token_env` also finds variables exported in your login shell, so they work
  when Tern is opened from the Dock or Finder.

### Changed

- Credential problems are one actionable line (for example "No token stored for
  cloud in the macOS keychain; open Grafana: Settings and use Connect or Update
  token", or "the 1Password CLI (op) is not installed"); Lua tracebacks go to
  Tern's log, never to the screen.
- No starter template uses the 1Password CLI anymore; `token_cmd` and
  `token_file` remain as advanced options for password managers.

## [0.1.1] - 2026-10-12

### Fixed

- Settings: choosing the Grafana Cloud (or any) starter template no longer fails
  with "table has a protected metatable". Tern tags decoded JSON arrays with a
  protected metatable, which `table.clone` refuses; every copy of decoded data
  now avoids it, and the test suite decodes JSON the same way Tern does.
- Config and `token_file`/`password_file` paths that are symlinks (stow, chezmoi,
  home-manager, sops-nix) are read; Settings refuses to overwrite a symlinked
  config and says to edit its target.
- Deploy annotations redact more secrets before posting: tokens in URL query
  strings, URL userinfo (passwords containing `@`), auth, token, cookie and key
  headers, `-u user:pass`, `--oauth2-bearer`, and `--set` values under secret keys.
- Investigate works for blocks on remote hosts: the prompt travels in the link
  instead of the local key-value store, and only a preview opened in this window
  can start the agent.
- Explanations such as "Cannot open logs" are shown; they used a toast level
  Tern does not accept.
- Times stay on the wall clock after the machine sleeps (alert staleness, watch
  toasts, Investigate expiry, silence and annotation times).
- Carly answers encode empty lists as `[]`, and large answers are refused
  earlier (512 KiB) so they stay within the window's time budget.

### Changed

- Alert fingerprints are computed without per-byte allocation.

## [0.1.0] - 2026-10-12

### Added

- Contexts and auth: one config file describing Grafana and direct Prometheus,
  Alertmanager, Loki and Tempo endpoints per context; credentials from
  `token_cmd`, an environment variable or a `0600` file; bearer, basic and extra
  headers (such as `X-Scope-OrgID`); the whole file is validated with every
  problem reported at once.
- Settings block ("Grafana: Settings"): edit the config safely and test each endpoint.
- TLS options (custom CA, mutual TLS, insecure) via a `curl` transport fallback.
- Grafana unit formatting and thresholds mapped to Tern tones.
- Grafana time ranges (`now-6h`, absolute times) and step math (`$__interval`,
  `$__rate_interval`, `$__range`) with LTTB downsampling.
- Query block ("Grafana: Query"): PromQL scratchpad with metric and label
  autocomplete, range picker, native time series graph with a keyboard cursor and
  legend read-out, table/instant view, auto-refresh and query history.
- `query` config section: `default_range`, `max_points`, `refresh`.
- Grafana URL routing: Explore links open the Query block; Grafana pages without a
  native view open in a Tern browser pane.
- Lens: `promtool query instant|range` output rendered as a native graph or table.
- Dashboard block ("Grafana: Dashboard"): search and open Grafana dashboards with
  their grid layout, rows, variables and picker, time range and auto-refresh.
  Panels are drawn natively (time series, stat, gauge, bar gauge, table, text,
  logs), else as a PNG from Grafana's image renderer when available, else with an
  action to open them in a Tern browser pane.
- Panel block: pin one dashboard panel as its own block.
- Grafana `/d/` and `/d-solo/` links open the Dashboard and Panel blocks; alert
  list and alert rule links open the alerts inbox.
- Alerts inbox ("Grafana: Alerts"): firing, pending and silenced alerts from
  Grafana unified alerting, Alertmanager v2 or Prometheus, grouped by labels, with
  runbook and dashboard links from annotations.
- Status-line segment with firing counts per context, toned by severity; clicking
  it opens the inbox. Visible while Tern's status bar is on.
- `dashboard` config section (`max_points`, `min_refresh`, `render_theme`) and
  `alerts` config section (`contexts`, `group_by`, `poll_s`, `toasts`,
  `toast_severities`).
- Opt-in toasts when alerts start firing in a polled context (`alerts.toasts`),
  filtered by severity and announced once across windows.
- Silences block ("Grafana: Silences", or `s` on an alert): create a silence
  prefilled from an alert with a preview of the alerts it covers, list and expire
  silences, on Alertmanager v2 or Grafana's Alertmanager. Every write is shown on a
  confirmation panel and sent only after you confirm.
- Rules view (`v` in the alerts inbox): Grafana-managed and Prometheus alerting and
  recording rules with status, health, last evaluation, last error and query.
- Ops block ("Grafana: Ops"): Prometheus targets health, TSDB cardinality, and
  build, runtime, config and flags info, directly or through Grafana's datasource
  proxy.
- Lenses: `promtool check rules|config` and `promtool test rules`; `curl` against
  `/api/v1/query*` and `/api/ds/query`; `amtool alert` and `amtool silence`;
  `logcli query`.
- Logs block ("Grafana: Logs"): LogQL against Loki directly or through Grafana,
  with label, value and pipeline suggestions, colored levels, volume bars per
  level, a polling tail, and label, metadata and parsed-field chips that filter
  the query. Grafana Explore links on a Loki datasource open it. `logs` config
  section: `default_range`, `limit`, `tail_interval`, `volume`.
- Trace block ("Grafana: Trace"): a Tempo trace as a waterfall with per-service
  colors, error spans, the critical path, folding and span detail (attributes,
  events, links, resource), tolerant of missing parents, clock skew and duplicate
  spans; TraceQL search with tag and value chips. Tempo directly or through
  Grafana. `trace` config section: `search_limit`, `range`.
- Deploy annotations: finished deploy commands (helm, kubectl, terraform, tofu,
  argocd, flux, or your own patterns) post a Grafana annotation after you approve
  it per context (Always, Once or Never). Off until `annotations.enabled`.
- Deploy impact watch: a card beside the terminal comparing configured or guessed
  signals before and after a deploy. Off until `impact.enabled`.
- Carly: functions to run PromQL, list alerts, find dashboards and query logs, and
  a firing-alerts summary in Carly's request context.
- Investigate: open an agent on an alert with its labels, query, recent values and
  runbook in a prompt you preview first. `investigate` config section: `range`.
- Personal PromQL threshold watches (`watches`) polled in the background, shown in
  the status line and as toasts.
- Per-host default contexts (`hosts`): map hostnames or globs to the context used
  on that machine.
- Exemplars on Query graphs and dashboard time series: `x` selects the nearest,
  `enter` opens its trace. `query` config keys `exemplars` and
  `exemplar_trace_label`.
- Jumps between signals: metrics to logs (`L` in the Query block and dashboard
  panels), logs to metrics (`M`), logs to trace (`T` or a line's `trace` chip)
  and a span to its logs (`L`). Config keys `logs.correlate_labels`,
  `logs.trace_id_pattern` and `trace.logs_query`.
- Shared time range and cursor (`S`) across Query, Dashboard, Panel, Logs and
  Trace search blocks.
- `logcli query` lens: open the same query in the Logs block.
- Project scaffold: `plugin.toml` at the repository root, sources under `plugin/`,
  pinned repo-local tooling (`make bootstrap`), formatting, lint, typecheck and
  unit test runner (`make check`), CI.
- Repository docs: README with roadmap, contributing guide, security policy,
  code of conduct, support, issue and pull request templates.
- Docker dev stack in `dev/` (Grafana 11 and 12, Prometheus 2.53 and 3,
  Alertmanager, Loki, Tempo, image renderer) and fixtures recorded from it.
- SDK capability matrix and architecture contract.

[Unreleased]: https://github.com/contrafy/tern-grafana/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/contrafy/tern-grafana/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/contrafy/tern-grafana/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/contrafy/tern-grafana/releases/tag/v0.1.0
