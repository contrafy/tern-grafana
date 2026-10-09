--!strict
-- A panel's data request must be the one Grafana's frontend sends for it:
-- the same targets, datasources, interpolated expressions and interval, so
-- the native panel shows the series the Grafana panel shows. Hidden targets
-- are not sent; a failing target is reported without blanking the others.
local Model = require("../../../plugin/lib/dashboard/model")
local Queries = require("../../../plugin/lib/dashboard/queries")
local Route = require("../../../plugin/lib/config/route")
local S = require("./support")
local Variables = require("../../../plugin/lib/dashboard/variables")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local HOUR = 3600000

for _, version in S.VERSIONS do
	local env = S.env()
	local datasources = Queries.frontendDatasources(S.response(S.grafana(version, "frontend_settings.json")), env)
	local panels = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_panels.json")), env))

	local function ctx(scope: any, span: number?): Queries.Context
		return {
			scope = scope or {},
			from_ms = S.NOW_MS - (span or HOUR),
			to_ms = S.NOW_MS,
			max_points = 600,
			datasources = datasources,
			dashboard_uid = "tern-panels",
			dashboard_title = "Tern Panels",
			org_id = 1,
		}
	end

	describe("queries for tern-panels on Grafana " .. version, function()
		it("reads the datasource catalog from the frontend settings, default included", function()
			local byUid = {}
			for _, ds in datasources do
				byUid[ds.uid] = ds
			end
			expect(byUid.prom3.type).toBe("prometheus")
			expect(byUid.prom3.is_default).toBe(true)
			expect(byUid.loki.type).toBe("loki")
			expect(byUid.prom2.is_default).toBe(false)
		end)

		it("sends a range target with Grafana's interval and leaves $__rate_interval to Grafana", function()
			local pq = assert(Queries.build(assert(Model.findPanel(panels, 2)).json, ctx(), env))
			expect(pq.ref_ids).toEqual({ "A" })
			local q = pq.queries[1]
			expect(q.datasource).toEqual({ uid = "prom3", type = "prometheus" })
			expect(q.expr).toBe("sum by (mode) (rate(node_cpu_seconds_total[$__rate_interval]))")
			expect(q.legendFormat).toBe("{{mode}}")
			expect(q.range).toBe(true)
			-- 1 h over 600 points = 6 s, rounded by Grafana's table to 5 s.
			expect(q.intervalMs).toBe(5000)
			expect(q.maxDataPoints).toBe(600)
		end)

		it("puts every target of a panel in one body", function()
			local pq = assert(Queries.build(assert(Model.findPanel(panels, 3)).json, ctx(), env))
			expect(pq.ref_ids).toEqual({ "A", "B", "C" })
			local route = assert(Route.route(S.CONFIG, "lab", "dashboards"))
			local req = Queries.request(route, pq, ctx(), env)
			expect(req.method).toBe("POST")
			expect(req.path).toBe("/api/ds/query")
			local body = json.decode(req.body :: string)
			expect(#body.queries).toBe(3)
			expect(body.to).toBe(string.format("%d", S.NOW_MS))
		end)

		it("gives Loki log targets a line limit and runs text panels without a query", function()
			local logs = assert(Queries.build(assert(Model.findPanel(panels, 12)).json, ctx(), env))
			expect(logs.queries[1].datasource).toEqual({ uid = "loki", type = "loki" })
			expect(logs.queries[1].maxLines).toBe(Queries.LOKI_MAX_LINES)
			local text, err = Queries.build(assert(Model.findPanel(panels, 10)).json, ctx(), env)
			expect(text).toBeNil()
			expect(err).toBeNil()
		end)

		it("skips hidden targets", function()
			local raw = table.clone(assert(Model.findPanel(panels, 3)).json)
			raw.targets = table.clone(raw.targets)
			raw.targets[2] = table.clone(raw.targets[2])
			raw.targets[2].hide = true
			local pq = assert(Queries.build(raw, ctx(), env))
			expect(pq.ref_ids).toEqual({ "A", "C" })
		end)

		it("splits a mixed result into frames per target and per-target errors", function()
			local pq = assert(Queries.build(assert(Model.findPanel(panels, 3)).json, ctx(), env))
			pq.ref_ids = { "A", "B" }
			local data = assert(Queries.parse(S.response(S.grafana(version, "ds_query_prom_range.json")), pq, env))
			expect(#data.frames > 1).toBe(true)
			expect(#data.errors).toBe(0)
			local failed =
				assert(Queries.parse(S.response(S.grafana(version, "ds_query_prom_error.json"), 400), pq, env))
			expect(#failed.frames).toBe(0)
			expect(#failed.errors).toBe(1)
			expect(string.sub(failed.errors[1], 1, 3)).toBe("A: ")
		end)
	end)

	describe("queries for tern-variables on Grafana " .. version, function()
		local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_variables.json")), env))
		local vars = Variables.fromModel(d.templating, env)
		for _, v in vars do
			if v.name == "ds" then
				Variables.setOptions(v, (Variables.datasourceOptions(v, datasources, Variables.scope(vars))))
			elseif v.name == "job" or v.name == "instance" then
				Variables.setOptions(
					v,
					{ { text = "node", value = "node" }, { text = "prometheus", value = "prometheus" } }
				)
			elseif v.status == "pending" then
				Variables.setOptions(v, { { text = "Mem", value = "Mem" } })
			end
		end
		local scope = Variables.scope(vars, { from_ms = S.NOW_MS - 1800000, to_ms = S.NOW_MS })

		it("interpolates multi-value, include-all and interval variables the Prometheus way", function()
			local pq = assert(Queries.build(assert(Model.findPanel(d, 1)).json, ctx(scope, 1800000), env))
			expect(pq.queries[1].expr).toBe(
				'sum by (mode) (rate(node_cpu_seconds_total{mode=~"(user|system)", instance=~".*"}[1m]))'
			)
		end)

		it("uses an interval variable as the target's min interval", function()
			local pq = assert(Queries.build(assert(Model.findPanel(d, 2)).json, ctx(scope, 1800000), env))
			expect(pq.queries[1].interval).toBe("1m")
			expect(pq.queries[1].intervalMs).toBe(60000)
			expect(pq.queries[1].expr).toBe(
				'sum by (handler) (rate(prometheus_http_requests_total{handler=~"/api/v1/.*"}[$__rate_interval]))'
			)
		end)

		it("resolves the panel's ${ds} datasource and a constant", function()
			local raw = table.clone(assert(Model.findPanel(d, 3)).json)
			raw.targets = { table.clone(raw.targets[1]) }
			raw.targets[1].datasource = nil
			local pq = assert(Queries.build(raw, ctx(scope, 1800000), env))
			expect(pq.queries[1].datasource).toEqual({ uid = "prom3", type = "prometheus" })
			expect(pq.queries[1].expr).toBe('sum(up{job=~".*", env=~"dev|"})')
		end)
	end)

	describe("queries that are not run natively on Grafana " .. version, function()
		local obs =
			assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_observability.json")), env))

		it("names the datasource type that keeps a panel off the native rung", function()
			local refs, err = Queries.resolve(assert(Model.findPanel(obs, 4)).json, {}, datasources, env)
			expect(refs).toBeNil()
			expect(err).toBe("tempo queries are not run natively")
		end)

		it("refuses an unresolved datasource variable and a -- Dashboard -- panel", function()
			local _, unresolved = Queries.resolve(
				{ datasource = { uid = "${nope}" }, targets = { {} } },
				{},
				datasources,
				env
			)
			expect(unresolved).toBe("datasource ${nope} is not resolved")
			local _, shared = Queries.resolve(
				{ datasource = { uid = "-- Dashboard --" }, targets = { {} } },
				{},
				datasources,
				env
			)
			expect(shared).toBe("reuses another panel's query (-- Dashboard --)")
		end)
	end)
end

return nil
