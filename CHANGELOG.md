# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (pre-1.0: minor
versions may break).

## [Unreleased]

### Added

- Project scaffold: `plugin.toml` at the repository root, sources under `plugin/`,
  pinned repo-local tooling (`make bootstrap`), formatting, lint, typecheck and
  unit test runner (`make check`), CI.
- Repository docs: README with roadmap, contributing guide, security policy,
  code of conduct, support, issue and pull request templates.
- Docker dev stack in `dev/` (Grafana 11 and 12, Prometheus 2.53 and 3,
  Alertmanager, Loki, Tempo, image renderer) and fixtures recorded from it.
- SDK capability matrix and architecture contract.
