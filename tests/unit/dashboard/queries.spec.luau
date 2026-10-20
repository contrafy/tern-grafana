--!strict
-- A panel's data request must be the one Grafana's frontend sends for it:
-- the same targets, datasources, interpolated expressions and interval, so
-- the native panel shows the series the Grafana panel shows. Hidden targets
-- are not sent (unless a server-side expression reads them); a failing
-- target is reported without blanking the others. Datasources Tern cannot
-- query as Grafana's frontend does are named with the reason.
local Fixtures = require("../../lib/fixtures")
local Interpolate = require("../../../plugin/lib/dashboard/interpolate")
local Model = require("../../../plugin/lib/dashboard/model")
local Queries = require("../../../plugin/lib/dashboard/queries")
local Route = require("../../../plugin/lib/config/route")
local S = require("./support")
local Tbl = require("../../../plugin/lib/tbl")
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
			local raw = Tbl.copy(assert(Model.findPanel(panels, 3)).json)
			raw.targets = Tbl.copy(raw.targets)
			raw.targets[2] = Tbl.copy(raw.targets[2])
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
			local raw = Tbl.copy(assert(Model.findPanel(d, 3)).json)
			raw.targets = { Tbl.copy(raw.targets[1]) }
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
			-- Tempo answers only the panels that draw its frames: traces and table.
			local tempoTable = assert(Model.findPanel(obs, 4)).json
			expect(Queries.resolve(tempoTable, {}, datasources, env) ~= nil).toBe(true)
			local asTimeseries =
				{ type = "timeseries", datasource = tempoTable.datasource, targets = tempoTable.targets }
			local refs, err = Queries.resolve(asTimeseries, {}, datasources, env)
			expect(refs).toBeNil()
			expect(err).toBe("tempo queries are not run natively")
		end)

		it("refuses an unresolved datasource variable and a -- Dashboard -- query among others", function()
			local _, unresolved = Queries.resolve(
				{ datasource = { uid = "${nope}" }, targets = { {} } },
				{},
				datasources,
				env
			)
			expect(unresolved).toBe("datasource ${nope} is not resolved")
			local refs = Queries.resolve(
				{ datasource = { uid = "-- Dashboard --" }, targets = { { panelId = 2 } } },
				{},
				datasources,
				env
			)
			expect(refs).toEqual({ { uid = "-- Dashboard --", type = "datasource" } })
			local _, mixed = Queries.resolve({
				datasource = { uid = "-- Mixed --" },
				targets = { { datasource = { uid = "-- Dashboard --" }, panelId = 2 } :: any, { expr = "up" } },
			}, {}, datasources, env)
			expect(mixed).toBe("a -- Dashboard -- query among other queries is not run natively")
		end)
	end)

	describe("queries for tern-sql (PostgreSQL) on Grafana " .. version, function()
		local sqlDatasources =
			Queries.frontendDatasources(S.response(S.grafana(version, "frontend_settings_sql.json")), env)
		local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_sql.json")), env))
		local vars = Variables.fromModel(d.templating, env)
		local scope = Variables.scope(vars, { from_ms = S.NOW_MS - HOUR, to_ms = S.NOW_MS })

		-- The fixture's request: the body Grafana's frontend sends for the panel.
		local function frontendBody(pid: number): any
			return json.decode(Fixtures.read(S.grafana(version, "ds_query_sql_" .. pid .. ".request.json")))
		end

		local function sqlCtx(maxPoints: number): Queries.Context
			local c = ctx(scope, HOUR)
			c.datasources = sqlDatasources
			c.max_points = maxPoints
			return c
		end

		it("reads which datasources have a backend from the frontend settings", function()
			local byUid = {}
			for _, ds in sqlDatasources do
				byUid[ds.uid] = ds
			end
			expect(byUid.postgres.type).toBe("grafana-postgresql-datasource")
			expect(byUid.postgres.backend).toBe(true)
			expect(byUid.alertmanager.backend).toBe(false)
		end)

		it("sends each SQL target as SqlDatasource.applyTemplateVariables does, variables SQL-quoted", function()
			for _, pid in { 1, 2, 3, 4, 7 } do
				local body = frontendBody(pid)
				local panel = assert(Model.findPanel(d, pid)).json
				local pq = assert(Queries.build(panel, sqlCtx(body.queries[1].maxDataPoints), env))
				expect(pq.queries).toEqual(Tbl.copy(body.queries))
			end
		end)

		it("gets the long rows of time series format back wide, as the backend converts them", function()
			local panel = assert(Model.findPanel(d, 1)).json
			local pq = assert(Queries.build(panel, sqlCtx(960), env))
			local data = assert(Queries.parse(S.response(S.grafana(version, "ds_query_sql_1.json")), pq, env))
			expect(#data.frames).toBe(1)
			local names = {}
			for _, f in data.frames[1].fields do
				table.insert(names, f.name .. ":" .. f.type)
			end
			expect(names).toEqual({ "Time:time", "checkout:number", "frontend:number" })
		end)

		it("sends a hidden query a server-side expression reads, and shows only the expression", function()
			local body = frontendBody(5)
			local panel = assert(Model.findPanel(d, 5)).json
			local pq = assert(Queries.build(panel, sqlCtx(body.queries[1].maxDataPoints), env))
			expect(pq.queries).toEqual(Tbl.copy(body.queries))
			expect(pq.ref_ids).toEqual({ "B" })
			local data = assert(Queries.parse(S.response(S.grafana(version, "ds_query_sql_5.json")), pq, env))
			expect(#data.frames).toBe(1)
			expect(data.frames[1].refId).toBe("B")
			expect(data.frames[1].fields[1].values[1]).toBe(22)
		end)

		it("sends nothing for a -- Dashboard -- panel and names its source", function()
			local panel = assert(Model.findPanel(d, 6)).json
			local pq, err = Queries.build(panel, sqlCtx(960), env)
			expect(pq).toBeNil()
			expect(err).toBeNil()
			expect((Queries.dashboardQuery(panel, env))).toEqual({ panel_id = 4, with_transforms = true })
		end)
	end)
end

-- Datasource patterns seen on real stacks, reproduced with synthetic names:
-- what each plugin's frontend sends (or why Tern cannot send it).
describe("queries for other datasource plugins", function()
	local env = S.env()
	env.array = json.array
	local function ds(name: string, uid: string, typ: string, backend: boolean?): any
		return { uid = uid, type = typ, name = name, meta = { backend = backend } }
	end
	local catalog = Queries.frontendDatasources(
		S.body(
			200,
			json.encode({
				defaultDatasource = "Metrics",
				datasources = {
					Metrics = ds("Metrics", "prom", "prometheus", true),
					Search = ds("Search", "es", "elasticsearch", true),
					Sheets = ds("Sheets", "inf", "yesoreyeram-infinity-datasource", true),
					Incidents = ds("Incidents", "inc", "grafana-incident-datasource", true),
					Zabbix = ds("Zabbix", "zbx", "alexanderzobnin-zabbix-datasource", true),
					Graphite = ds("Graphite", "gr", "graphite", true),
					JSON = ds("JSON", "js", "marcusolsson-json-datasource", false),
					Cardinality = ds("Cardinality", "card", "grafanacloud-cardinality-datasource", false),
					Acme = ds("Acme", "acme", "acme-backend-datasource", true),
					MySQL = ds("MySQL", "my", "mysql", nil),
				},
			})
		),
		env
	)
	local multi: Interpolate.Var = { values = { "a", "b" }, multi = true }
	local scope: Interpolate.Scope = {
		api = multi,
		team = { values = { "o'neil" } },
		hosts = multi,
		one = { values = { "x" }, multi = true, single = true },
	}
	local function c(): Queries.Context
		return { scope = scope, from_ms = S.NOW_MS - HOUR, to_ms = S.NOW_MS, max_points = 720, datasources = catalog }
	end
	local function panelOf(uid: string, target: { [string]: any }, typ: string?): { [string]: any }
		local tg = Tbl.copy(target)
		tg.refId = tg.refId or "A"
		return { type = typ or "timeseries", datasource = { uid = uid }, targets = { tg } }
	end
	local function reason(uid: string, target: { [string]: any }): string?
		local _, err = Queries.resolve(panelOf(uid, target), scope, catalog, env)
		return err
	end

	it("says why frontend-only plugins and browser-side query paths stay off the native rung", function()
		expect(reason("js", { urlPath = "" })).toBe(
			"marcusolsson-json-datasource queries run in the browser (a frontend datasource plugin)"
		)
		expect(reason("card", { cardinalityType = "labels" })).toBe(
			"grafanacloud-cardinality-datasource queries run in the browser (a frontend datasource plugin)"
		)
		expect(reason("zbx", { queryType = "0" })).toBe("Zabbix queries are post-processed in the browser")
		expect(reason("gr", { target = "a.b" })).toBe(
			"Graphite queries are sent by the browser through the datasource proxy"
		)
		-- A typed reference to a datasource Grafana does not list.
		local _, unknown = Queries.resolve(panelOf("x", { rawSql = "SELECT 1" }), scope, catalog, env)
		expect(unknown).toBe('unknown datasource "x"')
		local _, typed = Queries.resolve({
			type = "stat",
			datasource = { uid = "gone", type = "grafana-postgresql-datasource" },
			targets = { { refId = "A", rawSql = "SELECT 1" } },
		}, scope, catalog, env)
		expect(typed).toBe("grafana-postgresql-datasource queries are not run natively")
	end)

	it("runs Infinity queries its backend parses, and names the parser of the others", function()
		expect(reason("inf", { type = "json", parser = "backend", source = "url", url = "https://x/$team" })).toBeNil()
		expect(reason("inf", { type = "csv", parser = "jq-backend" })).toBeNil()
		expect(reason("inf", { type = "json", parser = "simple" })).toBe(
			"Infinity json queries with the simple parser run in the browser"
		)
		expect(reason("inf", { type = "json" })).toBe(
			"Infinity json queries with the default parser run in the browser"
		)
		expect(reason("inf", { type = "uql", uql = "parse-json" })).toBe(
			"Infinity uql queries with the default parser run in the browser"
		)
		expect(reason("inf", { type = "global", global_query_id = "q1" })).toBe(
			"Infinity global queries are not run natively"
		)
	end)

	it("runs Grafana Incident queries unless the query string uses a dashboard variable", function()
		expect(reason("inc", { queryType = "incidents", queryString = "status:active" })).toBeNil()
		expect(reason("inc", { queryType = "incidents", queryString = "or($hosts) or(status:active)" })).toBe(
			"Grafana Incident formats query variables in the browser"
		)
		-- Not a variable of this dashboard: Grafana leaves it as written too.
		expect(reason("inc", { queryType = "incidents", queryString = "label:'$x'" })).toBeNil()
	end)

	it("interpolates every string of a generic backend plugin's target with the default format", function()
		local pq = assert(Queries.build(
			panelOf("inf", {
				type = "json",
				parser = "backend",
				source = "url",
				url = "https://example.test/api?team=$team&hosts=${hosts}",
				url_options = { method = "GET", params = json.decode("[]") },
				columns = json.decode('[{"selector":"name","text":"$team"}]'),
			}),
			c(),
			env
		))
		local q = pq.queries[1]
		expect(q.url).toBe("https://example.test/api?team=o'neil&hosts={a,b}")
		expect(q.columns[1].text).toBe("o'neil")
		expect(q.datasource).toEqual({ uid = "inf", type = "yesoreyeram-infinity-datasource" })
		expect(q.intervalMs).toBe(5000)
		expect(q.maxDataPoints).toBe(720)
		-- Decoded lists stay lists: an empty one still goes out as [].
		expect(string.find(env.encode(q), '"params":[]', 1, true) ~= nil).toBe(true)
		local acme = assert(Queries.build(panelOf("acme", { query = "rate[$__interval] of $hosts" }), c(), env))
		expect(acme.queries[1].query).toBe("rate[5s] of {a,b}")
	end)

	it("formats an Elasticsearch Lucene query with the lucene format, then every string", function()
		local pq = assert(Queries.build(
			panelOf("es", {
				query = "api\\-name:${api:lucene} AND team:$team",
				metrics = json.decode('[{"id":"1","type":"count"}]'),
				bucketAggs = json.decode(
					'[{"id":"2","type":"filters","settings":{"filters":[{"query":"","label":""},{"query":"host:$hosts","label":"h"}]}},'
						.. '{"id":"3","type":"date_histogram","field":"@timestamp","settings":{"interval":"$__interval"}}]'
				),
				timeField = "@timestamp",
			}),
			c(),
			env
		))
		local q = pq.queries[1]
		expect(q.query).toBe('api\\-name:("a" OR "b") AND team:o\'neil')
		expect(q.bucketAggs[1].settings.filters[1].query).toBe("*")
		expect(q.bucketAggs[1].settings.filters[2].query).toBe('host:("a" OR "b")')
		expect(q.bucketAggs[2].settings.interval).toBe("5s")
	end)

	it("quotes SQL variables the way each SQL datasource does", function()
		local sql = "SELECT * FROM t WHERE team = '$team' AND host IN ($hosts) AND one = $one"
		local pq = assert(Queries.build(panelOf("my", { rawSql = sql, format = "table" }), c(), env))
		-- MySQL (SqlDatasource): a single value of a multi-value variable is quoted.
		expect(pq.queries[1]).toEqual({
			refId = "A",
			datasource = { uid = "my", type = "mysql" },
			rawSql = "SELECT * FROM t WHERE team = 'o''neil' AND host IN ('a','b') AND one = 'x'",
			format = "table",
			intervalMs = 5000,
			maxDataPoints = 720,
		})
		expect(Interpolate.replace("one = $one", scope, { format = Interpolate.postgres })).toBe("one = x")
	end)
end)

return nil
