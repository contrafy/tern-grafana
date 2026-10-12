# Testing

Three layers, cheapest first. CI (`.github/workflows/`) runs the first two; e2e needs Tern, which is closed beta and
not installable on CI runners, so it stays local.

| Layer | Command | Needs | CI |
| --- | --- | --- | --- |
| Unit, lint, types | `make check` | `make bootstrap` | `ci.yml`: macOS arm64, Linux x86_64 |
| Package | (CI only) | Python 3.11+ | `ci.yml` job `package`: Linux x86_64 |
| Dev stack smoke | `sh scripts/stack.sh up && sh scripts/stack.sh smoke` | Docker with compose v2, `curl`, `jq` | `dev-stack.yml`: Linux x86_64, on `dev/**` or fixture tooling changes and weekly |
| End to end | `make e2e` | Tern, `jq`, Docker, a desktop session, the running dev stack | no |

## Safety rules

- Tern only in a sandbox under `/tmp` via `scripts/dev-tern.sh` (it refuses other paths): `TERN_CONFIG_DIR`,
  `TERN_DAEMON_SOCKET`, the logs, `HOME` and `XDG_CONFIG_HOME` of the window always point into the sandbox, and
  `tern ctl` always runs with `--control <sandbox>/ctl.sock`. Never the user's own Tern config, daemon, shell rc
  files or tern-grafana config.
- Servers only from the local dev stack ([dev-stack.md](dev-stack.md)), bound to `127.0.0.1`. Its admin password and
  service-account tokens are local throwaways.
- Tokens stay in `.sandbox/stack/<grafana>.token` (mode 0600). Configs reference them with `token_file`; scripts hand
  them to `curl` on standard input (`curl -K -`), never as arguments. No token is written to a config, fixture,
  screenshot, log or block argument.
- The e2e suite reads the stack but never writes to it: it opens the silence and annotation confirmations and
  cancels them, then checks on the servers that nothing was created.

## Unit tests

`make check` = `fmt-check` (StyLua), `lint` (selene, std `tern`), `typecheck` (luau-lsp with the pinned
`tern.d.luau`), `test-runner-selfcheck`, `test`.

- Specs: `tests/unit/**/*.spec.luau`, run by `tests/run.luau` under the pinned standalone `luau` (no filesystem:
  `make test` passes the spec list). `make test FILTER=<substring>` runs only tests whose
  `<file> :: <describe> > <it>` contains the substring.
- They cover `plugin/lib/**` only; that is why the library must not touch the `tern` global
  ([architecture.md](architecture.md)). Host and window adapters are covered by e2e.
- `tests/selfcheck/check.sh` proves failing, crashing and unloadable specs turn the run red.

TDD: write the failing spec first; name tests after the reason, not the mechanism. No tests of wiring, forwarding or
source text.

## Fixtures

Specs parse real server output recorded from the dev stack, one directory per backend and version
(`tests/fixtures/<backend>/<version>/`, listed in `tests/fixtures/MANIFEST.tsv`). Never hand-write a fixture the
stack can produce; change the inputs under `dev/` and capture again.

- `make fixtures-capture` (`sh scripts/stack.sh capture [--refresh [PATTERN]]`) records new fixtures; existing ones
  are only overwritten with `--refresh`. Capture scrubs `glsa_` tokens and aborts if any credential string
  remains.
- `make fixtures` (`scripts/fixtures/embed.sh`) embeds everything into the gitignored
  `tests/fixtures/generated.luau`, because standalone luau cannot read files; specs read it through
  `tests/lib/fixtures.luau`. `make test` and `make typecheck` run it first.

Details, the capture layout and how to add a fixture: [dev-stack.md](dev-stack.md#fixtures).

## Dev stack

`make stack-up` starts Grafana 12 and 11, Prometheus 3 and 2.53, Alertmanager, Loki, Tempo, the image renderer and
the generators, waits until healthy and mints one token per Grafana; `make stack-down` removes it all.
`sh scripts/stack.sh status` shows what is up. Everything about it: [dev-stack.md](dev-stack.md).

## Manual sandbox

For interactive work, in a long-lived terminal:

```sh
TG_TERN_SANDBOX=/tmp/tg-tern-<name> sh scripts/dev-tern.sh start     # the window, foreground
TG_TERN_SANDBOX=/tmp/tg-tern-<name> sh scripts/dev-tern.sh link      # load this checkout (reloads on save)
```

then `ctl ...` (any `tern ctl` command: `tree SEL`, `key K`, `type "..."`, `click X Y`, `plugins run ID`,
`plugins expect "..."`), `shot NAME [DEST]`, `logs daemon|window`, `stop`, `clean`. The default sandbox is
`/tmp/tg-tern`. Write the sandbox's config to `<sandbox>/xdg/tern-grafana/config.json`; the panes see that
`XDG_CONFIG_HOME` too.

## End to end (local only)

`make e2e` (`scripts/e2e.sh [--only GLOB] [--keep]`) drives a real Tern window:

1. Skips with `e2e: SKIPPED` (exit 0) when `tern` is not installed, or when the dev stack is not up (any endpoint
   `DOWN` in `scripts/stack.sh status`, or a missing Grafana token).
2. Starts from a clean sandbox (`TG_E2E_SANDBOX`, default `/tmp/tg-tern-e2e`; `dev-tern.sh clean` first).
3. Writes the sandbox config from the running stack: context `lab` (Grafana 12 with `token_file` from
   `scripts/stack.sh token-path grafana12`, plus direct Prometheus 3, Alertmanager, Loki and Tempo), context `g11`
   (Grafana 11 with datasource `prom2`), a 15 s alert poll, deploy annotations for `helm upgrade`, and one threshold
   watch (`up{job="down"} == 0`).
4. Puts wrappers first on the pane's `PATH` (`<sandbox>/bin`): `promtool`, `amtool` and `logcli` run the stack's
   pinned images with `docker run --network host`, so `localhost` URLs work as typed; `helm` is a fake that only
   prints.
5. Links a snapshot of the package (HEAD's `plugin.toml` and `plugin/` plus their working-tree changes) copied into
   the sandbox, so saving files while it runs does not reload the plugin under test.
6. Runs `tests/e2e/scenarios/*.sh`, each in a subshell after closing every pane but the shell, prints one line per
   scenario with its time, then checks the logs for style sheet errors and lenses that fell back to raw on an
   error. Stops the window and deletes the sandbox (`--keep` or `E2E_KEEP=1` leaves it running).

`E2E_ONLY=<glob>` (or `--only`) runs matching scenarios, for example `E2E_ONLY='*dash*' make e2e`. Each scenario
takes at least one screenshot into `.sandbox/e2e/<scenario>/`; a failing one also leaves `fail.png` and `tree.json`
there, and the daemon and window logs go to `.sandbox/e2e/`.

Scenarios assert on the element tree (`tern ctl tree`, `plugins expect`), never on screenshots alone. Every scenario
is independent of the others and of their order, and leaves nothing behind:

| Scenario | Covers |
| --- | --- |
| `01-query` | Palette "Grafana: Query", type a query, `enter`: SVG chart and legend; `t`: instant table rows |
| `02-settings` | Settings block: `valid` badge, both contexts, `t` on lab's prometheus reports its version |
| `03-dashboard` | Picker lists the three provisioned dashboards; Tern Panels opens with native stat values; the same dashboard on Grafana 11 (clicked URL) shows the heatmap on the browser rung with its reason |
| `04-alerts` | Inbox firing count equals Alertmanager's active alerts, fixture alerts listed, status segment count; `v` rules view with the failing rule |
| `05-silence` | `s` on an alert opens the prefilled form, `S` the confirmation, `n` cancels; Alertmanager's silences are unchanged |
| `06-ops` | Targets tab: one down target, its pool first with the scrape error; `u` keeps only it |
| `07-lenses` | `promtool query instant`, `amtool alert query`, `logcli query` and `curl .../api/v1/query` claimed and rendered natively |
| `08-logs` | Logs block on `{job="loggen"}`: level chips and colored lines; the error chip filters to `level="error"` |
| `09-trace` | Trace search lists generated traces; `enter` opens a waterfall with one row per span |
| `10-watches` | The configured watch fires into the status line; clicking it opens its query |
| `11-annotations` | Fake `helm upgrade` opens the approve block with the annotation preview; Dismiss posts nothing (checked on Grafana) |
| `12-links` | A clicked Grafana 12 `/d/` URL opens the Dashboard block with the URL's range; `/d-solo/` opens the Panel block |

Not covered by e2e (unit specs only, or manual): Grafana's image renderer PNG rung (render timing makes it slow and
flaky), write paths (creating or expiring silences, posting annotations), toasts, the impact watch, Carly exports,
Investigate (needs an agent), remote hosts and Linux.

Writing a scenario: source-only shell (`tests/e2e/lib.sh` is already loaded), one block per behavior, wait with
`bwait BLOCK TEXT [SEL]` or `wait_for DESC CMD...` instead of sleeping, assert with `eq`/`contains`/`has`, and take a
`shot NAME`. Type text with `type_text` and lines with `type_line` (they escape quotes for `tern ctl`). Keep it
read-only against the stack. `shellcheck -x -s sh scripts/e2e.sh tests/e2e/lib.sh tests/e2e/scenarios/*.sh` must be
clean.
