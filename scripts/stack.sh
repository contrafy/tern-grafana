#!/bin/sh
# Local docker dev stack for tern-grafana (dev/compose.yml); see docs/dev-stack.md.
#
#   scripts/stack.sh up             start everything, wait until healthy, mint one Grafana
#                                   service-account token per Grafana, seed library panel + annotations
#   scripts/stack.sh down           stop and remove containers, their volumes, and the tokens
#   scripts/stack.sh reset          down, then up (fresh Grafana databases and TSDBs)
#   scripts/stack.sh status         containers, endpoint readiness, firing alerts, logs/traces presence
#   scripts/stack.sh smoke          fail unless every server has a firing alert and logs/traces are
#                                   queryable (waits up to STACK_WAIT_SECS); for CI after `up`
#   scripts/stack.sh capture [--refresh [PATTERN]]
#                                   record new fixtures into tests/fixtures (scripts/fixtures/capture.sh);
#                                   existing ones are only overwritten with --refresh matching PATTERN
#   scripts/stack.sh token-path G   print the token file path for G (grafana12|grafana11), never the token
#
# Tokens live only in .sandbox/stack/<grafana>.token (mode 0600) and are never printed. Every
# request that carries a credential passes it to curl on stdin (-K -), never on the command line.
# Admin credentials are the local-only ones from dev/compose.yml.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
COMPOSE_FILE=$ROOT/dev/compose.yml
STATE=$ROOT/.sandbox/stack
SA_NAME=tern-dev
ADMIN_USER='admin'
ADMIN_PASSWORD='tern-dev'
WAIT_SECS=${STACK_WAIT_SECS:-240}

GRAFANAS="grafana12 grafana11"

die() {
	printf 'stack: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '==> %s\n' "$*" >&2
}

usage() {
	printf 'usage: %s up|down|reset|status|smoke|capture|token-path <grafana12|grafana11>\n' "$0" >&2
	exit 2
}

dc() {
	docker compose -f "$COMPOSE_FILE" "$@"
}

require_tools() {
	command -v docker >/dev/null 2>&1 || die "docker not found"
	docker info >/dev/null 2>&1 || die "docker daemon is not reachable; start Docker"
	docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin not found"
	command -v curl >/dev/null 2>&1 || die "curl not found"
	command -v jq >/dev/null 2>&1 || die "jq not found"
}

grafana_url() {
	case $1 in
	grafana12) printf 'http://127.0.0.1:3000' ;;
	grafana11) printf 'http://127.0.0.1:3011' ;;
	*) die "unknown grafana '$1' (grafana12|grafana11)" ;;
	esac
}

token_file() {
	printf '%s/%s.token' "$STATE" "$1"
}

# admin_api GRAFANA METHOD PATH [JSON]: admin basic auth; prints the body, fails on HTTP >= 400.
admin_api() {
	base=$(grafana_url "$1")
	if [ $# -ge 4 ]; then
		printf 'user = "%s:%s"\n' "$ADMIN_USER" "$ADMIN_PASSWORD" |
			curl -fsS -K - -X "$2" -H 'Content-Type: application/json' --data-binary "$4" "$base$3"
	else
		printf 'user = "%s:%s"\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | curl -fsS -K - -X "$2" "$base$3"
	fi
}

# token_api GRAFANA METHOD PATH [JSON]: service-account bearer auth; prints the body.
token_api() {
	base=$(grafana_url "$1")
	tf=$(token_file "$1")
	[ -s "$tf" ] || die "no token for $1; run '$0 up'"
	if [ $# -ge 4 ]; then
		printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tf")" |
			curl -fsS -K - -X "$2" -H 'Content-Type: application/json' --data-binary "$4" "$base$3"
	else
		printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tf")" | curl -fsS -K - -X "$2" "$base$3"
	fi
}

token_works() {
	tf=$(token_file "$1")
	[ -s "$tf" ] || return 1
	token_api "$1" GET /api/user >/dev/null 2>&1
}

# wait_url NAME URL: poll until URL answers 2xx or WAIT_SECS pass.
wait_url() {
	i=0
	until curl -fsS -o /dev/null --max-time 3 "$2" 2>/dev/null; do
		i=$((i + 2))
		[ "$i" -lt "$WAIT_SECS" ] || die "$1 not ready at $2 after ${WAIT_SECS}s (see: docker compose -f dev/compose.yml logs)"
		sleep 2
	done
}

ensure_token() {
	g=$1
	if token_works "$g"; then
		return 0
	fi
	sa_id=$(admin_api "$g" GET "/api/serviceaccounts/search?query=$SA_NAME" |
		jq -r --arg n "$SA_NAME" '[.serviceAccounts[] | select(.name == $n)][0].id // empty')
	if [ -z "$sa_id" ]; then
		sa_id=$(admin_api "$g" POST /api/serviceaccounts "{\"name\":\"$SA_NAME\",\"role\":\"Admin\"}" | jq -r '.id')
	fi
	[ -n "$sa_id" ] && [ "$sa_id" != null ] || die "could not create service account on $g"
	# Old tokens for this account are stale by definition (we lost or never had the file).
	for tid in $(admin_api "$g" GET "/api/serviceaccounts/$sa_id/tokens" | jq -r '.[].id'); do
		admin_api "$g" DELETE "/api/serviceaccounts/$sa_id/tokens/$tid" >/dev/null
	done
	tf=$(token_file "$g")
	(
		umask 077
		admin_api "$g" POST "/api/serviceaccounts/$sa_id/tokens" "{\"name\":\"$SA_NAME-$(date +%s)\"}" |
			jq -r '.key' >"$tf.tmp"
	)
	[ -s "$tf.tmp" ] && [ "$(cat "$tf.tmp")" != null ] || {
		rm -f "$tf.tmp"
		die "token creation failed on $g"
	}
	chmod 600 "$tf.tmp"
	mv "$tf.tmp" "$tf"
	token_works "$g" || die "fresh token for $g does not authenticate"
}

seed() {
	g=$1
	if ! token_api "$g" GET /api/library-elements/tern-lib-up >/dev/null 2>&1; then
		token_api "$g" POST /api/library-elements "$(cat "$ROOT/dev/grafana/library-panels/tern-lib-up.json")" >/dev/null
	fi
	seeded=$(token_api "$g" GET '/api/annotations?tags=tern-seed&limit=10' | jq 'length')
	if [ "$seeded" = 0 ]; then
		now=$(date +%s)
		t1=$(((now - 20 * 60) * 1000))
		r0=$(((now - 45 * 60) * 1000))
		r1=$(((now - 40 * 60) * 1000))
		token_api "$g" POST /api/annotations \
			"{\"dashboardUID\":\"tern-panels\",\"panelId\":2,\"time\":$t1,\"tags\":[\"tern-seed\",\"deploy\"],\"text\":\"helm upgrade checkout --version 1.4.2\"}" >/dev/null
		token_api "$g" POST /api/annotations \
			"{\"time\":$r0,\"timeEnd\":$r1,\"tags\":[\"tern-seed\",\"maintenance\"],\"text\":\"Maintenance window (organization-wide region annotation)\"}" >/dev/null
	fi
}

cmd_up() {
	require_tools
	mkdir -p "$STATE"
	chmod 700 "$ROOT/.sandbox" "$STATE"
	log "starting containers"
	dc up -d --wait --wait-timeout "$WAIT_SECS"
	log "waiting for endpoints"
	wait_url grafana12 http://127.0.0.1:3000/api/health
	wait_url grafana11 http://127.0.0.1:3011/api/health
	wait_url prometheus3 http://127.0.0.1:9090/-/ready
	wait_url prometheus2 http://127.0.0.1:9091/-/ready
	wait_url alertmanager http://127.0.0.1:9093/-/ready
	wait_url loki http://127.0.0.1:3100/ready
	wait_url tempo http://127.0.0.1:3200/ready
	i=0
	until dc exec -T grafana12 wget -q -O /dev/null http://renderer:8081/healthz 2>/dev/null; do
		i=$((i + 2))
		[ "$i" -lt "$WAIT_SECS" ] || die "image renderer not healthy after ${WAIT_SECS}s"
		sleep 2
	done
	for g in $GRAFANAS; do
		log "service-account token for $g"
		ensure_token "$g"
		log "seeding $g"
		seed "$g"
	done
	log "stack is up; tokens in $STATE (mode 0600). Alerts start firing within about a minute."
}

cmd_down() {
	require_tools
	dc down --volumes --remove-orphans
	rm -f "$STATE"/*.token "$STATE"/*.token.tmp
}

probe() {
	if curl -fsS -o /dev/null --max-time 3 "$2" 2>/dev/null; then
		printf '  %-14s ready  %s\n' "$1" "$2"
	else
		printf '  %-14s DOWN   %s\n' "$1" "$2"
	fi
}

count_or_dash() {
	# count_or_dash JQ_FILTER: reads JSON on stdin, prints the number or "-" on any failure.
	jq -r "$1" 2>/dev/null || printf -- '-\n'
}

cmd_status() {
	require_tools
	dc ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
	printf '\nendpoints:\n'
	probe grafana12 http://127.0.0.1:3000/api/health
	probe grafana11 http://127.0.0.1:3011/api/health
	probe prometheus3 http://127.0.0.1:9090/-/ready
	probe prometheus2 http://127.0.0.1:9091/-/ready
	probe alertmanager http://127.0.0.1:9093/-/ready
	probe loki http://127.0.0.1:3100/ready
	probe tempo http://127.0.0.1:3200/ready
	if dc exec -T grafana12 wget -q -O /dev/null http://renderer:8081/healthz 2>/dev/null; then
		printf '  %-14s ready  %s\n' renderer 'http://renderer:8081 (internal)'
	else
		printf '  %-14s DOWN   %s\n' renderer 'http://renderer:8081 (internal)'
	fi
	printf '\nfiring alerts:\n'
	for p in prometheus3=9090 prometheus2=9091; do
		n=$(curl -fsS --max-time 3 "http://127.0.0.1:${p#*=}/api/v1/alerts" 2>/dev/null |
			count_or_dash '[.data.alerts[] | select(.state == "firing")] | length')
		printf '  %-14s %s\n' "${p%%=*}" "$n"
	done
	n=$(curl -fsS --max-time 3 'http://127.0.0.1:9093/api/v2/alerts?active=true&silenced=false&inhibited=false' 2>/dev/null |
		count_or_dash 'length')
	printf '  %-14s %s\n' alertmanager "$n"
	for g in $GRAFANAS; do
		if token_works "$g"; then
			n=$(token_api "$g" GET /api/prometheus/grafana/api/v1/alerts 2>/dev/null |
				count_or_dash '[.data.alerts[] | select(.state == "Alerting")] | length')
		else
			n="- (no token; run up)"
		fi
		printf '  %-14s %s\n' "$g" "$n"
	done
	printf '\ndata:\n'
	n=$(curl -fsS --max-time 5 -G 'http://127.0.0.1:3100/loki/api/v1/query_range' \
		--data-urlencode 'query={job="loggen"}' --data-urlencode 'limit=100' \
		--data-urlencode "start=$(($(date +%s) - 300))000000000" 2>/dev/null |
		count_or_dash '[.data.result[].values[]] | length')
	printf '  %-14s %s log lines in the last 5m (limit 100)\n' loki "$n"
	n=$(curl -fsS --max-time 5 -G 'http://127.0.0.1:3200/api/search' --data-urlencode 'q={}' \
		--data-urlencode 'limit=20' 2>/dev/null | count_or_dash '.traces | length')
	printf '  %-14s %s recent traces (limit 20)\n' tempo "$n"
}

# smoke_check NAME CMD...: retry CMD (which must print "ok") until it does or WAIT_SECS pass.
smoke_check() {
	name=$1
	shift
	i=0
	until [ "$("$@" 2>/dev/null)" = ok ]; do
		i=$((i + 3))
		[ "$i" -lt "$WAIT_SECS" ] || die "smoke: $name not satisfied after ${WAIT_SECS}s"
		sleep 3
	done
	printf 'smoke: %-34s ok\n' "$name"
}

json_ok() {
	# json_ok URL JQ_BOOL_FILTER [GRAFANA]: prints "ok" when the filter is true.
	if [ $# -ge 3 ]; then
		body=$(token_api "$3" GET "$1")
	else
		body=$(curl -fsS --max-time 5 "$1")
	fi
	[ "$(printf '%s' "$body" | jq -r "$2")" = true ] && printf ok
}

cmd_smoke() {
	require_tools
	firing='[.data.alerts[] | select(.state == "firing")] | length >= 1'
	smoke_check "prometheus3 firing alert" json_ok http://127.0.0.1:9090/api/v1/alerts "$firing"
	smoke_check "prometheus2 firing alert" json_ok http://127.0.0.1:9091/api/v1/alerts "$firing"
	smoke_check "alertmanager active alerts" json_ok 'http://127.0.0.1:9093/api/v2/alerts?active=true' 'length >= 1'
	for g in $GRAFANAS; do
		smoke_check "$g firing alert" json_ok /api/prometheus/grafana/api/v1/alerts \
			'[.data.alerts[] | select(.state == "Alerting")] | length >= 1' "$g"
		smoke_check "$g provisioned dashboards" json_ok '/api/search?query=Tern&type=dash-db' 'length >= 3' "$g"
	done
	smoke_check "prometheus3 exemplars" json_ok \
		'http://127.0.0.1:9090/api/v1/query_exemplars?query=traces_spanmetrics_latency_bucket' '.data | length >= 1'
	smoke_check "loki log lines" json_ok \
		"http://127.0.0.1:3100/loki/api/v1/query_range?query=%7Bjob%3D%22loggen%22%7D&limit=10&start=$(($(date +%s) - 300))000000000" \
		'[.data.result[].values[]] | length >= 1'
	smoke_check "tempo traces" json_ok 'http://127.0.0.1:3200/api/search?limit=5' '.traces | length >= 1'
	smoke_check "renderer" sh -c "docker compose -f '$COMPOSE_FILE' exec -T grafana12 wget -q -O /dev/null http://renderer:8081/healthz && printf ok"
}

case ${1:-} in
up) cmd_up ;;
down) cmd_down ;;
reset)
	cmd_down
	cmd_up
	;;
status) cmd_status ;;
smoke) cmd_smoke ;;
capture)
	shift
	exec sh "$ROOT/scripts/fixtures/capture.sh" "$@"
	;;
token-path)
	[ $# -eq 2 ] || usage
	grafana_url "$2" >/dev/null
	printf '%s\n' "$(token_file "$2")"
	;;
*) usage ;;
esac
