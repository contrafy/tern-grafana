# Settings block

`tern-grafana.settings` edits the config file described in [configuration.md](configuration.md) without opening
an editor, and tests each endpoint. Open it from the palette (Tern Grafana: Settings).

## What it shows

- The config path (`$XDG_CONFIG_HOME/tern-grafana/config.json`, else `~/.config/tern-grafana/config.json`) and its
  state: valid, the number of problems, not a JSON object, unreadable, or no file yet.
- Every validation problem with its JSON path, in the same words as the plugin's log. While any problem is listed
  the plugin uses none of the file.
- Each context, marked when it is the default, with its endpoints: url and `path_prefix`, the auth type and where
  the credential comes from (the `token_cmd` argv, the environment variable name or the file path), headers, TLS
  options, Grafana datasource uids, org id, timeout.

Header values whose names look like credentials (containing `auth`, `token`, `key`, `secret`, `passw`, `cookie`,
`session`, `credential` or `signature`) are shown as `********`, in the list and in the form. Tenant headers such as
`X-Scope-OrgID` are shown as written.

## Editing

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | Move. |
| `enter`, `e` | Edit the selected endpoint; on a context, add an endpoint to it. |
| `n` | New context (name, first endpoint and its fields). |
| `a` | Add an endpoint kind the selected context does not have yet. |
| `d` | Make the selected context the default. |
| `r` | Rename the selected context (the default follows the rename). |
| `x` | Remove the selected endpoint or context, after a confirmation. Removing the default context unsets `default_context`. |
| `t` | Test the selected endpoint, or every endpoint of the selected context. |
| `R` | Re-read the file. |
| `o` | Open the file in Tern. |
| `?` | Keys. |
| `escape` | Cancel the current edit, close the form, or close the block. |

In a form, `enter` or `space` edits a field or cycles a choice (`left` / `right` also cycle), `w` or `ctrl+s` saves,
`x` removes the selected header, `escape` discards the form.

Secrets are never typed into the block. For `bearer` and `basic` auth the form asks where the plugin reads the token
or password:

- `cmd`: a command line, written as words (`op read "op://Private/Grafana lab/credential"`, quotes group words) or
  as a JSON array (`["sh", "-c", "pass show grafana/lab | head -n 1"]`). It is stored as an argv array.
- `env`: an environment variable name of the Tern process.
- `file`: an absolute path or `~/...`.

Headers are added as `Name: value`. A sensitive header's value is hidden in the form too: leaving its edit empty
keeps the stored value, typing replaces it. `Authorization` is refused; use `auth`.

## Saving

Every save validates the whole new file first. If anything is wrong nothing is written, and each problem is shown
next to the field it concerns (or below the form when it concerns the file as a whole), for example
`contexts.lab.prometheus.timeout_ms: must be an integer between 1 and 600000 (milliseconds)`.

A valid file is written in these steps:

1. The file on disk must still be the text the block loaded (compared by content hash). If someone changed it
   meanwhile, nothing is written, the block reloads the file and keeps an open form, so the edit can be reviewed
   and saved again on top of the new text.
2. The previous file is copied to `config.json.bak`.
3. The new text goes to a temporary file in the same directory, which `mv` renames over the config, so readers
   never see a half-written file.
4. The written file is read back and compared; the plugin then re-reads its config and drops cached credentials.

Sections the block does not edit (`query`, `alerts`, `annotations`, `impact`, `watches`, `hosts`) are kept as they
were. Keys are written in the documented order with two-space indentation; JSON has no comments, so there are
none to lose.

The block refuses to edit a file that is not a JSON object; fix it in an editor (`o`).

## Starter templates

When the file does not exist the block offers templates, each previewed before writing:

| Template | Contents |
| --- | --- |
| Local dev stack | Grafana on `localhost:3000` (token from `GRAFANA_TOKEN`) plus Prometheus, Alertmanager, Loki and Tempo on their default ports. |
| Grafana Cloud | A Grafana stack with a service account token and direct Prometheus with basic auth, both read with `op read`. |
| Prometheus direct | One Prometheus-compatible server and its Alertmanager. |
| Mimir multi-tenant | Mimir's Prometheus API and Alertmanager under their path prefixes, with `X-Scope-OrgID`. |

Templates validate as shipped and are written only when the file is still missing. Replace the placeholder URLs,
item paths and tenants afterwards.

## Testing a connection

`t` tests the endpoints of the saved file (save first; a file with problems cannot be tested), with the same
transport and credentials as every other request:

| Endpoint | Requests | Reports |
| --- | --- | --- |
| grafana | `/api/health`, `/api/user`, and `/api/datasources` when `datasources` is set | version, the signed-in login, whether each configured datasource uid exists (listing the available uids when one does not) |
| prometheus | `/api/v1/status/buildinfo` | flavor (Prometheus, Thanos, Mimir, Cortex, VictoriaMetrics) and version |
| alertmanager | `/api/v2/status` | version |
| loki | `/loki/api/v1/status/buildinfo` | version |
| tempo | `/api/status/buildinfo` | version |

A failure shows the error and what to do next, for example:

| Failure | Hint |
| --- | --- |
| `invalid peer certificate: UnknownIssuer` | set `tls.ca_file` (or `tls.insecure` for a lab) |
| connection refused | nothing listens at the url |
| HTTP 401 without auth | configure `auth` |
| HTTP 401 with auth | the credential was rejected |
| HTTP 403 | the account lacks permission for the API |
| HTTP 404 | check `url` and `path_prefix` |
| timeout | check the url or raise `timeout_ms` |
| the credential could not be read | run the `token_cmd` in a terminal, check the Tern process environment or the file |
