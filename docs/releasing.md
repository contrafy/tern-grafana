# Releasing

## Versioning

- [SemVer](https://semver.org). Before 1.0.0 a minor bump (`0.y.0`) may break config keys, link formats
  (`tern-grafana://...`), kv records or saved block state; patch releases (`0.y.z`) only fix.
- The plugin version is `version` in `plugin.toml` (Tern shows it in `tern plugin list`; CI's `package` job rejects
  a version that is not SemVer). Tags are `v<version>`.
- The config file carries its own `version` (only `1` exists, [configuration.md](configuration.md)); bump it only
  with a migration path for existing files.

## Steps

Nothing is pushed, tagged or published without the maintainer's approval.

1. `master` is green in CI (`.github/workflows/ci.yml`, and `dev-stack.yml` if `dev/` changed), and locally on macOS
   arm64 with the dev stack up (`make stack-up`): `make check` and `make e2e` pass (CI cannot run Tern).
2. On a release branch:
   - set `version` in `plugin.toml`;
   - in `CHANGELOG.md` rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a new empty `## [Unreleased]`
     above it, and update the compare links at the bottom;
   - check `README.md` (status, tested Tern version, install lines) and the screenshots it links.

   Open a PR titled `chore(release): vX.Y.Z` and merge it.
3. Run the smoke test below on the merged commit.
4. Tag and publish:

   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   awk '/^## \[X.Y.Z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md >/tmp/notes.md
   gh release create vX.Y.Z --title "vX.Y.Z" --notes-file /tmp/notes.md --verify-tag
   ```

`tern plugin install github.com/contrafy/tern-grafana` clones the default branch, so a release is what `master`
holds at the tag. To install an exact tag, clone it and install the directory:

```sh
git clone --branch vX.Y.Z https://github.com/contrafy/tern-grafana
tern plugin install ./tern-grafana --force
```

## Manual smoke test

Run on macOS arm64 (and Linux x86_64 only if a Tern build for it is available; otherwise record it as not run).
The tester is not the author and uses only `README.md` and `docs/`; every point where they needed help is a
documentation bug to file before the release.

Use the local dev stack (`make stack-up`) and a scratch Tern that holds nothing of value: a sandbox from
`scripts/dev-tern.sh`, which keeps Tern's config, daemon, logs, `HOME` and `XDG_CONFIG_HOME` under `/tmp`:

```sh
export TG_TERN_SANDBOX=/tmp/tg-tern-release
sh scripts/dev-tern.sh clean
sh scripts/dev-tern.sh start            # in a long-lived terminal
sh scripts/dev-tern.sh env              # TERN_CONFIG_DIR, TERN_DAEMON_SOCKET, ... for the commands below
```

With those variables exported in a second terminal (never the real `~/.config`), install from GitHub, not the
checkout.

Install

- [ ] `tern plugin install github.com/contrafy/tern-grafana`
- [ ] `tern plugin list`: `tern-grafana` at the release version, `ready`, no problems.
- [ ] Palette "Grafana: Settings" without a config file offers the starter templates; "Local dev stack" previews
      and writes a valid file. Point it at the stack (`token_file` from `sh scripts/stack.sh token-path grafana12`)
      and `t` tests every endpoint green.

Query and lenses

- [ ] "Grafana: Query": `sum by (job) (up)`, `enter`: chart and legend; `t` table; `left`/`right` cursor; `h`
      history.
- [ ] `promtool query instant http://localhost:9090 up`, `amtool alert query --alertmanager.url=http://localhost:9093`,
      `logcli query --addr=http://localhost:3100 '{job="loggen"}'`, `curl -s 'http://localhost:9090/api/v1/query?query=up'`:
      native views; Native/Raw toggle; "Open in ..." actions.

Dashboards and links

- [ ] "Grafana: Dashboard": picker lists Tern Panels, Tern Variables, Tern Logs and Traces; panels draw natively;
      the heatmap renders through Grafana 12's renderer, and on Grafana 11 offers "Open in browser".
- [ ] Variable picker, `p` pins a panel, `o` opens a browser pane.
- [ ] Clicking `http://localhost:3000/d/tern-panels/...` and a `/d-solo/` URL in a terminal opens the blocks.

Alerts and ops

- [ ] "Grafana: Alerts": firing alerts grouped; `v` rules with the failing rule; status segment (status bar on)
      shows the firing count and opens the inbox.
- [ ] `s` on an alert, comment, `S`, `y`: the silence appears in Alertmanager; `x` and `y` in the list expire it.
- [ ] "Grafana: Ops": targets (one down), cardinality, info.

Logs, traces, watches and deploys

- [ ] "Grafana: Logs" on `{job="loggen"}`: level chips, `t` tail, `T` on a line with a trace id opens the trace.
- [ ] "Grafana: Traces": search, waterfall, `L` opens the span's logs.
- [ ] A watch in the config fires into the status line and toasts.
- [ ] With `annotations.enabled`, a fake `helm upgrade` opens the approve block; Once posts an annotation visible in
      Grafana.

Uninstall

- [ ] `tern plugin remove tern-grafana`; `tern plugin list` no longer shows it; `promtool query ...` shows raw
      output again.
- [ ] Optional cleanup documented and complete: config (`~/.config/tern-grafana/`).
- [ ] `sh scripts/dev-tern.sh clean` removes the scratch sandbox.
