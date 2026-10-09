--!strict
-- Prometheus HTTP API (also Thanos, Mimir, Cortex, VictoriaMetrics) request
-- builders and parsers. `base` is "" for a direct endpoint or the Grafana
-- datasource proxy prefix; the API below it is the same.

local Env = require("../env")
local Frame = require("../frame/types")
local FrameProm = require("../frame/prom")
local Http = require("../transport/http")
local Response = require("./response")
local TransportTypes = require("../transport/types")

type Env = Env.Env
type Request = TransportTypes.Request
type QueryError = TransportTypes.QueryError
type Response = TransportTypes.Response

export type ListResult = { ok: true, values: { string } } | { ok: false, error: QueryError }
export type Metadata = { type: string, help: string, unit: string }
export type MetadataResult = { ok: true, metadata: { [string]: Metadata } } | { ok: false, error: QueryError }
export type Flavor = "prometheus" | "thanos" | "mimir" | "cortex" | "victoriametrics"
export type HealthResult = { ok: true, version: string, flavor: Flavor } | { ok: false, error: QueryError }
export type ListOptions = { match: { string }?, from_ms: number?, to_ms: number? }

local M = {}

-- Epoch seconds as Prometheus accepts them: integral when whole, else ms precision.
function M.seconds(ms: number): string
	if ms % 1000 == 0 then
		return string.format("%d", ms // 1000)
	end
	return string.format("%.3f", ms / 1000)
end

local function form(pairs: { { string } }): string
	local parts = table.create(#pairs)
	for i, pair in pairs do
		parts[i] = Http.escape(pair[1]) .. "=" .. Http.escape(pair[2])
	end
	return table.concat(parts, "&")
end

-- Queries are POSTed form-encoded, as Grafana does: long expressions do not
-- fit every proxy's URL limit.
local function post(path: string, pairs: { { string } }): Request
	return {
		method = "POST",
		path = path,
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		body = form(pairs),
	}
end

function M.rangeRequest(base: string, q: { expr: string, from_ms: number, to_ms: number, step_ms: number }): Request
	return post(base .. "/api/v1/query_range", {
		{ "query", q.expr },
		{ "start", M.seconds(q.from_ms) },
		{ "end", M.seconds(q.to_ms) },
		{ "step", M.seconds(q.step_ms) },
	})
end

function M.instantRequest(base: string, q: { expr: string, time_ms: number }): Request
	return post(base .. "/api/v1/query", { { "query", q.expr }, { "time", M.seconds(q.time_ms) } })
end

local function listQuery(opts: ListOptions?): { { string } }
	local query: { { string } } = {}
	if opts then
		for _, m in (opts.match or {}) :: { string } do
			table.insert(query, { "match[]", m })
		end
		if opts.from_ms then
			table.insert(query, { "start", M.seconds(opts.from_ms) })
		end
		if opts.to_ms then
			table.insert(query, { "end", M.seconds(opts.to_ms) })
		end
	end
	return query
end

function M.labelsRequest(base: string, opts: ListOptions?): Request
	return { method = "GET", path = base .. "/api/v1/labels", query = listQuery(opts) }
end

function M.labelValuesRequest(base: string, label: string, opts: ListOptions?): Request
	return {
		method = "GET",
		path = base .. "/api/v1/label/" .. Http.escape(label) .. "/values",
		query = listQuery(opts),
	}
end

-- One entry per metric (metadata repeats per target otherwise); all metrics
-- unless `metric` names one.
function M.metadataRequest(base: string, metric: string?): Request
	local query: { { string } } = { { "limit_per_metric", "1" } }
	if metric then
		table.insert(query, 1, { "metric", metric })
	end
	return { method = "GET", path = base .. "/api/v1/metadata", query = query }
end

function M.healthRequest(base: string): Request
	return { method = "GET", path = base .. "/api/v1/status/buildinfo" }
end

-- The decoded success document, or the error to report.
local function success(response: Response, env: Env, what: string): (any, QueryError?)
	local doc, err = Response.json(response, env, what)
	if doc then
		local promErr = Response.promError(doc, env, response.status)
		if promErr then
			return nil, promErr
		end
	end
	if err then
		return nil, err
	end
	if doc == nil or doc.status ~= "success" then
		return nil, { kind = "parse", status = response.status, message = what .. ": the response is not a success" }
	end
	return doc, nil
end

function M.parseQuery(response: Response, env: Env): Frame.QueryResult
	local doc, err = success(response, env, "query")
	if err then
		return { ok = false, error = err }
	end
	return FrameProm.result(doc, env)
end

function M.parseList(response: Response, env: Env): ListResult
	local doc, err = success(response, env, "list")
	if err then
		return { ok = false, error = err }
	end
	local data = Env.value(env, doc.data)
	local values: { string } = {}
	if type(data) == "table" then
		for _, v in data do
			if type(v) == "string" then
				table.insert(values, v)
			end
		end
	end
	table.sort(values)
	return { ok = true, values = values }
end

function M.parseMetadata(response: Response, env: Env): MetadataResult
	local doc, err = success(response, env, "metadata")
	if err then
		return { ok = false, error = err }
	end
	local data = Env.value(env, doc.data)
	local out: { [string]: Metadata } = {}
	if type(data) == "table" then
		for metric, entries in data do
			local first = if type(entries) == "table" then entries[1] else nil
			if type(metric) == "string" and type(first) == "table" then
				out[metric] = {
					type = tostring(Env.value(env, first.type) or "unknown"),
					help = tostring(Env.value(env, first.help) or ""),
					unit = tostring(Env.value(env, first.unit) or ""),
				}
			end
		end
	end
	return { ok = true, metadata = out }
end

local function header(headers: { [string]: string }, name: string): string?
	local lower = string.lower(name)
	for k, v in headers do
		if string.lower(k) == lower then
			return v
		end
	end
	return nil
end

-- Which server answered. Mimir and Cortex name themselves in `application`;
-- Thanos versions are 0.x where Prometheus is 2.x/3.x; VictoriaMetrics
-- imitates Prometheus but reports only `version` (no revision/goVersion).
-- Anything else is Prometheus.
function M.flavor(doc: any, headers: { [string]: string }, env: Env): Flavor
	local data = Env.value(env, doc.data)
	local app = if type(data) == "table" then Env.value(env, data.application) else nil
	app = if type(app) == "string" then string.lower(app) else ""
	if string.find(app, "mimir", 1, true) then
		return "mimir"
	elseif string.find(app, "cortex", 1, true) then
		return "cortex"
	end
	local server = string.lower(header(headers, "Server") or "")
	if string.find(server, "victoria", 1, true) then
		return "victoriametrics"
	end
	if type(data) ~= "table" then
		return "prometheus"
	end
	local version = Env.value(env, data.version)
	if type(version) == "string" and string.match(version, "^v?0%.") then
		return "thanos"
	end
	if Env.isNull(env, data.revision) and Env.isNull(env, data.goVersion) then
		return "victoriametrics"
	end
	return "prometheus"
end

function M.parseHealth(response: Response, env: Env): HealthResult
	local doc, err = success(response, env, "buildinfo")
	if err then
		return { ok = false, error = err }
	end
	local data = Env.value(env, doc.data)
	local version = if type(data) == "table" then Env.value(env, data.version) else nil
	if type(version) ~= "string" or version == "" then
		return { ok = false, error = { kind = "parse", message = "buildinfo has no version" } }
	end
	return { ok = true, version = version, flavor = M.flavor(doc, response.headers or {}, env) }
end

return M
