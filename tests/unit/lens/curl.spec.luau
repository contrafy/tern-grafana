--!strict
-- `curl` against a query API is the quickest way to see what a server
-- returns. Our claim hides Tern's own JSON lens for these commands, so every
-- Prometheus or Grafana body must render here, errors first-class, and a
-- body that is neither must stay raw. Bodies are the recorded API responses
-- of both server generations; the request is read back from argv so the
-- query reopens in the Query block against the right context.
local Curl = require("../../../plugin/lib/lens/curl")
local Fixtures = require("../../lib/fixtures")
local S = require("./support")
local Scheme = require("../../../plugin/lib/links/scheme")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local PROM = { "2.53.5", "3.15.0" }
local GRAFANA = { "11.6.16", "12.4.12" }
local LOKI = "3.7.8"

local function cfg(text: string): any
	local c, problems = Validate.parseFile(text, json.decode)
	assert(c, problems[1] and Validate.format(problems[1]))
	return c
end

local LAB = cfg([[{"contexts": {
	"lab": {"prometheus": {"url": "http://localhost:9090"}},
	"graf": {"grafana": {"url": "http://localhost:3000", "datasources": {"prometheus": "prom3", "loki": "loki"}}}}}]])

-- The URL a fixture was captured from (its MANIFEST row), on `host`.
local function urlOf(path: string, host: string): string
	local row = S.manifest(path)
	assert(row, "no MANIFEST row for " .. path)
	return host .. row.command
end

type Lens = { state: Curl.State, view: any }

local function lens(args: { string }, lines: { string }, status: number?, config: any?): Lens
	local state = Curl.open(S.run("curl", args))
	for _, l in lines do
		Curl.line(state, l)
	end
	Curl.finish(state, status or 0)
	return { state = state, view = Curl.view(state, S.env(if config == nil then LAB else config)) }
end

local function promBody(version: string, name: string): ({ string }, string)
	local path = "prometheus/" .. version .. "/" .. name .. ".json"
	return S.body(path), urlOf(path, "http://localhost:9090")
end

local function grafanaRun(version: string, name: string): Lens
	local path = "grafana/" .. version .. "/" .. name .. ".json"
	local request = Fixtures.read("grafana/" .. version .. "/" .. name .. ".request.json")
	local args = {
		"-s",
		"-H",
		"Content-Type: application/json",
		"-d",
		request,
		urlOf(path, "http://localhost:3000"),
	}
	return lens(args, S.body(path))
end

local function linkParams(view: any, act: string): { [string]: string }
	local chips = S.findAll(view, S.withAction(act))
	assert(#chips == 1, "expected one " .. act .. " chip")
	local link = assert(Scheme.decode(chips[1].p.title))
	return link.params
end

local function sectionKinds(l: Lens): { string }
	local result = l.state.result :: Curl.Result
	local out: { string } = {}
	for _, s in result.sections do
		table.insert(out, s.kind)
	end
	return out
end

describe("curl Prometheus API bodies", function()
	for _, version in PROM do
		describe(version, function()
			it("shows an instant vector as a table and reopens it at its time", function()
				local body, url = promBody(version, "query_vector")
				local l = lens({ "-s", url }, body)
				expect(sectionKinds(l)).toEqual({ "vector" })
				local text = S.textOf(l.view)
				expect(S.contains(text, "GET /api/v1/query")).toBe(true)
				expect(#S.findAll(l.view, S.ofKind("chart"))).toBe(0)
				expect(linkParams(l.view, "query")).toEqual({
					context = "lab",
					expr = "up",
					mode = "table",
					from = "1791574298000",
					to = "1791577898000",
				})
			end)

			it("draws a range matrix as sparks, with the request's window in the link", function()
				local body, url = promBody(version, "query_range_multi")
				local l = lens({ url }, body)
				expect(sectionKinds(l)).toEqual({ "matrix" })
				expect(#S.findAll(l.view, S.ofKind("chart")) > 0).toBe(true)
				expect(#S.findAll(l.view, S.withAction("v=table:1"))).toBe(1)
				local params = linkParams(l.view, "query")
				expect(params.mode).toBe("graph")
				expect({ params.from, params.to }).toEqual({ "1791576998000", "1791577898000" })
				expect(params.expr).toBe('rate(node_cpu_seconds_total{mode=~"user|system|idle"}[1m])')
			end)

			it("renders parse and execution errors as errors, with the error type", function()
				for _, name in { "query_error_parse", "query_error_exec" } do
					local body, url = promBody(version, name)
					local l = lens({ "-s", url }, body)
					expect(l.view.p.tone).toBe("error")
					local text = S.textOf(l.view)
					expect(S.contains(text, if name == "query_error_parse" then "bad_data" else "execution")).toBe(true)
					expect(#S.findAll(l.view, S.withAction("query"))).toBe(0)
				end
			end)

			it("shows PromQL warnings next to an empty result", function()
				local body, url = promBody(version, "query_warning")
				local text = S.textOf(lens({ url }, body).view)
				expect(S.contains(text, "PromQL warning: bucket label")).toBe(true)
				expect(S.contains(text, "No data")).toBe(true)
			end)

			it("shows scalars and strings as values", function()
				local body, url = promBody(version, "query_scalar")
				expect(sectionKinds(lens({ url }, body))).toEqual({ "scalar" })
				local sbody, surl = promBody(version, "query_string")
				local l = lens({ surl }, sbody)
				expect(sectionKinds(l)).toEqual({ "string" })
				expect(S.contains(S.textOf(l.view), "tern")).toBe(true)
			end)

			it("lists exemplars with their trace ids and offers no Query block", function()
				local body, url = promBody(version, "query_exemplars")
				local l = lens({ url }, body)
				expect(sectionKinds(l)).toEqual({ "exemplars" })
				expect(S.contains(S.textOf(l.view), "traceID")).toBe(true)
				expect(S.contains(S.textOf(l.view), "Open in Query block")).toBe(false)
			end)

			it("reads the query of a form POST", function()
				local body = S.body("prometheus/" .. version .. "/query_post.json")
				local form = Fixtures.read("prometheus/" .. version .. "/query_post.request.txt")
				local l = lens({ "-s", "--data", form, "http://localhost:9090/api/v1/query" }, body)
				expect(l.state.invocation.method).toBe("POST")
				expect(linkParams(l.view, "query").expr).toBe("sum by (job) (up)")
				local enc = lens({ "--data-urlencode", "query=sum by (job) (up)", "localhost:9090/api/v1/query" }, body)
				expect(linkParams(enc.view, "query").expr).toBe("sum by (job) (up)")
			end)
		end)
	end
end)

describe("curl Grafana bodies", function()
	for _, version in GRAFANA do
		describe(version, function()
			it("shows each refId of /api/ds/query and reopens it through the datasource", function()
				local l = grafanaRun(version, "ds_query_prom_range")
				expect(sectionKinds(l)).toEqual({ "matrix", "matrix" })
				expect(linkParams(l.view, "query=A")).toEqual({
					context = "graf",
					ds = "prom3",
					expr = "sum by (mode) (rate(node_cpu_seconds_total[1m]))",
					mode = "graph",
					from = "now-15m",
					to = "now",
				})
				expect(linkParams(l.view, "query=B").expr).toBe("sum(up)")
				local effects = Curl.event(l.state, { ev = "action", act = "query", value = "B" }, S.env(LAB))
				expect(effects[1].kind).toBe("open")
			end)

			it("opens an instant query as a table", function()
				local l = grafanaRun(version, "ds_query_prom_instant")
				expect(sectionKinds(l)).toEqual({ "vector" })
				expect(linkParams(l.view, "query=A").mode).toBe("table")
			end)

			it("shows a failed refId as an error", function()
				local l = grafanaRun(version, "ds_query_prom_error")
				expect(sectionKinds(l)).toEqual({ "error" })
				expect(l.view.p.tone).toBe("error")
				expect(S.contains(S.textOf(l.view), "unclosed left parenthesis")).toBe(true)
			end)

			it("shows log frames as tables and keeps LogQL out of the Query block", function()
				local l = grafanaRun(version, "ds_query_loki_logs")
				expect(sectionKinds(l)).toEqual({ "frames" })
				expect(#S.findAll(l.view, S.withAction("query=A"))).toBe(0)
				expect(S.contains(S.textOf(l.view), "loki queries do not open")).toBe(true)
			end)

			it("reopens a datasource proxy query on that datasource", function()
				local path = "grafana/" .. version .. "/ds_proxy_prom_query.json"
				local l = lens({ urlOf(path, "http://localhost:3000") }, S.body(path))
				expect(sectionKinds(l)).toEqual({ "vector" })
				expect(linkParams(l.view, "query")).toEqual({
					context = "graf",
					ds = "prom3",
					expr = "up",
					mode = "table",
				})
				local errPath = "grafana/" .. version .. "/ds_proxy_prom_query_error.json"
				local e = lens({ urlOf(errPath, "http://localhost:3000") }, S.body(errPath))
				expect(e.view.p.tone).toBe("error")
			end)

			it("shows a Grafana API error body", function()
				local body = S.body("grafana/" .. version .. "/user_unauthorized.json")
				local l = lens({ "-XPOST", "http://localhost:3000/api/ds/query" }, body)
				expect(l.view.p.tone).toBe("error")
				local text = S.textOf(l.view)
				expect(S.contains(text, "Unauthorized")).toBe(true)
				expect(S.contains(text, "HTTP 401")).toBe(true)
				expect(S.contains(text, "POST /api/ds/query")).toBe(true)
			end)
		end)
	end
end)

describe("curl Loki bodies", function()
	local function loki(name: string): Lens
		local path = "loki/" .. LOKI .. "/" .. name .. ".json"
		return lens({ urlOf(path, "http://localhost:3100") }, S.body(path))
	end

	it("lists log lines newest first, without a Query block link", function()
		local l = loki("query_range_streams")
		expect(sectionKinds(l)).toEqual({ "streams" })
		local entries = (l.state.result :: Curl.Result).sections[1].entries
		expect(#entries > 1).toBe(true)
		expect(entries[1].time >= entries[2].time).toBe(true)
		expect(S.contains(S.textOf(l.view), "Open in Query block")).toBe(false)
	end)

	it("reads metric queries as series", function()
		expect(sectionKinds(loki("query_range_matrix"))).toEqual({ "matrix" })
		expect(sectionKinds(loki("query_vector"))).toEqual({ "vector" })
	end)

	it("stays raw for Loki's plain-text errors", function()
		local path = "loki/" .. LOKI .. "/query_error.txt"
		expect(lens({ urlOf(path, "http://localhost:3100") }, S.body(path)).view).toBeNil()
	end)
end)

describe("curl output noise", function()
	local body, url = promBody("3.15.0", "query_error_parse")
	local CURL = "curl/8.22.0/"

	local function argvOf(path: string): { string }
		local words: { string } = {}
		for w in string.gmatch((S.manifest(path) :: any).command, "%S+") do
			table.insert(words, w)
		end
		table.remove(words, 1)
		return words
	end

	it("skips the -i header block and shows its status", function()
		local path = CURL .. "prom_include_error.txt"
		local l = lens(argvOf(path), S.capture(path).lines)
		expect(l.view.p.tone).toBe("error")
		local text = S.textOf(l.view)
		expect(S.contains(text, "HTTP 400")).toBe(true)
		expect(S.contains(text, "bad_data")).toBe(true)
		-- Proxies and 100 Continue add header blocks before the real one.
		local lines = { "HTTP/1.1 100 Continue", "" }
		for _, line in S.capture(path).lines do
			table.insert(lines, line)
		end
		expect(S.contains(S.textOf(lens(argvOf(path), lines).view), "HTTP 400")).toBe(true)
	end)

	-- curl writes the trace to stderr around the body, and the body has no
	-- trailing newline, so the closing trace line lands on the body's row.
	it("skips -v trace lines, also the one glued to the body", function()
		local path = CURL .. "prom_verbose.txt"
		local trace = S.body(CURL .. "prom_verbose.stderr")
		local lines: { string } = {}
		for i = 1, #trace - 1 do
			table.insert(lines, trace[i])
		end
		table.insert(lines, S.body(path)[1] .. trace[#trace])
		local l = lens(argvOf(path), lines)
		expect(sectionKinds(l)).toEqual({ "vector" })
		expect(S.contains(S.textOf(l.view), "HTTP 200")).toBe(true)
		expect(#(l.state.result :: Curl.Result).sections[1].series).toBe(6)
	end)

	it("reads the body around a -w write-out", function()
		local path = CURL .. "prom_writeout.txt"
		local l = lens(argvOf(path), S.capture(path).lines)
		expect(sectionKinds(l)).toEqual({ "vector" })
	end)

	it("stays raw for bodies that are not Prometheus or Grafana JSON", function()
		expect(lens({ url }, { "<html><body>Bad Gateway</body></html>" }).view).toBeNil()
		expect(lens({ url }, { '{"hello": "world"}' }).view).toBeNil()
		expect(lens({ url }, {}, 7).view).toBeNil()
	end)

	it("stays raw while curl runs", function()
		local state = Curl.open(S.run("curl", { url }))
		Curl.line(state, body[1])
		expect(Curl.view(state, S.env(LAB))).toBeNil()
	end)
end)

describe("curl argv", function()
	local function parse(args: { string }): Curl.Invocation
		return Curl.parseArgs("curl", args)
	end

	it("reads glued and combined short options and --url", function()
		local inv = parse({ "-sSLXPOST", "-HAccept: application/json", "--url", "http://h:9090/api/v1/query_range" })
		expect(inv.endpoint).toBe("range")
		expect(inv.method).toBe("POST")
		expect(inv.base).toBe("http://h:9090")
		expect(parse({ "-G", "-d", "query=up", "http://h/api/v1/query" }).method).toBe("GET")
	end)

	it("re-checks the path the claim glob only saw somewhere in the line", function()
		expect(parse({ "-H", "X-Note: api/v1/query", "http://h:9090/api/v1/labels" }).endpoint).toBeNil()
		expect(parse({ "http://h:3000/api/ds/query_history" }).endpoint).toBeNil()
		expect(parse({ "http://h:3000/grafana/api/ds/query" }).base).toBe("http://h:3000/grafana")
	end)

	it("leaves requests that print no body raw", function()
		for _, args in
			{
				{ "-o", "out.json", "http://h/api/v1/query" },
				{ "-sI", "http://h/api/v1/query" },
				{ "-O", "http://h/api/v1/query" },
				{ "http://a/api/v1/query", "http://b/api/v1/query" },
			}
		do
			expect(parse(args).endpoint).toBeNil()
		end
	end)

	it("does not read a request body from a file", function()
		local inv = parse({ "-d", "@body.json", "http://h:3000/api/ds/query" })
		expect(inv.body).toBeNil()
		local link = Curl.queryLink(inv, nil, S.env(LAB))
		expect(link).toBeNil()
	end)
end)

return nil
