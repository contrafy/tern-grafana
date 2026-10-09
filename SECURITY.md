# Security policy

## Supported versions

tern-grafana is pre-release. Once released, only the latest `0.x` release
receives security fixes.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's private vulnerability reporting:
<https://github.com/contrafy/tern-grafana/security/advisories/new>.

Do not open a public issue, pull request or discussion for a vulnerability, and
do not include exploit details or real credentials anywhere public. Include what
you found, the tern-grafana, Tern and server versions, and steps or a proof of
concept.

## Trust model

Tern plugins run as your user and Tern has no plugin permission system: any
plugin can call every API (see Tern's
[Trust and Security](https://docs.stencil.so/tern/concepts/security.html)). tern-grafana's
guarantees are self-imposed and enforced by its code, tests and review:

- **Credentials are resolved, never stored.** A context's token comes from a
  `token_cmd` argv (run without a shell), an environment variable, or a file
  that must be mode `0600`. It is held in memory only for requests and never
  written to disk, Tern's key-value store, logs, fixtures, screenshots, block
  arguments or saved state.
- **Outbound network only to configured contexts.** Requests go only to the
  Grafana, Prometheus-compatible, Alertmanager, Loki and Tempo URLs you
  configure. Browser fallbacks open those same URLs.
- **Writes are previewed and confirmed.** Creating or expiring silences and
  posting annotations always show what will change and require confirmation.
  Automatic deploy annotations are opt-in and confirmed on first use per
  context.
- **Processes are explicit.** The only processes started are your configured
  `token_cmd` and `curl` for transports that need it (mTLS, custom CA,
  insecure TLS), with credentials passed outside the command line where possible.

A way to make tern-grafana break any of these is in scope. Out of scope:
vulnerabilities in Tern itself (report those to Stencil), in Grafana or the
backends, other plugins, and changes a user makes to the plugin's own source.
