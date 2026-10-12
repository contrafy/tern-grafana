--!strict
-- Names, signatures and documentation of Carly's exports (G3), apart from
-- their implementation (./exports) so the window entry registers them
-- without loading the query stack: window loads have a 50 ms budget.

local M = {}

local SIG_SERIES = "{name: string, labels: {[string]: string}, points: number, first: number?, last: number?, "
	.. "last_at: string?, min: number?, max: number?, avg: number?, trend: {number}?}"
local SIG_RANGE = "(string | {from: string, to: string})?"

M.NAMES = table.freeze({ "promql", "alerts", "find_dashboard", "logs" })

M.SPECS = table.freeze({
	promql = table.freeze({
		sig = "(expr: string, range: "
			.. SIG_RANGE
			.. ', context: string?) -> {context: string, expr: string, kind: "instant" | "range", '
			.. "from: string, to: string, step: string?, series: {"
			.. SIG_SERIES
			.. "}, omitted: number, warnings: {string}}",
		doc = "Runs a PromQL query on a Tern Grafana context (Prometheus direct or through Grafana) and returns "
			.. "one summary per series (first/last/min/max/avg, a short trend), largest last value first, never "
			.. "raw samples. Without `range` it is an instant query at now; `range` is a duration back from now "
			.. '("1h", "30m"), a Grafana start ("now-6h") or {from, to} in Grafana time syntax. `context` '
			.. "defaults to the config's default_context. `omitted` counts series left out. $__interval, "
			.. "$__rate_interval and $__range are filled in.",
	}),
	alerts = table.freeze({
		sig = "(context: string?) -> {context: string, counts: {firing: number, pending: number, "
			.. "silenced: number, inhibited: number}, alerts: {{name: string, state: string, severity: string, "
			.. "summary: string, since: string, labels: {[string]: string}, runbook: string?, "
			.. "dashboard: string?, source: string?, fingerprint: string}}, omitted: number, warnings: {string}}",
		doc = "Lists the firing and pending alerts of a Tern Grafana context (Alertmanager, Grafana-managed "
			.. "alerting or Prometheus), worst severity first, with counts of silenced and inhibited ones. "
			.. "`dashboard` is a tern-grafana:// or Grafana link that opens the alert's dashboard; `source` "
			.. "opens the rule's query. `context` defaults to default_context.",
	}),
	find_dashboard = table.freeze({
		sig = "(query: string, context: string?) -> {context: string, query: string, dashboards: {{uid: string, "
			.. "title: string, folder: string?, tags: {string}, url: string?, link: string}}, omitted: number}",
		doc = 'Searches the Grafana dashboards of a Tern Grafana context by title ("" lists them). `link` '
			.. "(tern-grafana://dashboard?...) opens the dashboard natively in Tern with cx:open; `url` is the "
			.. "Grafana page. `context` defaults to default_context.",
	}),
	logs = table.freeze({
		sig = "(expr: string, range: "
			.. SIG_RANGE
			.. ', context: string?) -> {context: string, expr: string, kind: "streams" | "matrix" | '
			.. '"vector", from: string, to: string, streams: {string}?, lines: {{t: string, level: string, '
			.. "line: string, s: number}}?, series: {"
			.. SIG_SERIES
			.. "}?, omitted: number, warnings: {string}}",
		doc = "Runs a LogQL query on a Tern Grafana context (Loki direct or through Grafana). Log queries "
			.. "return the newest lines (at most 100, each cut to 300 characters) with `s` indexing `streams` "
			.. "(label sets; 0 = not listed); metric queries return series summaries like promql. `range` "
			.. 'defaults to "1h" (same forms as promql). `context` defaults to default_context.',
	}),
})

return M
