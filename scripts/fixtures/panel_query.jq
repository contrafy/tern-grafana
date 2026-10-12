# Builds the /api/ds/query body Grafana's frontend sends for one panel of a provisioned dashboard,
# or nothing when the frontend would send no request (no targets, all hidden, empty expressions).
#
#   jq -c --argjson pid ID --argjson now NOW_MS --arg trace_id ID -f panel_query.jq dashboard.json
#
# Mirrors public/app/features/query/state/PanelQueryRunner.ts and
# public/app/features/dashboard/utils/panel.ts (applyPanelTimeOverrides):
# - range: dashboard `time` (relative "now-<dur>" only), replaced by panel `timeFrom` ("30m" ->
#   now-30m .. now), then moved back by panel `timeShift`; sent as epoch-ms strings like the frontend.
# - maxDataPoints: panel `maxDataPoints`, else the panel width in px, taken as gridPos.w * 80 (a 1920 px
#   wide dashboard).
# - intervalMs: rangeutil.calculateInterval: roundInterval(range / maxDataPoints), raised to the low
#   limit, which is panel `interval`, else the datasource's min interval (provisioned timeInterval 10s
#   for Prometheus).
# - each target gets its own or the panel's datasource; `${trace_id}` is replaced with $trace_id.

def dur_ms:
	capture("^(?<n>[0-9]+)(?<u>ms|s|m|h|d|w|y)$")
	| (.n | tonumber) * {"ms": 1, "s": 1000, "m": 60000, "h": 3600000, "d": 86400000, "w": 604800000, "y": 31536000000}[.u];

# packages/grafana-data/src/datetime/rangeutil.ts roundInterval
def round_interval:
	. as $i
	| [
		[15, 10], [35, 20], [75, 50], [150, 100], [350, 200], [750, 500], [1500, 1000], [3500, 2000],
		[7500, 5000], [12500, 10000], [17500, 15000], [25000, 20000], [45000, 30000], [90000, 60000],
		[210000, 120000], [450000, 300000], [750000, 600000], [1050000, 900000], [1500000, 1200000],
		[2700000, 1800000], [5400000, 3600000], [9000000, 7200000], [16200000, 10800000],
		[32400000, 21600000], [86400000, 43200000], [604800000, 86400000], [1814400000, 604800000],
		[3628800000, 2592000000]
	]
	| (map(select($i < .[0]))[0][1]) // 31536000000;

def ds_min_interval: {"prometheus": "10s"}[.type // ""];

def empty_expr: (.datasource.type == "prometheus" or .datasource.type == "loki") and ((.expr // "") == "");

. as $d
| ($d.panels[] | select(.id == $pid)) as $p
| ($d.time.from | ltrimstr("now-") | dur_ms) as $span
| (if $p.timeFrom then ($p.timeFrom | ltrimstr("now-") | dur_ms) else $span end) as $range
| (if $p.timeShift then ($p.timeShift | dur_ms) else 0 end) as $shift
| ($now - $shift) as $to
| ($to - $range) as $from
| ($p.maxDataPoints // ($p.gridPos.w * 80)) as $mdp
| [
	($p.targets // [])[]
	| . + {datasource: (.datasource // $p.datasource)}
	| select((.hide // false) | not)
	| select(empty_expr | not)
	| (($p.interval // (.datasource | ds_min_interval)) as $low
		| ($range / $mdp | round_interval) as $calc
		| (if $low then ([$calc, ($low | dur_ms)] | max) else $calc end)) as $interval_ms
	| . + {intervalMs: $interval_ms, maxDataPoints: $mdp}
	| walk(if type == "string" then gsub("\\$\\{trace_id\\}"; $trace_id) else . end)
]
| select(length > 0)
| {queries: ., from: ($from | tostring), to: ($to | tostring)}
