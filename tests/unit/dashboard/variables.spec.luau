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

		it("applies metrics() and its capture-group regex like Grafana (the group becomes the value)", function()
			local vars = load()
			local metric = assert(Variables.find(vars, "metric"))
			local fetch = assert(Variables.fetchFor(metric, Variables.scope(vars)))
			expect(fetch).toEqual({ kind = "metrics", regex = "node_memory_.*_bytes" })
			local direct = assert(Route.route(S.CONFIG, "lab", "metrics"))
			local raw =
				assert(Variables.parseFetch(fetch, direct, S.response("prometheus/3.15.0/label_values_name.json"), env))
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
			expect(string.match(raw[1], '^up{instance="[^"]+",job="[^"]+"} 1 %d+$') ~= nil).toBe(true)
			local options = assert(Variables.optionsFrom(topjob, raw, Variables.scope(vars)))
			expect(values(options)).toEqual({ "alertmanager", "down", "loki", "node", "prometheus", "tempo" })
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

	it("rejects queries it cannot run instead of guessing", function()
		local fetch, err = Variables.parseQuery("up")
		expect(fetch).toBeNil()
		expect(err ~= nil).toBe(true)
		expect((Variables.parseQuery("label_names()"))).toEqual({ kind = "label_names" })
		expect((Variables.parseQuery("label_values(job)"))).toEqual({ kind = "label_values", label = "job" })
	end)
end)

return nil
