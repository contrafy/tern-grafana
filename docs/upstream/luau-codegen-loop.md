# Tern 0.9.16: plugin loop miscompiled by native code generation (Luau 0.740)

Draft for Stencil; not filed.

## Summary

Release Tern compiles plugin chunks to native code with its embedded Luau 0.740 (`luau0-src-0.22.0+luau740` in the
0.9.16 binary). One loop shape is miscompiled into a loop that never ends. In a plugin this fills the plugin VM's heap
within one call, after which every hook of that plugin fails with `not enough memory` until Tern restarts it. Luau
0.742 and later run the same code correctly; their changelogs list native-code fixes to register restores at exits
("exit sync"), which match the IR below.

## Environment

- Tern 0.9.16 (41a10a5), macOS 27 arm64.
- Standalone `luau` 0.740 and 0.741 reproduce it with `--codegen`; 0.742 to 0.746 do not; `-O0` avoids it.

## Reproduction

```lua
--!strict
local function add(subs: { any }, p: any, n: number)
	for j = 0, n - 1 do
		table.insert(subs, { a = j * 2, b = (j + 1) * 2, p = p })
	end
end
local subs = {}
add(subs, {}, 15)
print(#subs)
```

- `luau repro.luau` prints `15`.
- `luau --codegen repro.luau` (0.740, 0.741) never ends, or fails with `table overflow`.

`luau-compile --codegenir` shows `j + 1` computed once and reused as the next loop index (`STORE_DOUBLE R5, %126`), and
held across `table.insert`'s fast path at points marked `exit sync: R10, {%126}`.

## Impact on tern-grafana

The gauge renderer's gradient loop had this shape. Opening a dashboard with a Grafana 12.4/13 radial gauge raised the
plugin's heap from 7.7 MB to 249 MB inside one render call; every later `view`, `init`, `save` and fetch callback of
the plugin then failed with `not enough memory`, so dashboard blocks stayed on "Loading" or failed to open.

## What the plugin does today

- The loop is rewritten (`for j = 1, n` using `j - 1` and `j`), which compiles correctly.
- `make test` runs every spec twice: interpreted, and with `luau --codegen` on the same Luau version Tern embeds
  (pinned in `scripts/bootstrap.sh`), so a native-code miscompile shows up in the test suite.

## Request

Ship Luau 0.742 or later in Tern, and say which Luau version a Tern release embeds (for example in `tern --version`
or the plugin docs), so plugin authors can test their code under the same compiler.
