--!strict
-- Suggestions must come from the server's real lists (recorded from both
-- Prometheus versions and through Grafana's datasource proxy), rank what the
-- user is typing first, and accepting one must leave valid PromQL: values
-- quoted and escaped for their operator, label names ready for a value,
-- functions opened.
local Metrics = require("../../../plugin/lib/source/metrics")
local Promql = require("../../../plugin/lib/query/promql")
local Route = require("../../../plugin/lib/config/route")
local Suggest = require("../../../plugin/lib/query/suggest")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local CFG = S.config()
local ENV = S.env(CFG)
local DIRECT = (Route.route(CFG, "lab", "metrics")) :: any
local VIA_GRAFANA = (Route.route(CFG, "graf", "metrics")) :: any

local function list(route: any, path: string): { string }
	local r: any = Metrics.parseList(route, S.response(path), ENV)
	assert(r.ok, path)
	return r.values
end

local function labels(item: { Suggest.Item }): { string }
	local out = {}
	for i, it_ in item do
		out[i] = it_.label
	end
	return out
end

local function ctxAt(text: string): Promql.Context
	return Promql.context(text, #text)
end

describe("Suggest.needs", function()
	it("asks for metric names and metadata at an expression position", function()
		local keys = {}
		for _, n in Suggest.needs(ctxAt("node_")) do
			table.insert(keys, n.key)
		end
		expect(keys).toEqual({ Suggest.valuesKey("__name__", nil), Suggest.METADATA_KEY })
	end)

	it("scopes label names and values to the metric being matched", function()
		local n = Suggest.needs(ctxAt("up{jo"))[1]
		expect(S.list(n.kind, n.match)).toEqual(S.list("labels", "up"))
		local v = Suggest.needs(ctxAt('up{job="'))[1]
		expect(S.list(v.kind, v.label, v.match)).toEqual(S.list("values", "job", "up"))
	end)

	it("reads __name__ values from the metric name list", function()
		local v = Suggest.needs(ctxAt('{__name__="no'))[1]
		expect(v.key).toBe(Suggest.valuesKey("__name__", nil))
	end)

	it("needs nothing for durations", function()
		expect(#Suggest.needs(ctxAt("rate(x["))).toBe(0)
	end)
end)

describe("Suggest.items", function()
	for _, version in S.PROMETHEUS do
		it("ranks prefix matches before other matches on Prometheus " .. version, function()
			local names = list(DIRECT, "prometheus/" .. version .. "/label_values_name.json")
			local items = Suggest.items(ctxAt("node_cpu"), { lists = { [Suggest.valuesKey("__name__", nil)] = names } })
			local got = labels(items)
			expect(got[1]).toBe("node_cpu_guest_seconds_total")
			expect(got).toContain("node_cpu_seconds_total")
			for _, label in got do
				expect(string.find(label, "node_cpu", 1, true) ~= nil).toBe(true)
			end
			local sub = labels(Suggest.items(ctxAt("cpu_seconds"), {
				lists = { [Suggest.valuesKey("__name__", nil)] = names },
			}))
			expect(sub).toContain("node_cpu_seconds_total")
		end)

		it("describes metrics with their type and help on Prometheus " .. version, function()
			local meta: any =
				Metrics.parseMetadata(DIRECT, S.response("prometheus/" .. version .. "/metadata.json"), ENV)
			assert(meta.ok, "metadata fixture did not parse")
			-- Both servers report alertmanager_nflog_* counters (different ones).
			local name: string? = nil
			for metric, m in meta.metadata do
				if string.find(metric, "^alertmanager_nflog_") and m.type == "counter" then
					name = metric
					break
				end
			end
			assert(name, "no alertmanager_nflog counter in the fixture")
			local items = Suggest.items(ctxAt("alertmanager_nflog_q"), {
				lists = { [Suggest.valuesKey("__name__", nil)] = { name :: string } },
				metadata = meta.metadata,
			})
			expect(items[1].detail).toContain("counter")
			expect(items[1].detail).toContain("notification log")
		end)

		it("offers label names without the ones already written on Prometheus " .. version, function()
			local names = list(DIRECT, "prometheus/" .. version .. "/labels.json")
			local ctx = ctxAt('x{env="dev", ')
			local got = labels(Suggest.items(ctx, { lists = { [Suggest.labelsKey("x")] = names } }))
			expect(got).toContain("cpu")
			expect(table.find(got, "env")).toBeNil()
			expect(table.find(got, "__name__")).toBeNil()
		end)
	end

	for _, version in S.GRAFANA do
		it("offers label values read through Grafana " .. version .. "'s datasource proxy", function()
			local values = list(VIA_GRAFANA, "grafana/" .. version .. "/ds_proxy_prom_label_values.json")
			local ctx = ctxAt('up{job="no')
			local got = labels(Suggest.items(ctx, { lists = { [Suggest.valuesKey("job", "up")] = values } }))
			expect(got).toEqual({ "node" })
		end)
	end

	it("lists functions and aggregations with their kind", function()
		local items = Suggest.items(ctxAt("rat"), { lists = {} })
		expect(items[1].label).toBe("rate")
		expect(items[1].detail).toBe("function")
		local sum = Suggest.items(ctxAt("su"), { lists = {} })
		expect(labels(sum)).toContain("sum")
		expect(labels(sum)).toContain("sum_over_time")
	end)

	it("keeps an exactly typed function (accepting it adds the parenthesis)", function()
		expect(labels(Suggest.items(ctxAt("rate"), { lists = {} }))[1]).toBe("rate")
	end)

	it("drops a metric that is already typed in full", function()
		local items = Suggest.items(ctxAt("up"), { lists = { [Suggest.valuesKey("__name__", nil)] = { "up" } } })
		expect(table.find(labels(items), "up")).toBeNil()
	end)

	it("offers Grafana interval macros first inside range brackets", function()
		expect(labels(Suggest.items(ctxAt("rate(x["), { lists = {} }))[1]).toBe("$__rate_interval")
	end)

	it("caps the list", function()
		local many = {}
		for i = 1, 500 do
			table.insert(many, string.format("metric_%03d", i))
		end
		local items = Suggest.items(ctxAt("metric_"), { lists = { [Suggest.valuesKey("__name__", nil)] = many } })
		expect(#items).toBe(Suggest.MAX_ITEMS)
	end)
end)

describe("Suggest.apply", function()
	-- `|` marks the caret, before and after accepting the item.
	local function apply(marked: string, label: string, kind: any): string
		local at = string.find(marked, "|", 1, true) or #marked + 1
		local text = string.sub(marked, 1, at - 1) .. string.sub(marked, at + 1)
		local ctx = Promql.context(text, at - 1)
		local out, caret = Suggest.apply(text, at - 1, ctx, { label = label, kind = kind })
		return string.sub(out, 1, caret) .. "|" .. string.sub(out, caret + 1)
	end

	it("completes a metric name and replaces the rest of the word", function()
		expect(apply("rate(node_|", "node_cpu_seconds_total", "metric")).toBe("rate(node_cpu_seconds_total|")
		expect(apply("rate(node_|cpu[5m])", "node_load1", "metric")).toBe("rate(node_load1|[5m])")
	end)

	it("opens a function's parenthesis", function()
		expect(apply("ra|", "rate", "function")).toBe("rate(|")
		expect(apply("ra|(x)", "rate", "function")).toBe("rate(|x)")
	end)

	it("readies a label name for its value", function()
		expect(apply("up{jo|", "job", "label")).toBe('up{job="|"')
		expect(apply('up{jo|="x"}', "job", "label")).toBe('up{job|="x"}')
	end)

	it("closes the quote after a value and keeps a closing quote already there", function()
		expect(apply('up{job="no|', "node", "value")).toBe('up{job="node"|')
		expect(apply('up{job="no|"}', "node", "value")).toBe('up{job="node"|}')
	end)

	it("quotes a value typed right after the operator", function()
		expect(apply("up{job=|", "node", "value")).toBe('up{job="node"|')
	end)

	it("escapes a value for its string quote", function()
		expect(apply('x{path="|', 'C:\\a "b"', "value")).toBe('x{path="C:\\\\a \\"b\\""|')
		expect(apply("x{q='|", "it's", "value")).toBe("x{q='it\\'s'|")
	end)

	it("escapes regex metacharacters for =~ and !~ so the value matches literally", function()
		expect(apply('x{instance=~"|', "node-exporter:9100.local", "value")).toBe(
			'x{instance=~"node-exporter:9100\\\\.local"|'
		)
		expect(apply("x{v!~`|", "a+b", "value")).toBe("x{v!~`a\\+b`|")
	end)

	it("inserts grouping labels and durations as they are", function()
		expect(apply("sum by (jo|", "job", "label")).toBe("sum by (job|")
		expect(apply("rate(x[|", "$__rate_interval", "duration")).toBe("rate(x[$__rate_interval|")
	end)
end)

return nil
