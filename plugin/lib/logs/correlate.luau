--!strict
-- Jumps between logs, metrics and traces (docs/logs.md, docs/traces.md):
-- - a series selector `{job="x",namespace="y"}` from a set of labels kept to
--   the configured correlation labels (`logs.correlate_labels`): LogQL stream
--   selectors and PromQL series selectors share this syntax and Go string
--   escapes, so one builder serves both directions;
-- - a log line's trace id, from structured metadata or parsed fields named
--   like a trace id, then a regular expression over the line text;
-- - the LogQL query that finds a span's logs (`trace.logs_query`) and the
--   window around a trace it runs over.

local LogQL = require("./logql")
local Regex = require("../regex")

export type Labels = { [string]: string }

local M = {}

M.DEFAULT_LABELS = table.freeze({
	"job",
	"namespace",
	"pod",
	"container",
	"service",
	"service_name",
	"app",
	"instance",
})

-- Grafana's Loki derived field for loggen-style lines, widened to JSON
-- (`"traceId":"..."`) and `key: value` forms; group 1 is the id.
M.DEFAULT_TRACE_PATTERN = [[trace_?id["']?\s*[=:]\s*["']?([0-9a-fA-F]{16,32})\b]]

-- Structured metadata and parsed field names that hold a trace id.
M.TRACE_FIELDS = table.freeze({ "trace_id", "traceID", "traceId", "traceid", "trace.id" })

M.DEFAULT_LOGS_QUERY = '{service_name="${service}"} |= "${traceId}"'

-- What `trace.logs_query` may reference.
M.TEMPLATE_VARS = table.freeze({ "service", "traceId", "spanId" })

-- Margin around a trace when looking for its logs.
M.WINDOW_MARGIN_MS = 60000

-- A label name LogQL and PromQL accept in a selector.
function M.validName(name: string): boolean
	return string.match(name, "^[%a_][%w_]*$") ~= nil
end

-- `{name="value",...}` of the `names` present in `labels` (in `names`
-- order), nil when none is.
function M.selector(labels: Labels, names: { string }): string?
	local parts: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, name in names do
		local value = labels[name]
		if value ~= nil and value ~= "" and not seen[name] and M.validName(name) then
			seen[name] = true
			table.insert(parts, name .. "=" .. LogQL.quote(value))
		end
	end
	if #parts == 0 then
		return nil
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- The equality matchers of a LogQL query's stream selector as labels (what
-- a log query certainly selects when no line is chosen).
function M.selectorLabels(expr: string): Labels
	local out: Labels = {}
	for _, m in LogQL.matchers(expr) do
		if m.op == "=" then
			out[m.name] = m.value
		end
	end
	return out
end

export type TraceMatcher = { re: Regex.Regex, default: boolean }

-- Compiles a trace id pattern (RE2 syntax, case-insensitive); nil and the
-- reason when it does not compile.
function M.traceMatcher(pattern: string?): (TraceMatcher?, string?)
	local source = pattern or M.DEFAULT_TRACE_PATTERN
	local re, err = Regex.compile(source, "i")
	if re == nil then
		return nil, err
	end
	return { re = re, default = pattern == nil or pattern == M.DEFAULT_TRACE_PATTERN }, nil
end

-- A trace id as the trace link takes it: 16 to 32 hex digits, lowercase.
local function hexId(v: string?): string?
	if v == nil or #v < 16 or #v > 32 or not string.match(v, "^%x+$") or not string.find(v, "[^0]") then
		return nil
	end
	return string.lower(v)
end

-- The trace id a log line names: structured metadata, then parsed fields
-- (`labels` too when the source did not tell them apart), then the line text.
function M.traceId(line: string, metadata: Labels, parsed: Labels, labels: Labels?, matcher: TraceMatcher): string?
	for _, set in { metadata, parsed, labels or {} } do
		for _, name in M.TRACE_FIELDS do
			local id = hexId(set[name])
			if id then
				return id
			end
		end
	end
	-- Lines without the word cannot match the default pattern; skip the regex.
	if matcher.default and not string.find(string.lower(line), "trace", 1, true) then
		return nil
	end
	local m = Regex.exec(matcher.re, line)
	if m == nil then
		return nil
	end
	return hexId(m.groups[1] or string.sub(line, m.start, m.finish))
end

-- The `${name}` references of a template that are not in TEMPLATE_VARS.
function M.unknownVars(template: string): { string }
	local out: { string } = {}
	for name in string.gmatch(template, "%${([^}]*)}") do
		if not table.find(M.TEMPLATE_VARS, name) then
			table.insert(out, name)
		end
	end
	return out
end

-- The LogQL query for a span's logs: `${service}`, `${traceId}` and
-- `${spanId}` replaced by their values escaped for a double-quoted string.
function M.logsQuery(template: string, vars: { service: string, traceId: string, spanId: string? }): string
	local values: { [string]: string } = {
		service = vars.service,
		traceId = vars.traceId,
		spanId = vars.spanId or "",
	}
	return (
		string.gsub(template, "%${([%w_]+)}", function(name: string): string
			local v = values[name]
			if v == nil then
				return "${" .. name .. "}"
			end
			return string.sub(LogQL.quote(v), 2, -2)
		end)
	)
end

-- Epoch-ms range around a trace: its start and end widened by the margin.
function M.window(start_ms: number, duration_ms: number): (number, number)
	local from = math.floor(start_ms) - M.WINDOW_MARGIN_MS
	local to = math.ceil(start_ms + math.max(0, duration_ms)) + M.WINDOW_MARGIN_MS
	return from, to
end

return M
