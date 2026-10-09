#!/bin/sh
# Records real responses from the running dev stack (scripts/stack.sh up) into
#
#   tests/fixtures/<backend>/<version>/<name>.<ext>      response body (ext from Content-Type)
#   tests/fixtures/<backend>/<version>/<name>.request.json   request body, for POST/PUT captures
#   tests/fixtures/<backend>/<version>/<name>.txt|.stderr    CLI stdout / stderr (stderr only if non-empty)
#   tests/fixtures/MANIFEST.tsv                           one row per response / CLI run
#
# <version> is what the server (or CLI) reports about itself, so captures from different pinned
# versions sit side by side. A run replaces each <backend>/<version> directory it captured as a
# whole and rewrites their MANIFEST rows; directories of other versions are kept.
#
# Secrets: credentials reach curl on stdin only; bodies are scrubbed of Grafana tokens and the
# run aborts (writing nothing) if any token, Authorization or Bearer string survives.
#
#   sh scripts/fixtures/capture.sh          (also: sh scripts/stack.sh capture)
#
# Env: CAPTURE_WAIT_SECS (default 240) bounds each readiness wait; CAPTURE_MIN_AGE (default 300)
# is how many seconds of Prometheus history to wait for (on top of CAPTURE_WAIT_SECS) so range
# queries are not mostly empty.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=$ROOT/tests/fixtures
MANIFEST=$OUT/MANIFEST.tsv
STACK=$ROOT/scripts/stack.sh
WAIT_SECS=${CAPTURE_WAIT_SECS:-240}
MIN_AGE=${CAPTURE_MIN_AGE:-300}

G12=http://127.0.0.1:3000
G11=http://127.0.0.1:3011
P3=http://127.0.0.1:9090
P2=http://127.0.0.1:9091
AM=http://127.0.0.1:9093
LOKI=http://127.0.0.1:3100
TEMPO=http://127.0.0.1:3200

die() {
	printf 'capture: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '==> %s\n' "$*" >&2
}

dc() {
	docker compose -f "$ROOT/dev/compose.yml" --progress quiet "$@"
}

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v curl >/dev/null 2>&1 || die "curl not found"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tern-grafana-capture.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
ROWS=$TMP/rows.tsv
DIRS=$TMP/dirs
: >"$ROWS"
: >"$DIRS"

enc() {
	jq -rn --arg s "$1" '$s | @uri'
}

iso() {
	jq -rn --argjson t "$1" '$t | todate'
}

# ---------------------------------------------------------------------------------------------
# Request plumbing. `use` selects the target; `req` captures one HTTP exchange.

B=
V=
BASE=
TOKEN_FILE=
DIR=
LAST=

use() {
	B=$1
	V=${2#v}
	BASE=$3
	TOKEN_FILE=${4:-}
	DIR=$TMP/out/$B/$V
	mkdir -p "$DIR"
	grep -qx "$B/$V" "$DIRS" || printf '%s/%s\n' "$B" "$V" >>"$DIRS"
}

auth_conf() {
	if [ -n "$TOKEN_FILE" ]; then
		printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TOKEN_FILE")"
	fi
}

ext_for() {
	case $1 in
	*json*) printf json ;;
	image/png*) printf png ;;
	text/html*) printf html ;;
	*yaml*) printf yaml ;;
	*protobuf*) printf pb ;;
	text/plain* | '') printf txt ;;
	*) printf bin ;;
	esac
}

# Strip anything credential-shaped from a recorded URL (none of ours carry one; belt and braces).
redact_url() {
	printf '%s' "$1" | sed -E 's/([?&](token|api_key|apikey|access_token|auth)=)[^&]*/\1REDACTED/g'
}

row() {
	# row PATH METHOD URL STATUS REQUEST
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$V" "$5" >>"$ROWS"
}

# req NAME METHOD PATH?QUERY [BODY [ACCEPT [BODY_CONTENT_TYPE]]]
# The body is saved next to the response as <name>.request.json (or .request.txt for form bodies).
req() {
	name=$1
	method=$2
	pathq=$3
	body=${4:-}
	accept=${5:-application/json}
	btype=${6:-application/json}
	resp=$DIR/$name.resp
	reqcol=-
	if [ -n "$body" ]; then
		case $btype in
		*json*) rf=$name.request.json ;;
		*) rf=$name.request.txt ;;
		esac
		printf '%s' "$body" >"$DIR/$rf"
		reqcol=$B/$V/$rf
		meta=$(auth_conf | curl -sS -K - -o "$resp" -w '%{http_code} %{content_type}' --max-time 60 \
			-X "$method" -H "Accept: $accept" -H "Content-Type: $btype" \
			--data-binary @"$DIR/$rf" "$BASE$pathq") || true
	else
		meta=$(auth_conf | curl -sS -K - -o "$resp" -w '%{http_code} %{content_type}' --max-time 60 \
			-X "$method" -H "Accept: $accept" "$BASE$pathq") || true
	fi
	[ -f "$resp" ] || : >"$resp"
	code=${meta%% *}
	[ -n "$code" ] || code=000
	case $meta in
	*' '*) ctype=${meta#* } ;;
	*) ctype= ;;
	esac
	ext=$(ext_for "$ctype")
	LAST=$DIR/$name.$ext
	mv "$resp" "$LAST"
	row "$B/$V/$name.$ext" "$method" "$(redact_url "$pathq")" "$code" "$reqcol"
	case $code in
	000) log "  $B/$V/$name: no response" ;;
	esac
}

get() {
	req "$1" GET "$2"
}

# cli NAME SERVICE ENTRYPOINT ARGS...: run a CLI inside its pinned image on the stack network.
cli() {
	name=$1
	svc=$2
	ep=$3
	shift 3
	set +e
	dc run --rm --no-deps -T --entrypoint "$ep" "$svc" "$@" >"$DIR/$name.txt" 2>"$DIR/$name.stderr"
	code=$?
	set -e
	[ -s "$DIR/$name.stderr" ] || rm -f "$DIR/$name.stderr"
	row "$B/$V/$name.txt" CLI "$ep $*" "$code" -
}

cli_version() {
	# cli_version SERVICE ENTRYPOINT: "promtool, version 3.15.0 (branch: ...)" -> 3.15.0.
	# Some builds (logcli 3.7.x) report an empty version; fall back to the pinned image tag.
	v=$(dc run --rm --no-deps -T --entrypoint "$2" "$1" --version 2>&1 |
		sed -n 's/.*version \([0-9][^ ]*\).*/\1/p' | head -n 1)
	if [ -z "$v" ]; then
		v=$(dc --profile tools config --format json | jq -r --arg s "$1" '.services[$s].image' | sed 's/.*://')
	fi
	printf '%s\n' "${v#v}"
}

# ---------------------------------------------------------------------------------------------
# Readiness: wait until the stack shows the states the fixtures are meant to record.

wait_for() {
	what=$1
	shift
	i=0
	until "$@" >/dev/null 2>&1; do
		i=$((i + 3))
		[ "$i" -lt "${WAIT_LIMIT:-$WAIT_SECS}" ] || die "timed out after ${WAIT_LIMIT:-$WAIT_SECS}s waiting for: $what"
		sleep 3
	done
}

jtest() {
	# jtest URL JQ_BOOL_FILTER [TOKEN_FILE]
	tf=${3:-}
	if [ -n "$tf" ]; then
		body=$(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tf")" | curl -fsS -K - --max-time 10 "$1")
	else
		body=$(curl -fsS --max-time 10 "$1")
	fi
	[ "$(printf '%s' "$body" | jq -r "$2")" = true ]
}

TOK12=$(sh "$STACK" token-path grafana12)
TOK11=$(sh "$STACK" token-path grafana11)
[ -s "$TOK12" ] && [ -s "$TOK11" ] || die "missing Grafana tokens; run 'sh scripts/stack.sh up'"

log "waiting for the stack to reach fixture state"
for p in $P3 $P2; do
	wait_for "$p ready" curl -fsS -o /dev/null "$p/-/ready"
	WAIT_LIMIT=$((MIN_AGE + WAIT_SECS))
	wait_for "$p history >= ${MIN_AGE}s" jtest "$p/api/v1/query?query=$(enc 'time() - min(process_start_time_seconds{job="prometheus"})')" \
		"(.data.result[0].value[1] | tonumber) >= $MIN_AGE"
	WAIT_LIMIT=
	wait_for "$p firing alerts" jtest "$p/api/v1/alerts" '[.data.alerts[] | select(.state == "firing")] | length >= 2'
	wait_for "$p pending alert" jtest "$p/api/v1/alerts" '[.data.alerts[] | select(.state == "pending")] | length >= 1'
	wait_for "$p failing rule" jtest "$p/api/v1/rules" '[.data.groups[].rules[] | select(.health == "err")] | length >= 1'
	wait_for "$p exemplars" jtest "$p/api/v1/query_exemplars?query=traces_spanmetrics_latency_bucket" '.data | length >= 1'
done
wait_for "alertmanager alerts" jtest "$AM/api/v2/alerts" 'length >= 3'
GRAFANA_RULES_READY='([.data.groups[].rules[] | select(.state == "firing")] | length >= 2) and ([.data.groups[].rules[] | select(.state == "pending")] | length >= 1)'
wait_for "$G12 firing + pending rules" jtest "$G12/api/prometheus/grafana/api/v1/rules" "$GRAFANA_RULES_READY" "$TOK12"
wait_for "$G11 firing + pending rules" jtest "$G11/api/prometheus/grafana/api/v1/rules" "$GRAFANA_RULES_READY" "$TOK11"
wait_for "loki streams" jtest "$LOKI/loki/api/v1/query?query=$(enc 'count(count_over_time({job="loggen"}[5m]))')" \
	'(.data.result[0].value[1] | tonumber) >= 5'
wait_for "tempo traces" jtest "$TEMPO/api/search?q=$(enc '{resource.service.name="payments"}')&limit=5" '.traces | length >= 1'

NOW=$(date +%s)
START=$((NOW - 900))
END=$NOW
NS_START=${START}000000000
NS_END=${END}000000000

# A trace that exists in Tempo, used both directly and through Grafana. Search results come from
# completed traces, so the id is fetchable by the time we ask for it.
TRACE_ID=$(curl -fsS "$TEMPO/api/search?q=$(enc '{resource.service.name="payments"}')&limit=1&start=$START&end=$END" | jq -r '.traces[0].traceID')
[ -n "$TRACE_ID" ] && [ "$TRACE_ID" != null ] || die "no trace id from Tempo search"

# ---------------------------------------------------------------------------------------------
# Prometheus (3.x and 2.53 LTS)

capture_prometheus() {
	base=$1
	ver=$(curl -fsS "$base/api/v1/status/buildinfo" | jq -r '.data.version')
	use prometheus "$ver" "$base"
	log "prometheus $ver ($base)"
	get buildinfo /api/v1/status/buildinfo
	get flags /api/v1/status/flags
	get runtimeinfo /api/v1/status/runtimeinfo
	get tsdb /api/v1/status/tsdb
	get config /api/v1/status/config
	get walreplay /api/v1/status/walreplay
	get query_vector "/api/v1/query?query=up&time=$END"
	get query_scalar "/api/v1/query?query=$(enc 'scalar(sum(up))')&time=$END"
	get query_string "/api/v1/query?query=$(enc '"tern"')&time=$END"
	get query_matrix "/api/v1/query?query=$(enc 'up{job="node"}[1m]')&time=$END"
	get query_empty "/api/v1/query?query=tern_nonexistent_metric&time=$END"
	get query_error_parse "/api/v1/query?query=$(enc 'sum(rate(up[5m])')&time=$END"
	get query_error_exec "/api/v1/query?query=$(enc 'up * on () up')&time=$END"
	# Form-encoded POST is what Grafana sends (datasource httpMethod: POST).
	req query_post POST /api/v1/query "query=$(enc 'sum by (job) (up)')&time=$END" application/json \
		application/x-www-form-urlencoded
	rng="start=$START&end=$END&step=15"
	get query_range_multi "/api/v1/query_range?query=$(enc 'rate(node_cpu_seconds_total{mode=~"user|system|idle"}[1m])')&$rng"
	get query_range_empty "/api/v1/query_range?query=tern_nonexistent_metric&$rng"
	get query_range_nan_inf "/api/v1/query_range?query=$(enc 'label_replace(vector(0/0), "kind", "nan", "", "") or label_replace(vector(1/0), "kind", "inf", "", "") or label_replace(vector(-1/0), "kind", "neginf", "", "")')&$rng"
	get query_range_gaps "/api/v1/query_range?query=$(enc 'vector(1) and on () (floor(vector(time()) / 60) % 2 == 0)')&$rng"
	get query_range_down_target "/api/v1/query_range?query=$(enc 'up{job=~"down|node"}')&$rng"
	get query_range_error_resolution "/api/v1/query_range?query=up&start=$((END - 7 * 86400))&end=$END&step=1"
	get labels "/api/v1/labels?start=$START&end=$END"
	get label_values_job "/api/v1/label/job/values?start=$START&end=$END"
	get label_values_name "/api/v1/label/__name__/values?start=$START&end=$END"
	get series "/api/v1/series?match%5B%5D=up&start=$START&end=$END"
	get metadata "/api/v1/metadata?limit=40"
	get metadata_metric "/api/v1/metadata?metric=prometheus_http_requests_total"
	get targets /api/v1/targets
	get targets_active "/api/v1/targets?state=active"
	get rules /api/v1/rules
	get rules_alert "/api/v1/rules?type=alert"
	get alerts /api/v1/alerts
	get alertmanagers /api/v1/alertmanagers
	get format_query "/api/v1/format_query?query=$(enc 'sum(rate(prometheus_http_requests_total{handler="/api/v1/query"}[5m]))by(job)')"
	get parse_query "/api/v1/parse_query?query=$(enc 'sum by (job) (rate(up[5m]))')"
	get query_exemplars "/api/v1/query_exemplars?query=traces_spanmetrics_latency_bucket&start=$START&end=$END"
}

capture_prometheus "$P3"
capture_prometheus "$P2"

# ---------------------------------------------------------------------------------------------
# Grafana (12 with image renderer, 11 without)

ds_query() {
	# ds_query NAME QUERIES_JSON [FROM [TO]]
	req "$1" POST /api/ds/query "{\"queries\":$2,\"from\":\"${3:-now-15m}\",\"to\":\"${4:-now}\"}"
}

capture_grafana() {
	base=$1
	tok=$2
	ver=$(curl -fsS "$base/api/health" | jq -r '.version')
	use grafana "$ver" "$base" "$tok"
	log "grafana $ver ($base)"
	TOKEN_FILE=
	get health /api/health
	TOKEN_FILE=$tok
	get frontend_settings /api/frontend/settings
	get user /api/user
	get org /api/org
	get search "/api/search?type=dash-db"
	get search_query "/api/search?query=$(enc 'Tern Pan')&type=dash-db"
	get search_folders "/api/search?type=dash-folder"
	get folders /api/folders
	for f in "$ROOT"/dev/grafana/dashboards/*.json; do
		uid=$(jq -r '.uid' "$f")
		get "dashboard_$(printf '%s' "$uid" | tr '-' '_')" "/api/dashboards/uid/$uid"
	done
	get dashboard_missing /api/dashboards/uid/tern-no-such-dashboard
	get library_element /api/library-elements/tern-lib-up
	get datasources /api/datasources
	get datasource_prom3 /api/datasources/uid/prom3

	ds_query ds_query_prom_range '[{"refId":"A","datasource":{"type":"prometheus","uid":"prom3"},"expr":"sum by (mode) (rate(node_cpu_seconds_total[1m]))","legendFormat":"{{mode}}","range":true,"instant":false,"intervalMs":15000,"maxDataPoints":200},{"refId":"B","datasource":{"type":"prometheus","uid":"prom3"},"expr":"sum(up)","range":true,"instant":false,"intervalMs":15000,"maxDataPoints":200}]'
	ds_query ds_query_prom_instant '[{"refId":"A","datasource":{"type":"prometheus","uid":"prom3"},"expr":"up","range":false,"instant":true,"intervalMs":15000,"maxDataPoints":200}]'
	ds_query ds_query_prom_table '[{"refId":"A","datasource":{"type":"prometheus","uid":"prom3"},"expr":"up","format":"table","range":false,"instant":true,"intervalMs":15000,"maxDataPoints":200}]'
	ds_query ds_query_prom_exemplars '[{"refId":"A","datasource":{"type":"prometheus","uid":"prom3"},"expr":"histogram_quantile(0.95, sum by (le, service) (rate(traces_spanmetrics_latency_bucket[1m])))","legendFormat":"{{service}}","range":true,"instant":false,"exemplar":true,"intervalMs":15000,"maxDataPoints":200}]'
	ds_query ds_query_prom_heatmap '[{"refId":"A","datasource":{"type":"prometheus","uid":"prom3"},"expr":"sum by (le) (increase(traces_spanmetrics_latency_bucket[1m]))","format":"heatmap","legendFormat":"{{le}}","range":true,"instant":false,"intervalMs":15000,"maxDataPoints":200}]'
	ds_query ds_query_prom_error '[{"refId":"A","datasource":{"type":"prometheus","uid":"prom3"},"expr":"sum(rate(up[1m])","range":true,"instant":false,"intervalMs":15000,"maxDataPoints":200}]'
	ds_query ds_query_prom2_range '[{"refId":"A","datasource":{"type":"prometheus","uid":"prom2"},"expr":"sum by (job) (up)","legendFormat":"{{job}}","range":true,"instant":false,"intervalMs":15000,"maxDataPoints":200}]'
	ds_query ds_query_loki_logs '[{"refId":"A","datasource":{"type":"loki","uid":"loki"},"expr":"{job=\"loggen\"}","queryType":"range","maxLines":50,"direction":"backward"}]' now-5m
	ds_query ds_query_loki_metric '[{"refId":"A","datasource":{"type":"loki","uid":"loki"},"expr":"sum by (level) (count_over_time({job=\"loggen\"}[1m]))","legendFormat":"{{level}}","queryType":"range","intervalMs":60000,"maxDataPoints":200}]'
	# Trace by id is queryType "traceId"; a TraceQL query that is only an id fails as a search.
	ds_query ds_query_tempo_trace "[{\"refId\":\"A\",\"datasource\":{\"type\":\"tempo\",\"uid\":\"tempo\"},\"queryType\":\"traceId\",\"query\":\"$TRACE_ID\"}]"
	# Grafana 12 answers TraceQL search here; Grafana 11 fails (its UI searches via the datasource proxy).
	ds_query ds_query_tempo_search '[{"refId":"A","datasource":{"type":"tempo","uid":"tempo"},"queryType":"traceql","query":"{resource.service.name=\"payments\"}","limit":20,"tableType":"traces"}]'

	get ds_proxy_prom_targets /api/datasources/proxy/uid/prom3/api/v1/targets
	get ds_proxy_prom_query "/api/datasources/proxy/uid/prom3/api/v1/query?query=up"
	get ds_resource_prom_labels "/api/datasources/uid/prom3/resources/api/v1/labels?start=$START&end=$END"
	get ds_resource_prom_label_values "/api/datasources/uid/prom3/resources/api/v1/label/job/values?start=$START&end=$END"
	get ds_proxy_tempo_search "/api/datasources/proxy/uid/tempo/api/search?q=$(enc '{resource.service.name="payments"}')&limit=10&start=$START&end=$END"
	get ds_proxy_tempo_trace "/api/datasources/proxy/uid/tempo/api/traces/$TRACE_ID"

	req render_d_solo GET "/render/d-solo/tern-panels/tern-panels?orgId=1&panelId=2&width=1000&height=500&from=now-1h&to=now&tz=UTC" "" '*/*'

	get alerting_prom_rules /api/prometheus/grafana/api/v1/rules
	get alerting_prom_alerts /api/prometheus/grafana/api/v1/alerts
	get alerting_ds_prom_rules /api/prometheus/prom3/api/v1/rules
	get alerting_ruler_rules /api/ruler/grafana/api/v1/rules
	get alerting_provisioning_rules /api/v1/provisioning/alert-rules
	get alerting_am_alerts /api/alertmanager/grafana/api/v2/alerts
	get alerting_am_alert_groups /api/alertmanager/grafana/api/v2/alerts/groups
	get alerting_am_silences /api/alertmanager/grafana/api/v2/silences
	get alerting_ext_am_alerts /api/alertmanager/alertmanager/api/v2/alerts

	get annotations "/api/annotations?limit=50"
	get annotations_dashboard "/api/annotations?dashboardUID=tern-panels&limit=50"
	req annotation_create POST /api/annotations \
		"{\"dashboardUID\":\"tern-panels\",\"panelId\":2,\"time\":$((NOW * 1000)),\"tags\":[\"tern-capture\",\"deploy\"],\"text\":\"kubectl apply -f deploy.yaml\"}"
	aid=$(jq -r '.id // empty' "$LAST")
	[ -n "$aid" ] && req annotation_delete DELETE "/api/annotations/$aid"

	body="{\"matchers\":[{\"name\":\"alertname\",\"value\":\"TernGrafanaAlwaysFiring\",\"isRegex\":false,\"isEqual\":true}],\"startsAt\":\"$(iso "$NOW")\",\"endsAt\":\"$(iso $((NOW + 3600)))\",\"createdBy\":\"tern-grafana capture\",\"comment\":\"Fixture capture silence\"}"
	req alerting_am_silence_create POST /api/alertmanager/grafana/api/v2/silences "$body"
	sid=$(jq -r '.silenceID // .id // empty' "$LAST")
	if [ -n "$sid" ]; then
		sleep 2
		get alerting_am_silences_active /api/alertmanager/grafana/api/v2/silences
		get alerting_am_alerts_silenced "/api/alertmanager/grafana/api/v2/alerts?silenced=true"
		req alerting_am_silence_expire DELETE "/api/alertmanager/grafana/api/v2/silence/$sid"
	fi
}

capture_grafana "$G12" "$TOK12"
capture_grafana "$G11" "$TOK11"

# ---------------------------------------------------------------------------------------------
# Alertmanager (+ amtool from the same image)

ver=$(curl -fsS "$AM/api/v2/status" | jq -r '.versionInfo.version')
use alertmanager "$ver" "$AM"
log "alertmanager $ver"
get status /api/v2/status
get receivers /api/v2/receivers
get alerts /api/v2/alerts
get alerts_filtered "/api/v2/alerts?filter=$(enc 'severity="critical"')&active=true"
get alert_groups /api/v2/alerts/groups
get silences /api/v2/silences
body="{\"matchers\":[{\"name\":\"alertname\",\"value\":\"TernAlwaysFiring\",\"isRegex\":false,\"isEqual\":true}],\"startsAt\":\"$(iso "$NOW")\",\"endsAt\":\"$(iso $((NOW + 3600)))\",\"createdBy\":\"tern-grafana capture\",\"comment\":\"Fixture capture silence\"}"
req silence_create POST /api/v2/silences "$body"
AM_SID=$(jq -r '.silenceID // empty' "$LAST")
sleep 2
get silences_active /api/v2/silences
[ -n "$AM_SID" ] && get silence "/api/v2/silence/$AM_SID"
get alerts_with_silenced "/api/v2/alerts?silenced=true"
get silence_invalid_id /api/v2/silence/not-a-uuid

ver=$(cli_version alertmanager amtool)
use amtool "$ver" "$AM"
log "amtool $ver"
AMURL=--alertmanager.url=http://alertmanager:9093
cli alert_query alertmanager amtool "$AMURL" alert query
cli alert_query_silenced alertmanager amtool "$AMURL" alert query --silenced
cli alert_query_extended alertmanager amtool "$AMURL" -o extended alert query
cli alert_query_json alertmanager amtool "$AMURL" -o json alert query
cli silence_query alertmanager amtool "$AMURL" silence query
cli silence_query_json alertmanager amtool "$AMURL" -o json silence query
cli check_config alertmanager amtool check-config /etc/alertmanager/alertmanager.yml

use alertmanager "$(curl -fsS "$AM/api/v2/status" | jq -r '.versionInfo.version')" "$AM"
[ -n "$AM_SID" ] && req silence_expire DELETE "/api/v2/silence/$AM_SID"
get silences_after_expire /api/v2/silences

# ---------------------------------------------------------------------------------------------
# promtool (from both Prometheus images, against their own server)

capture_promtool() {
	svc=$1
	ver=$(cli_version "$svc" promtool)
	use promtool "$ver" ""
	log "promtool $ver"
	url=http://$svc:9090
	cli query_instant "$svc" promtool query instant "$url" 'sum by (job) (up)'
	cli query_instant_json "$svc" promtool query instant -o json "$url" 'sum by (job) (up)'
	cli query_range "$svc" promtool query range --start="$((END - 300))" --end="$END" --step=60s "$url" 'sum by (job) (up)'
	cli query_range_json "$svc" promtool query range -o json --start="$((END - 300))" --end="$END" --step=60s "$url" 'sum by (job) (up)'
	cli query_error "$svc" promtool query instant "$url" 'sum(up'
	cli check_rules_good "$svc" promtool check rules /etc/prometheus/rules/recording.yml /etc/prometheus/rules/alerts.yml
	cli check_rules_bad "$svc" promtool check rules /etc/prometheus/promtool/rules-bad.yml
	cli check_config "$svc" promtool check config /etc/prometheus/prometheus.yml
	cli test_rules_pass "$svc" promtool test rules /etc/prometheus/promtool/rules-test-pass.yml
	cli test_rules_fail "$svc" promtool test rules /etc/prometheus/promtool/rules-test-fail.yml
}

capture_promtool prometheus3
capture_promtool prometheus2

# ---------------------------------------------------------------------------------------------
# Loki (+ logcli)

ver=$(curl -fsS "$LOKI/loki/api/v1/status/buildinfo" | jq -r '.version')
use loki "$ver" "$LOKI"
log "loki $ver"
lr="start=$NS_START&end=$NS_END"
get buildinfo /loki/api/v1/status/buildinfo
get labels "/loki/api/v1/labels?$lr"
get label_values_level "/loki/api/v1/label/level/values?$lr"
get label_values_app "/loki/api/v1/label/app/values?$lr"
get series "/loki/api/v1/series?match%5B%5D=$(enc '{job="loggen"}')&$lr"
get query_range_streams "/loki/api/v1/query_range?query=$(enc '{job="loggen"}')&limit=50&$lr"
get query_range_streams_forward "/loki/api/v1/query_range?query=$(enc '{app="payments"}')&limit=20&direction=forward&$lr"
get query_range_streams_json "/loki/api/v1/query_range?query=$(enc '{app="payments", level="warn"} | json')&limit=20&$lr"
get query_range_streams_logfmt "/loki/api/v1/query_range?query=$(enc '{app="checkout"} | logfmt | duration_ms > 400')&limit=20&$lr"
get query_range_matrix "/loki/api/v1/query_range?query=$(enc 'sum by (level) (count_over_time({job="loggen"}[1m]))')&step=60&$lr"
get query_vector "/loki/api/v1/query?query=$(enc 'sum by (app) (count_over_time({job="loggen"}[5m]))')&time=$NS_END"
get query_error "/loki/api/v1/query_range?query=$(enc '{job="loggen"')&$lr"
get index_volume "/loki/api/v1/index/volume?query=$(enc '{job="loggen"}')&$lr"
get index_volume_range "/loki/api/v1/index/volume_range?query=$(enc '{job="loggen"}')&step=60&$lr"
get index_stats "/loki/api/v1/index/stats?query=$(enc '{job="loggen"}')&$lr"

ver=$(cli_version logcli logcli)
use logcli "$ver" ""
log "logcli $ver"
cli query logcli logcli query --quiet --limit=20 --since=10m '{job="loggen"}'
cli query_jsonl logcli logcli query --quiet --limit=20 --since=10m --output=jsonl '{job="loggen"}'
cli query_raw logcli logcli query --quiet --limit=20 --since=10m --output=raw '{app="payments"}'
cli query_metric logcli logcli query --quiet --since=10m 'sum by (level) (count_over_time({job="loggen"}[5m]))'
cli labels logcli logcli labels --quiet --since=10m
cli series logcli logcli series --quiet --since=10m '{job="loggen"}'

# ---------------------------------------------------------------------------------------------
# Tempo

ver=$(curl -fsS "$TEMPO/api/status/buildinfo" | jq -r '.version')
use tempo "$ver" "$TEMPO"
log "tempo $ver"
get buildinfo /api/status/buildinfo
get echo /api/echo
get search "/api/search?q=$(enc '{resource.service.name="frontend"}')&limit=10&start=$START&end=$END"
get search_errors "/api/search?q=$(enc '{status=error}')&limit=10&start=$START&end=$END"
get search_error "/api/search?q=$(enc '{ resource.service.name = ')&start=$START&end=$END"
get search_tags /api/search/tags
get search_tags_v2 /api/v2/search/tags
get search_tag_values_v2 /api/v2/search/tag/resource.service.name/values
get trace "/api/traces/$TRACE_ID"
get trace_v2 "/api/v2/traces/$TRACE_ID"
get trace_not_found /api/traces/0000000000000000000000000000beef
get metrics_query_range "/api/metrics/query_range?q=$(enc '{} | rate() by (resource.service.name)')&start=$START&end=$END&step=60s"

# ---------------------------------------------------------------------------------------------
# Scrub, verify, install.

log "scrubbing"
find "$TMP/out" -type f ! -name '*.png' | while IFS= read -r f; do
	sed -E 's/glsa_[A-Za-z0-9_]+/<redacted>/g' "$f" >"$f.scrub" && mv "$f.scrub" "$f"
done
leaks=$(grep -rIil -e 'glsa_' -e 'authorization' -e 'bearer ' -e 'set-cookie' -e 'grafana_session' "$TMP/out" || true)
for tf in "$TOK12" "$TOK11"; do
	more=$(grep -rlF -f "$tf" "$TMP/out" || true)
	leaks="$leaks $more"
done
leaks=$(printf '%s' "$leaks" | tr -s ' \n' '  ' | sed 's/^ *//; s/ *$//')
[ -z "$leaks" ] || die "refusing to install: credential-like content in: $leaks"

mkdir -p "$OUT"
while IFS= read -r d; do
	rm -rf "${OUT:?}/$d"
	mkdir -p "$(dirname "$OUT/$d")"
	cp -R "$TMP/out/$d" "$OUT/$d"
done <"$DIRS"

{
	printf 'path\tmethod\turl\tstatus\tcaptured_at\tserver_version\trequest\n'
	{
		if [ -f "$MANIFEST" ]; then
			# Keep rows of directories this run did not capture.
			awk -F '\t' -v dirs="$DIRS" '
				BEGIN { while ((getline d < dirs) > 0) keep[d] = 1 }
				NR == 1 { next }
				{ split($1, p, "/"); if (!((p[1] "/" p[2]) in keep)) print }
			' "$MANIFEST"
		fi
		cat "$ROWS"
	} | LC_ALL=C sort -t "$(printf '\t')" -k1,1
} >"$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"

log "captured $(wc -l <"$ROWS" | tr -d ' ') fixtures:"
cut -f1 "$ROWS" | awk -F / '{ print $1 "/" $2 }' | sort | uniq -c | sed 's/^/    /' >&2
awk -F '\t' '$4 == "000" { print "    no response: " $1 }' "$ROWS" >&2
