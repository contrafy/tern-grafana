# Helpers for the Tern-in-the-loop scenarios (sourced by scripts/e2e.sh).
# Everything goes through scripts/dev-tern.sh against the sandbox in
# TG_TERN_SANDBOX; nothing here touches the default Tern or the user's
# tern-grafana config. The dev stack is only read, except where a scenario
# says otherwise (it never creates silences or annotations).

E2E_REPO=${E2E_REPO:?}
E2E_DEV="$E2E_REPO/scripts/dev-tern.sh"
E2E_SB=${TG_TERN_SANDBOX:?}
E2E_BIN="$E2E_SB/bin"
E2E_CFG="$E2E_SB/xdg/tern-grafana/config.json"
E2E_ART="$E2E_REPO/.sandbox/e2e"
E2E_FAILED=0
E2E_NAME=${E2E_NAME:-e2e}

PROM=http://localhost:9090
AM=http://localhost:9093
LOKI=http://localhost:3100
G12=http://localhost:3000
G11=http://localhost:3011

dev() {
	sh "$E2E_DEV" "$@"
}

ctl() {
	dev ctl "$@"
}

note() {
	printf '  %s\n' "$*"
}

fail() {
	printf '  FAIL %s\n' "$*"
	# shellcheck disable=SC2034 # read by scripts/e2e.sh after each scenario
	E2E_FAILED=1
	return 1
}

# --- Setup (scripts/e2e.sh) ----------------------------------------------------

# The sandbox config: contexts from the running stack. Tokens stay in the
# stack's 0600 files (token_file); nothing secret is written here. A watch on
# the always-down target and deploy annotations for `helm upgrade` are on for
# the watches and annotations scenarios; the alert poll is short so the status
# segment fills quickly.
write_config() {
	mkdir -p "$(dirname "$E2E_CFG")"
	cat >"$E2E_CFG" <<EOF
{
  "version": 1,
  "default_context": "lab",
  "contexts": {
    "lab": {
      "grafana": {
        "url": "$G12",
        "auth": { "type": "bearer", "token_file": "${E2E_TOK12:?}" },
        "datasources": { "prometheus": "prom3", "loki": "loki", "tempo": "tempo", "alertmanager": "alertmanager" }
      },
      "prometheus": { "url": "$PROM" },
      "alertmanager": { "url": "$AM" },
      "loki": { "url": "$LOKI" },
      "tempo": { "url": "http://localhost:3200" }
    },
    "g11": {
      "grafana": {
        "url": "$G11",
        "auth": { "type": "bearer", "token_file": "${E2E_TOK11:?}" },
        "datasources": { "prometheus": "prom2" }
      }
    }
  },
  "alerts": { "contexts": ["lab"], "poll_s": 15 },
  "annotations": { "enabled": true, "patterns": ["helm upgrade"], "context": "lab" },
  "watches": [
    { "name": "e2e target down", "context": "lab", "expr": "up{job=\"down\"}", "op": "==", "threshold": 0, "severity": "critical", "interval": "15s" }
  ]
}
EOF
}

# Wrappers first on the pane's PATH: promtool, amtool and logcli run from the
# stack's pinned images on the host network (so localhost URLs work as typed);
# helm is a fake that only prints, for the annotations scenario.
write_tools() {
	mkdir -p "$E2E_BIN"
	docker_bin=$(command -v docker)
	docker_host=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)}
	for t in promtool=quay.io/prometheus/prometheus:v3.15.0 amtool=quay.io/prometheus/alertmanager:v0.34.1 \
		logcli=grafana/logcli:3.7.8; do
		cat >"$E2E_BIN/${t%%=*}" <<EOF
#!/bin/sh
# e2e wrapper: ${t%%=*} from the dev stack's image, on the host network.
export DOCKER_HOST='$docker_host'
exec '$docker_bin' run --rm -i --network host --entrypoint ${t%%=*} ${t#*=} "\$@"
EOF
		chmod +x "$E2E_BIN/${t%%=*}"
	done
	cat >"$E2E_BIN/helm" <<'EOF'
#!/bin/sh
# e2e fake: deploys nothing.
echo "Release \"${3:-e2e}\" has been upgraded. Happy Helming!"
EOF
	chmod +x "$E2E_BIN/helm"
}

plugin_loaded() {
	dev list 2>/dev/null | grep -q '^tern-grafana .* ready$'
}

# --- Queries -----------------------------------------------------------------

# Visible matches of a selector: count, texts (JSON array), all text.
count() {
	ctl tree "$1" | jq -r '.count // 0'
}

texts() {
	ctl tree "$1" | jq -c '[.nodes[]?.text]'
}

alltext() {
	ctl tree "$1" | jq -r '[.nodes[]?.text // empty] | join("\n")'
}

daemon_log() {
	dev logs daemon
}

window_log() {
	dev logs window
}

log_lines() {
	wc -l <"$(daemon_log)" | tr -d ' '
}

# --- Waiting -----------------------------------------------------------------

# wait_for DESCRIPTION CMD...: retry CMD for up to E2E_WAIT seconds.
wait_for() {
	what=$1
	shift
	i=0
	limit=$((${E2E_WAIT:-10} * 4))
	until "$@" >/dev/null 2>&1; do
		i=$((i + 1))
		[ $i -ge $limit ] && {
			fail "timed out waiting for $what"
			return 1
		}
		sleep 0.25
	done
}

has() { # has SEL [N]: at least N (default 1) visible matches
	[ "$(count "$1")" -ge "${2:-1}" ]
}

lacks() {
	[ "$(count "$1")" -eq 0 ]
}

idle() {
	[ "$(ctl state | jq -r '.focused.running == null and .focused.busy == false')" = true ]
}

# --- Driving -----------------------------------------------------------------

# quoted TEXT: TEXT as one `tern ctl` scenario string ("..." with \ and "
# escaped), so lines may hold double quotes.
quoted() {
	printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# type_text TEXT: type TEXT into the focused element (no Enter).
type_text() {
	ctl type "$(quoted "$1")" >/dev/null
}

# type_line LINE: type a line and Enter into the focused pane.
type_line() {
	ctl run "$(quoted "$1")" >/dev/null
}

# sh_line LINE: a shell-only line (export, clear), waited for.
sh_line() {
	type_line "$1"
	wait_for "shell" idle
}

pane_count() {
	ctl state | jq '.panes | length'
}

# Back to one shell pane: blocks a scenario opened beside the shell are closed
# right-most first, so the original pane survives. The wrappers in bin/ go
# first on its PATH (again, in case a scenario replaced the pane).
reset_pane() {
	i=0
	while [ "$(pane_count)" -gt 1 ] && [ $i -lt 8 ]; do
		ctl focus right >/dev/null
		ctl close >/dev/null
		sleep 0.4
		i=$((i + 1))
	done
	# The survivor is the left-most pane; a click there gives it the keyboard.
	[ $i -gt 0 ] && ctl click 30 600 >/dev/null
	sh_line "typeset -U path; path=('$E2E_BIN' \$path)"
	sh_line clear
}

# lens LINE: clear the pane, run LINE, wait for it to finish and the view to
# settle; the block is then the only one in the pane.
lens() {
	sh_line clear
	type_line "$1"
	E2E_WAIT=${E2E_WAIT:-30} wait_for "command to finish: $1" idle
	sleep 0.6
	ctl scroll 100000 >/dev/null
	sleep 0.2
}

# keys KEY...: send keys to the focused pane, then let the view re-render.
keys() {
	for k in "$@"; do
		ctl key "$k" >/dev/null
	done
	sleep 0.4
}

# click_text TEXT [SEL]: click the visible element of SEL (default: any
# clickable) whose text is exactly TEXT (a trailing * matches a prefix).
click_text() {
	sel=${2:-.sf-act}
	xy=$(ctl tree "$sel" | jq -r --arg t "$1" '
		def hit: if ($t | endswith("*")) then ((.text // "") | startswith($t[:-1])) else .text == $t end;
		[.nodes[]? | select(hit)][0].rect // empty | "\(.[0] + .[2] / 2) \(.[1] + .[3] / 2)"')
	[ -n "$xy" ] || {
		fail "no visible \"$1\" in $sel"
		return 1
	}
	# shellcheck disable=SC2086
	ctl click $xy >/dev/null
	sleep 0.5
}

# click_url URL: print URL in the cleared shell pane and click it, as a user
# clicks a link in terminal output (Tern detects plain-text URLs). The URL is
# the row just above the prompt the cursor sits on.
click_url() {
	sh_line clear
	sh_line "echo '$1'"
	expect_grid "$1" || return 1
	xy=$(ctl tree '.tv-cursor' | jq -r '.nodes[0].rect // empty | "60 \(.[1] - .[3] / 2)"')
	[ -n "$xy" ] || {
		fail "no terminal cursor to locate the URL row"
		return 1
	}
	# shellcheck disable=SC2086
	ctl click $xy >/dev/null
	sleep 0.5
}

# shot NAME: one screenshot per scenario step, kept in .sandbox/e2e/<scenario>/.
shot() {
	mkdir -p "$E2E_ART/$E2E_NAME"
	dev shot "e2e-$E2E_NAME-$1" "$E2E_ART/$E2E_NAME/$1.png" >/dev/null 2>&1 || fail "shot $1"
}

# expect_text TEXT: `plugins expect` waits (up to 20 s) until a surface of the
# focused pane shows TEXT.
expect_text() {
	ctl plugins expect "$(quoted "$1")" | grep -q '"ok":true' || fail "\"$1\" never appeared in a plugin surface"
}

# expect_grid TEXT: `ctl expect` waits (up to 20 s) for the grid text.
expect_grid() {
	ctl expect "$(quoted "$1")" | grep -q '"ok":true' || fail "\"$1\" never appeared in a terminal"
}

# --- Blocks --------------------------------------------------------------------

# surface BLOCK: the selector of a tern-grafana block's surface.
surface() {
	printf "[data-surface='plugin.tern-grafana.%s']" "$1"
}

# btext BLOCK [SEL]: all text inside the block (SEL relative to it), one line.
btext() {
	alltext "$(surface "$1") ${2:-*}" | tr '\n' ' ' | tr -s ' '
}

b_has() {
	case $(btext "$1" "${3:-*}") in *"$2"*) true ;; *) false ;; esac
}

# bwait BLOCK TEXT [SEL]: wait until the block shows TEXT.
bwait() {
	E2E_WAIT=${E2E_WAIT:-20} wait_for "the $1 block to show \"$2\"" b_has "$1" "$2" "${3:-*}"
}

# open_block COMMAND BLOCK: run a palette command by id and wait for its block.
open_block() {
	ctl plugins run "plugin.tern-grafana.$1" >/dev/null
	E2E_WAIT=20 wait_for "the $2 block" has "$(surface "$2")"
}

# --- Assertions --------------------------------------------------------------

eq() { # eq WHAT GOT WANT
	[ "$2" = "$3" ] || fail "$1: got $2, want $3"
}

contains() { # contains WHAT HAYSTACK NEEDLE
	case $2 in
	*"$3"*) ;;
	*) fail "$1: \"$3\" not in: $(printf '%s' "$2" | head -c 400)" ;;
	esac
}

excludes() { # excludes WHAT HAYSTACK NEEDLE
	case $2 in
	*"$3"*) fail "$1: \"$3\" unexpectedly in: $(printf '%s' "$2" | head -c 400)" ;;
	*) ;;
	esac
}

# --- Stack (read-only) -----------------------------------------------------------

# Silences on the stack's Alertmanager, as JSON (all states).
am_silences() {
	curl -fsS --max-time 5 "$AM/api/v2/silences"
}

# g12_api PATH: GET PATH from Grafana 12 with the stack's token, handed to
# curl on stdin (never on the command line), as scripts/stack.sh does.
g12_api() {
	printf 'header = "Authorization: Bearer %s"\n' "$(cat "${E2E_TOK12:?}")" |
		curl -fsS --max-time 5 -K - "$G12$1"
}
