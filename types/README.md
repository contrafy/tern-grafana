# Tern type definitions

`tern.d.luau` is not vendored. `make bootstrap` (`scripts/bootstrap.sh`) downloads it from the MIT-licensed
[stencil-hq/tern-sdk](https://github.com/stencil-hq/tern-sdk) at a pinned commit and verifies its SHA-256:

- source: `https://raw.githubusercontent.com/stencil-hq/tern-sdk/3fe91247617744635cabb93f4561bd17ac26ca61/plugins/tern.d.luau`
- sha256: `fe56ffbe90cb74f1df59e82d58e81203b3dbb803a17c10fb1b25849363783fb2`
- installed to: `.tools/types/tern.d.luau` (gitignored)

The same file is what `tern plugin types DIR` writes for the installed Tern.

## luau-lsp copy

The upstream file uses the type `userdata` (`WindowCx:wait`), which Luau does not define; luau-lsp then rejects
the whole definitions file and reports `tern` as an unknown global. Bootstrap therefore also writes
`.tools/types/tern.lsp.d.luau`: the pristine file prefixed with `declare extern type userdata with end`.
`make typecheck` and editor setups should point at that copy:

```
luau-lsp analyze --platform=standard --definitions=@tern=.tools/types/tern.lsp.d.luau plugin tests
```

For VS Code, set `luau-lsp.types.definitionFiles` to `{"@tern": ".tools/types/tern.lsp.d.luau"}` and
`luau-lsp.platform.type` to `standard`.

Use the `tern` global in plugin code. luau-lsp does not resolve `require("tern")`.

## Updating

Bump the commit and checksum in `scripts/bootstrap.sh` and this file together, then run `make bootstrap check`.
