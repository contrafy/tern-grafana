--!strict
-- The ops endpoints must be asked for exactly where the servers were
-- recorded answering, directly and through Grafana's datasource proxy, and a
-- server that simply lacks an endpoint (Loki-style `404 page not found`,
-- VictoriaMetrics' `unsupported path`) must read as "unsupported", which the
-- block shows as a note, never as a broken connection. A JSON 404 is someone
-- explaining a real problem (an unknown datasource) and stays an error.
local Fixtures = require("../../lib/fixtures")
local Http = require("../../../plugin/lib/transport/http")
local Ops = require("../../../plugin/lib/source/ops")
local S = require("../source/support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local PROM = { "2.53.5", "3.15.0" }
local GRAFANA = { "11.6.16", "12.4.12" }

local STATUS = { "buildinfo", "flags", "runtimeinfo", "config", "tsdb" }

local function url(route: any, request: any): string
	return Http.url(route.endpoint, request)
end

local function recorded(route: any, path: string): string
	return route.endpoint.url .. S.row(path).url
end

local function textResponse(path: string): any
	return {
		status = S.row(path).status,
		headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
		body = Fixtures.read(path),
		timed_out = false,
	}
end

describe("ops requests", function()
	it("asks a direct Prometheus at the recorded targets and status URLs", function()
		expect(url(S.direct, Ops.targetsRequest(S.direct))).toBe(recorded(S.direct, "prometheus/3.15.0/targets.json"))
		expect(url(S.direct, Ops.tsdbRequest(S.direct))).toBe(recorded(S.direct, "prometheus/3.15.0/tsdb.json"))
		expect(url(S.direct, Ops.tsdbRequest(S.direct, 5))).toBe(
			recorded(S.direct, "prometheus/3.15.0/tsdb_limit.json")
		)
		for _, name in { "buildinfo", "flags", "runtimeinfo", "config" } do
			expect(url(S.direct, Ops.statusRequest(S.direct, name :: any))).toBe(
				recorded(S.direct, "prometheus/3.15.0/" .. name .. ".json")
			)
		end
	end)

	it("goes through the datasource proxy on a Grafana route", function()
		for _, v in GRAFANA do
			expect(url(S.datasource, Ops.targetsRequest(S.datasource))).toBe(
				recorded(S.datasource, "grafana/" .. v .. "/ds_proxy_prom_targets.json")
			)
			for _, name in STATUS do
				local req = if name == "tsdb"
					then Ops.tsdbRequest(S.datasource)
					else Ops.statusRequest(S.datasource, name :: any)
				expect(url(S.datasource, req)).toBe(
					recorded(S.datasource, "grafana/" .. v .. "/ds_proxy_prom_" .. name .. ".json")
				)
			end
		end
	end)

	it("refuses a route with neither a direct endpoint nor a datasource", function()
		expect(function()
			Ops.targetsRequest(S.grafana)
		end).toThrow("no prometheus endpoint")
	end)
end)

describe("ops parse", function()
	it("returns the data of every recorded answer, direct and proxied", function()
		local paths: { string } = {}
		for _, v in PROM do
			for _, name in
				{ "targets", "targets_dropped", "tsdb", "tsdb_limit", "buildinfo", "flags", "runtimeinfo", "config" }
			do
				table.insert(paths, "prometheus/" .. v .. "/" .. name .. ".json")
			end
		end
		for _, v in GRAFANA do
			table.insert(paths, "grafana/" .. v .. "/ds_proxy_prom_targets.json")
			for _, name in STATUS do
				table.insert(paths, "grafana/" .. v .. "/ds_proxy_prom_" .. name .. ".json")
			end
		end
		for _, path in paths do
			local r: any = Ops.parse(S.response(path), S.env, "/api/v1/x")
			expect({ path = path, ok = r.ok, data = type(r.data) }).toEqual({ path = path, ok = true, data = "table" })
		end
	end)

	it("reports a plain-text 404 as an unsupported endpoint", function()
		for _, path in
			{ "loki/3.7.8/targets_404.txt", "loki/3.7.8/status_tsdb_404.txt", "prometheus/2.53.5/parse_query.txt" }
		do
			local r: any = Ops.parse(textResponse(path), S.env, "/api/v1/targets")
			expect(r.ok).toBe(false)
			expect(r.error.kind).toBe("unsupported")
			expect(r.error.status).toBe(404)
			expect(r.error.message).toBe("this server has no /api/v1/targets endpoint (HTTP 404)")
		end
	end)

	it("keeps a JSON 404 (Grafana explaining what is missing) as an HTTP error", function()
		local r: any = Ops.parse(S.response("grafana/12.4.12/dashboard_missing.json"), S.env, "/api/v1/targets")
		expect(r.ok).toBe(false)
		expect(r.error.kind).toBe("http")
		expect(r.error.status).toBe(404)
	end)

	it("reports VictoriaMetrics' unsupported path answer as unsupported", function()
		-- Not in the dev stack: VictoriaMetrics' documented answer for a path it does not serve.
		local r: any = Ops.parse({
			status = 400,
			headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
			body = 'unsupported path requested: "/api/v1/status/config"\n',
			timed_out = false,
		}, S.env, "/api/v1/status/config")
		expect(r.error.kind).toBe("unsupported")
	end)

	it("reports a success status with a non-JSON body (an HTML UI) as unsupported", function()
		local r: any = Ops.parse({
			status = 200,
			headers = { ["Content-Type"] = "text/html" },
			body = Fixtures.read("loki/3.7.8/targets_404.txt"),
			timed_out = false,
		}, S.env, "/api/v1/targets")
		expect(r.error.kind).toBe("unsupported")
		expect(r.error.message).toBe("this server has no /api/v1/targets endpoint (the answer is not JSON)")
	end)

	it("keeps the server's words for a Prometheus API error", function()
		local r: any = Ops.parse(S.response("prometheus/3.15.0/query_error_parse.json"), S.env, "/api/v1/status/tsdb")
		expect(r.error.kind).toBe("query")
		expect(r.error.status).toBe(400)
	end)

	it("passes transport failures through", function()
		local r: any = Ops.parse(
			{ status = 0, headers = {}, body = "", error = "connection refused", timed_out = false },
			S.env,
			"/api/v1/targets"
		)
		expect(r.error.kind).toBe("network")
	end)
end)

return nil
