#!/bin/sh
# Guards the window half's load budget. Tern runs plugin/window.luau under the
# window's 50 ms budget, and every module required at load is read, compiled
# and JIT-compiled inside it: the cost grows with the bytes loaded (about
# 0.11 ms per KiB on an M-series Mac; 243 KiB took 26-40 ms). A trip
# disables the whole window half (routes, commands, status, Carly).
#
# Follows the top-level requires (a `require` at column 0, as statement or
# `local X = require(...)`) from plugin/window.luau and fails when their
# bytes exceed the budget. Requires inside functions are lazy and not counted.
#
#   check-window-load.sh [MAX_BYTES]   (default 40960)

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
max=${1:-40960}
cd "$repo"

seen=""
queue="plugin/window.luau"
total=0
while [ -n "$queue" ]; do
	f=${queue%% *}
	case $queue in
	*" "*) queue=${queue#* } ;;
	*) queue="" ;;
	esac
	case " $seen " in
	*" $f "*) continue ;;
	esac
	seen="$seen $f"
	total=$((total + $(wc -c <"$f")))
	dir=$(dirname "$f")
	for r in $(sed -n -E 's/^(local [A-Za-z_][A-Za-z0-9_]* = )?require\("(\.{1,2}\/[^"]+)"\).*/\2/p' "$f"); do
		p="$dir/$r"
		if [ -f "$p.luau" ]; then
			p="$p.luau"
		elif [ -f "$p/init.luau" ]; then
			p="$p/init.luau"
		else
			echo "check-window-load: $f requires $r: not found" >&2
			exit 1
		fi
		# Normalize ./ and dir/../ segments so each module counts once.
		p=$(printf '%s\n' "$p" | sed -E -e 's#/\./#/#g' -e ':a' -e 's#[^/]+/\.\./##' -e 'ta')
		queue="${queue:+$queue }$p"
	done
done

if [ "$total" -gt "$max" ]; then
	echo "check-window-load: plugin/window.luau loads $total bytes at load time (budget $max):" >&2
	for f in $seen; do
		printf '  %8d %s\n' "$(wc -c <"$f")" "$f" >&2
	done
	echo "Require heavy modules inside the handlers that use them (docs/architecture.md)." >&2
	exit 1
fi
echo "window load: $total bytes in $(echo "$seen" | wc -w | tr -d ' ') modules (budget $max)"
