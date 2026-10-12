#!/bin/sh
# Pushes labeled, multi-level log lines to Loki's push API, a small batch every 2 seconds.
# Streams: app in {checkout, payments, frontend} x level in {debug, info, warn, error}.
# Bodies mix logfmt and JSON so parsers and level detection have both shapes to chew on.
#
# Every 10 seconds it also asks Tempo for recent traces and pushes one line per trace (each trace
# once) to stream {job="tracegen", service_name=<root service>, level=info|error}, so logs link to
# real traces: `level=info msg="handled request" trace_id=<id> service=<svc>`. Payments traces
# carry error status, so their lines are level=error.
set -u

LOKI_URL=${LOKI_URL:-http://loki:3100}
TEMPO_URL=${TEMPO_URL:-http://tempo:3200}
SEEN=/tmp/loggen-seen-traces
i=0
: >"$SEEN"

until curl -fsS -o /dev/null "$LOKI_URL/ready"; do
	sleep 2
done

# Prints "<traceID> <rootServiceName>" per trace in a Tempo search response (no jq in this image).
trace_pairs() {
	sed 's/{"traceID"/\n&/g' |
		sed -n 's/.*"traceID":"\([0-9a-f]*\)".*"rootServiceName":"\([^"]*\)".*/\1 \2/p'
}

push_trace_logs() {
	now=$(date +%s)
	{
		curl -fsS "$TEMPO_URL/api/search?limit=5&start=$((now - 120))&end=$now" || true
		# Payments traces are rarer than frontend ones; ask for them too so error lines show up.
		curl -fsS -G "$TEMPO_URL/api/search" --data-urlencode 'q={resource.service.name="payments"}' \
			--data-urlencode limit=2 --data-urlencode "start=$((now - 120))" --data-urlencode "end=$now" || true
	} | trace_pairs | while read -r id svc; do
		grep -qx "$id" "$SEEN" && continue
		printf '%s\n' "$id" >>"$SEEN"
		level=info
		[ "$svc" = payments ] && level=error
		body="{\"streams\":[{\"stream\":{\"job\":\"tracegen\",\"service_name\":\"$svc\",\"level\":\"$level\"},\"values\":[[\"${now}000000000\",\"level=$level msg=\\\"handled request\\\" trace_id=$id service=$svc\"]]}]}"
		curl -fsS -o /dev/null -H 'Content-Type: application/json' --data-binary "$body" "$LOKI_URL/loki/api/v1/push" || true
	done
	# Ids older than the 120 s search window never come back; keep the file small.
	tail -n 100 "$SEEN" >"$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
}

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
	[ $((i % 5)) -eq 0 ] && push_trace_logs
	sleep 2
done
