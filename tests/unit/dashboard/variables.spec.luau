--!strict
-- Variables decide what every panel queries. The tern-variables dashboard
-- holds one of each kind Grafana users rely on: a datasource variable that
-- the query variables use (`${ds}`), chained label_values (instance depends
-- on job), metrics() with a capture-group regex, query_result() with a
-- regex, a multi-value custom variable with All, a hidden constant, an auto
-- interval and a textbox. Each must resolve to the options and selection
-- Grafana would show, from the recorded Grafana and Prometheus answers.
local Interpolate = require("../../../plugin/lib/dashboard/interpolate")
local Model = require("../../../plugin/lib/dashboard/model")
local Queries = require("../../../plugin/lib/dashboard/queries")
local Route = require("../../../plugin/lib/config/route")
local S = require("./support")
local Variables = require("../../../plugin/lib/dashboard/variables")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local RANGE = { from_ms = S.NOW_MS - 1800000, to_ms = S.NOW_MS }

local function names(vars: { Variables.Variable }): { string }
	local out = {}
	for _, v in vars do
		table.insert(out, v.name)
	end
	return out
end

local function values(options: { Variables.Option }): { string }
	local out = {}
	for _, o in options do
		table.insert(out, o.value)
	end
	return out
end

local function dsRoute(): Route.Route
	local base = assert(Route.route(S.CONFIG, "lab", "dashboards"))
	return {
		context = base.context,
		signal = "metrics",
		via = "datasource",
		endpoint_name = "grafana",
		endpoint = base.endpoint,
		datasource_uid = "prom3",
	}
end

-- A Prometheus answered directly (raw /api/v1 bodies).
local function directRoute(): Route.Route
	local r = dsRoute()
	r.via = "direct"
	r.datasource_uid = nil
	return r
end

-- `up` of the first series in each instant capture: Prometheus answers a
-- vector in no fixed order, and Grafana 13's capture led with the down target.
local FIRST_UP = { ["11.6.16"] = "1", ["12.4.12"] = "1", ["13.3.1"] = "0" }
local MAJOR = { ["11.6.16"] = 11, ["12.4.12"] = 12, ["13.3.1"] = 13 }

for _, version in S.VERSIONS do
	local env = S.env()
	local function load(): { Variables.Variable }
		local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_variables.json")), env))
		local vars, err = Variables.fromModel(d.templating, env)
		expect(err).toBeNil()
		return vars
	end
	local datasources = Queries.frontendDatasources(S.response(S.grafana(version, "frontend_settings.json")), env)

	describe("variables model on Grafana " .. version, function()
		it("orders variables after what they reference", function()
			local vars = load()
			expect(names(vars)).toEqual({
				"ds",
				"job",
				"instance",
				"metric",
				"topjob",
				"mode",
				"env",
				"step",
				"handler",
			})
			local job = assert(Variables.find(vars, "job"))
			expect(job.deps).toEqual({ "ds" })
			expect(assert(Variables.find(vars, "instance")).deps).toEqual({ "job", "ds" })
		end)

		it("resolves local variables at once and leaves fetched ones pending", function()
			local vars = load()
			local mode = assert(Variables.find(vars, "mode"))
			expect(mode.values).toEqual({ "user", "system" })
			expect(values(mode.options)).toEqual({ "user", "system", "idle", "iowait" })
			local step = assert(Variables.find(vars, "step"))
			expect(step.values).toEqual({ "1m" })
			expect(values(step.options)).toEqual({ "$__auto_interval_step", "10s", "30s", "1m", "5m", "10m" })
			expect(assert(Variables.find(vars, "env")).values).toEqual({ "dev" })
			expect(assert(Variables.find(vars, "handler")).values).toEqual({ "/api/v1/.*" })
			expect(names(Variables.ready(vars))).toEqual({ "ds" })
			expect(Variables.settled(vars)).toBe(false)
		end)

		it("lists Prometheus datasources for the datasource variable and keeps prom3", function()
			local vars = load()
			local ds = assert(Variables.find(vars, "ds"))
			local options = Variables.datasourceOptions(ds, datasources, Variables.scope(vars))
			expect(options).toEqual({
				{ text = "Prometheus 2.53", value = "prom2" },
				{ text = "Prometheus 3", value = "prom3" },
			})
			Variables.setOptions(ds, options)
			expect(ds.values).toEqual({ "prom3" })
			expect(Variables.display(ds)).toBe("Prometheus 3")
			-- job, metric and topjob only waited for ds; instance still waits for job.
			expect(names(Variables.ready(vars))).toEqual({ "job", "metric", "topjob" })
		end)

		it("fetches chained label_values through the selected datasource", function()
			local vars = load()
			local ds = assert(Variables.find(vars, "ds"))
			Variables.setOptions(ds, (Variables.datasourceOptions(ds, datasources, Variables.scope(vars))))
			local scope = Variables.scope(vars)
			local job = assert(Variables.find(vars, "job"))
			expect(Variables.datasourceUid(job, scope)).toBe("prom3")
			local fetch = assert(Variables.fetchFor(job, scope))
			expect(fetch).toEqual({ kind = "label_values", label = "job", match = "up" })
			local req = Variables.request(fetch, dsRoute(), RANGE)
			expect(req.path).toBe("/api/datasources/proxy/uid/prom3/api/v1/label/job/values")

			local raw = assert(
				Variables.parseFetch(
					fetch,
					dsRoute(),
					S.response(S.grafana(version, "ds_proxy_prom_label_values.json")),
					env
				)
			)
			Variables.setOptions(job, (assert(Variables.optionsFrom(job, raw, scope))))
			expect(values(job.options)).toEqual({ "alertmanager", "down", "loki", "node", "prometheus", "tempo" })
			-- No saved selection and include-all: All, as Grafana defaults.
			expect(job.values).toEqual({ Variables.ALL })
			expect(Variables.display(job)).toBe("All")

			-- instance now sees job = All, which interpolates as the custom all value.
			expect(names(Variables.ready(vars))).toEqual({ "instance", "metric", "topjob" })
			local instance = assert(Variables.find(vars, "instance"))
			expect((Variables.fetchFor(instance, Variables.scope(vars)))).toEqual({
				kind = "label_values",
				label = "instance",
				match = 'up{job=~".*"}',
			})
		end)

		-- Grafana 12.1 moved metrics() to the server: an anchored
		-- `{__name__=~"..."}` match on the label values call. 11 lists every
		-- name and keeps those its unanchored regex finds.
		it("applies metrics() as the Grafana version does and extracts the capture group as the value", function()
			local vars = load()
			local metric = assert(Variables.find(vars, "metric"))
			local major = MAJOR[version]
			local fetch = assert(Variables.fetchFor(metric, Variables.scope(vars), nil, { major = major }))
			expect(fetch).toEqual({ kind = "metrics", regex = "node_memory_.*_bytes", server = major >= 12 })
			local direct = assert(Route.route(S.CONFIG, "lab", "metrics"))
			local req = Variables.request(fetch, directRoute(), RANGE)
			expect(req.path).toBe("/api/v1/label/__name__/values")
			expect((req.query :: any)[1][1]).toBe(if major >= 12 then "match[]" else "start")
			local frontend: Variables.Fetch = { kind = "metrics", regex = "node_memory_.*_bytes", server = false }
			local raw = assert(
				Variables.parseFetch(frontend, direct, S.response("prometheus/3.15.0/label_values_name.json"), env)
			)
			for _, name in raw do
				expect(string.match(name, "^node_memory_.*_bytes$") ~= nil).toBe(true)
			end
			local options = assert(Variables.optionsFrom(metric, raw, Variables.scope(vars)))
			expect(values(options)).toEqual({ "Buffers", "Cached", "Mem" })
			Variables.setOptions(metric, options)
			expect(metric.values).toEqual({ "Buffers" })
		end)

		it("formats query_result() rows like Grafana and extracts the regex group", function()
			local vars = load()
			local topjob = assert(Variables.find(vars, "topjob"))
			local fetch = assert(Variables.fetchFor(topjob, Variables.scope(vars)))
			expect(fetch).toEqual({ kind = "query_result", expr = "topk(3, sum by (job) (up))" })
			local raw = assert(
				Variables.parseFetch(
					fetch,
					dsRoute(),
					S.response(S.grafana(version, "ds_query_prom_instant.json")),
					env
				)
			)
			local pattern = '^up{instance="[^"]+",job="[^"]+"} ' .. FIRST_UP[version] .. " %d+$"
			expect(string.match(raw[1], pattern) ~= nil).toBe(true)
			local options = assert(Variables.optionsFrom(topjob, raw, Variables.scope(vars)))
			expect(values(options)).toEqual({ "alertmanager", "down", "loki", "node", "prometheus", "tempo" })
		end)

		-- A provisioned billing dashboard pattern: hidden query_result()
		-- variables chained into the panel PromQL. One reads an epoch with a
		-- fraction through a regex; the next computes `1 - $flag` without a
		-- regex, a scalar answer, and multiplies a term that must vanish.
		it("expands a hidden query_result() variable without a regex to the bare scalar Grafana uses", function()
			local vars = assert(Variables.fromModel({
				{
					type = "query",
					name = "at",
					hide = 2,
					datasource = { type = "prometheus", uid = "prom3" },
					query = "query_result(vector(time()))",
					regex = "{} (.*) .*",
				},
				{
					type = "query",
					name = "rest",
					hide = 2,
					datasource = { type = "prometheus", uid = "prom3" },
					query = "query_result(1 - 1)",
				},
			}, env))
			local at = assert(Variables.find(vars, "at"))
			local direct = directRoute()
			local fetch = assert(Variables.fetchFor(at, Variables.scope(vars)))
			local raw = assert(
				Variables.parseFetch(fetch, direct, S.response("prometheus/3.15.0/query_vector_fraction.json"), env)
			)
			-- Prometheus writes the sample as "1791577898.125"; so does the row.
			expect(raw).toEqual({ "{} 1791577898.125 1791577898125" })
			Variables.setOptions(at, (assert(Variables.optionsFrom(at, raw, Variables.scope(vars)))))
			expect(at.values).toEqual({ "1791577898.125" })

			local rest = assert(Variables.find(vars, "rest"))
			fetch = assert(Variables.fetchFor(rest, Variables.scope(vars)))
			raw = assert(
				Variables.parseFetch(fetch, dsRoute(), S.response(S.grafana(version, "ds_query_prom_scalar.json")), env)
			)
			expect(raw).toEqual({ "0" })
			Variables.setOptions(rest, (assert(Variables.optionsFrom(rest, raw, Variables.scope(vars)))))
			local expr = "sum(up) @ $at\n# partner term\n- (9999999999 * $rest) >= 0"
			expect(Interpolate.replace(expr, Variables.scope(vars), { format = Interpolate.prometheus })).toBe(
				"sum(up) @ 1791577898.125\n# partner term\n- (9999999999 * 0) >= 0"
			)
		end)

		it("fails a query_result() whose answer is a range vector, as Grafana does", function()
			local fetch = assert(Variables.parseQuery("query_result(up[1m])"))
			local options, err =
				Variables.parseFetch(fetch, directRoute(), S.response("prometheus/3.15.0/query_matrix.json"), env)
			expect(options).toBeNil()
			expect(err).toBe("Unknown/Unhandled result type: [matrix]")
		end)

		it("computes the auto interval from the range and auto_count/auto_min", function()
			local vars = load()
			local step = assert(Variables.find(vars, "step"))
			Variables.select(step, { "$__auto_interval_step" })
			-- 30 min / 30 = 60 s.
			local scope = Variables.scope(vars, RANGE)
			expect(Interpolate.replace("$step", scope)).toBe("1m")
			-- 5 min / 30 = 10 s, the auto_min.
			local short = Variables.scope(vars, { from_ms = S.NOW_MS - 300000, to_ms = S.NOW_MS })
			expect(Interpolate.replace("$step", short)).toBe("10s")
			expect(Variables.display(step)).toBe("auto")
		end)
	end)

	-- tern-pub-vars reproduces the variables of popular public dashboards
	-- Tern could not resolve: a bare series selector cut by a regex (gcom
	-- 17781 Loki Metrics: every panel read the variables), and Loki
	-- label_values variables (gcom 13639 Logs/App, 12611 Logging via Loki).
	describe("public dashboard variable patterns on Grafana " .. version, function()
		local major = MAJOR[version]
		local function pub(): { Variables.Variable }
			local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_pub_vars.json")), env))
			local vars, err = Variables.fromModel(d.templating, env)
			expect(err).toBeNil()
			return vars
		end
		local function lokiRoute(): Route.Route
			local r = dsRoute()
			r.datasource_uid = "loki"
			return r
		end
		-- Fetches `name` from the recorded answer the way the dashboard does.
		local function resolve(
			vars: { Variables.Variable },
			name: string,
			ctx: Variables.FetchContext,
			route: Route.Route,
			file: string
		)
			local v = assert(Variables.find(vars, name))
			local scope = Variables.scope(vars)
			local fetch = assert(Variables.fetchFor(v, scope, nil, ctx))
			local raw = assert(Variables.parseFetch(fetch, route, S.response(S.grafana(version, file)), env))
			Variables.setOptions(v, (assert(Variables.optionsFrom(v, raw, scope))))
			return v
		end

		it("resolves a bare series selector through its regex, as Grafana's classic query does", function()
			local vars = pub()
			local ctx = { ds_type = "prometheus", major = major }
			local jobs = resolve(vars, "jobs", ctx, dsRoute(), "ds_proxy_prom_label_values.json")
			expect(values(jobs.options)).toEqual({ "node", "prometheus" })
			expect(jobs.values).toEqual({ "node" })

			local host = assert(Variables.find(vars, "host"))
			local fetch = assert(Variables.fetchFor(host, Variables.scope(vars), nil, ctx))
			expect(fetch).toEqual({ kind = "series", match = 'up{job=~"node"}' })
			-- Whole seconds, the start rounded down and the end up (getPrometheusTime).
			local req = Variables.request(fetch, dsRoute(), { from_ms = S.NOW_MS - 900500, to_ms = S.NOW_MS + 1 })
			expect(req.path).toBe("/api/datasources/proxy/uid/prom3/api/v1/series")
			expect(req.query).toEqual({
				{ "match[]", 'up{job=~"node"}' },
				{ "start", string.format("%d", (S.NOW_MS - 901000) // 1000) },
				{ "end", string.format("%d", S.NOW_MS // 1000 + 1) },
			})
			local raw = assert(
				Variables.parseFetch(fetch, dsRoute(), S.response(S.grafana(version, "ds_proxy_prom_series.json")), env)
			)
			expect(raw).toEqual({ 'up{env="dev",instance="node-exporter:9100",job="node"}' })

			resolve(vars, "host", ctx, dsRoute(), "ds_proxy_prom_series.json")
			local port = resolve(vars, "port", ctx, dsRoute(), "ds_proxy_prom_series.json")
			expect(values(host.options)).toEqual({ "node-exporter" })
			expect(port.values).toEqual({ "9100" })
			expect(Interpolate.replace('up{instance="$host:$port"}', Variables.scope(vars), {
				format = Interpolate.prometheus,
			})).toBe('up{instance="node-exporter:9100"}')
		end)

		it("reports the parse error of a series query Prometheus rejects", function()
			local fetch = assert(Variables.parseQuery("sum(up)", major))
			expect(fetch).toEqual({ kind = "series", match = "sum(up)" })
			local options, err = Variables.parseFetch(
				fetch,
				dsRoute(),
				S.response(S.grafana(version, "ds_proxy_prom_series_error.json")),
				env
			)
			expect(options).toBeNil()
			expect(err).toBe('invalid parameter "match[]": 1:4: parse error: unexpected "("')
		end)

		it("reads Loki label_values variables, as strings and as editor objects with a stream", function()
			local vars = pub()
			local ctx = { ds_type = "loki", major = major }
			local app = assert(Variables.find(vars, "app"))
			local fetch = assert(Variables.fetchFor(app, Variables.scope(vars), nil, ctx))
			expect(fetch).toEqual({ kind = "loki_label_values", label = "app" })
			local req = Variables.request(fetch, lokiRoute(), RANGE)
			expect(req.path).toBe("/api/datasources/proxy/uid/loki/loki/api/v1/label/app/values")
			expect(req.query).toEqual({
				{ "start", string.format("%d000000", RANGE.from_ms) },
				{ "end", string.format("%d000000", RANGE.to_ms) },
			})
			resolve(vars, "app", ctx, lokiRoute(), "ds_proxy_loki_label_values_app.json")
			expect(values(app.options)).toEqual({ "checkout", "frontend", "payments" })
			expect(app.values).toEqual({ "checkout" })

			-- The editor object wins over its stale `definition`.
			local level = assert(Variables.find(vars, "level"))
			fetch = assert(Variables.fetchFor(level, Variables.scope(vars), nil, ctx))
			expect(fetch).toEqual({ kind = "loki_label_values", label = "level", stream = '{app="checkout"}' })
			req = Variables.request(fetch, lokiRoute(), RANGE)
			expect((req.query :: any)[3]).toEqual({ "query", '{app="checkout"}' })
			resolve(vars, "level", ctx, lokiRoute(), "ds_proxy_loki_label_values_level.json")
			expect(level.values).toEqual({ Variables.ALL })
			local expr = '{app="$app", level=~"$level"} |= "$search"'
			expect(Interpolate.replace(expr, Variables.scope(vars), { format = Interpolate.loki })).toBe(
				'{app="checkout", level=~"' .. table.concat(values(level.options), "|") .. '"} |= ""'
			)
		end)

		it("lists Loki label names for a variable whose datasource is named, not referenced", function()
			local vars = pub()
			local label = assert(Variables.find(vars, "label"))
			expect(label.datasource_uid).toBe("Loki")
			expect(label.datasource_type).toBeNil()
			local ctx = { ds_type = "loki", major = major }
			local fetch = assert(Variables.fetchFor(label, Variables.scope(vars), nil, ctx))
			expect(fetch.kind).toBe("loki_label_names")
			expect(Variables.request(fetch, lokiRoute(), RANGE).path).toBe(
				"/api/datasources/proxy/uid/loki/loki/api/v1/labels"
			)
			resolve(vars, "label", ctx, lokiRoute(), "ds_proxy_loki_labels.json")
			expect(values(label.options)).toEqual({ "app", "env", "job", "level", "service_name" })
		end)
	end)
end

describe("variables selection", function()
	local env = S.env()
	local function custom(multi: boolean, includeAll: boolean, query: string): Variables.Variable
		local vars = Variables.fromModel({
			{ type = "custom", name = "c", query = query, multi = multi, includeAll = includeAll, current = {} },
		}, env)
		return vars[1]
	end

	it("parses custom options with escaped commas and `text : value` pairs", function()
		expect(Variables.customOptions("a, b\\,c , Prod : prod-1,,")).toEqual({
			{ text = "a", value = "a" },
			{ text = "b,c", value = "b,c" },
			{ text = "Prod", value = "prod-1" },
		})
	end)

	it("defaults to the first option, or All when the variable includes it", function()
		expect(custom(false, false, "x,y").values).toEqual({ "x" })
		expect(custom(true, true, "x,y").values).toEqual({ Variables.ALL })
	end)

	it("keeps the still-valid part of a multi selection when options change", function()
		local v = custom(true, false, "a,b,c")
		Variables.select(v, { "a", "c" })
		Variables.setOptions(v, { { text = "c", value = "c" }, { text = "d", value = "d" } })
		expect(v.values).toEqual({ "c" })
		Variables.setOptions(v, { { text = "e", value = "e" } })
		expect(v.values).toEqual({ "e" })
	end)

	it("keeps a saved single value by its text when the options renamed its value", function()
		local vars = Variables.fromModel({
			{ type = "query", name = "db", query = "label_values(db)", current = { text = "orders", value = "db-1" } },
		}, env)
		local db = vars[1]
		Variables.setOptions(db, { { text = "billing", value = "db-2" }, { text = "orders", value = "db-3" } })
		expect(db.values).toEqual({ "db-3" })
	end)

	it("takes link values over the saved selection, including values the options do not list", function()
		local vars = Variables.fromModel({
			{ type = "custom", name = "mode", query = "user,system,idle", multi = true, includeAll = true },
			{ type = "query", name = "job", query = "label_values(job)", multi = true, includeAll = true },
			{ type = "constant", name = "env", query = "dev" },
		}, env)
		Variables.applyUrl(vars, { mode = { "idle" }, job = { "custom-job" }, env = { "prod" } })
		expect(assert(Variables.find(vars, "mode")).values).toEqual({ "idle" })
		expect(assert(Variables.find(vars, "env")).values).toEqual({ "dev" })
		local job = assert(Variables.find(vars, "job"))
		Variables.setOptions(job, { { text = "node", value = "node" } })
		expect(job.values).toEqual({ "custom-job" })
		Variables.applyUrl(vars, { mode = { "All" } })
		expect(assert(Variables.find(vars, "mode")).values).toEqual({ Variables.ALL })
		expect(Variables.urlValues(vars)).toEqual({ mode = { "$__all" }, job = { "custom-job" } })
	end)

	it("sorts like Grafana: alphabetical, numerical, case-insensitive and natural, descending on even modes", function()
		local opts = {}
		for _, s in { "b10", "a2", "B1", "a10" } do
			table.insert(opts, { text = s, value = s })
		end
		expect(values(Variables.sortOptions(opts, 1))).toEqual({ "B1", "a10", "a2", "b10" })
		expect(values(Variables.sortOptions(opts, 2))).toEqual({ "b10", "a2", "a10", "B1" })
		expect(values(Variables.sortOptions(opts, 3))).toEqual({ "B1", "a2", "b10", "a10" })
		expect(values(Variables.sortOptions(opts, 5))).toEqual({ "a10", "a2", "B1", "b10" })
		expect(values(Variables.sortOptions(opts, 7))).toEqual({ "a2", "a10", "B1", "b10" })
		expect(values(Variables.sortOptions(opts, 0))).toEqual({ "b10", "a2", "B1", "a10" })
	end)

	it("refetches dependents of a changed variable and time-dependent ones on a range change", function()
		local vars = Variables.fromModel({
			{ type = "custom", name = "a", query = "1,2" },
			{ type = "query", name = "b", query = 'label_values(x{a="$a"}, b)', refresh = 1 },
			{ type = "query", name = "c", query = 'label_values(y{b="$b"}, c)', refresh = 1 },
			{ type = "query", name = "d", query = "label_values(z)", refresh = 2 },
		}, env)
		for _, v in vars do
			if v.status == "pending" then
				Variables.setOptions(v, {})
			end
		end
		expect(Variables.dependents(vars, { "a" })).toEqual({ "b", "c" })
		Variables.invalidate(vars, Variables.dependents(vars, { "a" }))
		expect(names(Variables.ready(vars))).toEqual({ "b" })
		for _, v in vars do
			Variables.setOptions(v, v.options)
		end
		expect(Variables.onTimeRange(vars)).toEqual({ "d" })
		expect(names(Variables.ready(vars))).toEqual({ "d" })
	end)
end)

describe("variable queries as Grafana's datasources parse them", function()
	local env = S.env()

	-- metric_find_query.ts: the function forms by their regexes, everything
	-- else a series query; the empty forms ask for nothing.
	it("parses the Prometheus forms and sends any other expression as a series query", function()
		expect((Variables.parseQuery("label_names()"))).toEqual({ kind = "label_names" })
		expect((Variables.parseQuery("label_values(job)"))).toEqual({ kind = "label_values", label = "job" })
		expect((Variables.parseQuery('label_values(up{a=~"x,y"}, instance)'))).toEqual({
			kind = "label_values",
			label = "instance",
			match = 'up{a=~"x,y"}',
		})
		-- isFilterDefined: `{ }` is no filter.
		expect((Variables.parseQuery("label_values({ }, job)"))).toEqual({ kind = "label_values", label = "job" })
		expect((Variables.parseQuery("up"))).toEqual({ kind = "series", match = "up" })
		-- JavaScript's `.` stops at a line break: a multi-line query_result()
		-- is not one for Grafana either.
		expect((Variables.parseQuery("query_result(\n  up\n)"))).toEqual({
			kind = "series",
			match = "query_result(\n  up\n)",
		})
		for _, q in { "", "label_values()", "metrics()", "query_result()" } do
			local fetch, err = Variables.parseQuery(q)
			expect(fetch).toBeNil()
			expect(err).toBeNil()
		end
	end)

	it("lists label names of metrics matching label_names(m) without __name__, as Grafana does", function()
		local fetch = assert(Variables.parseQuery("label_names(prometheus_http)"))
		expect(fetch).toEqual({ kind = "label_names", match = '{__name__=~".*prometheus_http.*"}' })
		local route = directRoute()
		local response = S.response("prometheus/3.15.0/labels_match_http_requests.json")
		local labels = assert(Variables.parseFetch(fetch, route, response, env))
		expect(table.find(labels, "__name__")).toBeNil()
		expect(table.find(labels, "handler") ~= nil).toBe(true)
		local all = assert(Variables.parseFetch({ kind = "label_names" }, route, response, env))
		expect(table.find(all, "__name__") ~= nil).toBe(true)
	end)

	-- PrometheusVariableSupport puts the datasource's scrape interval in
	-- scope as $__interval (jsonData.timeInterval, else 15s).
	it("interpolates $__interval as the datasource's scrape interval", function()
		local vars = Variables.fromModel({
			{
				type = "query",
				name = "rate",
				datasource = { type = "prometheus", uid = "prom3" },
				query = "query_result(rate(up[$__interval]) * $__interval_ms)",
			},
		}, env)
		local v = vars[1]
		local ds =
			{ uid = "prom3", type = "prometheus", name = "P", is_default = true, json_data = { timeInterval = "30s" } }
		expect((Variables.fetchFor(v, {}, nil, { ds = ds }))).toEqual({
			kind = "query_result",
			expr = "rate(up[30s]) * 30000",
		})
		expect((Variables.fetchFor(v, {}, nil, {}))).toEqual({ kind = "query_result", expr = "rate(up[15s]) * 15000" })
	end)

	-- Loki's migrateVariableQuery and processMetricFindQuery.
	it("reads Loki variable queries as the Loki datasource does", function()
		local function fetch(query: any, scope: any?, major: number?): any
			local vars = Variables.fromModel(
				{ { type = "query", name = "x", datasource = { type = "loki", uid = "loki" }, query = query } },
				env
			)
			return (Variables.fetchFor(vars[1], scope or {}, nil, { major = major }))
		end
		expect(fetch("label_names()")).toEqual({
			kind = "loki_label_names",
			hidden = { "__aggregated_metric__", "__tenant_id__", "__stream_shard__" },
		})
		-- Grafana 11's frontend hid a misspelled name.
		expect(fetch("label_names()", nil, 11).hidden[1]).toBe("__aggregrated_metric__")
		expect(fetch('label_values({app="a"}, level)')).toEqual({
			kind = "loki_label_values",
			label = "level",
			stream = '{app="a"}',
		})
		expect(fetch({ type = 1, label = "level", stream = "{}" })).toEqual({
			kind = "loki_label_values",
			label = "level",
		})
		expect(fetch({ type = 0 }).kind).toBe("loki_label_names")
		-- Anything else answers no options, unasked.
		expect(fetch('{app="a"}')).toBeNil()
		expect(fetch({ type = 1, stream = '{app="a"}' })).toBeNil()
		-- A multi-value stream variable: regex-escaped values joined by `|`.
		local scope = {
			app = { values = { "a", "b.c" }, multi = true },
		}
		expect(fetch({ type = 1, label = "level", stream = '{app=~"$app"}' }, scope).stream).toBe('{app=~"a|b\\\\.c"}')
	end)

	it("leaves out the label names Loki's frontend hides", function()
		local route = assert(Route.route(S.CONFIG, "lab", "metrics"))
		local body = '{"status":"success","data":["__stream_shard__","app","__aggregated_metric__","__tenant_id__"]}'
		local fetch: Variables.Fetch =
			{ kind = "loki_label_names", hidden = { "__aggregated_metric__", "__tenant_id__", "__stream_shard__" } }
		expect((Variables.parseFetch(fetch, route, S.body(200, body), env))).toEqual({ "app" })
	end)
end)

describe("Loki variable interpolation", function()
	-- interpolateQueryExpr (Grafana 11.6 to 13): a single value stays as it
	-- is; multi-value ones are regex-escaped without escaping quotes.
	it("keeps a plain value raw and regex-escapes a multi-value one without touching quotes", function()
		local scope: Interpolate.Scope = {
			path = { values = { "C:\\logs" } },
			who = { values = { "o'neil", "a.b" }, multi = true },
		}
		expect(Interpolate.replace('{path="$path"}', scope, { format = Interpolate.loki })).toBe('{path="C:\\logs"}')
		expect(Interpolate.replace('{who=~"$who"}', scope, { format = Interpolate.loki })).toBe(
			'{who=~"o\'neil|a\\\\.b"}'
		)
	end)
end)

return nil
