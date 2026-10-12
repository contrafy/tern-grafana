# Settings block

`tern-grafana.settings` edits the config file described in [configuration.md](configuration.md) without opening
an editor, connects Grafana with a service account token, and tests each endpoint. Open it from the palette (Tern
Grafana: Settings).

## Connect Grafana

The usual way in, for Grafana Cloud and any Grafana 11 or 12: the first item on the starter screen when there is no
config file yet, `c` (or the Connect Grafana chip) in the context list otherwise.

1. Get a token. In Grafana: **Administration > Users and access > Service accounts > Add service account** (role
   **Viewer** to read; **Editor** to also create silences and annotations) **> Add service account token**. Copy it;
   it starts with `glsa_` and is shown once.
2. Fill the form: the Grafana URL (`https://you.grafana.net`; a missing `https://`, a copied page path or query is
   dropped), the token (paste it with cmd+v; the field shows bullets and the character count, never the token),
   the context name (derived from the URL: the stack name for `*.grafana.net`, else the host) and where to store the
   token: **keychain** (the macOS login keychain, or the Secret Service on Linux; offered only when `security` or
   `secret-tool` exists) or **env** (you name the variable, `GRAFANA_TOKEN` by default; use another name such as
   `GRAFANA_PROD_TOKEN` for a second stack). `enter` ends a field and moves to the next one.
3. `t` tests: `/api/user`, `/api/frontend/settings` and `/api/access-control/user/actions` with the typed token.
   The block shows the signed-in identity, the Grafana version and, for a Viewer token, that silences and
   annotations stay disabled. A rejected token says how to fix it; nothing is stored.
4. The test lists the Prometheus, Loki, Tempo and Alertmanager datasources the token can see and picks one per
   kind: the default datasource first, then a Grafana Cloud stack's own (`grafanacloud-[stack-]prom`, `-logs`,
   `-traces`), then the rest by name, with Grafana Cloud's internal ones (usage, ML, alert state history) last.
   Alertmanager stays on none (Grafana-managed alerting) unless you pick one. Cycle a pick with `left` / `right`.
5. `w` connects: the new file is validated first, then the token goes to the keychain as item `<context>/grafana`
   (service `tern-grafana`; the token reaches `security` / `secret-tool` on stdin, never in arguments), then the
   context is written with `"auth": {"type": "bearer", "token_keychain": "<context>/grafana"}` (or `token_env`).
   The block forgets the token as soon as it is stored. With env storage nothing is stored: set the variable in your
   shell profile (the plugin reads it from your login shell when Tern, started from the Dock, does not have it) or
   with `launchctl setenv`.

Changing the URL or the token after a test needs a new test. `escape` or Cancel leaves without storing anything.

**Update token** (`u` on a context or its grafana endpoint) runs the same flow for an existing grafana endpoint:
URL, storage and datasource picks start from the file, the test uses the endpoint's headers, TLS options and org,
and saving keeps every other setting of the endpoint.

The token is never written to the config, Tern's key-value store, logs, block arguments, saved state, messages or
the view.

## What it shows

- The config path (`$XDG_CONFIG_HOME/tern-grafana/config.json`, else `~/.config/tern-grafana/config.json`) and its
  state: valid, the number of problems, not a JSON object, unreadable, or no file yet.
- Every validation problem with its JSON path, in the same words as the plugin's log. While any problem is listed
  the plugin uses none of the file.
- Each context, marked when it is the default, with its endpoints: url and `path_prefix`, the auth type and where
  the credential comes from (the keychain item, the environment variable name, the `token_cmd` argv or the file
  path), headers, TLS options, Grafana datasource uids, org id, timeout.

Header values whose names look like credentials (containing `auth`, `token`, `key`, `secret`, `passw`, `cookie`,
`session`, `credential` or `signature`) are shown as `********`, in the list and in the form. Tenant headers such as
`X-Scope-OrgID` are shown as written.

## Editing

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | Move. |
| `c` | Connect Grafana (see above). |
| `u` | Update token of the selected context's grafana endpoint. |
| `enter`, `e` | Edit the selected endpoint; on a context, add an endpoint to it. |
| `n` | New context (name, first endpoint and its fields). |
| `a` | Add an endpoint kind the selected context does not have yet. |
| `d` | Make the selected context the default. |
| `r` | Rename the selected context (the default follows the rename). |
| `x` | Remove the selected endpoint or context, after a confirmation. Removing the default context unsets `default_context`. When its auth uses a keychain item that no other endpoint references, the confirmation offers to delete the item too (`y`) or keep it (`k`). |
| `t` | Test the selected endpoint, or every endpoint of the selected context. |
| `R` | Re-read the file. |
| `o` | Open the file in Tern. |
| `?` | Keys. |
| `escape` | Cancel the current edit, close the form, or close the block. |

In a form, `enter` or `space` edits a field or cycles a choice (`left` / `right` also cycle), `w` or `ctrl+s` saves,
`x` removes the selected header, `escape` discards the form.

Secrets are never typed into the edit form (only into Connect Grafana). For `bearer` and `basic` auth the form asks
where the plugin reads the token or password:

- `keychain`: an item name in the OS keychain (service `tern-grafana`), such as `lab/grafana`. Store the token with
  Update token, or yourself: `security add-generic-password -s tern-grafana -a lab/grafana -w` on macOS.
- `env`: an environment variable name, read from Tern's environment or else your login shell.
- `cmd` (password managers): a command line, written as words (`op read "op://Private/Grafana lab/credential"`,
  quotes group words) or as a JSON array (`["sh", "-c", "pass show grafana/lab | head -n 1"]`). It is stored as an
  argv array.
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

When the file does not exist the block offers Connect Grafana first, then templates, each previewed before writing:

| Template | Contents |
| --- | --- |
| Local dev stack | Grafana on `localhost:3000` (token from `GRAFANA_TOKEN`) plus Prometheus, Alertmanager, Loki and Tempo on their default ports. |
| Grafana Cloud (manual) | A Grafana Cloud stack whose token is the keychain item `cloud/grafana`, with the `grafanacloud-prom`, `-logs` and `-traces` datasources. Use Update token on it to store the token. |
| Prometheus direct | One Prometheus-compatible server and its Alertmanager. |
| Mimir multi-tenant | Mimir's Prometheus API and Alertmanager under their path prefixes, with `X-Scope-OrgID`. |

Templates validate as shipped and are written only when the file is still missing. Replace the placeholder URLs
and tenants afterwards.

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
| the credential could not be read | the message says which: no keychain item (use Update token), the environment variable is unset, or the `token_cmd` program is missing or failed |
