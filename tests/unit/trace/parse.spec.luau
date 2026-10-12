--!strict
-- Spans must read the same whichever way they arrive: Tempo's protobuf JSON
-- (base64 ids, nanosecond times as decimal strings), its v2 envelope, plain
-- OTLP JSON (hex ids, numeric enums, the older instrumentationLibrarySpans),
-- or Grafana's Trace data frame. Ids are compared across all of them (links,
-- search hits, the `span` link parameter), so they normalize to one form, and
-- nanosecond times must stay exact: a double rounds an epoch in nanoseconds
-- to 256 ns, which would make back-to-back spans overlap.
local Fixtures = require("../../lib/fixtures")
local FrameGrafana = require("../../../plugin/lib/frame/grafana")
local Ids = require("../../../plugin/lib/trace/ids")
local Nanos = require("../../../plugin/lib/trace/nanos")
local Otlp = require("../../../plugin/lib/trace/otlp")
local TraceFrame = require("../../../plugin/lib/trace/frame")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null } :: any

local TRACE = "0082c9f1c2bda850d878e52762cc0816"
local ROOT, FIRST, SECOND = "fd222e3b400b8c5e", "a0f1187d5c9dc4d6", "93f869ac82c50e2b"

local function byName(spans: { any }): { [string]: any }
	local out: { [string]: any } = {}
	for _, s in spans do
		out[s.name] = s
	end
	return out
end

describe("trace ids", function()
	it("turns Tempo's base64 ids into the hex everything else uses", function()
		expect(Ids.trace("AILJ8cK9qFDYeOUnYswIFg==")).toBe(TRACE)
		expect(Ids.span("/SIuO0ALjF4=")).toBe(ROOT)
		expect(Ids.span("oPEYfVydxNY=")).toBe(FIRST)
	end)

	it("pads short hex ids and lowercases them", function()
		expect(Ids.trace("82C9F1C2BDA850D878E52762CC0816")).toBe(TRACE)
		expect(Ids.short(TRACE)).toBe("82c9f1c2bda850d878e52762cc0816")
	end)

	it("reads an empty or all-zero parent as no parent, and rejects junk", function()
		expect(Ids.span("")).toBeNil()
		expect(Ids.span("AAAAAAAAAAA=")).toBeNil()
		expect(Ids.span("0000000000000000")).toBeNil()
		expect(Ids.span("not an id!")).toBeNil()
		expect(Ids.span(string.rep("a", 17))).toBeNil()
	end)
end)

describe("nanosecond times", function()
	it("keeps decimal epoch nanoseconds exact", function()
		local a = Nanos.parse("1791577563622704346") :: any
		local b = Nanos.parse("1791577563742704346") :: any
		expect(a).toEqual({ sec = 1791577563, nsec = 622704346 })
		expect(Nanos.diff(b, a)).toBe(120000000)
		expect(Nanos.diff(Nanos.add(a, 1500000001), a)).toBe(1500000001)
		expect(Nanos.parse("12")).toEqual({ sec = 0, nsec = 12 })
		expect(Nanos.parse("-5")).toBeNil()
	end)

	it("converts Grafana's fractional milliseconds", function()
		local t0 = Nanos.fromMs(1791577563622.7043)
		expect(t0.sec).toBe(1791577563)
		expect(math.abs(t0.nsec - 622704300) < 1000).toBe(true)
	end)
end)

describe("OTLP JSON", function()
	it("reads Tempo's batches: resource service, scope, ids, kinds, status, attributes", function()
		local spans = Otlp.parse(json.decode(Fixtures.read("tempo/2.10.8/trace.json")), env) :: { any }
		expect(#spans).toBe(3)
		local s = byName(spans)
		local root, first = s["lets-go"], s["okey-dokey-0"]
		expect(root.trace_id).toBe(TRACE)
		expect(root.span_id).toBe(ROOT)
		expect(root.parent_id).toBeNil()
		expect(root.kind).toBe("client")
		expect(root.status).toBe("error")
		expect(root.service).toBe("payments")
		expect(root.scope).toBe("telemetrygen")
		expect(root.resource).toEqual({ { key = "service.name", value = "payments", kind = "string" } })
		expect(first.parent_id).toBe(ROOT)
		expect(first.kind).toBe("server")
		expect(first.attributes).toEqual({
			{ key = "network.peer.address", value = "1.2.3.4", kind = "string" },
			{ key = "service.peer.name", value = "telemetrygen-client", kind = "string" },
		})
		expect(Nanos.diff(first.stop, first.start)).toBe(120000000)
		expect(Nanos.diff(s["okey-dokey-1"].start, root.start)).toBe(120000000)
	end)

	it("reads the v2 envelope the same way", function()
		local v1 = Otlp.parse(json.decode(Fixtures.read("tempo/2.10.8/trace.json")), env)
		local v2 = Otlp.parse(json.decode(Fixtures.read("tempo/2.10.8/trace_v2.json")), env)
		expect(v2).toEqual(v1)
	end)

	it("reads plain OTLP JSON: hex ids, numeric enums, events, links, typed values", function()
		local doc = json.decode([[{"resourceSpans":[{"resource":{"attributes":[
			{"key":"service.name","value":{"stringValue":"api"}},
			{"key":"host.name","value":{"stringValue":"web-1"}}]},
			"instrumentationLibrarySpans":[{"instrumentationLibrary":{"name":"otel-go","version":"1.2"},"spans":[
			{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174",
			 "parentSpanId":"","name":"GET /users","kind":2,
			 "startTimeUnixNano":"1544712660000000000","endTimeUnixNano":"1544712661000000000",
			 "status":{"code":2,"message":"boom"},
			 "attributes":[{"key":"http.status_code","value":{"intValue":"500"}},
			   {"key":"ok","value":{"boolValue":false}},
			   {"key":"ratio","value":{"doubleValue":0.5}},
			   {"key":"tags","value":{"arrayValue":{"values":[{"stringValue":"a"},{"intValue":"2"}]}}}],
			 "events":[{"timeUnixNano":"1544712660500000000","name":"exception",
			   "attributes":[{"key":"exception.message","value":{"stringValue":"nil map"}}]}],
			 "links":[{"traceId":"0af7651916cd43dd8448eb211c80319c","spanId":"b7ad6b7169203331"}]}]}]}]}]])
		local spans = Otlp.parse(doc, env) :: { any }
		expect(#spans).toBe(1)
		local s = spans[1]
		expect(s.parent_id).toBeNil()
		expect(s.kind).toBe("server")
		expect(s.status).toBe("error")
		expect(s.status_message).toBe("boom")
		expect(s.scope).toBe("otel-go")
		expect(s.scope_version).toBe("1.2")
		expect(s.attributes).toEqual({
			{ key = "http.status_code", value = "500", kind = "number" },
			{ key = "ok", value = "false", kind = "boolean" },
			{ key = "ratio", value = "0.5", kind = "number" },
			{ key = "tags", value = '["a", 2]', kind = "other" },
		})
		expect(#s.events).toBe(1)
		expect(s.events[1].name).toBe("exception")
		expect(Nanos.diff(s.events[1].time, s.start)).toBe(500000000)
		expect(s.links).toEqual({
			{ trace_id = "0af7651916cd43dd8448eb211c80319c", span_id = "b7ad6b7169203331", attributes = {} },
		})
	end)

	it("says why a document is not a trace", function()
		local spans, why = Otlp.parse(json.decode('{"status":"success"}'), env)
		expect(spans).toBeNil()
		expect(why).toContain("not an OTLP trace")
		expect((Otlp.parse(json.decode('{"batches":[]}'), env))).toEqual({})
	end)
end)

describe("Grafana Trace frame", function()
	it("reads the same spans as Tempo's own answer", function()
		for _, v in { "11.6.16", "12.4.12" } do
			local doc = json.decode(Fixtures.read("grafana/" .. v .. "/ds_query_tempo_trace.json"))
			local frame = FrameGrafana.frames(doc.results.A.frames, env)[1]
			local spans = TraceFrame.spans(frame, env) :: { any }
			expect(#spans).toBe(3)
			local s = byName(spans)
			expect(s["lets-go"].span_id).toBe(ROOT)
			expect(s["lets-go"].parent_id).toBeNil()
			expect(s["lets-go"].kind).toBe("client")
			expect(s["okey-dokey-0"].parent_id).toBe(ROOT)
			expect(s["okey-dokey-1"].span_id).toBe(SECOND)
			expect(s["okey-dokey-1"].status).toBe("error")
			expect(s["okey-dokey-1"].scope).toBe("telemetrygen")
			expect(s["okey-dokey-1"].resource).toEqual({ { key = "service.name", value = "payments", kind = "string" } })
			expect(s["okey-dokey-1"].attributes[2]).toEqual({
				key = "service.peer.name",
				value = "telemetrygen-client",
				kind = "string",
			})
			expect(Nanos.diff(s["lets-go"].stop, s["lets-go"].start)).toBe(240000000)
		end
	end)

	it("ignores frames that are not traces", function()
		expect(TraceFrame.spans({ name = "Traces", fields = {} } :: any, env)).toBeNil()
	end)
end)

return nil
