--!strict
-- Ad hoc filter variables change what every panel on their datasource
-- queries. The query rewriting must match Grafana's own, byte for byte, or a
-- filtered panel shows other series than Grafana does: the cases below are
-- Grafana's own addLabelToQuery tests (packages/grafana-prometheus/src/
-- add_label_to_query.test.ts and public/app/plugins/datasource/loki/
-- modifyQuery.test.ts, v12.4.0). The dev dashboard tern-fid2-adhoc pins the
-- requests Grafana 12.4's frontend sent for its panels (captured from the
-- browser), and the URL form is scenes' `var-<name>=key|op|value`.
local Adhoc = require("../../../plugin/lib/dashboard/adhoc")
local Interpolate = require("../../../plugin/lib/dashboard/interpolate")
local Queries = require("../../../plugin/lib/dashboard/queries")
local S = require("./support")
local Variables = require("../../../plugin/lib/dashboard/variables")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("ad hoc filters", function()
	local PROM_CASES: { { string } } = {
		{ "foo", "bar", "baz", "=", 'foo{bar="baz"}' },
		{ "foo{}", "bar", "baz", "=", 'foo{bar="baz"}' },
		{ 'foo{x="yy"}', "bar", "baz", "=", 'foo{x="yy", bar="baz"}' },
		{ "metric > 0.001", "foo", "bar", "=", 'metric{foo="bar"} > 0.001' },
		{ "foo{}", "bar", "baz", "!=", 'foo{bar!="baz"}' },
		{ 'foo{x="yy"}', "bar", "baz", "!=", 'foo{x="yy", bar!="baz"}' },
		{ "rate(metric[1m])", "foo", "bar", "=", 'rate(metric{foo="bar"}[1m])' },
		{ "sum by (xx) (foo)", "bar", "baz", "=", 'sum by (xx) (foo{bar="baz"})' },
		{
			"sum(rate(prometheus_tsdb_compaction_chunk_size_bytes_bucket[5m])) by (le)",
			"le",
			"+Inf",
			"=",
			'sum(rate(prometheus_tsdb_compaction_chunk_size_bytes_bucket{le="+Inf"}[5m])) by (le)',
		},
		{ 'foo{instance="my-host.com:9100"}', "bar", "baz", "=", 'foo{instance="my-host.com:9100", bar="baz"}' },
		{ "foo:metric:rate1m", "bar", "baz", "=", 'foo:metric:rate1m{bar="baz"}' },
		{ 'avg(foo:metric:rate1m{a="b"})', "bar", "baz", "=", 'avg(foo:metric:rate1m{a="b", bar="baz"})' },
		{ 'foo{list="a,b,c"}', "bar", "baz", "=", 'foo{list="a,b,c", bar="baz"}' },
		{ "foo + foo", "bar", "baz", "=", 'foo{bar="baz"} + foo{bar="baz"}' },
		{ 'foo{x="yy"} + metric', "bar", "baz", "=", 'foo{x="yy", bar="baz"} + metric{bar="baz"}' },
		{ "avg(foo) + sum(xx_yy)", "bar", "baz", "=", 'avg(foo{bar="baz"}) + sum(xx_yy{bar="baz"})' },
		{
			'foo{x="yy"} * metric{y="zz",a="bb"} * metric2',
			"bar",
			"baz",
			"=",
			'foo{x="yy", bar="baz"} * metric{y="zz", a="bb", bar="baz"} * metric2{bar="baz"}',
		},
		{ '{x="y"} |="yy"', "bar", "baz", "=", '{x="y", bar="baz"} |="yy"' },
		{ '{x="y"} |="yy" !~"xx"', "bar", "baz", "=", '{x="y", bar="baz"} |="yy" !~"xx"' },
		{ "foo_info or bar_info", "bar", "baz", "=", 'foo_info{bar="baz"} or bar_info{bar="baz"}' },
		{ "foo_info and bar_info", "bar", "baz", "=", 'foo_info{bar="baz"} and bar_info{bar="baz"}' },
		{
			'sum(rate({job="foo"}[2m])) by (value $variable)',
			"bar",
			"baz",
			"=",
			'sum(rate({job="foo", bar="baz"}[2m])) by (value $variable)',
		},
		{
			'avg(rate((my_metric{job="foo"} > 0)[3h:])) by (label)',
			"bar",
			"baz",
			"=",
			'avg(rate((my_metric{job="foo", bar="baz"} > 0)[3h:])) by (label)',
		},
		{ "rate(my_metric[${__range_s}s])", "bar", "baz", "=", 'rate(my_metric{bar="baz"}[${__range_s}s])' },
		{
			'count(my_metric{job!="foo"} < (5*1024*1024*1024) or vector(0)) - 1',
			"bar",
			"baz",
			"=",
			'count(my_metric{job!="foo", bar="baz"} < (5*1024*1024*1024) or vector(0)) - 1',
		},
		{ "ALERTS < bool 1", "bar", "baz", "=", 'ALERTS{bar="baz"} < bool 1' },
		{ '{"metric.name"}', "cenk.erdem", "muhabbet", "=", '{"metric.name", "cenk.erdem"="muhabbet"}' },
		{
			'metric{label="val"}',
			"cenk.erdem",
			"muhabbet",
			"=",
			'metric{label="val", "cenk.erdem"="muhabbet"}',
		},
		{
			'{"metric.name", "cenk.erdem"="muhabbet"}',
			"cenk.erdem",
			"muhabbet",
			"=",
			'{"metric.name", "cenk.erdem"="muhabbet"}',
		},
		{
			'metric{label="val", "cenk.erdem"="muhabbet"}',
			"cenk.erdem",
			"muhabbet",
			"=",
			'metric{label="val", "cenk.erdem"="muhabbet"}',
		},
	}
	local LOKI_CASES: { { string } } = {
		{ '{x="yy"}', "bar", "=", "baz", '{x="yy", bar="baz"}' },
		{ '{x="yy"}', "bar", "=", "baz", '{x="yy", bar="baz"}' },
		{ '{x="yy"}', "bar", "!=", "baz", '{x="yy", bar!="baz"}' },
		{ "rate({}[1m])", "bar", "=", "baz", 'rate({bar="baz"}[1m])' },
		{ "sum by (host) (rate({} [1m]))", "bar", "=", "baz", 'sum by (host) (rate({bar="baz"}[1m]))' },
		{ '{instance="my-host.com:9100"}', "bar", "=", "baz", '{instance="my-host.com:9100", bar="baz"}' },
		{ '{list="a,b,c"}', "bar", "=", "baz", '{list="a,b,c", bar="baz"}' },
		{ "rate({}[5m]) + rate({}[5m])", "bar", "=", "baz", 'rate({bar="baz"}[5m]) + rate({bar="baz"}[5m])' },
		{
			'avg(rate({x="y"} [$__interval]))+ sum(rate({}[5m]))',
			"bar",
			"=",
			"baz",
			'avg(rate({x="y", bar="baz"} [$__interval]))+ sum(rate({bar="baz"}[5m]))',
		},
		{
			'rate({x="yy"}[5m]) * rate({y="zz",a="bb"}[5m]) * rate({}[5m])',
			"bar",
			"=",
			"baz",
			'rate({x="yy", bar="baz"}[5m]) * rate({y="zz", a="bb", bar="baz"}[5m]) * rate({bar="baz"}[5m])',
		},
		{ '{x="yy", bar!="baz"}', "bar", "!=", "baz", '{x="yy", bar!="baz"}' },
		{ 'rate({bar="baz"}[1m])', "bar", "=", "baz", 'rate({bar="baz"}[1m])' },
		{ '{list="a,b,c", bar="baz"}', "bar", "=", "baz", '{list="a,b,c", bar="baz"}' },
		{
			'avg(rate({bar="baz"} [$__interval]))+ sum(rate({bar="baz"}[5m]))',
			"bar",
			"=",
			"baz",
			'avg(rate({bar="baz"} [$__interval]))+ sum(rate({bar="baz"}[5m]))',
		},
		{ '{x="y"} |="yy"', "bar", "=", "baz", '{x="y", bar="baz"} |="yy"' },
		{ '{x="y"} |="yy" !~"xx"', "bar", "=", "baz", '{x="y", bar="baz"} |="yy" !~"xx"' },
		{ '{x="y"} or {}', "bar", "=", "baz", '{x="y", bar="baz"} or {bar="baz"}' },
		{ '{x="y"} and {}', "bar", "=", "baz", '{x="y", bar="baz"} and {bar="baz"}' },
		{
			'sum(rate({job="foo"}[2m])) by (value $variable)',
			"bar",
			"=",
			"baz",
			'sum(rate({job="foo", bar="baz"}[2m])) by (value $variable)',
		},
		{ 'rate({x="y"}[${__range_s}s])', "bar", "=", "baz", 'rate({x="y", bar="baz"}[${__range_s}s])' },
		{
			'max by (id, name, type) ({type=~"foo|bar|baz-test"}) * on(id) group_right(id, type, name) sum by (id) (rate({} [5m])) * 1000',
			"bar",
			"=",
			"baz",
			'max by (id, name, type) ({type=~"foo|bar|baz-test", bar="baz"}) * on(id) group_right(id, type, name) sum by (id) (rate({bar="baz"}[5m])) * 1000',
		},
		{ '{foo="bar"} | logfmt', "bar", "=", "baz", '{foo="bar"} | logfmt | bar=`baz`' },
		{ '{foo="bar"} | logfmt | json', "bar", "=", "baz", '{foo="bar"} | logfmt | json | bar=`baz`' },
		{ '{foo="bar"} | logfmt | x="y"', "bar", "=", "baz", '{foo="bar"} | logfmt | x="y" | bar=`baz`' },
		{ 'rate({foo="bar"} | logfmt [5m])', "bar", "=", "baz", 'rate({foo="bar"} | logfmt | bar=`baz` [5m])' },
		{
			'sum by(host) (rate({foo="bar"} | logfmt | x="y" | line_format "{{.status}}" [5m]))',
			"bar",
			"=",
			"baz",
			'sum by(host) (rate({foo="bar"} | logfmt | x="y" | bar=`baz` | line_format "{{.status}}" [5m]))',
		},
		{
			'sum by(host) (rate({foo="bar"} | logfmt | x="y" | label_format process="{{.process}}" [5m]))',
			"bar",
			"=",
			"baz",
			'sum by(host) (rate({foo="bar"} | logfmt | x="y" | label_format process="{{.process}}" | bar=`baz` [5m]))',
		},
		{
			'{foo="bar"} | logfmt | x="y" | label_format process="{{.process}}"',
			"bar",
			"=",
			"baz",
			'{foo="bar"} | logfmt | x="y" | label_format process="{{.process}}" | bar=`baz`',
		},
		{
			'{foo="bar"} | logfmt | line_format "{{.status}}"',
			"bar",
			"=",
			"baz",
			'{foo="bar"} | logfmt | bar=`baz` | line_format "{{.status}}"',
		},
		{
			'{foo="bar"} | logfmt | line_format "{{status}}"',
			"bar",
			"=",
			"baz",
			'{foo="bar"} | logfmt | bar=`baz` | line_format "{{status}}"',
		},
		{ "{}", "bar", "=", "baz", '{bar="baz"}' },
		{ "{} | logfmt", "bar", "=", "baz", '{bar="baz"}| logfmt' },
		{ '{} | x="y"', "bar", "=", "baz", '{bar="baz"}| x="y"' },
		{ '{} | logfmt | x="y"', "bar", "=", "baz", '{bar="baz"}| logfmt | x="y"' },
		{
			'sum(rate({x="y"} [5m])) + sum(rate({} | logfmt [5m]))',
			"bar",
			"=",
			"baz",
			'sum(rate({x="y", bar="baz"} [5m])) + sum(rate({bar="baz"}| logfmt [5m]))',
		},
		{
			'sum(rate({x="y"} | logfmt [5m])) + sum(rate({} [5m]))',
			"bar",
			"=",
			"baz",
			'sum(rate({x="y", bar="baz"} | logfmt [5m])) + sum(rate({bar="baz"}[5m]))',
		},
		{
			'sum(rate({x="y", bar="baz"} | logfmt [5m])) + sum(rate({x="y", bar="baz"} [5m]))',
			"x",
			"=",
			"y",
			'sum(rate({x="y", bar="baz"} | logfmt [5m])) + sum(rate({x="y", bar="baz"} [5m]))',
		},
		{ '{x="yy"}', "bar", "=", '"baz"', '{x="yy", bar=""baz""}' },
		{ '{x="yy"}', "bar", "=", '\\"baz\\"', '{x="yy", bar="\\"baz\\""}' },
		{ '{x="yy"}', "bar", "=", "baz\\\\", '{x="yy", bar="baz\\\\"}' },
		{ '{x="yy"}', "bar", "~=", "baz\\\\", '{x="yy", bar~="baz\\\\"}' },
		{ '{foo="bar"} | logfmt', "bar", "=", '\\"baz\\"', '{foo="bar"} | logfmt | bar=`"baz"`' },
		{ '{foo=`"bar"`} | logfmt', "foo", "=", '"bar"', '{foo=""bar""} | logfmt' },
		{ '{foo="\\"bar\\""`} | logfmt', "foo", "=", '\\"bar\\"', '{foo="\\"bar\\""} | logfmt' },
		{ '{foo="bar"} | logfmt', "foo", "=", "bar", '{foo="bar"} | logfmt' },
		{ "{foo=`bar`} | logfmt", "foo", "=", "bar", '{foo="bar"} | logfmt' },
		{
			"{service_name=`grafana/hosted-grafana-gateway`} | logfmt | caller!=`handler.go:637` ",
			"service_name",
			"=",
			"grafana/hosted-grafana-gateway",
			'{service_name="grafana/hosted-grafana-gateway"} | logfmt | caller!=`handler.go:637` ',
		},
		{
			"{service_name=`grafana/hosted-grafana-gateway`, pod_template_hash!=`5fd76866f4`} | logfmt | caller!=`handler.go:637`",
			"service_name",
			"=",
			"grafana/hosted-grafana-gateway",
			'{service_name="grafana/hosted-grafana-gateway", pod_template_hash!="5fd76866f4"} | logfmt | caller!=`handler.go:637`',
		},
		{
			"{service_name=`grafana/hosted-grafana-gateway`, x!=`y`} | logfmt | caller!=`handler.go:637`",
			"x",
			"!=",
			"y",
			'{service_name="grafana/hosted-grafana-gateway", x!="y"} | logfmt | caller!=`handler.go:637`',
		},
		{
			'{service_name="grafana/hosted-grafana-gateway"} | logfmt | caller!=`handler.go:637` ',
			"service_name",
			"=",
			"grafana/hosted-grafana-gateway",
			'{service_name="grafana/hosted-grafana-gateway"} | logfmt | caller!=`handler.go:637` ',
		},
		{ '{foo="bar"} | logfmt', "bar", "=", "baz\\\\", '{foo="bar"} | logfmt | bar=`baz\\`' },
		{ '{foo="bar"} | logfmt', "bar", "~=", '\\"baz\\"', '{foo="bar"} | logfmt | bar~=`"baz"`' },
		{ '{foo="bar"} | logfmt', "bar", "~=", '\\"baz\\"', '{foo="bar"} | logfmt | bar~=`"baz"`' },
		{ '{foo="bar"} | logfmt', "bar", ">", "5", '{foo="bar"} | logfmt | bar>5' },
		{ '{foo="bar"} | logfmt', "bar", "<", "5KiB", '{foo="bar"} | logfmt | bar<`5KiB`' },
		{
			'sum(rate({x="y"} | logfmt [5m])) + sum(rate({x="z"} | logfmt [5m]))',
			"bar",
			"=",
			"baz",
			'sum(rate({x="y"} | logfmt | bar=`baz` [5m])) + sum(rate({x="z"} | logfmt | bar=`baz` [5m]))',
		},
	}

	it("adds a filter to every Prometheus selector as Grafana's addLabelToQuery does", function()
		for _, c in PROM_CASES do
			expect(Adhoc.promAddLabel(c[1], c[2], c[3], c[4])).toBe(c[5])
		end
		-- Twice the same filter adds it once; another operator replaces it.
		local once = Adhoc.promAddLabel('foo{x="yy"}', "bar", "baz", "!=")
		expect(Adhoc.promAddLabel(once, "bar", "baz", "!=")).toBe('foo{x="yy", bar!="baz"}')
		expect(Adhoc.promAddLabel(once, "bar", "baz", "=")).toBe('foo{x="yy", bar="baz"}')
	end)

	it("adds a filter to Loki stream selectors, or after the parsers, as Grafana's modifyQuery does", function()
		for _, c in LOKI_CASES do
			expect(Adhoc.lokiAddLabel(c[1], c[2], c[3], c[4])).toBe(c[5])
		end
	end)

	it("escapes regex values and maps one-of operators from Grafana 13", function()
		local f = { key = "route", operator = "=~", value = "/a'b" }
		expect(Adhoc.promApply("up", { f })).toBe([[up{route=~"/a\\'b"}]])
		local oneOf = { key = "job", operator = "=|", value = "a", values = { "a", "b" } }
		expect(Adhoc.promApply("up", { oneOf }, { major = 13 })).toBe('up{job=~"a|b"}')
		-- Grafana 12 hands `=|` to addLabelToQuery unchanged (the query fails there too).
		expect(Adhoc.promApply("up", { oneOf }, { major = 12 })).toBe('up{job=|"a"}')
	end)

	it("renders the variable's value as scenes' filter expression", function()
		local filters: { Adhoc.Filter } = {
			{ key = "env", operator = "=", value = 'pr"od' },
			{ key = "route", operator = "=~", value = "/cart.json" },
			{ key = "all", operator = "=~", value = ".*" },
		}
		expect(Adhoc.expression(filters)).toBe([[env="pr\"od",route=~"/cart\\.json"]])
	end)

	it("round-trips filters through scenes' URL form", function()
		local f: Adhoc.Filter = { key = "path", operator = "=", value = "a|b,c#d" }
		local url = Adhoc.toUrl(f)
		expect(url).toBe("path|=|a__gfp__b__gfc__c__gfh__d")
		local back = Adhoc.fromUrl(url) :: Adhoc.Filter
		expect(back.key).toBe("path")
		expect(back.operator).toBe("=")
		expect(back.value).toBe("a|b,c#d")
		local multi = Adhoc.fromUrl("job|=__gfp__|a|b") :: Adhoc.Filter
		expect(table.concat(multi.values :: { string }, ",")).toBe("a,b")
		expect(Adhoc.fromUrl("")).toBe(nil)
	end)

	it("takes the saved filters and link overrides, and exposes the expression to ${filter}", function()
		local env = S.env()
		local vars = Variables.fromModel({
			{
				name = "ds",
				type = "datasource",
				query = "prometheus",
				current = { value = "prom3", text = "Prometheus 3" },
			},
			{
				name = "filter",
				type = "adhoc",
				datasource = { type = "prometheus", uid = "${ds}" },
				filters = { { key = "job", operator = "=", value = "prometheus" } },
			},
		}, env)
		local v = Variables.find(vars, "filter") :: Variables.Variable
		expect(v.kind).toBe("adhoc")
		expect(table.concat(v.deps, ",")).toBe("ds")
		expect(Interpolate.replace("${filter}", Variables.scope(vars))).toBe('job="prometheus"')
		expect(table.concat(Variables.urlValues(vars).filter, ",")).toBe("job|=|prometheus")
		Variables.applyUrl(vars, { filter = { "job|!=|node", "env|=~|a.*" } })
		expect(Interpolate.replace("${filter}", Variables.scope(vars))).toBe('job!="node",env=~"a\\\\.\\\\*"')
		Variables.applyUrl(vars, { filter = { "" } })
		expect(#(v.adhoc :: Adhoc.Set).filters).toBe(0)
		-- Grafana writes an empty ad hoc variable as `var-filter=`.
		expect(Variables.urlValues(vars).filter[1]).toBe("")
	end)

	it("filters the panels on the variable's datasource as Grafana 12.4 sent tern-fid2-adhoc", function()
		local env = S.env()
		local datasources = {
			{ uid = "prom3", type = "prometheus", name = "Prometheus 3", is_default = true },
			{ uid = "loki", type = "loki", name = "Loki", is_default = false },
		}
		local ctx: Queries.Context = {
			scope = { datasource = { values = { "prom3" } } },
			from_ms = S.NOW_MS - 3600000,
			to_ms = S.NOW_MS,
			max_points = 100,
			datasources = datasources,
			grafana_major = 12,
			features = { lokiQuerySplitting = true },
			adhoc = {
				{ datasource = "prom3", filters = { { key = "job", operator = "=", value = "prometheus" } } },
				{ datasource = "loki", filters = { { key = "service_name", operator = "=", value = "checkout" } } },
			},
		}
		local function exprOf(panel: { [string]: any }): string
			local pq = assert(Queries.build(panel, ctx, env))
			return pq.queries[1].expr
		end
		local prom = { type = "prometheus", uid = "${datasource}" }
		expect(exprOf({ datasource = prom, targets = { { refId = "A", datasource = prom, expr = "count(up == 1)" } } })).toBe(
			'count(up{job="prometheus"} == 1)'
		)
		expect(exprOf({
			datasource = prom,
			targets = {
				{
					refId = "A",
					datasource = prom,
					expr = "sum by (job) (scrape_samples_scraped) / on(job) group_left count by (job) (up)",
				},
			},
		})).toBe(
			'sum by (job) (scrape_samples_scraped{job="prometheus"}) / on(job) group_left count by (job) (up{job="prometheus"})'
		)
		-- A -- Mixed -- panel gets no filters.
		expect(exprOf({
			datasource = { type = "datasource", uid = "-- Mixed --" },
			targets = { { refId = "A", datasource = { type = "prometheus", uid = "prom3" }, expr = "count(up == 1)" } },
		})).toBe("count(up == 1)")
		local loki = { type = "loki", uid = "loki" }
		expect(exprOf({
			datasource = loki,
			targets = {
				{
					refId = "A",
					datasource = loki,
					expr = 'sum(count_over_time({env=~".+"}[5m]))',
					queryType = "instant",
				},
			},
		})).toBe('sum(count_over_time({env=~".+", service_name="checkout"}[5m]))')
		-- A split range query gets the filter twice after its parser (runSplitQuery, then the backend query).
		expect(exprOf({
			datasource = loki,
			targets = { { refId = "A", datasource = loki, expr = '{env=~".+"} | logfmt', queryType = "range" } },
		})).toBe('{env=~".+"} | logfmt | service_name=`checkout` | service_name=`checkout`')
	end)
end)

return nil
