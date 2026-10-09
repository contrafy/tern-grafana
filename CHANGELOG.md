# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (pre-1.0: minor
versions may break).

## [Unreleased]

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
- Grafana URL routing: Explore links open the Query block; dashboard, panel and
  alert links open in a Tern browser pane.
- Lens: `promtool query instant|range` output rendered as a native graph or table.

- Project scaffold: `plugin.toml` at the repository root, sources under `plugin/`,
  pinned repo-local tooling (`make bootstrap`), formatting, lint, typecheck and
  unit test runner (`make check`), CI.
- Repository docs: README with roadmap, contributing guide, security policy,
  code of conduct, support, issue and pull request templates.
- Docker dev stack in `dev/` (Grafana 11 and 12, Prometheus 2.53 and 3,
  Alertmanager, Loki, Tempo, image renderer) and fixtures recorded from it.
- SDK capability matrix and architecture contract.
