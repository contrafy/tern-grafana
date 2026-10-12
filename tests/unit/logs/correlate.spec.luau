--!strict
-- Jumps between logs, metrics and traces hinge on three small pieces: the
-- label selector both query languages read (only the configured correlation
-- labels, values escaped so a quote in a label cannot break the query), the
-- trace id a log line names (structured metadata first, then the line text
-- through a configurable pattern; never a short number that merely follows
-- "trace_id"), and the span-to-logs query template.
local Correlate = require("../../../plugin/lib/logs/correlate")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NAMES = Correlate.DEFAULT_LABELS

-- Lines as loggen writes them (tests/fixtures/loki/3.7.8/query_range_streams_forward.json).
local ERROR_LINE =
	'level=error msg="charge failed" error="card declined" order_id=20 trace_id=f9feca95e64abcfdc9479170b7ad3523'
local DEFAULT = (Correlate.traceMatcher(nil)) :: Correlate.TraceMatcher

describe("selector", function()
	it("keeps only the correlation labels, in their configured order", function()
		local labels = {
			app = "payments",
			detected_level = "error",
			env = "dev",
			job = "loggen",
			level = "error",
			service_name = "payments",
		}
		expect(Correlate.selector(labels, NAMES)).toBe('{job="loggen",service_name="payments",app="payments"}')
		expect(Correlate.selector(labels, { "env", "job" })).toBe('{env="dev",job="loggen"}')
	end)

	it("escapes values for a double-quoted string", function()
		expect(Correlate.selector({ job = 'a"b\\c\nd' }, { "job" })).toBe('{job="a\\"b\\\\c\\nd"}')
	end)

	it("is nil when no correlation label is present or set", function()
		expect(Correlate.selector({ env = "dev", job = "" }, NAMES)).toBeNil()
	end)

	it("reads the equality matchers of a query's stream selector", function()
		local labels = Correlate.selectorLabels('{job="loggen", app=~"pay.*", env!="prod"} |= "x"')
		expect(labels).toEqual({ job = "loggen" })
	end)
end)

describe("trace ids in log lines", function()
	it("finds loggen's trace_id=<hex> in the line text", function()
		expect(Correlate.traceId(ERROR_LINE, {}, {}, nil, DEFAULT)).toBe("f9feca95e64abcfdc9479170b7ad3523")
	end)

	it("reads JSON and colon forms and lowercases the id", function()
		local json = '{"level":"info","traceId":"4BF92F3577B34DA6A3CE929D0E0E4736","msg":"ok"}'
		expect(Correlate.traceId(json, {}, {}, nil, DEFAULT)).toBe("4bf92f3577b34da6a3ce929d0e0e4736")
		expect(Correlate.traceId("TraceID: 00f067aa0ba902b7", {}, {}, nil, DEFAULT)).toBe("00f067aa0ba902b7")
	end)

	it("prefers structured metadata and parsed fields over the text", function()
		local meta = { trace_id = "0af7651916cd43dd8448eb211c80319c" }
		expect(Correlate.traceId(ERROR_LINE, meta, {}, nil, DEFAULT)).toBe("0af7651916cd43dd8448eb211c80319c")
		local parsed = { traceID = "b7ad6b7169203331b7ad6b7169203331" }
		expect(Correlate.traceId("no id here", {}, parsed, nil, DEFAULT)).toBe("b7ad6b7169203331b7ad6b7169203331")
		-- Without label categories parsed fields arrive among the labels.
		local labels = { trace_id = "807c3c5f325956a7b4efa00c66748f91" }
		expect(Correlate.traceId("plain", {}, {}, labels, DEFAULT)).toBe("807c3c5f325956a7b4efa00c66748f91")
	end)

	it("ignores values that are not a 16 to 32 digit hex id", function()
		expect(Correlate.traceId("trace_id=42 done", {}, {}, nil, DEFAULT)).toBeNil()
		expect(Correlate.traceId("order placed order_id=445", {}, {}, nil, DEFAULT)).toBeNil()
		expect(Correlate.traceId("x", { trace_id = "not-hex" }, {}, nil, DEFAULT)).toBeNil()
		expect(Correlate.traceId("trace_id=00000000000000000000000000000000", {}, {}, nil, DEFAULT)).toBeNil()
	end)

	it("uses a configured pattern, its first group being the id", function()
		local custom = (Correlate.traceMatcher([[\btid=([0-9a-f]+)]])) :: Correlate.TraceMatcher
		expect(Correlate.traceId("GET /x tid=0af7651916cd43dd8448eb211c80319c", {}, {}, nil, custom)).toBe(
			"0af7651916cd43dd8448eb211c80319c"
		)
		expect(Correlate.traceId(ERROR_LINE, {}, {}, nil, custom)).toBeNil()
		local whole = (Correlate.traceMatcher("[0-9a-f]{32}")) :: Correlate.TraceMatcher
		expect(Correlate.traceId("req 0af7651916cd43dd8448eb211c80319c ok", {}, {}, nil, whole)).toBe(
			"0af7651916cd43dd8448eb211c80319c"
		)
	end)

	it("reports a pattern that does not compile", function()
		local m, err = Correlate.traceMatcher("trace_id=(")
		expect(m).toBeNil()
		expect(err).toContain("regex")
	end)
end)

describe("span logs query", function()
	it("fills the default template with the span's service and trace id", function()
		local q = Correlate.logsQuery(
			Correlate.DEFAULT_LOGS_QUERY,
			{ service = "checkout", traceId = "82c9f1c2bda850d878e52762cc0816", spanId = "a0f1187d5c9dc4d6" }
		)
		expect(q).toBe('{service_name="checkout"} |= "82c9f1c2bda850d878e52762cc0816"')
	end)

	it("escapes substituted values and leaves unknown references alone", function()
		local q = Correlate.logsQuery('{app="${service}"} |= "${spanId}" ${other}', {
			service = 'we"ird',
			traceId = "x",
			spanId = "a0f1187d5c9dc4d6",
		})
		expect(q).toBe('{app="we\\"ird"} |= "a0f1187d5c9dc4d6" ${other}')
		expect(Correlate.unknownVars("${service} ${trace} ${traceId} ${x}")).toEqual({ "trace", "x" })
	end)

	it("widens the trace by a minute on each side", function()
		local from, to = Correlate.window(1791577000000.4, 1500.2)
		expect(from).toBe(1791577000000 - 60000)
		expect(to).toBe(1791577001501 + 60000)
	end)
end)

return nil
