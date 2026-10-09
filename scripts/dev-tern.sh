#!/bin/sh
# Isolated Tern for developing tern-grafana. Every command runs against a
# sandbox (default /tmp/tg-tern, override with TG_TERN_SANDBOX) and never
# touches the default Tern config, daemon socket or logs.
#
#   start [--print]   run the sandbox window in the foreground (keep it in a
#                     long-lived terminal/service). The window runs with
#                     HOME and CFFIXED_USER_HOME = <sandbox>/home, so Tern's
#                     blob cache (~/Library/Caches/Tern) and WebKit's data and
#                     cookies stay in the sandbox; panes see that HOME too.
#                     Only ~/Library/Keychains is linked to the real one (the
#                     Stencil sign-in lives there). Shells get a neutral zsh
#                     (sandbox ZDOTDIR, no user rc files); the window and its
#                     daemon read tern-grafana config from <sandbox>/xdg,
#                     never the user's. --print shows the environment
#   link [DIR]        point <sandbox>/cfg/plugins/tern-grafana.path at the repo
#                     root (or DIR, e.g. a spike plugin) and reload the daemon
#   unlink            remove the link and reload
#   reload            reload the sandbox daemon's plugins
#   list              plugins of the sandbox daemon
#   ctl ARGS...       tern ctl against the sandbox control socket
#   wait-ready [SECS] wait until the window answers `ready` (default 30 s)
#   run LINE          type LINE and Enter into the focused pane
#   expect TEXT       wait until a plugin surface shows TEXT
#   shot NAME [DEST]  screenshot the window; prints the PNG path (copied to
#                     DEST when given)
#   logs [daemon|window]  print the sandbox log path
#   stop              quit the sandbox window and its daemon
#   clean             stop, then delete the sandbox
#   env               print the sandbox environment as shell assignments

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
sb=${TG_TERN_SANDBOX:-/tmp/tg-tern}
tern_bin=${TERN_BIN:-tern}
plugin_id=tern-grafana

case $sb in
/tmp/?* | /private/tmp/?* | "$repo"/.sandbox/?*) ;;
*)
	echo "dev-tern: refusing sandbox outside /tmp or $repo/.sandbox: $sb" >&2
	exit 2
	;;
esac

export TERN_CONFIG_DIR="$sb/cfg"
export TERN_DAEMON_SOCKET="$sb/d.sock"
export STENCIL_LOG_DIR="$sb/logs"
window_log="${STENCIL_LOG:-warn,stencil=info,tern::plugin=debug}"
# CLI calls (ctl, plugin reload) log to stderr; only the window logs verbosely.
export STENCIL_LOG=warn
# Inherited from a surrounding Tern pane; they describe the user's Tern.
unset TERN_WINDOW_KEY TERN_WINDOW_SOCKET TERN_PANE TERN_PANE_SOCKET TERN_BLOB_DIR \
	TERN_COMPLETE TERN_IDENTITY TERN_LENSES TERM_PROGRAM TERM_PROGRAM_VERSION
ctl_sock="$sb/ctl.sock"
zdot="$sb/zsh"
home="$sb/home"

ctl() {
	"$tern_bin" ctl --control "$ctl_sock" "$@"
}

# `tern ctl` joins its words into one scenario line; a quoted string keeps
# spaces and shell metacharacters as one argument.
quoted() {
	case $1 in
	*'"'*)
		echo "dev-tern: double quotes are not supported in scenario strings: $1" >&2
		exit 2
		;;
	esac
	printf '"%s"' "$1"
}

daemon_pids() {
	pgrep -f -- "$sb/d.sock" 2>/dev/null || true
}

# A neutral interactive zsh: no user rc files (they may reorder PATH or define
# aliases). Tern passes panes only part of the launch environment and
# /etc/zprofile's path_helper rebuilds PATH for login shells, so the values are
# written into the sandbox rc files instead.
write_zdotdir() {
	mkdir -p "$zdot"
	cat >"$zdot/.zshenv" <<EOF
export XDG_CONFIG_HOME='$sb/xdg'
EOF
	cat >"$zdot/.zshrc" <<EOF
HISTFILE='$zdot/history'
PROMPT='%1~ %# '
RPROMPT=''
export XDG_CONFIG_HOME='$sb/xdg'
EOF
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case $cmd in
start)
	print=0
	for a in "$@"; do
		case $a in
		--print) print=1 ;;
		*)
			echo "dev-tern: start [--print]" >&2
			exit 2
			;;
		esac
	done
	mkdir -p "$TERN_CONFIG_DIR" "$STENCIL_LOG_DIR"
	export STENCIL_LOG="$window_log"
	# tern-grafana reads $XDG_CONFIG_HOME/tern-grafana/config.json; scenarios write it.
	export XDG_CONFIG_HOME="$sb/xdg"
	mkdir -p "$XDG_CONFIG_HOME/$plugin_id"
	# Tern derives its caches (blobs, terminfo) from HOME and WebKit its data
	# and cookie jar from CFFIXED_USER_HOME; without them the sandbox writes
	# into the user's real ~/Library. The keychains stay linked: Tern's Stencil
	# sign-in lives there and a sandbox without it stops at the sign-in sheet.
	mkdir -p "$home/Library"
	[ -e "$home/Library/Keychains" ] || ln -s "$HOME/Library/Keychains" "$home/Library/Keychains"
	export HOME="$home"
	export CFFIXED_USER_HOME="$home"
	export ZDOTDIR="$zdot"
	export SHELL=/bin/zsh
	write_zdotdir
	if [ $print = 1 ]; then
		env | grep -E '^(TERN_|STENCIL_|XDG_CONFIG_HOME=|ZDOTDIR=|HOME=|CFFIXED_USER_HOME=|SHELL=|PATH=)' | sort
		echo "$tern_bin --control $ctl_sock $repo  (cwd $sb)"
		exit 0
	fi
	# Shots land in <cwd>/target/shots: keep them in the sandbox.
	cd "$sb"
	exec "$tern_bin" --control "$ctl_sock" "$repo"
	;;
link)
	mkdir -p "$TERN_CONFIG_DIR/plugins"
	dir=$(CDPATH='' cd -- "${1:-$repo}" && pwd)
	printf '%s\n' "$dir" >"$TERN_CONFIG_DIR/plugins/$plugin_id.path"
	"$tern_bin" plugin reload
	;;
unlink)
	rm -f "$TERN_CONFIG_DIR/plugins/$plugin_id.path"
	"$tern_bin" plugin reload
	;;
reload)
	"$tern_bin" plugin reload "$@"
	;;
list)
	"$tern_bin" plugin list "$@"
	;;
ctl)
	ctl "$@"
	;;
wait-ready)
	limit=${1:-30}
	i=0
	until ctl ready >/dev/null 2>&1; do
		i=$((i + 1))
		if [ $i -ge $((limit * 4)) ]; then
			echo "dev-tern: window not ready after ${limit}s" >&2
			exit 1
		fi
		sleep 0.25
	done
	;;
run)
	ctl run "$(quoted "$*")"
	;;
expect)
	ctl plugins expect "$(quoted "$*")"
	;;
shot)
	name=${1:?shot NAME [DEST]}
	png=$(ctl shot "$name" | sed -n 's/.*"png":"\([^"]*\)".*/\1/p')
	case $png in
	/*) ;;
	?*) png="$sb/$png" ;;
	*)
		echo "dev-tern: shot failed" >&2
		exit 1
		;;
	esac
	if [ $# -ge 2 ]; then
		cp "$png" "$2"
		echo "$2"
	else
		echo "$png"
	fi
	;;
logs)
	case ${1:-daemon} in
	daemon) echo "$STENCIL_LOG_DIR/tern-daemon.log" ;;
	window) echo "$STENCIL_LOG_DIR/tern.log" ;;
	*)
		echo "dev-tern: logs daemon|window" >&2
		exit 2
		;;
	esac
	;;
stop)
	ctl quit >/dev/null 2>&1 || true
	i=0
	while [ -n "$(daemon_pids)" ] && [ $i -lt 20 ]; do
		sleep 0.25
		i=$((i + 1))
	done
	pids=$(daemon_pids)
	if [ -n "$pids" ]; then
		# shellcheck disable=SC2086
		kill $pids 2>/dev/null || true
	fi
	;;
clean)
	"$0" stop
	rm -rf "$sb"
	;;
env)
	printf 'TERN_CONFIG_DIR=%s\nTERN_DAEMON_SOCKET=%s\nSTENCIL_LOG_DIR=%s\nSTENCIL_LOG=%s\nXDG_CONFIG_HOME=%s\n' \
		"$TERN_CONFIG_DIR" "$TERN_DAEMON_SOCKET" "$STENCIL_LOG_DIR" "$window_log" "$sb/xdg"
	;;
*)
	sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
	[ -z "$cmd" ] && exit 0
	exit 2
	;;
esac
