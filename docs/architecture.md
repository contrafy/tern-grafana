# Architecture

Tern Grafana is one Tern plugin package: the repository root holds `plugin.toml`, and every shipped source lives
under `plugin/`. SDK facts this design relies on are recorded with evidence in
[sdk-capability-matrix.md](sdk-capability-matrix.md); the local backend stack used for fixtures and integration
runs is described in [dev-stack.md](dev-stack.md).

## Rule: pure core, thin host glue

- `plugin/lib/**` is pure Luau. It never references the `tern` global. Whatever it needs (JSON decoder, the JSON
  null sentinel, clock values, pane size, config) is passed in through an `Env` table. It runs under the standalone
  `luau` binary, so every decision is unit tested in `tests/unit/` against recorded fixtures.
- Only `plugin/host.luau`, `plugin/window.luau` and the `plugin/*_host.luau` adapters call `tern.*`. They execute
  effects and feed results back; they decide nothing.
- Views are plain `{k, p, c}` tables built by `plugin/lib/ui.luau`, not `tern.ui` builders.

## Module map

```
plugin.toml                manifest: lenses, blocks, styles; entries under plugin/
plugin/
  host.luau                host half: registers blocks and lenses, starts pollers, command hooks
  window.luau              window half: route.link (tern-grafana:// and Grafana URLs), palette commands,
                           status segment, Carly exports, agent handoff
  transport_host.luau      executes Http effects: auth resolution, tern.fetch or curl fallback
  blob_host.luau           turns view assets (SVG/PNG bytes) into blob ids, cached by content hash
  <block>_host.luau        one adapter per block: runs lib/<block>/state effects
  tern-grafana.css         styles, including chart series classes bound to theme variables
  lib/
    env.luau               Env type and helpers (no tern access)
    ui.luau                {k,p,c} node builders
    config/                config schema, validation, defaults, context routing
    auth/                  credential source descriptions (token_cmd/env/file), header building
    transport/             Request/Response types, URL joining, curl argv building, error classification
    frame/                 Frame model, conversions (Prometheus, Grafana data frames, Loki, Tempo)
    source/
      prom.luau            Prometheus HTTP API request builders and parsers
      grafana.luau         Grafana HTTP API request builders and parsers
      alertmanager.luau    Alertmanager v2 (direct and Grafana-managed)
      loki.luau            Loki HTTP API
      tempo.luau           Tempo HTTP API
    time/                  range parsing (now-6h), step/interval math, $__interval, $__rate_interval
    units/                 Grafana unit ids, value formatting, thresholds -> tones
    render/                svg_timeseries, legend, stat, gauge, bargauge, table, logs, waterfall
    panels/                panel registry: supports(panel) and view(panel, frames, env)
    dashboard/             dashboard model, layout from gridPos, variables, interpolation, ladder
    query/ alerts/ silences/ ops/ logs/ trace/ settings/ impact/ watches/   block state machines
    lens/                  promtool, amtool, logcli, curl capture parsers and views
    links/                 tern-grafana:// encode/decode, Grafana URL recognition
```

## Configuration

One JSON file on the machine running the host half: `$XDG_CONFIG_HOME/tern-grafana/config.json`
(default `~/.config/tern-grafana/config.json`). It never contains secrets, only descriptions of where to get them.

```json
{
  "version": 1,
  "default_context": "lab",
  "contexts": {
    "lab": {
      "grafana": {
        "url": "http://localhost:3000",
        "auth": { "type": "bearer", "token_cmd": ["op", "read", "op://dev/grafana/token"] },
        "org_id": 1,
        "datasources": { "prometheus": "prom3", "loki": "loki", "tempo": "tempo", "alertmanager": "am" }
      },
      "prometheus": {
        "url": "http://localhost:9090",
        "auth": { "type": "none" },
        "headers": { "X-Scope-OrgID": "tenant-1" },
        "path_prefix": "",
        "tls": { "ca_file": null, "cert_file": null, "key_file": null, "insecure": false },
        "timeout_ms": 15000
      },
      "alertmanager": { "url": "http://localhost:9093" },
      "loki": { "url": "http://localhost:3100" },
      "tempo": { "url": "http://localhost:3200" }
    }
  }
}
```

- An endpoint is `{url, auth?, headers?, path_prefix?, tls?, timeout_ms?}`. `auth` is one of
  `{type="none"}`, `{type="bearer", token_cmd|token_env|token_file}`,
  `{type="basic", username, password_cmd|password_env|password_file}`.
- A context may hold a `grafana` endpoint, direct endpoints, or both. Routing (`lib/config/route.luau`) picks per
  signal (metrics, logs, traces, alerts): a configured direct endpoint wins; otherwise the Grafana datasource of
  that signal, queried through `/api/ds/query` or the datasource proxy.
- Any `tls` field set forces the curl transport for that endpoint, because `tern.fetch` has no TLS options.
- Feature sections (`query`, `alerts`, `annotations`, `impact`, `watches`, `hosts`) are added by the milestones
  that own them and documented in `docs/configuration.md`.

Secrets: tokens are resolved in the host half on demand, held only in host VM memory with a TTL, and passed to
curl through stdin (`--config -`), never argv. They are never written to kv, files, logs, fixtures, block args,
saved state or URLs.

## Data model

```luau
type FieldType = "time" | "number" | "string" | "boolean" | "other"
type Field = {
	name: string,
	type: FieldType,
	values: { any },            -- dense; a missing value is Frame.NULL, never nil
	labels: { [string]: string }?,
	config: { unit: string?, displayName: string?, decimals: number?, min: number?, max: number? }?,
}
type Frame = {
	name: string?,
	refId: string?,
	fields: { Field },
	meta: { type: string?, executedQueryString: string?, notices: { { severity: string, text: string } }? }?,
}
type QueryError = {
	kind: "auth" | "network" | "timeout" | "http" | "parse" | "query" | "unsupported",
	message: string,
	status: number?,
}
type QueryResult = { ok: true, frames: { Frame }, warnings: { string } } | { ok: false, error: QueryError }
```

Times are epoch milliseconds. Prometheus sample strings (`"NaN"`, `"+Inf"`, `"-Inf"`) become numbers. A time
series is one frame with a time field and one number field carrying the series labels, the same shape Grafana's
multi-frame time series uses, so Grafana and direct results flow into the same renderers.

## Effects

Every block and lens is a pure state machine in `lib/<feature>/state.luau`:

```luau
init(args: { string }, saved: any, env: Env) -> (State, { Effect })
update(state: State, msg: Msg, env: Env) -> (State, { Effect })
view(state: State, env: Env) -> (Node, Assets)
save(state: State) -> any            -- JSON values, never secrets
```

`Effect` is a tagged table executed by the adapter: `{kind = "http", tag, context, signal, request}`,
`{kind = "timer", tag, ms}`, `{kind = "kv_set", key, value}`, `{kind = "toast", level, text, sub}`,
`{kind = "open", target}`, `{kind = "copy", text}`, `{kind = "exit"}`. Results come back as messages
(`{kind = "http_done", tag, response}`, `{kind = "tick", tag}`, key and UI events). A generation counter in state
drops late responses after the user changed the query or range.

`Assets` maps an asset key to `{mime, bytes}`; `image` nodes reference assets by `p.asset`. `blob_host.luau`
replaces `asset` with a blob id from `cx:blob`, reusing ids for unchanged bytes (Tern keeps every blob file, so
an unchanged chart must never mint a new blob).

Block `init` is idempotent: Tern restores blocks after a restart by re-running `init` with the same args and saved
state, so one-shot effects (opening panes, posting annotations, creating silences) only ever follow a user event.

## Charts

Time series are SVG documents built in `lib/render/svg_timeseries.luau` and shown in an `image` node. Tern does not
resolve `var()` in SVG attributes or inline styles, so every stroke and fill is a class (`tg-s1` ... `tg-s10`,
`tg-grid`, `tg-axis`, `tg-th-<tone>`) that `plugin/tern-grafana.css` binds to theme variables; a theme switch
recolors without a re-render. An SVG blob is capped at 256 KiB, so the renderer downsamples (LTTB) to a point
budget and drops series beyond a cap with a legend note. Tern strips SVG `<title>`, and plugin blocks always report
80x24 cells with no resize callback, so:

- `maxDataPoints` is a config default (not derived from the pane), and the image scales to the pane width.
- Point read-out is a keyboard cursor drawn as an overlay child of the `image` node (a flex spacer plus a 1-px
  line), which moves without a new blob; the legend shows values at the cursor.

Native kinds cover the rest: `meter` for gauge and bargauge, `rate` and `text` for stat, `chart` spark for
sparklines, `table`/`el` grids for tables, `text` for logs.

## Rendering ladder

For each dashboard panel `lib/dashboard/ladder.luau` decides:

1. Native: the panel registry supports the panel type and options, and every query resolved.
2. Grafana PNG: the context has Grafana and `/api/frontend/settings` reports `rendererAvailable`. A render takes
   about 5 s, so it is requested asynchronously behind a placeholder and cached per panel, range and size.
3. Browser: open the panel (`/d-solo/...`) or dashboard in a Tern browser pane, which reuses the user's own Grafana
   login cookie.

The reason for each fallback is shown on the panel.

## Links

`tern-grafana://<action>?<query>` links (`query`, `dashboard`, `panel`, `alerts`, `silence`, `logs`, `trace`,
`ops`, `settings`, `browse`) carry no secrets. The window half claims every such link, wraps the handler in
`pcall`, and on error answers `{url = ...}` for Grafana URLs (the browser still opens) or `{handled = true}` for
private links, so a link never falls through to the OS. Grafana URLs under a configured Grafana base URL (plain
clicks in terminal output included) are claimed the same way and opened natively.

A block's `cx:open` goes through our own `route.link`, which claims Grafana URLs, so the host half asks for the
browser with `tern-grafana://browse?url=<encoded>` and the window answers `{url = <decoded>}`. The window half's own
`cx:open` skips routes and opens the browser directly.

## Cross-half state

The halves share only `tern.kv` keys under `tern-grafana.` (for example the alert summary the status segment shows,
the shared time range, query history, focused panes for poll throttling). kv is a 0644 file readable by any local
program, and block args and saved state are written to the daemon's state file, so none of them hold secrets or
query results beyond small summaries.

Toasts come from the window half (its timers receive a `cx`) or from a live block's `cx`; host timers have no `cx`.
The status segment reads the kv summary (well under the 4 ms formatter budget) and a window timer calls
`tern.chrome.refresh()` only when the summary changed. Host `command_finished` carries `line`, `pane`, `status` and
`took_ms` but no `cwd`, so the host pairs it with the `cwd` from `command_started` per pane.
