# Command lenses on real CLI output: promtool, amtool and logcli run from the
# stack's images (wrappers in the sandbox's bin/, host network), curl is the
# system one. Each command's block is claimed by its tern-grafana lens and
# rendered natively from what the tool printed.
LB='.sf-block[data-role="lens.plugin.tern-grafana.'

# lensed ID LINE: run LINE; its block must be claimed by lens ID, native.
lensed() {
	E2E_WAIT=60 lens "$2"
	E2E_WAIT=10 wait_for "lens $1 to claim the block" has "$LB$1\"]" || return 1
	contains "$1 shows native" "$(texts "$LB$1\"] .sf-block-opt.on")" '"Native"'
}

lensed promtool-query "promtool query instant $PROM 'sum by (job) (up)'" || return
L="$LB"'promtool-query"]'
contains "promtool header" "$(alltext "$L .sf-card-head")" "promtool query instant 6 series"
contains "promtool table has the down job" "$(texts "$L .tg-table .tg-c")" '"down"'
has "$L .sf-act" || fail "promtool: no Open in Query block action"
shot promtool

lensed amtool "amtool alert query --alertmanager.url=$AM" || return
L="$LB"'amtool"]'
want=$(curl -fsS --max-time 5 "$AM/api/v2/alerts?active=true&silenced=false&inhibited=false" | jq length)
contains "amtool header counts the active alerts" "$(alltext "$L .sf-card-head")" "amtool alert query $want alerts"
contains "amtool lists the fixture alert" "$(alltext "$L *")" "TernAlwaysFiring"
shot amtool

lensed logcli "logcli query --addr=$LOKI --since=5m --limit=20 '{job=\"loggen\"}'" || return
L="$LB"'logcli"]'
contains "logcli header" "$(alltext "$L .sf-card-head")" "logcli query 20 lines (limit reached)"
contains "logcli common labels" "$(alltext "$L *" | tr '\n' ' ')" 'job="loggen"'
shot logcli

lensed curl "curl -s '$PROM/api/v1/query?query=up'" || return
L="$LB"'curl"]'
contains "curl header" "$(alltext "$L .sf-card-head" | head -1)" "GET /api/v1/query"
contains "curl table has the down job" "$(texts "$L .tg-table .tg-c")" '"down"'
shot curl
