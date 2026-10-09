#!/bin/sh
# Pushes labeled, multi-level log lines to Loki's push API, a small batch every 2 seconds.
# Streams: app in {checkout, payments, frontend} x level in {debug, info, warn, error}.
# Bodies mix logfmt and JSON so parsers and level detection have both shapes to chew on.
set -u

LOKI_URL=${LOKI_URL:-http://loki:3100}
i=0

until curl -fsS -o /dev/null "$LOKI_URL/ready"; do
	sleep 2
done

hex() {
	# 32 hex chars from /dev/urandom, used as an opaque trace id in log lines.
	od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

while :; do
	now=$(date +%s)
	ts="${now}000000000"
	i=$((i + 1))
	status=200
	[ $((i % 7)) -eq 0 ] && status=503
	dur=$((i % 900 + 12))
	tid=$(hex)
	body=$(cat <<EOF
{"streams":[
 {"stream":{"job":"loggen","app":"checkout","env":"dev","level":"info"},
  "values":[["${ts}","level=info msg=\"order placed\" order_id=$i duration_ms=$dur trace_id=$tid"]]},
 {"stream":{"job":"loggen","app":"checkout","env":"dev","level":"debug"},
  "values":[["${ts}","level=debug msg=\"cart loaded\" items=$((i % 5 + 1))"]]},
 {"stream":{"job":"loggen","app":"payments","env":"dev","level":"warn"},
  "values":[["${ts}","{\"level\":\"warn\",\"msg\":\"slow upstream\",\"upstream\":\"bank\",\"latency_ms\":$((dur * 3))}"]]},
 {"stream":{"job":"loggen","app":"frontend","env":"dev","level":"info"},
  "values":[["${ts}","GET /checkout status=$status bytes=$((i * 37 % 5000)) duration_ms=$dur"]]}
]}
EOF
)
	if [ $((i % 5)) -eq 0 ]; then
		body=$(cat <<EOF
{"streams":[
 {"stream":{"job":"loggen","app":"payments","env":"dev","level":"error"},
  "values":[["${ts}","level=error msg=\"charge failed\" error=\"card declined\" order_id=$i trace_id=$tid"]]}
]}
EOF
)
		curl -fsS -o /dev/null -H 'Content-Type: application/json' --data-binary "$body" "$LOKI_URL/loki/api/v1/push" || true
		body=$(cat <<EOF
{"streams":[
 {"stream":{"job":"loggen","app":"checkout","env":"dev","level":"info"},
  "values":[["${ts}","level=info msg=\"order placed\" order_id=$i duration_ms=$dur trace_id=$tid"]]},
 {"stream":{"job":"loggen","app":"frontend","env":"dev","level":"info"},
  "values":[["${ts}","GET /checkout status=$status bytes=$((i * 37 % 5000)) duration_ms=$dur"]]}
]}
EOF
)
	fi
	curl -fsS -o /dev/null -H 'Content-Type: application/json' --data-binary "$body" "$LOKI_URL/loki/api/v1/push" || true
	sleep 2
done
