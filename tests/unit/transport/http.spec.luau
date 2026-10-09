--!strict
-- Every API call goes through url(): a doubled slash breaks Grafana's subpath
-- routing, an unencoded PromQL character changes the query, and reordering or
-- merging repeated keys (match[]) changes the result set.
local Http = require("../../../plugin/lib/transport/http")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function ep(url: string, prefix: string?): any
	return { url = url, path_prefix = prefix or "", headers = {}, auth = { type = "none" }, timeout_ms = 15000 }
end

local function get(path: string, query: { { string } }?): any
	return { method = "GET", path = path, query = query }
end

describe("url joining", function()
	it("joins base and path with exactly one slash", function()
		expect(Http.url(ep("http://h:9090"), get("/api/v1/query"))).toBe("http://h:9090/api/v1/query")
		expect(Http.url(ep("http://h:9090/"), get("api/v1/query"))).toBe("http://h:9090/api/v1/query")
		expect(Http.url(ep("http://h:9090//"), get("//api/v1/query"))).toBe("http://h:9090/api/v1/query")
	end)

	it("keeps a base path such as Grafana served under a subpath", function()
		expect(Http.url(ep("https://ex.com/grafana"), get("/api/search"))).toBe("https://ex.com/grafana/api/search")
	end)

	it("inserts path_prefix whatever slashes it carries", function()
		local want = "http://mimir/prometheus/api/v1/labels"
		for _, prefix in { "/prometheus", "prometheus", "prometheus/", "/prometheus/", "//prometheus//" } do
			expect(Http.url(ep("http://mimir/", prefix), get("/api/v1/labels"))).toBe(want)
		end
		expect(Http.url(ep("http://mimir", "/"), get("/api/v1/labels"))).toBe("http://mimir/api/v1/labels")
	end)

	it("keeps a multi-segment prefix", function()
		expect(Http.url(ep("http://vm:8481", "/select/0/prometheus"), get("/api/v1/query"))).toBe(
			"http://vm:8481/select/0/prometheus/api/v1/query"
		)
	end)

	it("omits the query separator when there are no parameters", function()
		expect(Http.url(ep("http://h"), get("/api/v1/labels", {}))).toBe("http://h/api/v1/labels")
	end)
end)

describe("query encoding", function()
	it("percent-encodes everything outside RFC 3986 unreserved characters", function()
		local q = 'sum by (job) (rate(http_requests_total{code=~"5..",path!="/a b"}[5m])) > 0.5 & +1'
		expect(Http.url(ep("http://h"), get("/api/v1/query", { { "query", q }, { "time", "1700000000.5" } }))).toBe(
			"http://h/api/v1/query?query=sum%20by%20%28job%29%20%28rate%28http_requests_total%7Bcode%3D~%225..%22%2Cpath%21%3D%22%2Fa%20b%22%7D%5B5m%5D%29%29%20%3E%200.5%20%26%20%2B1&time=1700000000.5"
		)
	end)

	it("keeps unreserved characters as they are", function()
		expect(Http.escape("AZaz09-._~")).toBe("AZaz09-._~")
	end)

	it("encodes unicode as UTF-8 bytes", function()
		expect(Http.escape('{city="Zürich"}')).toBe("%7Bcity%3D%22Z%C3%BCrich%22%7D")
		expect(Http.escape("日本")).toBe("%E6%97%A5%E6%9C%AC")
	end)

	it("keeps repeated keys in order", function()
		local u = Http.url(
			ep("http://h"),
			get("/api/v1/series", { { "match[]", "up" }, { "match[]", 'node_load1{job="n"}' }, { "start", "1" } })
		)
		expect(u).toBe("http://h/api/v1/series?match%5B%5D=up&match%5B%5D=node_load1%7Bjob%3D%22n%22%7D&start=1")
	end)

	it("encodes empty values", function()
		expect(Http.url(ep("http://h"), get("/x", { { "q", "" } }))).toBe("http://h/x?q=")
	end)

	it("appends to a path that already has a query", function()
		expect(Http.url(ep("http://h"), get("/api/search?type=dash-db", { { "query", "a b" } }))).toBe(
			"http://h/api/search?type=dash-db&query=a%20b"
		)
	end)
end)

describe("header merging", function()
	it("layers endpoint, org, request and auth headers, later winning case-insensitively", function()
		local endpoint = ep("http://g")
		endpoint.headers = { ["X-Scope-OrgID"] = "t1", ["Accept"] = "text/plain" }
		endpoint.org_id = 2
		local request = { method = "GET", path = "/", headers = { accept = "application/json", Authorization = "x" } }
		expect(Http.headers(endpoint, request, { Authorization = "Bearer s" })).toEqual({
			["X-Scope-OrgID"] = "t1",
			["X-Grafana-Org-Id"] = "2",
			accept = "application/json",
			Authorization = "Bearer s",
		})
	end)

	it("adds nothing when nothing is configured", function()
		expect(Http.headers(ep("http://p"), get("/"), {})).toEqual({})
	end)
end)

return nil
