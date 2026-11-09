--!strict
-- Grafana Cloud cardinality management (a frontend-only plugin), ported: the
-- panels on the cardinality management dashboards must show what Grafana's
-- browser builds from the same Mimir cardinality API answers. That needs the
-- exact requests (sorted parameters, `label_names[]`, the selector rules,
-- the target Prometheus datasource's proxy), the exact frames (field names,
-- display names, the gradient-gauge percentage column the tables draw as
-- gauges) and the plugin's own error texts. Fixtures are synthetic (the
-- plugin is Grafana Cloud only) in the shapes recorded from a real stack.
local Cardinality = require("../../../plugin/lib/datasources/cardinality")
local Frame = require("../../../plugin/lib/frame/types")
local Registry = require("../../../plugin/lib/datasources/registry")
local Support = require("../../lib/support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = Support.env()
local mod: any = Cardinality
local NULL = Frame.NULL

local PROM = "/api/datasources/proxy/uid/prom"
local CARD = "/api/datasources/proxy/uid/card"
local LV = PROM .. "/api/v1/cardinality/label_values?count_method=active"
local LN = PROM .. "/api/v1/cardinality/label_names?count_method=active"

local function datasources(unused: any?): { any }
	return {
		{
			uid = "card",
			name = "Cardinality",
			type = Cardinality.types[1],
			is_default = false,
			url = CARD,
			json_data = { unusedMetrics = unused },
		},
		{ uid = "prom", name = "Metrics", type = "prometheus", is_default = true, url = PROM },
		{
			uid = "prom2",
			name = "Other",
			type = "prometheus",
			is_default = false,
			url = "/api/datasources/proxy/uid/prom2",
		},
		{ uid = "direct", name = "Direct", type = "prometheus", is_default = false, url = "http://prom:9090" },
		{ uid = "nourl", name = "NoUrl", type = "prometheus", is_default = false },
		{ uid = "logs", name = "Logs", type = "loki", is_default = false, url = "/api/datasources/proxy/uid/logs" },
	}
end

local INSIGHTS = { metricsDataSourceUid = "prom", proxyType = "insights" }

local function ctx(scope: any?, unused: any?): any
	local list = datasources(unused)
	return {
		scope = scope or {},
		from_ms = 0,
		to_ms = 1,
		interval_ms = 1000,
		max_points = 100,
		now_ms = 1794250000123,
		datasources = list,
		ds = list[1],
		grafana_major = 13,
	}
end

-- What Grafana answers, by request (path, then the query as sent, unencoded).
local ROUTES: { [string]: { any } } = {
	[LV .. "&label_names[]=__name__&selector={}"] = { "metrics_names.json" },
	[LV .. "&label_names[]=__name__&limit=100&selector={}"] = { "metrics_names.json" },
	[LN .. "&selector={}"] = { "label_names.json" },
	[LN .. "&limit=100&selector={}"] = { "label_names.json" },
	[LN .. "&limit=500&selector={__name__='checkout_requests_total'}"] = { "metric_label_names.json" },
	[LN .. "&selector={__name__='checkout_requests_total'}"] = { "metric_label_names.json" },
	[LV .. "&label_names[]=route&label_names[]=region&label_names[]=status&label_names[]=__name__&limit=3&selector={__name__='checkout_requests_total'}"] = {
		"metric_examples.json",
	},
	[LV .. "&label_names[]=__name__&selector={__name__='checkout_requests_total'}"] = { "metric_subtotal.json" },
	[LV .. "&label_names[]=service&limit=500&selector={}"] = { "label_values_service.json" },
	[LV .. "&label_names[]=service&limit=16&selector={}"] = { "label_values_service.json" },
	[LV .. "&label_names[]=service&limit=0&selector={}"] = { "label_subtotal.json" },
	[LV .. "&label_names[]=__name__&selector={service='checkout'}"] = { "pairs_details.json" },
	[PROM .. "/api/v1/label/__name__/values?end=1794250800&limit=200&start=1794243600"] = { "list_metrics.json" },
	[PROM .. "/api/v1/labels?end=1794250800&limit=200&start=1794243600"] = { "list_labels.json" },
	[CARD .. "/unused"] = { "unused.json" },
	[CARD .. "/usages/checkout_requests_total"] = { "usage.json" },
	["/api/dashboards/uid/shop-overview"] = { "dashboard.json" },
	["/api/dashboards/uid/retired-board"] = { "dashboard_not_found.json", 404 },
	["/api/v1/provisioning/alert-rules/rule-a1"] = { "alert_rule.json" },
	["/api/v1/provisioning/alert-rules/rule-gone"] = { "alert_rule_not_found.json", 404 },
}

local function key(r: any): string
	local q: { string } = {}
	for _, p in r.query or {} do
		table.insert(q, p[1] .. "=" .. p[2])
	end
	return r.path .. (if #q > 0 then "?" .. table.concat(q, "&") else "")
end

-- Runs a job to its outcome against ROUTES (`over` replaces answers by
-- request); returns the outcome and the requests of each round.
local function run(job: any, over: { [string]: any }?): (any, { { string } })
	local rounds: { { string } } = {}
	local j, reqs, outcome = mod.step(job, {}, env)
	while outcome == nil do
		assert(#rounds < 8, "too many rounds")
		local round: { string } = {}
		local answers: { [string]: any } = {}
		for _, r in reqs do
			local k = key(r.request)
			table.insert(round, k)
			local answer = over and over[k]
			if answer == nil then
				local route = ROUTES[k]
				assert(route, "no route for " .. k)
				answer = Support.response("cardinality/" .. route[1], route[2])
			end
			answers[r.tag] = answer
		end
		table.insert(rounds, round)
		j, reqs, outcome = mod.step(j, answers, env)
	end
	return outcome, rounds
end

local function query(targets: { any }, c: any?, over: { [string]: any }?): (any, { { string } })
	return run(mod.start(targets, c or ctx(), env), over)
end

local function target(fields: { [string]: any }): any
	local q: { [string]: any } = { refId = "A", targetDatasource = "${datasource}" }
	for k, v in fields do
		q[k] = v
	end
	return q
end

local DS_SCOPE = { datasource = { values = { "prom" } } }

local function frameOf(outcome: any): any
	assert(outcome.data, outcome.error)
	return outcome.data.frames[1]
end

local function names(frame: any): { string }
	local out: { string } = {}
	for _, f in frame.fields do
		table.insert(out, f.name .. ":" .. f.type .. ":" .. tostring(f.config and f.config.displayName))
	end
	return out
end

local PERCENTAGE_CONFIG = {
	custom = { displayMode = "gradient-gauge" },
	max = 100,
	min = 0,
	thresholds = { mode = "percentage", steps = { { color = "blue", value = 0 }, { color = "yellow", value = 30 } } },
	unit = "percent",
}

local function percentageConfig(displayName: string): any
	local c: any = table.clone(PERCENTAGE_CONFIG)
	c.displayName = displayName
	return c
end

describe("cardinality overview panels", function()
	it("reads the four totals from the target's cardinality API", function()
		local cases: { { any } } = {
			{ "metrics", LV .. "&label_names[]=__name__&selector={}", "values", 4 },
			{ "series", LV .. "&label_names[]=__name__&selector={}", "series", 88 },
			{ "labels", LN .. "&selector={}", "labels", 6 },
			{ "pairs", LN .. "&selector={}", "pairs", 30 },
		}
		for _, c in cases do
			local outcome, rounds = query({ target({ cardinalityType = c[1], resultType = "total" }) }, ctx(DS_SCOPE))
			expect(rounds).toEqual({ { c[2] } })
			expect(frameOf(outcome)).toEqual({
				refId = "A",
				fields = { { name = c[3], type = "number", values = { c[4] } } },
			})
		end
	end)

	it("builds the metrics top table with a gradient-gauge percentage column", function()
		local outcome, rounds =
			query({ target({ cardinalityType = "metrics", resultType = "top", limit = "100" }) }, ctx(DS_SCOPE))
		-- No unusedMetrics config: no /unused request and no Used column.
		expect(rounds).toEqual({ { LV .. "&label_names[]=__name__&limit=100&selector={}" } })
		local frame = frameOf(outcome)
		expect(names(frame)).toEqual({
			"value:string:Metric",
			"count:number:Number of series",
			"percentage:number:Percentage of total series",
		})
		expect(frame.fields[1].values).toEqual({
			"checkout_requests_total",
			"checkout_latency_seconds_bucket",
			"queue_depth",
			"worker_up",
		})
		expect(frame.fields[2].values).toEqual({ 40, 30, 12, 6 })
		expect(frame.fields[3].values).toEqual({ 40 / 88 * 100, 30 / 88 * 100, 12 / 88 * 100, 6 / 88 * 100 })
		expect(frame.fields[3].config).toEqual(percentageConfig("Percentage of total series"))
	end)

	it("marks unused metrics from the plugin's own proxy when it serves the target", function()
		local tg = target({ cardinalityType = "metrics", resultType = "top", limit = "100" })
		local outcome, rounds = query(
			{ tg },
			ctx(DS_SCOPE, INSIGHTS),
			{ [CARD .. "/unused"] = Support.response("cardinality/unused_map.json") }
		)
		expect(rounds[1]).toEqual({ CARD .. "/unused", LV .. "&label_names[]=__name__&limit=100&selector={}" })
		local used = frameOf(outcome).fields[4]
		expect(used.name).toBe("used")
		expect(used.type).toBe("boolean")
		expect(used.values).toEqual({ true, true, false, false })
		-- The recorded answer has no unused map: the bundle drops the column.
		local recorded = frameOf((query({ tg }, ctx(DS_SCOPE, INSIGHTS))))
		expect(#recorded.fields).toBe(3)
		-- 204: the column stays, empty, reading "pending".
		local pending =
			frameOf((query({ tg }, ctx(DS_SCOPE, INSIGHTS), { [CARD .. "/unused"] = Support.body("", 204) })))
		expect(pending.fields[4]).toEqual({
			name = "used",
			type = "string",
			values = { NULL, NULL, NULL, NULL },
			config = { displayName = "Used", noValue = "pending" },
		})
		-- Another target than the configured metrics datasource: no usage data.
		local other = { datasource = { values = { "Other" } } }
		local _, otherRounds = query({ tg }, ctx(other, INSIGHTS), {
			["/api/datasources/proxy/uid/prom2/api/v1/cardinality/label_values?count_method=active&label_names[]=__name__&limit=100&selector={}"] = Support.response(
				"cardinality/metrics_names.json"
			),
		})
		expect(#otherRounds[1]).toBe(1)
	end)

	it("builds the labels top table", function()
		local outcome =
			query({ target({ cardinalityType = "labels", resultType = "top", limit = "100" }) }, ctx(DS_SCOPE))
		local frame = frameOf(outcome)
		expect(names(frame)).toEqual({
			"label:string:Label",
			"count:number:Number of unique values",
			"percentage:number:Percentage of total unique values",
		})
		expect(frame.fields[1].values).toEqual({ "pod", "route", "__name__", "service", "region", "env" })
		expect(frame.fields[3].values[1]).toBe(11 / 30 * 100)
		expect(frame.fields[3].config).toEqual(percentageConfig("Percentage of total unique values"))
	end)
end)

describe("cardinality metric detail panels", function()
	local scope = { datasource = { values = { "prom" } }, metric = { values = { "checkout_requests_total" } } }

	it("asks for a metric's labels, then their example values, in the order of the first answer", function()
		local outcome, rounds = query({
			target({
				cardinalityType = "metrics",
				resultType = "details",
				parameterList = { "${metric}" },
				exampleCount = "3",
			}),
		}, ctx(scope))
		expect(rounds).toEqual({
			{ LN .. "&selector={__name__='checkout_requests_total'}" },
			{
				LV
					.. "&label_names[]=route&label_names[]=region&label_names[]=status&label_names[]=__name__&limit=3&selector={__name__='checkout_requests_total'}",
			},
		})
		local frame = frameOf(outcome)
		expect(names(frame)).toEqual({
			"label:string:Label",
			"count:number:Number of values",
			"examples:other:Example label values",
		})
		expect(frame.fields[1].values).toEqual({ "route", "region", "status", "__name__" })
		expect(frame.fields[2].values).toEqual({ 5, 3, 2, 1 })
		expect(frame.fields[3].values).toEqual({
			{ "/cart", "/pay", "/ship" },
			{ "eu-west", "us-east", "ap-south" },
			{ "200", "500" },
			{ "checkout_requests_total" },
		})
	end)

	it("feeds the treemap from one label_names request without examples", function()
		local outcome, rounds = query({
			target({
				cardinalityType = "metrics",
				resultType = "details",
				parameterList = { "${metric}" },
				limit = 500,
			}),
		}, ctx(scope))
		expect(rounds).toEqual({ { LN .. "&limit=500&selector={__name__='checkout_requests_total'}" } })
		expect(names(frameOf(outcome))).toEqual({ "label:string:Label", "count:number:Number of values" })
	end)

	it("counts a metric's series with the top table's frame", function()
		local outcome, rounds = query(
			{ target({ cardinalityType = "series", resultType = "subtotal", parameterList = { "${metric}" } }) },
			ctx(scope)
		)
		expect(rounds).toEqual({ { LV .. "&label_names[]=__name__&selector={__name__='checkout_requests_total'}" } })
		local frame = frameOf(outcome)
		expect(frame.fields[1].values).toEqual({ "checkout_requests_total" })
		expect(frame.fields[2].values).toEqual({ 40 })
		expect(frame.fields[3].values).toEqual({ 100 })
	end)

	it("lists dashboards, Grafana rules and query counts that use the metric", function()
		local usage = target({
			cardinalityType = "metrics",
			resultType = "usage",
			parameterList = { "${metric}" },
			selector = "$metric",
		})
		local outcome, rounds = query({ usage }, ctx(scope, INSIGHTS))
		expect(rounds).toEqual({
			{ CARD .. "/usages/checkout_requests_total" },
			{ "/api/dashboards/uid/shop-overview", "/api/dashboards/uid/retired-board" },
		})
		local frame = frameOf(outcome)
		expect(names(frame)).toEqual({
			"dashboardUid:string:Dashboard UID",
			"dashboardTitle:string:Dashboard",
			"grafanaruleUid:string:Grafana rule UID",
			"grafanaruleTitle:string:Grafana rule",
			"rule:number:Mimir Rule count",
			"time:time:Time",
			"querycount:number:Query count",
		})
		local cols: { [string]: { any } } = {}
		for _, f in frame.fields do
			cols[f.name] = f.values
		end
		-- A deleted dashboard (404) reads as an empty title; each query log
		-- interval is a row at the interval's end.
		expect(cols.dashboardUid).toEqual({ "shop-overview", "retired-board", NULL, NULL })
		expect(cols.dashboardTitle).toEqual({ "Shop overview", "", NULL, NULL })
		expect(cols.time).toEqual({ NULL, NULL, 1793404800000, 1793491200000 })
		expect(cols.querycount).toEqual({ NULL, NULL, 3, 4 })

		local withRules = frameOf((query({ usage }, ctx(scope, INSIGHTS), {
			[CARD .. "/usages/checkout_requests_total"] = Support.response("cardinality/usage_rules.json"),
		})))
		local rcols: { [string]: { any } } = {}
		for _, f in withRules.fields do
			rcols[f.name] = f.values
		end
		expect(rcols.grafanaruleUid).toEqual({ NULL, "rule-a1", "rule-gone", NULL })
		expect(rcols.grafanaruleTitle).toEqual({ NULL, "checkout / Checkout errors", "", NULL })
		expect(rcols.rule).toEqual({ NULL, NULL, NULL, 2 })
	end)

	it("reports the plugin's usage errors", function()
		local usage = target({ cardinalityType = "metrics", resultType = "usage", parameterList = { "${metric}" } })
		expect((query({ usage }, ctx(scope))).error).toBe(
			"Usage data only available for the metric instance of this stack"
		)
		expect((query({ usage }, ctx(scope, INSIGHTS), {
			[CARD .. "/usages/checkout_requests_total"] = Support.body('{"message":"not found"}', 404),
		})).error).toBe("No data found for stack")
		-- Any other failure: the target has no frame, the panel no error.
		local failed = query({ usage }, ctx(scope, INSIGHTS), {
			[CARD .. "/usages/checkout_requests_total"] = Support.body('{"message":"boom"}', 500),
		})
		expect(failed.data.frames).toEqual({})
	end)
end)

describe("cardinality label detail panels", function()
	local scope = {
		datasource = { values = { "prom" } },
		label = { values = { "service" } },
		labelValues = { values = { "checkout" }, multi = true, include_all = true, single = true },
	}

	it("counts a label's values and its share of all series", function()
		local outcome, rounds = query(
			{ target({ cardinalityType = "labels", resultType = "subtotal", parameterList = { "${label}" } }) },
			ctx(scope)
		)
		expect(rounds).toEqual({ { LV .. "&label_names[]=service&limit=0&selector={}" } })
		expect(frameOf(outcome)).toEqual({
			refId = "A",
			fields = {
				{ name = "label", type = "string", values = { "service" }, config = { displayName = "Label" } } :: any,
				{ name = "subtotal", type = "number", values = { 4 }, config = { displayName = "Subtotal" } } :: any,
				{
					name = "percent",
					type = "number",
					values = { 70 / 88 * 100 },
					config = { decimals = 1, displayName = "Percent of series", unit = "%" },
				},
			},
		})
	end)

	it("lists a label's values and each value's metrics by series", function()
		local values = frameOf((query({
			target({ cardinalityType = "labels", resultType = "details", parameterList = { "${label}" }, limit = 500 }),
		}, ctx(scope))))
		expect(names(values)).toEqual({ "value:string:service", "count:number:Count of series" })
		expect(values.fields[1].values).toEqual({ "checkout", "cart", "billing", "search" })

		-- The repeated pairs table: one panel per labelValues value.
		local pairs, rounds = query({
			target({ cardinalityType = "pairs", resultType = "details", selector = "{${label}='${labelValues}'}" }),
		}, ctx(scope))
		expect(rounds).toEqual({ { LV .. "&label_names[]=__name__&selector={service='checkout'}" } })
		local frame = frameOf(pairs)
		expect(names(frame)).toEqual({ "value:string:Metric", "count:number:Count of series" })
		expect(frame.fields[1].values).toEqual({ "checkout_requests_total", "checkout_latency_seconds_bucket" })
		expect(frame.fields[2].values).toEqual({ 28, 12 })
	end)
end)

describe("cardinality selectors", function()
	-- The labels total request's selector for a target selector and scope.
	local function selector(sel: string, scope: any): string
		local q = target({ cardinalityType = "labels", resultType = "total", selector = sel })
		local captured = ""
		local job = mod.start({ q }, ctx(scope), env)
		local _, reqs = mod.step(job, {}, env)
		for _, p in reqs[1].request.query do
			if p[1] == "selector" then
				captured = p[2]
			end
		end
		return captured
	end

	it("puts the ad hoc filters first, with escapes undone, then the target's selector without braces", function()
		local scope = {
			datasource = { values = { "prom" } },
			filter = { values = { 'env="prod",route=~"/cart\\\\.json"' } },
			x = { values = { "v" } },
		}
		expect(selector("{ job='$x' }", scope)).toBe('{env="prod",route=~"/cart.json",job=\'v\'}')
		-- An unresolved ${filter} adds nothing; an only-braces selector stays
		-- as written (the bundle's regex keeps it).
		expect(selector("", DS_SCOPE)).toBe("{}")
		expect(selector("{}", DS_SCOPE)).toBe("{{}}")
		expect(selector("job='a'", DS_SCOPE)).toBe("{job='a'}")
	end)

	it("puts the metric first in details selectors", function()
		local scope = {
			datasource = { values = { "prom" } },
			metric = { values = { "checkout_requests_total" } },
			filter = { values = { 'env="prod"' } },
		}
		local _, rounds = query(
			{
				target({ cardinalityType = "series", resultType = "subtotal", parameterList = { "${metric}" } }),
			},
			ctx(scope),
			{
				[LV .. "&label_names[]=__name__&selector={__name__='checkout_requests_total',env=\"prod\"}"] = Support.response(
					"cardinality/metric_subtotal.json"
				),
			}
		)
		expect(rounds[1]).toEqual({
			LV .. "&label_names[]=__name__&selector={__name__='checkout_requests_total',env=\"prod\"}",
		})
	end)
end)

describe("cardinality errors", function()
	it("names a missing, unknown, incompatible or URL-less target the way the plugin does", function()
		local function err(tds: any): string?
			local q = target({ cardinalityType = "metrics", resultType = "total" })
			q.targetDatasource = tds
			local outcome, rounds = query({ q }, ctx({}))
			expect(#rounds).toBe(0)
			return outcome.error
		end
		expect(err(nil)).toBe("No target data source has been selected.")
		expect(err("gone")).toBe('The target data source "gone" could not be found.')
		expect(err("logs")).toBe('The target data source "loki" is not compatible.')
		expect(err("nourl")).toBe('The target data source "NoUrl" does not have a URL.')
	end)

	it("says the target does not support cardinality management when the API is missing (404)", function()
		local outcome = query({ target({ cardinalityType = "labels", resultType = "total" }) }, ctx(DS_SCOPE), {
			[LN .. "&selector={}"] = Support.body("404 page not found", 404),
		})
		expect(outcome.error).toBe('The target data source "Metrics" does not support Cardinality management.')
		local panel = Registry.panelData({ outcome = outcome, ref_ids = { "A" } } :: any)
		expect(panel.errors).toEqual({ 'A: The target data source "Metrics" does not support Cardinality management.' })
	end)

	it("fails the panel with the first failing target's error, as query() awaits them in order", function()
		local ok = target({ cardinalityType = "labels", resultType = "total" })
		local bad = target({ refId = "B", cardinalityType = "pairs", resultType = "total", targetDatasource = "gone" })
		local outcome = query({ ok, bad }, ctx(DS_SCOPE))
		expect(outcome.error).toBe('The target data source "gone" could not be found.')
	end)

	it("does not query hidden targets", function()
		local hidden = target({ cardinalityType = "labels", resultType = "total", hide = true })
		local outcome, rounds = query({ hidden }, ctx(DS_SCOPE))
		expect(#rounds).toBe(0)
		expect(outcome.data.frames).toEqual({})
	end)

	it("leaves the native rung only for a target the browser reaches directly", function()
		local bctx = { scope = DS_SCOPE, datasources = datasources(), ds = datasources()[1] }
		expect(mod.blocker(target({}), bctx, env)).toBeNil()
		expect(mod.blocker(target({ targetDatasource = "direct" }), bctx, env)).toBe(
			'the cardinality target data source "Direct" uses browser (direct) access, which only the browser can reach'
		)
	end)
end)

describe("cardinality query variables", function()
	it("lists metric and label names of the last two hours, rounded up to 15 minutes", function()
		local metric, rounds = run(
			mod.variable(
				{ cardinalityType = "metrics", resultType = "list", targetDatasource = "${datasource}" },
				ctx(DS_SCOPE),
				env
			)
		)
		expect(rounds).toEqual({ { PROM .. "/api/v1/label/__name__/values?end=1794250800&limit=200&start=1794243600" } })
		expect(metric.options[1]).toEqual({
			text = "checkout_latency_seconds_bucket",
			value = "checkout_latency_seconds_bucket",
		})
		expect(#metric.options).toBe(4)
		local label = run(
			mod.variable({ cardinalityType = "labels", resultType = "list", targetDatasource = "prom" }, ctx(), env)
		)
		expect(#label.options).toBe(7)
	end)

	it("lists a label's values for the hidden labelValues variable", function()
		local scope = { datasource = { values = { "prom" } }, label = { values = { "service" } } }
		local outcome, rounds = run(mod.variable({
			cardinalityType = "labels",
			resultType = "details",
			parameterList = { "${label}" },
			limit = 16,
			targetDatasource = "${datasource}",
		}, ctx(scope), env))
		expect(rounds).toEqual({ { LV .. "&label_names[]=service&limit=16&selector={}" } })
		expect(outcome.options).toEqual({
			{ text = "checkout", value = "checkout" },
			{ text = "cart", value = "cart" },
			{ text = "billing", value = "billing" },
			{ text = "search", value = "search" },
		})
	end)
end)

return nil
