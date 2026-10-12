#!/bin/sh
# End-to-end tests in a real, isolated Tern window (`make e2e`). Local only:
# needs Tern, jq, Docker, a desktop session and the running dev stack
# (scripts/stack.sh up); skipped with a message (exit 0) when `tern` is not
# installed or the stack is not up.
#
#   scripts/e2e.sh [--only GLOB] [--keep]
#
# E2E_ONLY=GLOB (or --only) runs the scenarios whose name matches GLOB
# (tests/e2e/scenarios/<name>.sh, e.g. E2E_ONLY='*dash*'). --keep (or
# E2E_KEEP=1) leaves the window running afterwards.
#
# The window runs in its own sandbox (TG_E2E_SANDBOX, default
# /tmp/tg-tern-e2e), started from a clean state, with a snapshot copy of the
# package (HEAD's plugin.toml and plugin/ plus their working-tree changes), so
# saves made while it runs do not reload the plugin under test. Its config is
# generated from the running stack: contexts lab (Grafana 12, Prometheus 3,
# Alertmanager, Loki, Tempo) and g11 (Grafana 11 with prom2). Failure
# artifacts (shots, logs) are kept in .sandbox/e2e/.

set -u

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tern_bin=${TERN_BIN:-tern}

if ! command -v "$tern_bin" >/dev/null 2>&1; then
	echo "e2e: SKIPPED: \`$tern_bin\` is not installed; the e2e suite drives a real Tern window."
	exit 0
fi
for tool in jq docker curl bash; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "e2e: $tool is required" >&2
		exit 2
	}
done

only=${E2E_ONLY:-*}
keep=${E2E_KEEP:-0}
while [ $# -gt 0 ]; do
	case $1 in
	--only)
		only=$2
		shift
		;;
	--keep) keep=1 ;;
	*)
		sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
		exit 2
		;;
	esac
	shift
done

# The stack must be up: every endpoint ready and both Grafana tokens minted.
status=$(sh "$repo/scripts/stack.sh" status 2>&1)
if ! printf '%s\n' "$status" | grep -q '^  grafana12 *ready' || printf '%s\n' "$status" | grep -q ' DOWN '; then
	echo "e2e: SKIPPED: the dev stack is not up (sh scripts/stack.sh up; status below)."
	printf '%s\n' "$status" | sed -n '/^endpoints:/,/^$/p'
	exit 0
fi
tok12=$(sh "$repo/scripts/stack.sh" token-path grafana12)
tok11=$(sh "$repo/scripts/stack.sh" token-path grafana11)
if [ ! -s "$tok12" ] || [ ! -s "$tok11" ]; then
	echo "e2e: SKIPPED: Grafana tokens missing ($tok12, $tok11); run sh scripts/stack.sh up."
	exit 0
fi

export TG_TERN_SANDBOX="${TG_E2E_SANDBOX:-/tmp/tg-tern-e2e}"
export E2E_REPO="$repo"
export E2E_TOK12="$tok12" E2E_TOK11="$tok11"
# shellcheck source=tests/e2e/lib.sh disable=SC1091
. "$repo/tests/e2e/lib.sh"

need() {
	echo "e2e: $*" >&2
	exit 1
}

artifacts="$repo/.sandbox/e2e"

# `dev-tern.sh clean` stops the sandbox with a bounded teardown (it does not
# rely on the window quitting) and deletes it.
cleanup() {
	if [ "$keep" = 0 ]; then
		dev clean >/dev/null
	else
		echo "e2e: window kept running (TG_TERN_SANDBOX=$E2E_SB sh scripts/dev-tern.sh stop)"
	fi
}

# Snapshot of the package: HEAD's plugin.toml and plugin/, then the working
# tree's changes on top (modified and untracked files copied, deleted removed).
snapshot() {
	dest=$1
	mkdir -p "$dest"
	if git -C "$repo" rev-parse --verify -q HEAD >/dev/null 2>&1; then
		git -C "$repo" archive HEAD plugin.toml plugin | tar -x -C "$dest" || return 1
		git -C "$repo" ls-files -d -z -- plugin.toml plugin | (cd "$dest" && xargs -0 rm -f) || return 1
		# shellcheck disable=SC2016 # $1/$2 belong to the inner sh
		git -C "$repo" ls-files -m -o --exclude-standard -z -- plugin.toml plugin |
			(cd "$repo" && xargs -0 -I{} sh -c '[ ! -f "$1" ] || { mkdir -p "$2/$(dirname "$1")" && cp "$1" "$2/$1"; }' _ {} "$dest") ||
			return 1
	else
		cp "$repo/plugin.toml" "$dest/plugin.toml" && cp -R "$repo/plugin" "$dest/plugin"
	fi
}

dev clean >/dev/null
mkdir -p "$E2E_SB" "$artifacts"
rm -rf "${artifacts:?}"/*
snapshot "$E2E_SB/pkg" || need "cannot snapshot the package"
write_config
write_tools
trap cleanup EXIT
trap 'exit 130' INT TERM

start=$(date +%s)
# The window (and the daemon it spawns) must not inherit our output or any
# other descriptor of the caller, or `make e2e | tail` waits for them: start it
# with only stdin/stdout/stderr open, its output in the artifacts.
# shellcheck disable=SC2016 # expanded by the inner bash
bash -c 'for fd in $(ls /dev/fd); do [ "$fd" -gt 2 ] && eval "exec $fd>&-"; done; exec "$@"' \
	_ sh "$E2E_DEV" start </dev/null >"$artifacts/window.out" 2>&1 &
E2E_WAIT=30 wait_for "the sandbox window" ctl ready || {
	cat "$artifacts/window.out" >&2
	exit 1
}
dev link "$E2E_SB/pkg" >/dev/null 2>&1 || need "cannot link the plugin"
E2E_WAIT=30 wait_for "the first prompt" ctl ready || exit 1
ctl resize 1400 900 >/dev/null
sleep 1
E2E_WAIT=30 wait_for "the plugin to load" plugin_loaded || {
	dev list >&2
	exit 1
}

# The pane must see the wrappers (promtool, amtool, logcli, helm) first on PATH.
reset_pane
# shellcheck disable=SC2016 # expanded by the pane's zsh
sh_line 'print -r -- TG_CHECK $(command -v promtool)'
ctl expect "\"TG_CHECK $E2E_BIN/promtool\"" | grep -q '"ok":true' || need "the sandbox pane does not see $E2E_BIN on PATH"
log_start=$(log_lines)

failed=""
passed=0
results=""
for f in "$repo"/tests/e2e/scenarios/*.sh; do
	name=$(basename "$f" .sh)
	# shellcheck disable=SC2254
	case $name in
	$only) ;;
	*) continue ;;
	esac
	echo "RUN  $name"
	t0=$(date +%s)
	if (
		export E2E_NAME="$name"
		reset_pane
		# shellcheck source=/dev/null
		. "$f"
		exit "$E2E_FAILED"
	); then
		passed=$((passed + 1))
		verdict=ok
	else
		failed="$failed $name"
		verdict=FAIL
		mkdir -p "$artifacts/$name"
		dev shot "e2e-fail-$name" "$artifacts/$name/fail.png" >/dev/null 2>&1 &&
			echo "     shot: $artifacts/$name/fail.png"
		ctl tree >"$artifacts/$name/tree.json" 2>/dev/null
		ctl key escape >/dev/null 2>&1
		ctl key ctrl+c >/dev/null 2>&1
	fi
	dt=$(($(date +%s) - t0))
	printf '%-4s %s (%ss)\n' "$verdict" "$name" "$dt"
	results="$results$(printf '%-4s %-16s %4ss' "$verdict" "$name" "$dt")
"
done

# Whole-run checks: the style sheets parsed and no lens or block crashed.
if grep -q 'plugin style sheet has errors sheet="plugin:local:tern-grafana' "$(window_log)"; then
	failed="$failed stylesheet"
	echo "FAIL stylesheet: $(grep -o 'message: "[^"]*"' "$(window_log)" | head -3)"
fi
if tail -n +"$((log_start + 1))" "$(daemon_log)" | grep -q 'tern-grafana.*failed; showing raw'; then
	failed="$failed lens-errors"
	echo "FAIL lens errors:"
	tail -n +"$((log_start + 1))" "$(daemon_log)" | grep 'tern-grafana.*failed; showing raw' | head -5
fi

if [ -n "$failed" ]; then
	cp "$(daemon_log)" "$artifacts/tern-daemon.log" 2>/dev/null
	cp "$(window_log)" "$artifacts/tern.log" 2>/dev/null
fi

printf '\n%s' "$results"
echo "e2e: $passed passed in $(($(date +%s) - start))s${failed:+; FAILED:$failed}"
[ -z "$failed" ]
