--!strict
-- Logs reach the Logs block from Loki directly or through Grafana's Loki
-- datasource, and both must produce the same lines: newest first, a level
-- per line, indexed labels apart from structured metadata and parsed fields
-- (filters on them are written differently), and ids that stay equal when
-- the same entry is fetched twice. Requests must match what Loki and
-- Grafana's own editor send, or results differ from Explore.
local Fixtures = require("../../lib/fixtures")
local FrameLoki = require("../../../plugin/lib/frame/loki")
local Http = require("../../../plugin/lib/transport/http")
local Loki = require("../../../plugin/lib/source/loki")
local S = require("./support")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local VERSIONS = { "11.6.16", "12.4.12" }
local FROM_MS = S.START * 1000
local TO_MS = S.END * 1000

local direct = table.clone(S.direct)
direct.signal = "logs"
direct.endpoint_name = "loki"
direct.endpoint = table.clone(S.direct.endpoint)
direct.endpoint.url = "http://127.0.0.1:3100"

local viaGrafana = table.clone(S.datasource)
viaGrafana.signal = "logs"
viaGrafana.datasource_uid = "loki"

local function url(route: any, request: any): string
	return Http.url(route.endpoint, request)
end

local function recorded(path: string): string
	return direct.endpoint.url .. S.row(path).url
end

local function parse(route: any, path: string): any
	return Loki.parse(route, S.response(path), S.env)
end

describe("direct requests", function()
	it("asks for log lines newest first with a limit, as recorded", function()
		local req =
			Loki.rangeRequest(direct, { expr = '{job="loggen"}', from_ms = FROM_MS, to_ms = TO_MS, limit = 50 }, S.env)
		expect(req.method).toBe("GET")
		expect(url(direct, req)).toBe(recorded("loki/3.7.8/query_range_streams.json"))
	end)

	it("sends direction only when it is forward (backward is Loki's default)", function()
		local req = Loki.rangeRequest(direct, {
			expr = '{app="payments"}',
			from_ms = FROM_MS,
			to_ms = TO_MS,
			limit = 20,
			direction = "forward",
		}, S.env)
		expect(url(direct, req)).toBe(recorded("loki/3.7.8/query_range_streams_forward.json"))
	end)

	it("sends a step for metric queries", function()
		local req = Loki.rangeRequest(direct, {
			expr = 'sum by (level) (count_over_time({job="loggen"}[1m]))',
			from_ms = FROM_MS,
			to_ms = TO_MS,
			step_ms = 60000,
		}, S.env)
		expect(url(direct, req)).toBe(recorded("loki/3.7.8/query_range_matrix.json"))
	end)

	it("asks Loki to keep structured metadata and parsed labels apart", function()
		local req = Loki.rangeRequest(direct, { expr = '{a="b"}', from_ms = 0, to_ms = 1 }, S.env)
		expect((req.headers :: any)["X-Loki-Response-Encoding-Flags"]).toBe("categorize-labels")
	end)

	it("lists label names and values over the range", function()
		local opts = { from_ms = FROM_MS, to_ms = TO_MS }
		expect(url(direct, Loki.labelsRequest(direct, opts))).toBe(recorded("loki/3.7.8/labels.json"))
		expect(url(direct, Loki.labelValuesRequest(direct, "level", opts))).toBe(
			recorded("loki/3.7.8/label_values_level.json")
		)
	end)
end)

describe("requests through Grafana", function()
	it("sends the log target Grafana's Loki editor sends", function()
		local req = Loki.rangeRequest(viaGrafana, {
			expr = '{job="loggen"}',
			from_ms = 1000,
			to_ms = 2000,
			limit = 50,
			direction = "backward",
		}, S.env)
		expect(req.method).toBe("POST")
		expect(req.path).toBe("/api/ds/query")
		local body = json.decode(req.body :: string)
		for _, v in VERSIONS do
			local want = json.decode(Fixtures.read("grafana/" .. v .. "/ds_query_loki_logs.request.json"))
			expect(body.queries[1]).toEqual(want.queries[1])
		end
		expect({ body.from, body.to }).toEqual({ "1000", "2000" })
	end)

	it("sends metric targets with Grafana's interval and point budget", function()
		local req = Loki.rangeRequest(viaGrafana, {
			expr = 'sum by (level) (count_over_time({job="loggen"}[1m]))',
			from_ms = 1000,
			to_ms = 2000,
			step_ms = 60000,
			max_points = 200,
			legend = "{{level}}",
		}, S.env)
		local q = json.decode(req.body :: string).queries[1]
		local want = json.decode(Fixtures.read("grafana/12.4.12/ds_query_loki_metric.request.json")).queries[1]
		for k, value in want do
			expect({ [k] = q[k] }).toEqual({ [k] = value })
		end
	end)

	it("lists labels through the datasource proxy", function()
		expect(Loki.labelsRequest(viaGrafana).path).toBe("/api/datasources/proxy/uid/loki/loki/api/v1/labels")
		expect(Loki.labelValuesRequest(viaGrafana, "app").path).toBe(
			"/api/datasources/proxy/uid/loki/loki/api/v1/label/app/values"
		)
	end)
end)

local function isNewestFirst(lines: { any }): boolean
	for i = 2, #lines do
		if FrameLoki.compareNs(lines[i - 1].ts_ns, lines[i].ts_ns) < 0 then
			return false
		end
	end
	return true
end

describe("direct log results", function()
	it("merges every stream into one newest-first list with a level per line", function()
		local r = parse(direct, "loki/3.7.8/query_range_streams.json")
		expect(r.ok).toBe(true)
		expect(r.kind).toBe("streams")
		expect(#r.lines).toBe(50)
		expect(isNewestFirst(r.lines)).toBe(true)
		local levels: { [string]: number } = {}
		for _, l in r.lines do
			levels[l.level] = (levels[l.level] or 0) + 1
		end
		expect(levels).toEqual({ debug = 11, info = 26, error = 2, warning = 11 })
	end)

	it("keeps lines that share a timestamp and text but not a stream apart", function()
		local r = parse(direct, "loki/3.7.8/query_range_streams.json")
		local ids: { [string]: boolean } = {}
		for _, l in r.lines do
			expect(ids[l.id]).toBeNil()
			ids[l.id] = true
		end
		-- checkout info and frontend info both log at the newest second.
		expect(r.lines[1].ts_ns).toBe(r.lines[2].ts_ns)
	end)

	it("returns lines oldest first when asked forward, still sorted newest first", function()
		local r = parse(direct, "loki/3.7.8/query_range_streams_forward.json")
		expect(#r.lines).toBe(20)
		expect(isNewestFirst(r.lines)).toBe(true)
	end)

	it("separates stream labels, structured metadata and parsed fields when categorized", function()
		local r = parse(direct, "loki/3.7.8/query_range_streams_categorized.json")
		expect(#r.lines).toBe(20)
		local info
		for _, l in r.lines do
			if l.labels.level == "info" then
				info = l
				break
			end
		end
		expect(info.categorized).toBe(true)
		expect(info.labels).toEqual({
			app = "checkout",
			env = "dev",
			job = "loggen",
			level = "info",
			service_name = "checkout",
		})
		expect(info.metadata).toEqual({ detected_level = "info" })
		expect(info.parsed.level_extracted).toBe("info")
		expect(info.parsed.msg).toBe("order placed")
		expect(#info.parsed.trace_id).toBe(32)
		expect(info.level).toBe("info")
	end)

	it("keeps parsed labels among the stream labels when the server did not categorize", function()
		local r = parse(direct, "loki/3.7.8/query_range_streams_logfmt.json")
		local l = r.lines[1]
		expect(l.categorized).toBe(false)
		expect(l.labels.msg).toBe("order placed")
		expect((next(l.parsed))).toBeNil()
	end)

	it("hands direct lines to frame consumers in Grafana's Loki frame shape", function()
		local r = parse(direct, "loki/3.7.8/query_range_streams_categorized.json")
		local frame = r.frames[1]
		expect(frame.meta.custom.frameType).toBe("LabeledTimeValues")
		local back = FrameLoki.fromFrames(r.frames, S.env)
		expect(#back).toBe(#r.lines)
		for i, l in back do
			local want = r.lines[i]
			expect({ id = l.id, labels = l.labels, metadata = l.metadata, parsed = l.parsed }).toEqual({
				id = want.id,
				labels = want.labels,
				metadata = want.metadata,
				parsed = want.parsed,
			})
		end
	end)
end)

describe("direct metric results", function()
	it("reads a matrix as one series per level", function()
		local r = parse(direct, "loki/3.7.8/query_range_matrix.json")
		expect(r.ok).toBe(true)
		expect(r.kind).toBe("matrix")
		expect(#r.lines).toBe(0)
		local levels: { string } = {}
		for _, f in r.frames do
			table.insert(levels, f.fields[2].labels.level)
		end
		expect(levels).toEqual({ "debug", "error", "info", "warn" })
		expect(r.frames[1].fields[1].values[1]).toBe(1791577020000)
		expect(r.frames[1].fields[2].values[1]).toBe(23)
	end)

	it("reads an instant vector", function()
		local r = parse(direct, "loki/3.7.8/query_vector.json")
		expect(r.kind).toBe("vector")
		expect(#r.frames).toBe(3)
	end)

	it("reports Loki's parse error as a query error", function()
		local r: any = Loki.parse(direct, {
			status = S.row("loki/3.7.8/query_error.txt").status,
			headers = { ["Content-Type"] = "text/plain" },
			body = Fixtures.read("loki/3.7.8/query_error.txt"),
			timed_out = false,
		}, S.env)
		expect(r.ok).toBe(false)
		expect(r.error.kind).toBe("query")
		expect(r.error.status).toBe(400)
		expect(r.error.message).toBe("parse error at line 1, col 14: syntax error: unexpected $end, expecting } or ,")
	end)
end)

for _, v in VERSIONS do
	describe("Grafana " .. v .. " results", function()
		it("reads Loki log frames into the same lines, metadata apart", function()
			local r: any = Loki.parse(viaGrafana, S.response("grafana/" .. v .. "/ds_query_loki_logs.json"), S.env)
			expect(r.ok).toBe(true)
			expect(r.kind).toBe("streams")
			expect(#r.lines).toBe(50)
			expect(isNewestFirst(r.lines)).toBe(true)
			local l = r.lines[1]
			expect(l.categorized).toBe(true)
			expect(l.labels.detected_level).toBeNil()
			expect(l.metadata.detected_level).toBe(l.labels.level)
			expect(l.level ~= "unknown").toBe(true)
			expect(#l.ts_ns).toBe(19)
		end)

		it("reads Loki metric frames as series", function()
			local r: any = Loki.parse(viaGrafana, S.response("grafana/" .. v .. "/ds_query_loki_metric.json"), S.env)
			expect(r.ok).toBe(true)
			expect(r.kind).toBe("matrix")
			expect(#r.lines).toBe(0)
			expect(#r.frames).toBe(4)
		end)
	end)
end

describe("label lists", function()
	it("reads label names and values sorted", function()
		local r: any = Loki.parseList(direct, S.response("loki/3.7.8/labels.json"), S.env)
		expect(r.values).toEqual({ "app", "env", "job", "level", "service_name" })
		local v: any = Loki.parseList(direct, S.response("loki/3.7.8/label_values_level.json"), S.env)
		expect(v.values).toEqual({ "debug", "error", "info", "warn" })
	end)
end)

describe("line ids", function()
	it("are stable for the same entry and differ for another stream", function()
		expect(FrameLoki.hash("abc")).toBe(FrameLoki.hash("abc"))
		expect(FrameLoki.hash("abc") ~= FrameLoki.hash("abd")).toBe(true)
		-- FNV-1a 32 reference values.
		expect(FrameLoki.hash("")).toBe("811c9dc5")
		expect(FrameLoki.hash("a")).toBe("e40c292c")
		expect(FrameLoki.hash("foobar")).toBe("bf9cf968")
	end)

	it("compare nanosecond timestamps beyond double precision", function()
		expect(FrameLoki.compareNs("1791577897000000001", "1791577897000000000")).toBe(1)
		expect(FrameLoki.compareNs("999", "1000")).toBe(-1)
		expect(FrameLoki.nsToMs("1791577897123456789")).toBe(1791577897123.456789)
	end)
end)

return nil
