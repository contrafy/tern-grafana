# Contributing

## Setup

Supported dev hosts: macOS arm64 and Linux x86_64. You need Tern, Docker (with
compose), `make`, `curl` and `jq`.

```sh
make bootstrap   # pinned luau, luau-lsp, StyLua, selene into .tools/
make check       # format check, lint, typecheck, unit tests
```

Tools are repo-local (`.tools/`, gitignored); nothing is installed globally.
See [docs/architecture.md](docs/architecture.md) before changing structure.

| Target | What it does |
| --- | --- |
| `make test` | Unit tests (`tests/unit/**/*.spec.luau` via `tests/run.luau`) |
| `make lint` / `make typecheck` | selene and luau-lsp |
| `make fmt` / `make fmt-check` | StyLua (tabs, column 120) |
| `make stack-up` / `make stack-down` | Docker dev stack in `dev/` |
| `make fixtures-capture` | Record fixtures from the running dev stack |
| `make e2e` | Drive a sandboxed Tern with `tern ctl` |

## Dev stack

`make stack-up` starts local servers from `dev/` with admin credentials that are
only for this stack: Grafana 12 (:3000), Grafana 11 (:3011), Prometheus 3
(:9090), Prometheus 2.53 (:9091), Alertmanager (:9093), Loki (:3100), Tempo
(:3200), plus the image renderer and node-exporter on the internal network.
Throwaway containers for experiments use other ports (13000+, 19090+).

## Fixtures

Fixtures in `tests/fixtures/` are recorded from the real dev stack per server
version with `make fixtures-capture`, never hand-invented when a real capture is
possible. Capture scrubs `Authorization` headers and tokens; check the diff
before committing anyway.

## Sandbox Tern

Run Tern only through `scripts/dev-tern.sh`, which uses a sandbox under `/tmp`.
Never run `tern` subcommands against your own Tern config or daemon. `make e2e`
uses the same sandbox and drives it with `tern ctl` (`plugins expect`, `click`,
`key`, `shot`). Screenshots must not show tokens, personal paths or hostnames.

## Conventions

- **Conventional Commits** (`feat:`, `fix:`, `docs:`, `test:`, `build:`,
  `ci:`, `chore:`, `refactor:`), imperative, small and atomic.
- **One branch per milestone** (or smaller change), PR against `master`.
- **TDD**: write the failing test first; tests state why the behavior matters.
  No tests of wiring, forwarding or source text.
- **Pure core**: code under `plugin/lib/` never references the `tern` global;
  decoders, clocks and config are passed in. Only `plugin/host.luau`,
  `plugin/window.luau` and `plugin/*_host.luau` adapters call `tern.*`; they
  execute effects and decide nothing.
- Views are plain `{k, p, c}` tables. Parse and render in the host half only.
  Budgets: host 2 s per call, window 50 ms, formatters 4 ms.
- `--!strict` in every Luau file. The package is the repository root:
  `plugin.toml` there, shipped sources only under `plugin/` (`.luau`, `.css`),
  and no `require` leaves it.
- Never write secrets to disk, kv, logs, fixtures, screenshots, block args or
  saved state.
- No emojis in code, docs or commit messages.
- Keep `README.md` and `docs/` true to the code in the same PR; add a line under
  `## [Unreleased]` in `CHANGELOG.md` for user-visible changes.
