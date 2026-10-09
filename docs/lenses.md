# Command lenses

A lens replaces a command's raw output in the terminal with a native view. Tern keeps the raw output one click away
(the block's **Native/Raw** toggle), and every lens falls back to raw for output it cannot read faithfully.

## How claims work

Tern decides which commands a lens takes from the `match` globs in `plugin.toml`, before any plugin code runs
(docs/sdk-capability-matrix.md row 11a):

- The text matched is the program and its arguments joined by single spaces, after quotes are removed, leading
  `VAR=value` assignments and wrappers (`command`, `sudo`, `env`, `time`, ...) are skipped, and stderr/stdin
  redirections (`2>/dev/null`, `< file`) are dropped.
- `*` is any run of characters (none included), `?` exactly one; everything else matches itself.
- Pipelines (`curl ... | jq`), lists (`clear; curl ...`), stdout redirections (`> out.json`), subshells and heredocs are
  never lensed.
- Among a plugin's lenses, the first in manifest order with a matching glob wins. A claim also keeps Tern's built-in
  lens (for example its HTTP/JSON lens) from running, so the claimed commands below render JSON and error bodies
  themselves instead of returning to raw.

Every lens stays raw while the command runs (the output is read whole at the end) and returns to raw for help output,
output larger than 8 MiB or 50,000 lines, and anything it does not recognize. Lines it could not place are counted in
a muted "N lines not shown (Raw shows everything)" note.

Each view's state is rebuilt from the command line and the captured output after a plugin reload, so clicks keep
working on old blocks: every clickable carries its whole choice (for example `v=table:1`) in its action.

## promtool query

Lens id `promtool-query`, `plugin/lib/lens/promtool_query.luau`.

| Claims | |
|---|---|
| `promtool query instant *`, `promtool query range *`, `promtool query series *`, `promtool query labels *` | flags before the verb: `promtool query -* <verb> *` |
| `promtool -* query *` | global flags before `query` |

Reads both output formats (`-o promql`, the default, and `-o json`) of Prometheus 2.53 and 3.x promtool.

| Result | View |
|---|---|
| Range matrix | One row per series: name (labels shared by all series are listed once above), a spark, Last/Min/Max. **Graph/Table** chips switch to a table of every sample |
| Instant vector | A table: labels as columns, the value |
| Scalar | The number |
| `query series` | Label sets as a table |
| `query labels` | The values |
| `query error: ...`, unreachable server, timeout, rejected arguments | An error card naming the server when it could not be reached |

**Open in Query block** opens `tern-grafana://query` with the expression, mode (graph for range, table for
instant) and time range of the run, on the configured context whose `prometheus` URL (with `path_prefix`) is the
promtool server, or on a Grafana context when the server is that Grafana's datasource proxy
(`<grafana>/api/datasources/proxy/uid/<uid>`, the datasource carried as `ds`). Without a matching context the view
says which server is not configured.

## promtool check and test

Lens id `promtool-check`, `plugin/lib/lens/promtool_check.luau`.

| Claims | |
|---|---|
| `promtool check rules`, `promtool check rules *` | rule files, or rules on standard input |
| `promtool check config *` | a config and every rule file it loads |
| `promtool test rules *` | rule unit tests |

Other `promtool check` commands (`web-config`, `healthy`, `ready`, `metrics`, `service-discovery`) are not claimed.

The view is a card with a pass/fail meter over the files, then one row per file (`OK`, `FAILED`, or `LINT` for
lint findings that only fail with `--lint-fatal`) with promtool's summary ("4 rules found", "3 rule files found",
"valid config syntax"):

- **check**: each finding is a diagnostic card under its file: the location `file:line:col` (linking to the file,
  `#L<line>C<col>`; relative paths resolve against the shell's directory), the rule group, rule number and name, and
  the message (click to copy). Multi-line messages (YAML error lists, duplicate-rule details) keep their extra lines
  in a code block. Rule errors carry their file name, so they land on the right file even when a wrapper such as
  `docker run` delivers stderr after later files' output.
- **test**: each failure is an error card titled by promtool's first line (`alertname: X, time: 1m`,
  `expr: "...", time: ...`) with the expected and actual output (`exp:`/`got:`) in a code block, cut at 40 lines.
  Prometheus 3 prints no `Unit Testing:` header per file, so verdicts are matched to the file arguments in order;
  when that is not possible (an unexpanded glob) the files are numbered.

At most 100 findings are drawn, then "... N more". A non-zero exit with no failure read is noted under the files.

## curl

Lens id `curl`, `plugin/lib/lens/curl.luau`.

| Claims | |
|---|---|
| `curl *api/v1/query*` | Prometheus-compatible `/api/v1/query`, `/api/v1/query_range`, `/api/v1/query_exemplars`, also through a Grafana datasource proxy and Loki's `/loki/api/v1/query*` |
| `curl *api/ds/query*` | Grafana's `/api/ds/query` |

The globs see the whole line, so the lens re-checks the URL: a request whose path does not end in one of the paths
above (`/api/v1/labels` with `api/v1/query` in a header, `/api/ds/query_history`), several URLs, or options that write
no body to the terminal (`-o`, `-O`, `-I`, `--help`) stay raw.

The output is the response body. `-i` header blocks and `-v` trace lines are skipped (also curl's closing
`* Connection ... left intact`, which lands on the body's row because the body has no trailing newline), and the
HTTP status they show is put in the header. A `-w` write-out around the body is ignored.

| Body | View |
|---|---|
| Prometheus `status: success`, matrix / vector / scalar / string | As for promtool query: spark rows with Graph/Table, a table, or the value. PromQL warnings and infos are listed |
| Prometheus `status: error` | The error, its `errorType`, red card |
| Exemplars | A table: series, exemplar labels (trace id), value, time |
| Loki streams | Log lines newest first (time, line; the stream labels as the tooltip), up to 200 |
| Grafana `/api/ds/query` results | One section per refId with its expression: number series as above, other frames (logs, tables, traces) as tables, a failed refId as an error |
| Grafana API error (`{"message": ...}`) | The message and status, red card |
| Anything else (plain text, HTML, other JSON, nothing) | Raw |

**Open in Query block** reads the request from argv: the URL's query string, `-d`/`--data`/`--data-raw` form data,
`--data-urlencode name=value`, and an inline JSON body (`-d '{...}'`, `--json`). Data read from a file (`-d @file`)
is not available, so those requests get no link.

- Prometheus: `query`, and `start`/`end` (range, opened as a graph) or `time` (instant, opened as a table over the
  hour before it), on the context whose `prometheus` URL is the request's server, or on the Grafana context whose
  datasource proxy it is.
- Grafana `/api/ds/query`: each refId's `expr`, datasource uid (`ds`), `from`/`to` and `instant`, on the context whose
  Grafana URL is the request's. Non-Prometheus datasources (a `datasource.type` other than `prometheus`, or the
  context's Loki datasource) get no link.
- LogQL and exemplar requests get no link.

The view never shows request headers or credentials; `--oauth2-bearer`, `-u` and `-H Authorization: ...` values are
read only to skip them.

## amtool

**Claims.** Lens `amtool`: `amtool alert`, `amtool alert *`, `amtool silence`, `amtool silence *`, `amtool -* alert`,
`amtool -* alert *`, `amtool -* silence`, `amtool -* silence *`. So `amtool alert`, `amtool alert query ...`, matchers
after `alert` (its default command), and global flags before or after the command all reach the lens.

**What it reads.** argv by kingpin rules (`--name=value`, `--name value`, `-ojson`, bool clusters such as `-sa`,
`--`): the command, matcher groups (a first argument without an operator reads as `alertname="<arg>"`, as amtool does),
`--alertmanager.url` (userinfo removed, never kept), state flags, `--receiver`, `--expired`, `--within`, `--created-by`,
`--id`, `-q`. The output format comes from the output itself, because amtool's config file can change the default:
`simple` and `extended` tabwriter tables (cut at the header's columns, counted in runes), `-o json`, and the bare IDs
of `silence query -q`. `amtool: error: ...` lines are errors; `Warning: ...` (version mismatch) is kept as a warning.

**View.** Alerts: a grid of alert name, state, start time and summary; `extended` and `json` add a severity column
(critical and error red, warning amber, info blue) and the labels other than alertname, severity and reserved `__x__`
names. State: `active` red, `unprocessed` amber, `suppressed` muted (`json` tells silenced from inhibited). The simple
format has no labels, so the view says severity needs `-o extended` or `-o json`. Silences: ID (first 8 characters),
matchers, state (`json`), start (`extended`), end, creator, comment. The header names the Alertmanager, matchers and
which states or silences are shown. Rows past 50 sit behind Show all (up to 500).

**Actions.** "Open alerts inbox" opens `tern-grafana://alerts` for the context whose `alertmanager` endpoint is the
amtool URL, or whose Grafana serves it (`<grafana>/api/alertmanager/<grafana|uid>`), filtered by the query's matchers;
with no such context it opens the default context and the view says so. Clicking an alert row opens the inbox filtered
to that alert name. Clicking a silence row copies its full ID.

**Raw fallbacks.** Other subcommands (`alert add`, `silence add|expire|import|update`), `check-config`, `config`,
`template`, help and version output, unknown `-o` values, output that is neither a known table nor JSON, while amtool
runs, and captures past 20,000 lines or 8 MiB. Table rows a newline in a summary broke out of the table are counted as
"not shown (Raw shows everything)". Errors render as an error card: cannot reach Alertmanager, timed out, not
authorized, arguments rejected, query failed.

## logcli

**Claims.** Lens `logcli`: `logcli query *`, `logcli -* query *` (flags before or after `query`).

**What it reads.** argv by kingpin rules: the LogQL query, `--addr` (userinfo removed), `--output` (`default`, `raw`,
`jsonl`), `--no-labels`, `--quiet`, `--limit` (default 30), `--since`, `--from`, `--to`; values of every other flag,
credentials included (`--password`, `--bearer-token`, `--header`), are dropped. A query starting with a `{...}`
selector is a log query, anything else a metric query. Output: default lines `<time> <labels> <line>` (any
`--output-timestamp-format`), `--no-labels` lines `<time> <line>`, jsonl objects, raw lines; metric results are the
API's JSON (logcli prints it whatever `--output` says). logcli's stderr (Go log prefix `YYYY/MM/DD HH:MM:SS`): the
request URL is skipped, `Common labels: {...}` is kept, `error response from server: ...`, `error sending request ...`
and `Query failed: ...` are errors, `logcli: error: ...` is a usage error. In a zsh pane the shell's end-of-line mark
lands after logcli's final `]` of metric JSON (logcli prints no trailing newline; Tern captures `]%`); the lens drops
it.

**View.** Log queries: level counts, then one row per entry with time, level badge, stream labels and the line. The
level comes from the `level`, `detected_level`, `severity`, `lvl` or `loglevel` label (entry, then common labels),
then from the line (`level=`, `"level":`, a leading `ERROR`/`[warn]` word); critical and error red, warning amber, info
blue, debug muted. Common labels show in the header and are left out of rows; level labels are left out of the Stream
column while the Level column shows them (the cell tooltip keeps all labels). The head says "limit reached" when the
entry count reaches `--limit`. Metric queries render like `promtool query` (lib/lens/series.luau): spark grid with
Graph/Table chips, a table for vectors, one number for a scalar. Rows past 50 behind Show all (up to 500).

**Actions.** Click a log line to copy it. No "Open in Logs block" yet; it arrives with the logs block (M5).

**Raw fallbacks.** `--tail`/`--follow`, `instant-query`, `labels`, `series` and other commands (not claimed or not
rendered), help, unknown `--output`, an unquoted query split into several words, lines that are not logcli output,
while logcli runs, and captures past 50,000 lines or 8 MiB. Errors render as an error card naming the server's message
(e.g. the LogQL parse error) or the connection error, not logcli's closing "run out of attempts".
