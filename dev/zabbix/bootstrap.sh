#!/bin/sh
# Seed the dev Zabbix 7.0 (compose profile `zabbix`) with the shapes the tern-s4-zabbix dashboard and
# the Zabbix fixtures need: host group "Netbox Hosts", two hosts polled through zabbix-agent with
# numeric items (bps, %, B) tagged `description: NNI-...`, four triggers that stay in problem state
# (severities 2..5, one tagged Priority:1) and one acknowledged problem. Idempotent: an existing
# host group means it already ran (`sh scripts/stack.sh down` wipes it).
#
# Only ever talks to the local dev server (ZABBIX_URL, default http://127.0.0.1:18080) with its
# local-only default credentials Admin / zabbix. The session token stays in a shell variable and
# reaches curl on stdin, never on the command line.
set -eu

URL=${ZABBIX_URL:-http://127.0.0.1:18080}/api_jsonrpc.php
WAIT_SECS=${STACK_WAIT_SECS:-240}
AUTH=

die() {
	printf 'zabbix: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '==> %s\n' "$*" >&2
}

# api METHOD PARAMS_JSON: print .result, die on a JSON-RPC error.
api() {
	body=$(jq -cn --arg m "$1" --argjson p "$2" '{jsonrpc: "2.0", method: $m, params: $p, id: 1}')
	if [ -n "$AUTH" ]; then
		resp=$(printf 'header = "Authorization: Bearer %s"\n' "$AUTH" |
			curl -fsS --max-time 20 -K - -H 'Content-Type: application/json-rpc' -d "$body" "$URL")
	else
		resp=$(curl -fsS --max-time 20 -H 'Content-Type: application/json-rpc' -d "$body" "$URL")
	fi
	if printf '%s' "$resp" | jq -e '.error' >/dev/null; then
		die "$1: $(printf '%s' "$resp" | jq -c '.error')"
	fi
	printf '%s' "$resp" | jq -c '.result'
}

log "waiting for the Zabbix API at $URL"
deadline=$(($(date +%s) + WAIT_SECS))
until curl -fsS --max-time 5 -H 'Content-Type: application/json-rpc' \
	-d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' "$URL" 2>/dev/null | jq -e '.result' >/dev/null; do
	[ "$(date +%s)" -lt "$deadline" ] || die "API not ready after ${WAIT_SECS}s"
	sleep 3
done
AUTH=$(api user.login '{"username":"Admin","password":"zabbix"}' | jq -r .)

# The image's own "Zabbix server" host polls an agent at 127.0.0.1 that is not there; its "agent is not
# available" problem would pollute the counts, so disable it.
zid=$(api host.get '{"output":["hostid"],"filter":{"host":["Zabbix server"]}}' | jq -r '.[0].hostid // empty')
[ -z "$zid" ] || api host.update "$(jq -cn --arg h "$zid" '{hostid: $h, status: 1}')" >/dev/null

if [ "$(api hostgroup.get '{"filter":{"name":["Netbox Hosts"]}}' | jq length)" -gt 0 ]; then
	log "already bootstrapped"
	exit 0
fi

gid=$(api hostgroup.create '{"name":"Netbox Hosts"}' | jq -r '.groupids[0]')

# host NAME CIRCUIT: an agent host (all hosts poll the one zabbix-agent container) with traffic,
# CPU and memory items; the traffic items carry the circuit tag the dashboard filters on.
host() {
	params=$(jq -cn --arg name "$1" --arg circuit "$2" --arg gid "$gid" '{
		host: $name,
		groups: [{groupid: $gid}],
		interfaces: [{type: 1, main: 1, useip: 0, ip: "", dns: "zabbix-agent", port: "10050"}]
	}')
	hid=$(api host.create "$params" | jq -r '.hostids[0]')
	iid=$(api hostinterface.get "$(jq -cn --arg h "$hid" '{hostids: [$h]}')" | jq -r '.[0].interfaceid')
	items=$(jq -cn --arg h "$hid" --arg i "$iid" --arg circuit "$2" '
		def traffic($name; $key): {
			hostid: $h, interfaceid: $i, type: 0, value_type: 3, delay: "30s", units: "bps",
			name: $name, key_: $key,
			preprocessing: [
				{type: 10, params: "", error_handler: 0, error_handler_params: ""},
				{type: 1, params: "8", error_handler: 0, error_handler_params: ""}
			],
			tags: [{tag: "description", value: $circuit}, {tag: "component", value: "network"}]
		};
		[
			traffic("Interface eth0(\($circuit)): Bits received"; "net.if.in[eth0]"),
			traffic("Interface eth0(\($circuit)): Bits sent"; "net.if.out[eth0]"),
			{hostid: $h, interfaceid: $i, type: 0, value_type: 0, delay: "30s", units: "%",
				name: "CPU utilization", key_: "system.cpu.util", tags: [{tag: "component", value: "cpu"}]},
			{hostid: $h, interfaceid: $i, type: 0, value_type: 3, delay: "30s", units: "B",
				name: "Memory used", key_: "vm.memory.size[used]", tags: [{tag: "component", value: "memory"}]}
		]')
	api item.create "$items" >/dev/null
	log "host $1 ($2)"
}

host nni-edge-dfw "NNI-ACME-DFW: Dallas transit"
host nni-edge-ord "NNI-ACME-ORD: Chicago transit"

# Always-true expressions, so each trigger stays in problem state once its item has a value.
triggers=$(jq -cn '[
	{description: "High CPU on {HOST.NAME}", priority: 2,
		expression: "last(/nni-edge-dfw/system.cpu.util)>=0"},
	{description: "Memory pressure on {HOST.NAME}", priority: 3,
		expression: "last(/nni-edge-ord/vm.memory.size[used])>=0"},
	{description: "Transit {HOST.NAME} saturated", priority: 4,
		expression: "last(/nni-edge-dfw/net.if.in[eth0])>=0",
		tags: [{tag: "Priority", value: "1"}]},
	{description: "Transit {HOST.NAME} down", priority: 5,
		expression: "last(/nni-edge-ord/net.if.out[eth0])>=0",
		tags: [{tag: "Priority", value: "1"}]}
]')
api trigger.create "$triggers" >/dev/null
log "4 triggers (severities 2..5)"

log "waiting for problems (first item values take up to a minute)"
deadline=$(($(date +%s) + WAIT_SECS))
while :; do
	problems=$(api problem.get '{"output":["eventid","name","severity"],"recent":false}')
	[ "$(printf '%s' "$problems" | jq length)" -ge 4 ] && break
	[ "$(date +%s)" -lt "$deadline" ] || die "only $(printf '%s' "$problems" | jq length)/4 problems after ${WAIT_SECS}s"
	sleep 5
done

# Acknowledge (2) + add message (4) on the warning problem.
eid=$(printf '%s' "$problems" | jq -r '[.[] | select(.severity == "2")][0].eventid')
api event.acknowledge "$(jq -cn --arg e "$eid" '{eventids: [$e], action: 6, message: "Known: tern dev stack"}')" >/dev/null
log "acknowledged event $eid; Zabbix ready"
