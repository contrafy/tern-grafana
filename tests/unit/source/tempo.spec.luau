--!strict
-- Tempo must be asked exactly where the servers were recorded answering,
-- directly and through Grafana (/api/ds/query and the datasource proxy), and
-- every recorded answer must read the same way: a trace as spans, a search as
-- traces newest first, tags and values as suggestions. Grafana 11.6 answers
-- every TraceQL search through /api/ds/query with HTTP 500, so that failure
-- must ask for the proxy fallback, while a bad query (HTTP 400) or a missing
-- trace (HTTP 404) must not. Tempo 2.10 and 3.1 answer the same way.
local Fixtures = require("../../lib/fixtures")
local Http = require("../../../plugin/lib/transport/http")
local S = require("./support")
local Tempo = require("../../../plugin/lib/source/tempo")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Capture = {
	tempo: string,
	grafana: { string },
	trace_id: string,
	-- The id as spans carry it: 32 hex digits, Tempo's search may drop leading zeros.
	span_trace_id: string,
	start: number,
	stop: number,
	first_hit: string,
}

-- One capture run each: the Grafanas proxied the Tempo of their run, so they
-- share its trace id and search range.
local CAPTURES: { Capture } = {
	{
		tempo = "tempo/2.10.8/",
		grafana = { "11.6.16", "12.4.12" },
		trace_id = "82c9f1c2bda850d878e52762cc0816",
		span_trace_id = "0082c9f1c2bda850d878e52762cc0816",
		start = S.START,
		stop = S.END,
		first_hit = "458794a8f0dc1a988fe494649848662e",
	},
	{
		tempo = "tempo/3.1.1/",
		grafana = { "13.3.0" },
		trace_id = "2e45191bf0545e5e1225ff9f8e4e468",
		span_trace_id = "02e45191bf0545e5e1225ff9f8e4e468",
		start = 1794238846,
		stop = 1794239746,
		first_hit = "164255f64ce38336a24e7554229ba384",
	},
}

local function endpoint(url: string): any
	return { url = url, auth = { type = "none" }, headers = {}, path_prefix = "", timeout_ms = 15000 }
end

local direct = {
	context = "lab",
	signal = "traces",
	via = "direct",
	endpoint_name = "tempo",
	endpoint = endpoint("http://127.0.0.1:3200"),
} :: any

local datasource = {
	context = "lab",
	signal = "traces",
	via = "datasource",
	endpoint_name = "grafana",
	endpoint = endpoint("http://127.0.0.1:3000"),
	datasource_uid = "tempo",
} :: any

local function url(route: any, request: any): string
	return Http.url(route.endpoint, request)
end

local function recorded(route: any, path: string): string
	return route.endpoint.url .. S.row(path).url
end

local function text(path: string): any
	return {
		status = S.row(path).status,
		headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
		body = Fixtures.read(path),
		timed_out = false,
	}
end

local function search(c: Capture, q: string): any
	return { q = q, limit = 10, from_ms = c.start * 1000, to_ms = c.stop * 1000 }
end

describe("tempo requests", function()
	for _, c in CAPTURES do
		it("asks " .. c.tempo .. " directly at the recorded trace, search and tag URLs", function()
			expect(url(direct, Tempo.traceRequest(direct, "direct", c.trace_id, S.env))).toBe(
				recorded(direct, c.tempo .. "trace.json")
			)
			expect(
				url(
					direct,
					Tempo.searchRequest(direct, "direct", search(c, '{resource.service.name="frontend"}'), S.env)
				)
			).toBe(recorded(direct, c.tempo .. "search.json"))
			expect(url(direct, Tempo.tagsRequest(direct, "direct"))).toBe(
				recorded(direct, c.tempo .. "search_tags_v2.json")
			)
			expect(url(direct, Tempo.tagValuesRequest(direct, "direct", "resource.service.name"))).toBe(
				recorded(direct, c.tempo .. "search_tag_values_v2.json")
			)
		end)

		it(
			"goes through Grafana " .. table.concat(c.grafana, ", ") .. "'s datasource proxy at the recorded URLs",
			function()
				for _, v in c.grafana do
					local dir = "grafana/" .. v .. "/"
					expect(url(datasource, Tempo.traceRequest(datasource, "proxy", c.trace_id, S.env))).toBe(
						recorded(datasource, dir .. "ds_proxy_tempo_trace.json")
					)
					expect(
						url(
							datasource,
							Tempo.searchRequest(
								datasource,
								"proxy",
								search(c, '{resource.service.name="payments"}'),
								S.env
							)
						)
					).toBe(recorded(datasource, dir .. "ds_proxy_tempo_search.json"))
				end
			end
		)

		it(
			"sends Grafana " .. table.concat(c.grafana, ", ") .. " the Tempo queries its own query editor sends",
			function()
				expect(Tempo.mode(datasource)).toBe("dsquery")
				expect(Tempo.mode(direct)).toBe("direct")
				for _, v in c.grafana do
					local dir = "grafana/" .. v .. "/"
					local trace = Tempo.traceRequest(datasource, "dsquery", c.trace_id, S.env)
					expect(trace.method).toBe("POST")
					expect(trace.path).toBe("/api/ds/query")
					local want = json.decode(Fixtures.read(dir .. "ds_query_tempo_trace.request.json"))
					expect(json.decode(trace.body :: string).queries).toEqual(want.queries)

					local s = search(c, '{resource.service.name="payments"}')
					s.limit = 20
					local req = Tempo.searchRequest(datasource, "dsquery", s, S.env)
					local body = json.decode(req.body :: string)
					want = json.decode(Fixtures.read(dir .. "ds_query_tempo_search.request.json"))
					expect(body.queries).toEqual(want.queries)
					expect(body.from).toBe(string.format("%d", c.start * 1000))
					expect(body.to).toBe(string.format("%d", c.stop * 1000))
				end
			end
		)
	end

	it("never asks /api/ds/query for tags (Grafana has no such query type)", function()
		expect(Tempo.tagsRequest(datasource, "dsquery").path).toBe(
			"/api/datasources/proxy/uid/tempo/api/v2/search/tags"
		)
	end)
end)

local function spanNames(spans: { any }): { string }
	local out: { string } = {}
	for _, s in spans do
		table.insert(out, s.name)
	end
	table.sort(out)
	return out
end

describe("tempo traces", function()
	for _, c in CAPTURES do
		it("reads the same three spans from " .. c.tempo .. ", the proxy and /api/ds/query", function()
			local cases: { { any } } = {
				{ "direct", c.tempo .. "trace.json" },
				{ "direct", c.tempo .. "trace_v2.json" },
			}
			for _, v in c.grafana do
				table.insert(cases, { "proxy", "grafana/" .. v .. "/ds_proxy_tempo_trace.json" })
				table.insert(cases, { "dsquery", "grafana/" .. v .. "/ds_query_tempo_trace.json" })
			end
			for _, case in cases do
				local r: any = Tempo.parseTrace(case[1], S.response(case[2]), S.env)
				expect(r.ok).toBe(true)
				expect(#r.spans).toBe(3)
				expect(spanNames(r.spans)).toEqual({ "lets-go", "okey-dokey-0", "okey-dokey-1" })
				for _, span in r.spans do
					expect(span.trace_id).toBe(c.span_trace_id)
					expect(span.service).toBe("payments")
					expect(span.status).toBe("error")
				end
			end
		end)

		it("reports a trace " .. c.tempo .. " does not have as not found", function()
			local r: any = Tempo.parseTrace("direct", text(c.tempo .. "trace_not_found.txt"), S.env)
			expect(r.ok).toBe(false)
			expect(r.error.message).toBe("trace not found")
			expect(Tempo.fallback("direct", r.error)).toBe(false)
		end)
	end
end)

describe("tempo search", function()
	for _, c in CAPTURES do
		it("lists " .. c.tempo .. "'s traces newest first with matches and per-service errors", function()
			local r: any = Tempo.parseSearch("direct", S.response(c.tempo .. "search.json"), S.env)
			expect(r.ok).toBe(true)
			expect(#r.hits).toBe(10)
			local first = r.hits[1]
			expect(first.trace_id).toBe(c.first_hit)
			expect(first.root_service).toBe("frontend")
			expect(first.root_name).toBe("lets-go")
			expect(first.duration_ms).toBe(120)
			expect(first.matched).toBe(4)
			expect(first.services).toEqual({ { name = "frontend", spans = 4, errors = 0 } })
			for i = 2, #r.hits do
				expect(r.hits[i - 1].start_ms >= r.hits[i].start_ms).toBe(true)
			end
			local errs: any = Tempo.parseSearch("direct", S.response(c.tempo .. "search_errors.json"), S.env)
			expect(errs.hits[1].errors).toBe(3)
		end)

		it("shows a broken TraceQL query as " .. c.tempo .. "'s own parse error", function()
			local r: any = Tempo.parseSearch("direct", text(c.tempo .. "search_error.txt"), S.env)
			expect(r.ok).toBe(false)
			expect(r.error.kind).toBe("query")
			expect(r.error.message).toBe(
				"invalid TraceQL query: parse error at line 1, col 27: syntax error: unexpected $end"
			)
			expect(Tempo.fallback("dsquery", r.error)).toBe(false)
		end)
	end

	for _, v in { "12.4.12", "13.3.0" } do
		it("reads Grafana " .. v .. "'s Traces table frame from /api/ds/query", function()
			local r: any =
				Tempo.parseSearch("dsquery", S.response("grafana/" .. v .. "/ds_query_tempo_search.json"), S.env)
			expect(r.ok).toBe(true)
			expect(#r.hits).toBe(20)
			local newest = r.hits[1]
			expect(newest.root_service).toBe("payments")
			expect(newest.duration_ms).toBe(240)
			expect(newest.matched).toBe(3)
			expect(#newest.trace_id).toBe(32)
		end)
	end

	it("asks for the proxy fallback when Grafana 11's Tempo plugin fails the search", function()
		local r: any = Tempo.parseSearch("dsquery", S.response("grafana/11.6.16/ds_query_tempo_search.json"), S.env)
		expect(r.ok).toBe(false)
		expect(r.error.status).toBe(500)
		expect(r.error.message).toContain("An error occurred within the plugin")
		expect(Tempo.fallback("dsquery", r.error)).toBe(true)
		expect(Tempo.fallback("proxy", r.error)).toBe(false)
		local viaProxy: any =
			Tempo.parseSearch("proxy", S.response("grafana/11.6.16/ds_proxy_tempo_search.json"), S.env)
		expect(#viaProxy.hits).toBe(10)
	end)
end)

describe("tempo tags", function()
	for _, c in CAPTURES do
		it("reads " .. c.tempo .. "'s tag names by scope and a tag's values", function()
			local tags: any = Tempo.parseTags(S.response(c.tempo .. "search_tags_v2.json"), S.env)
			expect(tags.ok).toBe(true)
			expect(tags.tags).toContain({ scope = "resource", name = "service.name" })
			expect(tags.tags).toContain({ scope = "span", name = "http.route" })
			expect(tags.tags).toContain({ scope = "intrinsic", name = "status" })
			local v1: any = Tempo.parseTags(S.response(c.tempo .. "search_tags.json"), S.env)
			expect(v1.tags).toContain({ scope = "", name = "service.name" })
			local values: any = Tempo.parseTagValues(S.response(c.tempo .. "search_tag_values_v2.json"), S.env)
			expect(values.values).toEqual({ "frontend", "payments" })
		end)
	end
end)

return nil
