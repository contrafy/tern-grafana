--!strict
-- Variable interpolation must match Grafana's TemplateSrv: a dashboard query
-- runs against the same datasource Grafana would query, so any difference in
-- escaping or format changes which series a panel shows. The format table is
-- Grafana's documented example (servers = test1, test2).
local Interpolate = require("../../../plugin/lib/dashboard/interpolate")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local servers: Interpolate.Var = { values = { "test1", "test2" }, multi = true }
local scope: Interpolate.Scope = { servers = servers }

local function fmt(f: string): string
	return Interpolate.replace("${servers:" .. f .. "}", scope)
end

describe("interpolate formats (Grafana's variable syntax docs)", function()
	it("formats a multi-value selection per format id", function()
		expect(fmt("csv")).toBe("test1,test2")
		expect(fmt("doublequote")).toBe('"test1","test2"')
		expect(fmt("glob")).toBe("{test1,test2}")
		expect(fmt("json")).toBe('["test1","test2"]')
		expect(fmt("lucene")).toBe('("test1" OR "test2")')
		expect(fmt("percentencode")).toBe("test1%2Ctest2")
		expect(fmt("pipe")).toBe("test1|test2")
		expect(fmt("raw")).toBe("test1,test2")
		expect(fmt("regex")).toBe("(test1|test2)")
		expect(fmt("singlequote")).toBe("'test1','test2'")
		expect(fmt("sqlstring")).toBe("'test1','test2'")
		expect(fmt("text")).toBe("test1 + test2")
		expect(fmt("queryparam")).toBe("var-servers=test1&var-servers=test2")
	end)

	it("escapes single values the way each format needs", function()
		local s: Interpolate.Scope = { v = { values = { "a.b'c (x)" } } }
		expect(Interpolate.replace("${v:regex}", s)).toBe("a\\.b'c \\(x\\)")
		expect(Interpolate.replace("${v:sqlstring}", s)).toBe("'a.b''c (x)'")
		expect(Interpolate.replace("${v:singlequote}", s)).toBe("'a.b\\'c (x)'")
		expect(Interpolate.replace("${v:percentencode}", s)).toBe("a.b%27c%20%28x%29")
		expect(Interpolate.replace("${v:lucene}", s)).toBe("a.b'c\\ \\(x\\)")
		expect(Interpolate.replace("${v:json}", { v = { values = { 'say "hi"' } } })).toBe('"say \\"hi\\""')
	end)

	it("supports $x, ${x}, [[x]] and [[x:fmt]], leaving unknown names alone", function()
		local s: Interpolate.Scope = { job = { values = { "node" } }, i = { values = { "5m" } } }
		expect(Interpolate.replace('up{job="$job"}[$i] [[job]] [[job:regex]] ${job}x', s)).toBe(
			'up{job="node"}[5m] node node nodex'
		)
		expect(Interpolate.replace("rate(x[$__rate_interval]) $jobs ${nope:csv}", s)).toBe(
			"rate(x[$__rate_interval]) $jobs ${nope:csv}"
		)
	end)
end)

describe("interpolate Prometheus formatting", function()
	local fmtOpts = { format = Interpolate.prometheus }

	it("regex-escapes multi-value and include-all variables into an alternation", function()
		local s: Interpolate.Scope = {
			mode = { values = { "user", "system" }, multi = true, include_all = true },
			handler = { values = { "/api/v1/query" }, multi = true },
		}
		expect(Interpolate.replace('{mode=~"$mode"}', s, fmtOpts)).toBe('{mode=~"(user|system)"}')
		-- One value of a multi variable is still an escaped regex, without parentheses.
		expect(Interpolate.replace('{h=~"$handler"}', s, fmtOpts)).toBe('{h=~"/api/v1/query"}')
		local dotted: Interpolate.Scope = { h = { values = { "a.b" }, multi = true } }
		expect(Interpolate.replace("$h", dotted, fmtOpts)).toBe("a\\\\.b")
	end)

	it("keeps plain values for a single-value variable (only quotes are escaped)", function()
		local s: Interpolate.Scope = { handler = { values = { "/api/v1/.*" } }, q = { values = { "it's" } } }
		expect(Interpolate.replace('{handler=~"$handler"}', s, fmtOpts)).toBe('{handler=~"/api/v1/.*"}')
		expect(Interpolate.replace("$q", s, fmtOpts)).toBe("it\\\\'s")
	end)

	it("uses a custom all value raw and expands All without one", function()
		local withAllValue: Interpolate.Scope =
			{ job = { values = { "a", "b" }, multi = true, include_all = true, is_all = true, all_value = ".*" } }
		expect(Interpolate.replace('{job=~"$job"}', withAllValue, fmtOpts)).toBe('{job=~".*"}')
		expect(Interpolate.replace("${job:text}", withAllValue)).toBe("All")
		expect(Interpolate.replace("${job:queryparam}", withAllValue)).toBe("var-job=$__all")
		local expanded: Interpolate.Scope =
			{ job = { values = { "a", "b" }, multi = true, include_all = true, is_all = true } }
		expect(Interpolate.replace('{job=~"$job"}', expanded, fmtOpts)).toBe('{job=~"(a|b)"}')
	end)

	it("formats a repeated copy's single value as that value, not a list", function()
		local s: Interpolate.Scope = { job = { values = { "node" }, multi = true, include_all = true, single = true } }
		expect(Interpolate.replace("${job:glob} ${job:json}", s)).toBe('node "node"')
	end)
end)

describe("interpolate built-ins", function()
	local b = Interpolate.builtins({
		from_ms = 1791576000000,
		to_ms = 1791579600000,
		interval_ms = 5000,
		interval = "5s",
		dashboard_title = "Tern Panels",
		dashboard_uid = "tern-panels",
		org_id = 1,
		user_login = "admin",
	})

	it("provides the range, interval and dashboard values", function()
		expect(Interpolate.replace("$__interval $__interval_ms $__range $__range_s $__range_ms", b)).toBe(
			"5s 5000 3600s 3600 3600000"
		)
		expect(Interpolate.replace("${__dashboard} ${__dashboard.uid} ${__org} ${__user.login}", b)).toBe(
			"Tern Panels tern-panels 1 admin"
		)
	end)

	it("formats $__from and $__to as epoch ms, ISO dates and seconds", function()
		expect(Interpolate.replace("$__from ${__to}", b)).toBe("1791576000000 1791579600000")
		expect(Interpolate.replace("${__from:date} ${__from:date:iso}", b)).toBe(
			"2026-10-09T20:00:00.000Z 2026-10-09T20:00:00.000Z"
		)
		expect(Interpolate.replace("${__to:date:seconds}", b)).toBe("1791579600")
	end)

	it("lists referenced names once, in order", function()
		expect(Interpolate.references('label_values(up{job=~"$job", x="${inst:regex}"}, [[job]])')).toEqual({
			"job",
			"inst",
		})
	end)
end)

return nil
