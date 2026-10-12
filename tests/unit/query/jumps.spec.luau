--!strict
-- `L` and `enter` leave a chart for logs and traces. What matters: the logs
-- selector keeps only labels that also exist on log streams (the configured
-- correlation list, in its order), the link keeps the context and the range,
-- and an exemplar without a usable trace id says so instead of opening junk.
local Jumps = require("../../../plugin/lib/query/jumps")
local Frame = require("../../../plugin/lib/frame/types")
local Scheme = require("../../../plugin/lib/links/scheme")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NAMES = Jumps.correlateLabels(nil)

local function params(link: string?): { [string]: string }
	local l = Scheme.decode(link :: string)
	return (l :: Scheme.Link).params
end

describe("Jumps.logsLink", function()
	it("builds a LogQL selector from the series labels kept to logs.correlate_labels", function()
		local link = Jumps.logsLink(
			"lab",
			{ __name__ = "up", job = "node", instance = "node-exporter:9100", le = "0.5", mode = "idle" },
			NAMES,
			"now-1h",
			"now"
		)
		local p = params(link)
		expect(p.expr).toBe('{job="node",instance="node-exporter:9100"}')
		expect(p.context).toBe("lab")
		expect(p.from).toBe("now-1h")
		expect(p.to).toBe("now")
	end)

	it("escapes values and follows the configured order", function()
		local p = params((Jumps.logsLink("lab", { app = 'a"b', namespace = "ns" }, { "namespace", "app" }, "1", "2")))
		expect(p.expr).toBe('{namespace="ns",app="a\\"b"}')
	end)

	it("explains when no label correlates", function()
		local link, err = Jumps.logsLink("lab", { le = "0.5" }, NAMES, "now-1h", "now")
		expect(link).toBeNil()
		expect(err).toContain("none of the labels")
	end)
end)

describe("Jumps.commonLabels", function()
	it("keeps the labels every series shares", function()
		local frames = {
			Frame.timeSeries({ job = "node", instance = "a", mode = "idle" }, { 1 }, { 1 }),
			Frame.timeSeries({ job = "node", instance = "b", mode = "idle" }, { 1 }, { 2 }),
		}
		expect(Jumps.commonLabels(frames)).toEqual({ job = "node", mode = "idle" })
		expect(Jumps.commonLabels({})).toEqual({})
	end)
end)

describe("Jumps.traceLink", function()
	local function ex(labels: { [string]: string }): any
		return { time_ms = 1, value = 1, labels = labels, series = {} }
	end

	it("opens the trace block on the exemplar's trace id in the same context", function()
		local p = params((Jumps.traceLink("lab", ex({ traceID = "3E5DFA736ABF8D76554DF10772603F10" }))))
		expect(p).toEqual({ context = "lab", id = "3e5dfa736abf8d76554df10772603f10" })
	end)

	it("uses the configured label first", function()
		local p = params((Jumps.traceLink("lab", ex({ otel_trace = "abcd", traceID = "ef01" }), "otel_trace")))
		expect(p.id).toBe("abcd")
	end)

	it("refuses exemplars without a trace id or with one that is not hex", function()
		local link, err = Jumps.traceLink("lab", ex({ span = "x" }))
		expect(link).toBeNil()
		expect(err).toContain("no trace id")
		local bad, why = Jumps.traceLink("lab", ex({ trace_id = "not-a-trace" }))
		expect(bad).toBeNil()
		expect(why).toContain("Not a trace id")
	end)
end)

return nil
