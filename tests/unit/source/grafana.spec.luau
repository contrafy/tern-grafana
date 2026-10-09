--!strict
-- Grafana's own API tells the plugin what the server can do: its version
-- (11 vs 12 differences), whether the image renderer exists (ladder step B is
-- only offered when it does), and which datasources a context can route
-- through. A Grafana-level failure (no results at all) must read differently
-- from one failed query.
local Fixtures = require("../../lib/fixtures")
local Grafana = require("../../../plugin/lib/source/grafana")
local Http = require("../../../plugin/lib/transport/http")
local S = require("./support")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local VERSIONS = { "11.6.16", "12.4.12" }

local function url(request: any): string
	return Http.url(S.grafana.endpoint, request)
end

describe("requests", function()
	it("targets the recorded endpoints", function()
		local base = S.grafana.endpoint.url
		expect(url(Grafana.healthRequest(S.grafana))).toBe(base .. S.row("grafana/12.4.12/health.json").url)
		expect(url(Grafana.userRequest(S.grafana))).toBe(base .. S.row("grafana/12.4.12/user.json").url)
		expect(url(Grafana.frontendSettingsRequest(S.grafana))).toBe(
			base .. S.row("grafana/12.4.12/frontend_settings.json").url
		)
		expect(url(Grafana.datasourcesRequest(S.grafana))).toBe(base .. S.row("grafana/12.4.12/datasources.json").url)
	end)

	it("encodes Prometheus targets as the recorded /api/ds/query body", function()
		local req = Grafana.promQueryRequest({
			{
				ref_id = "A",
				uid = "prom3",
				expr = "sum by (mode) (rate(node_cpu_seconds_total[1m]))",
				legend = "{{mode}}",
				instant = false,
				interval_ms = 15000,
				max_points = 200,
			},
			{ ref_id = "B", uid = "prom3", expr = "sum(up)", instant = false, interval_ms = 15000, max_points = 200 },
		}, 1000, 2000)
		local body = json.decode(req.body :: string)
		local recorded = json.decode(Fixtures.read("grafana/12.4.12/ds_query_prom_range.request.json"))
		for i, q in recorded.queries do
			for k, value in q do
				expect({ [k] = body.queries[i][k] }).toEqual({ [k] = value })
			end
		end
		expect({ body.from, body.to }).toEqual({ "1000", "2000" })
	end)

	it("escapes quotes and control characters in expressions", function()
		local req = Grafana.promQueryRequest({
			{ ref_id = "A", uid = "p", expr = 'up{job="a\\b"}\n', instant = true, interval_ms = 1, max_points = 1 },
		}, 0, 1)
		expect(json.decode(req.body :: string).queries[1].expr).toBe('up{job="a\\b"}\n')
	end)

	it("sends caller-built queries of any datasource through the host codec", function()
		local loki = json.decode(Fixtures.read("grafana/12.4.12/ds_query_loki_metric.request.json")).queries
		local req = Grafana.dsQueryRequest(S.grafana, loki, { from_ms = 1000, to_ms = 2000 }, S.env)
		local body = json.decode(req.body :: string)
		expect(body.queries).toEqual(loki)
		expect(req.path).toBe("/api/ds/query")
	end)
end)

for _, v in VERSIONS do
	local dir = "grafana/" .. v .. "/"
	describe("Grafana " .. v, function()
		it("reads version and database state from /api/health", function()
			local r: any = Grafana.parseHealth(S.grafana, S.response(dir .. "health.json"), S.env)
			expect(r.ok).toBe(true)
			expect(r.version).toBe(v)
			expect(r.database).toBe("ok")
		end)

		it("reads the signed-in identity", function()
			local r: any = Grafana.parseUser(S.grafana, S.response(dir .. "user.json"), S.env)
			expect(r.user.login).toBe("sa-1-tern-dev")
			expect(r.user.org_id).toBe(1)
			expect(r.user.is_grafana_admin).toBe(false)
		end)

		it("lists datasources by name with the default marked", function()
			local r: any = Grafana.parseDatasources(S.grafana, S.response(dir .. "datasources.json"), S.env)
			local uids: { string } = {}
			local default: string? = nil
			for _, ds in r.datasources do
				table.insert(uids, ds.uid)
				if ds.is_default then
					default = ds.uid
				end
			end
			expect(uids).toEqual({ "alertmanager", "loki", "prom2", "prom3", "tempo" })
			expect(default).toBe("prom3")
			expect(r.datasources[4]).toEqual({
				uid = "prom3",
				type = "prometheus",
				name = "Prometheus 3",
				is_default = true,
			})
		end)
	end)
end

describe("frontend settings", function()
	-- The dev stack runs the image renderer next to Grafana 12 only.
	it("knows when the image renderer is available", function()
		local g12: any =
			Grafana.parseFrontendSettings(S.grafana, S.response("grafana/12.4.12/frontend_settings.json"), S.env)
		expect(g12.settings).toEqual({ renderer_available = true, renderer_version = "5.0.0", version = "12.4.12" })
		local g11: any =
			Grafana.parseFrontendSettings(S.grafana, S.response("grafana/11.6.16/frontend_settings.json"), S.env)
		expect(g11.settings).toEqual({ renderer_available = false, version = "11.6.16" })
	end)
end)

describe("parseDsQuery", function()
	it("keeps per-ref results apart", function()
		local r: any = Grafana.parseDsQuery(S.response("grafana/12.4.12/ds_query_prom_range.json"), S.env)
		expect(r.ok).toBe(true)
		expect(#r.results.A.frames).toBe(8)
		expect(#r.results.B.frames).toBe(1)
	end)

	-- Grafana 11 cannot run TraceQL search here and fails the whole request.
	it("reports a failure without results as an HTTP error with Grafana's message", function()
		local r: any = Grafana.parseDsQuery(S.response("grafana/11.6.16/ds_query_tempo_search.json"), S.env)
		expect(r).toEqual({
			ok = false,
			error = { kind = "http", status = 500, message = "HTTP 500: An error occurred within the plugin" },
		})
	end)
end)

return nil
