# Per-host default contexts

`hosts` maps hostnames or globs to the context used on that machine whenever none
is named: blocks opened without a context, the alerts poller, threshold watches
without `context`, and every other host-side default. Useful when one config file
is shared between a laptop and remote machines (Tern remote daemons), each close
to a different environment.

```json
{
  "default_context": "lab",
  "hosts": {
    "bastion-1.prod.example.com": "prod",
    "*.prod.example.com": "prod-replica",
    "ci-*": "staging"
  }
}
```

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `hosts` | object: hostname or glob -> context name | absent | Default context per machine. |

## Matching

- The host half reads its hostname once when it starts: `HOSTNAME` from the
  daemon's environment, else the output of `hostname`. On a remote daemon this is
  the remote machine's name, so each machine picks its own context.
- Hostnames compare case-insensitively, without a trailing dot. A pattern matches
  either the full hostname or its first label, so `build-box` matches
  `build-box.local`.
- In globs, `*` matches any run of characters (dots included) and `?` exactly one.
- An exact hostname wins over every glob. Among matching globs the longest pattern
  wins; equal lengths prefer fewer wildcards, then alphabetical order.

## Precedence

For any request: a context named explicitly (in a link, block, or watch) wins;
otherwise the `hosts` match; otherwise `default_context`; otherwise the only
context when exactly one is defined.

An entry naming an unknown context, an empty pattern, or two patterns differing
only in case is skipped and logged (`hosts.<pattern>: ...`); the other entries
still apply. Until `hostname` answers (milliseconds after start) no host default
applies. The window half (links clicked in a pane) keeps using `default_context`.
