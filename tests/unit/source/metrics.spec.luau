--!strict
-- The metrics source must send exactly what the servers were recorded
-- answering (so the fixtures are the contract), and report failures with the
-- server's own words: a PromQL parse error is something the user fixes in
-- the query, not a broken connection.
local Fixtures = require("../../lib/fixtures")
local Frame = require("../../../plugin/lib/frame/types")
local Http = require("../../../plugin/lib/transport/http")
local Metrics = require("../../../plugin/lib/source/metrics")
local S = require("./support")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local PROM = { "2.53.5", "3.15.0" }
local GRAFANA = { "11.6.16", "12.4.12" }

local START_MS, END_MS = S.START * 1000, S.END * 1000

local function url(route: any, request: any): string
	return Http.url(route.endpoint, request)
end

local function recorded(route: any, path: string): string
	return route.endpoint.url .. S.row(path).url
end

local function queryString(path: string): string
	return string.match(S.row(path).url, "%?(.*)$") :: string
end

describe("direct Prometheus requests", function()
	it("POSTs a range query with the parameters of the recorded GET", function()
		local req = Metrics.rangeRequest(S.direct, {
			expr = 'rate(node_cpu_seconds_total{mode=~"user|system|idle"}[1m])',
			from_ms = START_MS,
			to_ms = END_MS,
			step_ms = 15000,
		})
		expect(req.method).toBe("POST")
		expect(url(S.direct, req)).toBe("http://127.0.0.1:9090/api/v1/query_range")
		expect((req.headers :: any)["Content-Type"]).toBe("application/x-www-form-urlencoded")
		expect(req.body).toBe(queryString("prometheus/3.15.0/query_range_multi.json"))
	end)

	it("POSTs an instant query exactly like the recorded form body", function()
		local req = Metrics.instantRequest(S.direct, { expr = "sum by (job) (up)", time_ms = END_MS })
		expect(url(S.direct, req)).toBe("http://127.0.0.1:9090/api/v1/query")
		expect(req.body).toBe(Fixtures.read("prometheus/3.15.0/query_post.request.txt"))
	end)

	it("sends sub-second times and steps in seconds with ms precision", function()
		local req = Metrics.rangeRequest(S.direct, { expr = "up", from_ms = 1500, to_ms = 2000, step_ms = 250 })
		expect(req.body).toBe("query=up&start=1.500&end=2&step=0.250")
	end)

	it("asks for labels, label values and metadata at the recorded URLs", function()
		local opts = { from_ms = START_MS, to_ms = END_MS }
		expect(url(S.direct, Metrics.labelsRequest(S.direct, opts))).toBe(
			recorded(S.direct, "prometheus/3.15.0/labels.json")
		)
		expect(url(S.direct, Metrics.labelValuesRequest(S.direct, "job", opts))).toBe(
			recorded(S.direct, "prometheus/3.15.0/label_values_job.json")
		)
		expect(url(S.direct, Metrics.metadataRequest(S.direct, "prometheus_http_requests_total"))).toBe(
			"http://127.0.0.1:9090/api/v1/metadata?metric=prometheus_http_requests_total&limit_per_metric=1"
		)
		expect(url(S.direct, Metrics.healthRequest(S.direct))).toBe(
			recorded(S.direct, "prometheus/3.15.0/buildinfo.json")
		)
	end)

	it("escapes a label name in the path and repeats match[]", function()
		local req = Metrics.labelValuesRequest(S.direct, "a/b", { match = { 'up{job="x"}', "down" } })
		expect(url(S.direct, req)).toBe(
			"http://127.0.0.1:9090/api/v1/label/a%2Fb/values?match%5B%5D=up%7Bjob%3D%22x%22%7D&match%5B%5D=down"
		)
	end)
end)

for _, v in PROM do
	local dir = "prometheus/" .. v .. "/"
	describe("direct Prometheus " .. v .. " results", function()
		it("parses a range result into frames", function()
			local r = Metrics.parse(S.direct, S.response(dir .. "query_range_multi.json"), S.env, "range")
			expect(r.ok).toBe(true)
			expect(#(r :: any).frames).toBe(30)
		end)

		it("parses an empty result as ok with no frames", function()
			local r: any = Metrics.parse(S.direct, S.response(dir .. "query_range_empty.json"), S.env, "range")
			expect(r.ok).toBe(true)
			expect(#r.frames).toBe(0)
		end)

		it("parses instant vector, scalar and string results", function()
			local vector: any = Metrics.parse(S.direct, S.response(dir .. "query_vector.json"), S.env, "instant")
			expect(#vector.frames).toBe(6)
			local scalar: any = Metrics.parse(S.direct, S.response(dir .. "query_scalar.json"), S.env, "instant")
			expect(Frame.numberFields(scalar.frames[1])[1].values).toEqual({ 5 })
			local str: any = Metrics.parse(S.direct, S.response(dir .. "query_string.json"), S.env, "instant")
			expect(str.frames[1].fields[2].values).toEqual({ "tern" })
		end)

		it("reports PromQL errors as query errors with the server's message", function()
			local parse: any = Metrics.parse(S.direct, S.response(dir .. "query_error_parse.json"), S.env, "instant")
			expect(parse).toEqual({
				ok = false,
				error = {
					kind = "query",
					status = 400,
					message = 'invalid parameter "query": 1:17: parse error: unclosed left parenthesis',
				},
			})
			local exec: any = Metrics.parse(S.direct, S.response(dir .. "query_error_exec.json"), S.env, "instant")
			expect(exec.error.kind).toBe("query")
			expect(exec.error.status).toBe(422)
			expect(string.find(exec.error.message, "many-to-many matching not allowed", 1, true) ~= nil).toBe(true)
			local resolution: any =
				Metrics.parse(S.direct, S.response(dir .. "query_range_error_resolution.json"), S.env, "range")
			expect(string.find(resolution.error.message, "exceeded maximum resolution", 1, true) ~= nil).toBe(true)
		end)

		it("passes PromQL annotations through as warnings", function()
			local r: any = Metrics.parse(S.direct, S.response(dir .. "query_info.json"), S.env, "instant")
			expect(#r.warnings).toBe(1)
		end)

		it("lists label names and values, sorted", function()
			local labels: any = Metrics.parseList(S.direct, S.response(dir .. "labels.json"), S.env)
			expect(labels.ok).toBe(true)
			expect(labels.values).toContain("__name__")
			expect(labels.values).toContain("job")
			local jobs: any = Metrics.parseList(S.direct, S.response(dir .. "label_values_job.json"), S.env)
			expect(jobs.values).toEqual({ "alertmanager", "down", "loki", "node", "prometheus", "tempo" })
		end)

		it("reads metadata as one type/help/unit per metric", function()
			local r: any = Metrics.parseMetadata(S.direct, S.response(dir .. "metadata_metric.json"), S.env)
			expect(r.metadata).toEqual({
				prometheus_http_requests_total = { type = "counter", help = "Counter of HTTP requests.", unit = "" },
			})
			local all: any = Metrics.parseMetadata(S.direct, S.response(dir .. "metadata_limit_per_metric.json"), S.env)
			local n = 0
			for _ in all.metadata do
				n += 1
			end
			expect(n).toBe(5)
		end)

		it("identifies the server and version from buildinfo", function()
			local r: any = Metrics.parseHealth(S.direct, S.response(dir .. "buildinfo.json"), S.env)
			expect(r).toEqual({ ok = true, version = v, flavor = "prometheus" })
		end)
	end)
end

describe("through a Grafana datasource", function()
	it("sends a range query as Grafana's Prometheus editor does", function()
		local req = Metrics.rangeRequest(S.datasource, {
			expr = "sum(up)",
			from_ms = START_MS,
			to_ms = END_MS,
			step_ms = 15000,
			max_points = 200,
			ref_id = "B",
		})
		expect(url(S.datasource, req)).toBe("http://127.0.0.1:3000/api/ds/query")
		expect(req.method).toBe("POST")
		local body = json.decode(req.body :: string)
		local recordedQuery = json.decode(Fixtures.read("grafana/12.4.12/ds_query_prom_range.request.json")).queries[2]
		-- Every field Grafana's own editor sent, plus the explicit defaults.
		for k, value in recordedQuery do
			expect({ [k] = body.queries[1][k] }).toEqual({ [k] = value })
		end
		expect(body.queries[1].format).toBe("time_series")
		expect(body.from).toBe(tostring(START_MS))
		expect(body.to).toBe(tostring(END_MS))
	end)

	it("sends an instant query with instant=true and the time as `to`", function()
		local req = Metrics.instantRequest(S.datasource, { expr = "up", time_ms = END_MS, format = "table" })
		local body = json.decode(req.body :: string)
		local recordedQuery = json.decode(Fixtures.read("grafana/12.4.12/ds_query_prom_table.request.json")).queries[1]
		for k, value in recordedQuery do
			if k ~= "maxDataPoints" then
				expect({ [k] = body.queries[1][k] }).toEqual({ [k] = value })
			end
		end
		expect(body.to).toBe(tostring(END_MS))
	end)

	it("asks for labels, values and metadata through the datasource proxy", function()
		local opts = { from_ms = START_MS, to_ms = END_MS }
		local ds = S.datasource
		expect(url(ds, Metrics.labelsRequest(ds, opts))).toBe(recorded(ds, "grafana/12.4.12/ds_proxy_prom_labels.json"))
		expect(url(ds, Metrics.labelValuesRequest(ds, "job", opts))).toBe(
			recorded(ds, "grafana/12.4.12/ds_proxy_prom_label_values.json")
		)
		expect(url(ds, Metrics.healthRequest(ds))).toBe(
			"http://127.0.0.1:3000/api/datasources/proxy/uid/prom3/api/v1/status/buildinfo"
		)
	end)

	for _, v in GRAFANA do
		local dir = "grafana/" .. v .. "/"
		describe("Grafana " .. v, function()
			it("parses the first refId's frames", function()
				local r: any =
					Metrics.parse(S.datasource, S.response(dir .. "ds_query_prom_range.json"), S.env, "range")
				expect(r.ok).toBe(true)
				expect(#r.frames).toBe(8)
				local instant: any =
					Metrics.parse(S.datasource, S.response(dir .. "ds_query_prom_instant.json"), S.env, "instant")
				expect(#instant.frames).toBe(6)
			end)

			it("reports the per-query error, not the HTTP 400", function()
				local r: any =
					Metrics.parse(S.datasource, S.response(dir .. "ds_query_prom_error.json"), S.env, "range")
				expect(r.error.kind).toBe("query")
				expect(r.error.message).toBe(
					'bad_data: invalid parameter "query": 1:17: parse error: unclosed left parenthesis'
				)
			end)

			it("lists labels, values and metadata relayed by the proxy", function()
				local labels: any =
					Metrics.parseList(S.datasource, S.response(dir .. "ds_proxy_prom_labels.json"), S.env)
				expect(labels.values).toContain("__name__")
				local jobs: any =
					Metrics.parseList(S.datasource, S.response(dir .. "ds_proxy_prom_label_values.json"), S.env)
				expect(jobs.values).toEqual({ "alertmanager", "down", "loki", "node", "prometheus", "tempo" })
				local meta: any =
					Metrics.parseMetadata(S.datasource, S.response(dir .. "ds_proxy_prom_metadata.json"), S.env)
				expect(meta.ok).toBe(true)
				expect(next(meta.metadata) ~= nil).toBe(true)
			end)

			it("reports a Prometheus error relayed by the proxy as a query error", function()
				local r: any =
					Metrics.parseList(S.datasource, S.response(dir .. "ds_proxy_prom_query_error.json"), S.env)
				expect(r.error.kind).toBe("query")
				expect(r.error.status).toBe(400)
			end)
		end)
	end
end)

describe("transport failures", function()
	it("are classified, not parsed", function()
		local r: any = Metrics.parse(S.direct, {
			status = 0,
			headers = {},
			body = "",
			timed_out = false,
			error = "io: Connection refused (os error 61)",
		}, S.env, "range")
		expect(r.error.kind).toBe("network")
	end)
end)

return nil
