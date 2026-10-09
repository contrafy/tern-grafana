--!strict
-- Suggestions are only useful when they match what PromQL accepts at the
-- caret: a label name offered where a metric belongs, or a metric offered
-- inside a matcher's quotes, would write an invalid query. The caret is at
-- the end of each string unless a `|` marks it.
local Promql = require("../../../plugin/lib/query/promql")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function at(text: string): Promql.Context
	local bar = string.find(text, "|", 1, true)
	if bar then
		return Promql.context(string.sub(text, 1, bar - 1) .. string.sub(text, bar + 1), bar - 1)
	end
	return Promql.context(text, #text)
end

local function kindPrefix(text: string): { any }
	local c = at(text)
	return S.list(c.kind, c.prefix)
end

describe("Promql.context", function()
	it("offers metrics and functions at expression positions", function()
		local cases: { { any } } = {
			{ "node_", { "expr", "node_" } },
			{ "rate(node_cpu", { "expr", "node_cpu" } },
			{ "up + node_", { "expr", "node_" } },
			{ "up / on(job) group_left sum(proc", { "expr", "proc" } },
			{ "histogram_quantile(0.9, sum by (le) (rate(http_", { "expr", "http_" } },
			{ "sum(rate(x[5m])) / ignoring(cpu) co", { "expr", "co" } },
			-- An empty token is still an expression position; the block only
			-- lists everything on ctrl+space.
			{ "x and ", { "expr", "" } },
			{ "", { "expr", "" } },
		}
		for _, c in cases do
			expect(kindPrefix(c[1])).toEqual(c[2])
		end
	end)

	it("offers label names inside braces, scoped to the metric before them", function()
		local c = at("node_cpu_seconds_total{mo")
		expect(c.kind).toBe("label_name")
		expect(c.prefix).toBe("mo")
		expect(c.metric).toBe("node_cpu_seconds_total")
		local after = at('up{job="node", ')
		expect(after.kind).toBe("label_name")
		expect(after.prefix).toBe("")
		expect(after.used).toEqual({ "job" })
		local bare = at("{")
		expect(bare.kind).toBe("label_name")
		expect(bare.metric).toBeNil()
		local inFn = at("rate(http_requests_total{code")
		expect(inFn.metric).toBe("http_requests_total")
	end)

	it("never treats a function name as the metric of a matcher", function()
		expect(at("sum{").metric).toBeNil()
	end)

	it("offers label values inside a matcher's quotes, with label and operator", function()
		local c = at('up{job="no')
		expect(c.kind).toBe("label_value")
		expect(c.prefix).toBe("no")
		expect(c.label).toBe("job")
		expect(c.op).toBe("=")
		expect(c.quote).toBe('"')
		expect(c.metric).toBe("up")
		expect(c.from).toBe(#'up{job="')
		local re = at("node_cpu_seconds_total{mode=~'us")
		expect(S.list(re.kind, re.label, re.op, re.quote, re.prefix)).toEqual(
			S.list("label_value", "mode", "=~", "'", "us")
		)
		local neg = at('x{a="1",b!~"')
		expect(S.list(neg.kind, neg.label, neg.op, neg.prefix)).toEqual(S.list("label_value", "b", "!~", ""))
		local ne = at('x{ env != "p')
		expect(S.list(ne.kind, ne.label, ne.op)).toEqual(S.list("label_value", "env", "!="))
	end)

	it("offers quoted values right after an operator with no quote yet", function()
		local c = at("up{job=")
		expect(c.kind).toBe("label_value")
		expect(c.quote).toBeNil()
	end)

	it("knows a closed matcher value is done", function()
		expect(at('up{job="node"').kind).toBe("none")
		expect(kindPrefix('up{job="node"} o')).toEqual({ "expr", "o" })
	end)

	it("does not suggest inside strings that are not matcher values", function()
		expect(at('count_values("ver').kind).toBe("none")
		expect(at('label_replace(up, "dst", "$1", "src", "(.*').kind).toBe("none")
	end)

	it("handles escaped quotes in finished values", function()
		local c = at('x{a="q\\"x", b')
		expect(c.kind).toBe("label_name")
		expect(c.used).toEqual({ "a" })
	end)

	it("offers labels inside grouping clauses, not metrics", function()
		local cases = {
			"sum by (jo",
			"sum(rate(x[5m])) by (in",
			"avg without(instance, mo",
			"a / on(jo",
			"a * ignoring (cp",
			"a * on(job) group_left(ver",
		}
		for _, text in cases do
			expect(at(text).kind).toBe("grouping")
		end
		local c = at("avg without(instance, mo")
		expect(c.prefix).toBe("mo")
		expect(c.used).toEqual({ "instance" })
	end)

	it("returns to expressions after a grouping clause closes", function()
		expect(kindPrefix("sum by (job) (rat")).toEqual({ "expr", "rat" })
	end)

	it("offers durations inside range brackets", function()
		expect(kindPrefix("rate(x[")).toEqual({ "duration", "" })
		expect(kindPrefix("rate(x[5")).toEqual({ "duration", "5" })
		expect(kindPrefix("rate(x[$__ra")).toEqual({ "duration", "$__ra" })
		expect(kindPrefix("max_over_time(rate(x[1m])[1h:")).toEqual({ "duration", "" })
	end)

	it("uses only the text before the caret", function()
		local c = at("rate(node_|cpu_seconds_total[5m])")
		expect(S.list(c.kind, c.prefix, c.from)).toEqual(S.list("expr", "node_", 5))
		local v = at('up{job="|"}')
		expect(S.list(v.kind, v.prefix)).toEqual(S.list("label_value", ""))
	end)

	it("ignores comments", function()
		expect(at("# a comment with node_").kind).toBe("none")
		expect(kindPrefix("# note\nnode_")).toEqual({ "expr", "node_" })
	end)
end)

return nil
