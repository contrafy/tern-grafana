--!strict
-- Chip clicks edit the user's LogQL in place: an indexed label belongs in the
-- stream selector (Loki reads fewer streams), anything else is a label filter
-- stage (structured metadata and parsed fields do not exist in the selector).
-- A second click on the same chip removes the filter, the opposite chip flips
-- it, and the rest of the query is never rewritten.
local LogQL = require("../../../plugin/lib/logs/logql")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("stream selector", function()
	it("finds matchers with every operator and both quote styles", function()
		local m = LogQL.matchers('{app="api", level!="debug", pod=~`web-.*`, ns!~"kube.*"} |= "}"')
		local got = {}
		for _, x in m do
			table.insert(got, x.name .. x.op .. x.value)
		end
		expect(got).toEqual({ "app=api", "level!=debug", "pod=~web-.*", "ns!~kube.*" })
	end)

	it("adds an include matcher before the closing brace", function()
		expect((LogQL.filter('{job="loggen"} |= "x"', "level", "error", false, true))).toBe(
			'{job="loggen", level="error"} |= "x"'
		)
	end)

	it("removes the matcher on a second click", function()
		local once = LogQL.filter('{job="loggen"}', "app", "checkout", false, true)
		expect((LogQL.filter(once, "app", "checkout", false, true))).toBe('{job="loggen"}')
		expect((LogQL.filter('{app="checkout", job="loggen"}', "app", "checkout", false, true))).toBe('{job="loggen"}')
	end)

	it("flips an include into an exclude in place", function()
		expect((LogQL.filter('{job="loggen", app="a"} | json', "app", "a", true, true))).toBe(
			'{job="loggen", app!="a"} | json'
		)
	end)

	it("refuses to empty the selector", function()
		local expr, err = LogQL.filter('{app="a"}', "app", "a", false, true)
		expect(expr).toBe('{app="a"}')
		expect(err).toBe("a stream selector needs at least one matcher")
	end)

	it("escapes values as LogQL strings", function()
		expect((LogQL.filter('{a="b"}', "msg", 'say "hi"\\', false, true))).toBe('{a="b", msg="say \\"hi\\"\\\\"}')
		local m = LogQL.matchers('{a="b", msg="say \\"hi\\"\\\\"}')
		expect(m[2].value).toBe('say "hi"\\')
	end)
end)

describe("label filter stages", function()
	it("appends a stage for structured metadata and parsed fields", function()
		expect((LogQL.filter('{app="checkout"} | logfmt', "detected_level", "info", false, false))).toBe(
			'{app="checkout"} | logfmt | detected_level = "info"'
		)
	end)

	it("removes and flips the stage it added", function()
		local on = LogQL.filter('{app="c"} | json', "upstream", "bank", false, false)
		expect((LogQL.filter(on, "upstream", "bank", false, false))).toBe('{app="c"} | json')
		expect((LogQL.filter(on, "upstream", "bank", true, false))).toBe('{app="c"} | json | upstream != "bank"')
	end)

	it("does not mistake a longer stage value for the chip's", function()
		local expr = '{a="b"} | x = "1" | x = "10"'
		expect(LogQL.hasStage(expr, "x", "=", "1")).toBe(true)
		expect((LogQL.filter('{a="b"} | x = "10"', "x", "1", false, false))).toBe('{a="b"} | x = "10" | x = "1"')
	end)

	it("leaves metric queries alone", function()
		local q = 'sum(count_over_time({a="b"}[1m]))'
		local expr, err = LogQL.filter(q, "a", "b", false, true)
		expect(expr).toBe(q)
		expect(err).toBe("filters apply to log queries")
	end)
end)

describe("volume query", function()
	it("counts the query's lines per level over the bucket", function()
		expect(LogQL.volume(' {job="loggen"} |= "x" ', "level, detected_level", "1m")).toBe(
			'sum by (level, detected_level) (count_over_time({job="loggen"} |= "x" [1m]))'
		)
	end)

	it("tells log queries from metric queries", function()
		expect(LogQL.isMetric('{a="b"}')).toBe(false)
		expect(LogQL.isMetric('rate({a="b"}[1m])')).toBe(true)
	end)
end)

describe("suggestions", function()
	it("completes label names inside the selector", function()
		local ctx: any = LogQL.context("{ap", 3)
		expect(ctx.kind).toBe("label")
		expect(ctx.prefix).toBe("ap")
		local items = LogQL.items(ctx, { "app", "env", "job" }, 10)
		expect(#items).toBe(1)
		local text, cursor = LogQL.apply("{ap", ctx, items[1])
		expect(text).toBe("{app=")
		expect(cursor).toBe(5)
	end)

	it("completes values after an operator, quoted, replacing a typed prefix", function()
		local ctx: any = LogQL.context('{app="ch"}', 8)
		expect(ctx.kind).toBe("value")
		expect(ctx.label).toBe("app")
		expect(ctx.prefix).toBe("ch")
		local items = LogQL.items(ctx, { "checkout", "frontend" }, 10)
		expect(#items).toBe(1)
		local text, cursor = LogQL.apply('{app="ch"}', ctx, items[1])
		expect(text).toBe('{app="checkout"}')
		expect(cursor).toBe(15)
		local bare: any = LogQL.context("{app=", 5)
		expect(bare.kind).toBe("value")
		expect((LogQL.apply("{app=", bare, LogQL.items(bare, { "api" }, 10)[1]))).toBe('{app="api"')
	end)

	it("suggests parsers after a pipe, but not inside line filters", function()
		local ctx: any = LogQL.context('{a="b"} | lo', 12)
		expect(ctx.kind).toBe("pipe")
		expect(LogQL.items(ctx, nil, 10)[1].label).toBe("logfmt")
		expect(LogQL.context('{a="b"} |= "lo', 14).kind).toBe("none")
	end)
end)

return nil
