--!strict
-- JSON API (marcusolsson-json-datasource 1.3.23) has no backend: Grafana's
-- browser fetches every target through the datasource proxy and builds the
-- frame itself. Tern must send the very URL the plugin's frontend builds
-- (proxy path, urlPath, the target's params, then the datasource's
-- jsonData.queryParams), shape the document into the frames the plugin
-- makes, and fail the way Grafana fails, or a gauge shows another number
-- (or another error) than Grafana does. Fixtures are the dev stack's answers
-- through each Grafana's datasource proxy (dashboard tern-s4-json); the
-- fake appid in queryParams is scrubbed to "redacted-appid" by the capture.
-- On real stacks queryParams hold an API key (OpenWeatherMap's appid), so it
-- must never reach saved state, logs, compat output or an error text.
local Analyze = require("../../../plugin/lib/compat/analyze")
local DashState = require("../../../plugin/lib/dashboard/state")
local Fixtures = require("../../lib/fixtures")
local JP = require("../../../plugin/lib/datasources/jsonpath")
local JsonApi = require("../../../plugin/lib/datasources/json_api")
local Model = require("../../../plugin/lib/dashboard/model")
local Route = require("../../../plugin/lib/config/route")
local S = require("../dashboard/support")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local mod: any = JsonApi
local APPID = "redacted-appid"
local PROXY = "/api/datasources/proxy/uid/"

-- Request paths of the s4_json_* captures (MANIFEST urls; the capture
-- records the appid as REDACTED), by fixture name.
local function captured(version: string): { [string]: string }
	local out: { [string]: string } = {}
	for line in string.gmatch(Fixtures.read("MANIFEST.tsv"), "[^\n]+") do
		local path, method, url = string.match(line, "^([^\t]+)\t([^\t]+)\t([^\t]+)")
		local name = if path
			then string.match(path, "^grafana/" .. string.gsub(version, "%.", "%%.") .. "/(s4_json_[%w_]+)%.")
			else nil
		if name and method == "GET" then
			out[name :: string] = (string.gsub(url :: string, "appid=REDACTED", "appid=" .. APPID))
		end
	end
	return out
end

local function headersFor(name: string): { [string]: string }
	if string.match(name, "%.html$") then
		return { ["Content-Type"] = "text/html" }
	elseif string.match(name, "unknown_datasource") then
		return { ["Content-Type"] = "application/json; charset=UTF-8" }
	end
	return { ["Content-Type"] = "application/json" }
end

local function fixture(version: string, name: string, status: number?): any
	local r = S.response(S.grafana(version, name), status)
	r.headers = headersFor(name)
	return r
end

-- The capture answering a request path, nil for the documents not captured.
local function answerFor(version: string, path: string): any
	local byPath: { [string]: { string | number } } = {}
	for name, url in captured(version) do
		local file = if name == "s4_json_missing" then name .. ".html" else name .. ".json"
		local status = if name == "s4_json_missing" then 404 else 200
		byPath[url] = { file, status }
	end
	local hit = byPath[path]
	if hit == nil then
		return nil
	end
	return fixture(version, hit[1] :: string, hit[2] :: number)
end

type Block = { s: any, env: any, effects: { any }, paths: { string } }

-- The Dashboard block on tern-s4-json (city = chicago), every request
-- answered from the captures it has.
local function open(version: string): Block
	local env = S.env()
	local s, first =
		DashState.init({ "tern-grafana://dashboard?context=lab&uid=tern-s4-json&var-city=chicago" }, nil, env)
	local b: Block = { s = s, env = env, effects = {}, paths = {} }
	local function apply(list: { any })
		for _, e in list do
			table.insert(b.effects, e)
			if e.kind ~= "http" then
				continue
			end
			local tg = e.tag
			local response: any = nil
			if string.match(tg, "^dash/") then
				response = S.response(S.grafana(version, "dashboard_tern_s4_json.json"))
			elseif string.match(tg, "^fs/") then
				response = S.response(S.grafana(version, "s4_json_frontend_settings.json"))
			elseif string.match(tg, "^user/") then
				response = S.response(S.grafana(version, "user.json"))
			elseif string.sub(e.request.path, 1, #PROXY) == PROXY then
				table.insert(b.paths, e.request.path)
				response = answerFor(version, e.request.path)
			end
			if response then
				local _, more = DashState.update(s, { kind = "http_done", tag = tg, response = response }, env)
				apply(more)
			end
		end
	end
	apply(first)
	return b
end

local function panelData(b: Block, id: number): any
	for _, sec in b.s.sections do
		for _, inst in sec.panels do
			if inst.panel.id == id then
				return b.s.panels[inst.key].data
			end
		end
	end
	return nil
end

local function fieldsOf(frame: any): { [string]: any }
	local out: { [string]: any } = {}
	for _, f in frame.fields do
		out[f.name] = f
	end
	return out
end

for _, version in S.VERSIONS do
	describe("JSON API on tern-s4-json, Grafana " .. version, function()
		local b = open(version)
		local urls = captured(version)

		it("sends every target to the URL the plugin's frontend builds", function()
			local sent: { [string]: boolean } = {}
			for _, p in b.paths do
				sent[p] = true
			end
			-- One base-URL datasource and per-city datasources with a document URL.
			for _, name in { "s4_json_dallas", "s4_json_cities", "s4_json_city_chicago", "s4_json_forecast_params" } do
				expect(sent[urls[name]]).toBe(true)
			end
			expect(sent[urls.s4_json_forecast]).toBe(true)
			expect(sent[urls.s4_json_missing]).toBe(true)
			expect(sent[PROXY .. "json-seattle?lat=47.61&lon=-122.33&units=imperial&appid=" .. APPID]).toBe(true)
			expect(#b.paths).toBe(9)
		end)

		it("lists the city variable's options from its text and value fields", function()
			local city: any = nil
			for _, v in b.s.vars do
				if v.name == "city" then
					city = v
				end
			end
			expect(city.error).toBeNil()
			local opts = {}
			for _, o in city.options do
				table.insert(opts, o.text .. "=" .. o.value)
			end
			expect(table.concat(opts, ",")).toBe("Dallas=dallas,Chicago=chicago,Seattle=seattle")
		end)

		it("shapes the documents into the plugin's frames", function()
			local gauge = panelData(b, 1)
			expect(#gauge.errors).toBe(0)
			expect(gauge.frames[1].name).toBe("A")
			local temp = gauge.frames[1].fields[1]
			expect(temp.name).toBe("temp")
			expect(temp.type).toBe("number")
			expect(temp.values).toEqual({ 88.3 })
			expect(panelData(b, 5).frames[1].fields[1].values).toEqual({ 61.7 })

			-- groupBy city: a frame per city named after it; the metric field
			-- shows the frame name; ISO strings with Z are detected as time.
			local grouped = panelData(b, 6)
			local names = {}
			for _, f in grouped.frames do
				table.insert(names, f.name)
				local fields = fieldsOf(f)
				expect(fields.city).toBeNil()
				expect(fields.time.type).toBe("time")
				expect(fields.time.values[1]).toBe(1762689600000)
				expect(fields.temp.config.displayName).toBe(f.name)
				expect(#fields.temp.values).toBe(4)
			end
			expect(table.concat(names, ",")).toBe("Dallas,Chicago,Seattle")

			-- Epoch seconds typed as time become ms; dt_txt (no offset) stays a
			-- string, named after the path's last part.
			local tbl = fieldsOf(panelData(b, 7).frames[1])
			expect(tbl.Time.values[2]).toBe(1762689600000)
			expect(tbl.dt_txt.type).toBe("string")
			expect(tbl.dt_txt.values[1]).toBe("2025-11-09 12:00:00")
			expect(tbl.Condition.values[2]).toBe("Clouds")
			expect(#tbl.Temp.values).toBe(12)
		end)

		it("fails a missing document with the proxied body, as Grafana's backendSrv reports it", function()
			local missing = panelData(b, 8)
			expect(#missing.frames).toBe(0)
			expect(missing.errors).toEqual({ "A: " .. Fixtures.read(S.grafana(version, "s4_json_missing.html")) })
		end)

		it("keeps the appid out of saved state, block effects and panel errors", function()
			expect((string.find(json.encode(DashState.save(b.s)), APPID, 1, true))).toBeNil()
			for _, e in b.effects do
				if e.kind ~= "http" then
					expect((string.find(json.encode(e), APPID, 1, true))).toBeNil()
				end
			end
			for _, sec in b.s.sections do
				for _, inst in sec.panels do
					local d = b.s.panels[inst.key].data
					for _, line in (if d then d.errors else {}) :: { string } do
						expect((string.find(line, APPID, 1, true))).toBeNil()
					end
				end
			end
		end)

		it("reports every JSON API panel native in the compat scan, without the appid", function()
			local env = S.env()
			local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_s4_json.json")), env))
			local route = assert(Route.route(S.CONFIG, "lab", "dashboards"))
			local settings = assert(
				(Analyze.settings(route, S.response(S.grafana(version, "s4_json_frontend_settings.json")), env)),
				"settings"
			)
			local panels = Analyze.panels(d, settings, env)
			expect(#panels).toBe(8)
			for _, p in panels do
				expect(p.blocker).toBeNil()
			end
			expect((string.find(json.encode(panels), APPID, 1, true))).toBeNil()
		end)
	end)
end

-- Module level ----------------------------------------------------------------------

local env = S.env()
local SECRET = "s3cr3t-key-0123"

local function ds(url: string?, queryParams: string?): any
	return {
		uid = "w",
		type = "marcusolsson-json-datasource",
		name = "W",
		is_default = false,
		url = url,
		json_data = if queryParams then { queryParams = queryParams } else nil,
	}
end

local function ctx(d: any, scope: any?): any
	return {
		scope = scope or {},
		from_ms = 1700000000123,
		to_ms = 1700003600999,
		interval_ms = 1000,
		max_points = 100,
		now_ms = 1700003600999,
		datasources = { d },
		ds = d,
	}
end

local API = ds("/api/datasources/proxy/uid/w", "units=metric&appid=" .. SECRET)

-- The requests of the first step for `targets`, or its outcome.
local function requests(targets: { any }, c: any?): ({ any }, any)
	local job = mod.start(targets, c or ctx(API), env)
	local _, reqs, outcome = mod.step(job, {}, env)
	return reqs, outcome
end

local function target(extra: { [string]: any }): any
	local tg: any = { refId = "A", method = "GET", urlPath = "", fields = { { jsonPath = "$.v" } } }
	for k, v in extra do
		tg[k] = v
	end
	return tg
end

-- The outcome of one target answered with `response`.
local function answered(tg: any, response: any, d: any?): any
	local job = mod.start({ tg }, ctx(d or API), env)
	local _, reqs = mod.step(job, {}, env)
	local _, _, outcome = mod.step(job, { [reqs[1].tag] = response }, env)
	return outcome
end

local function body(text: string, status: number?, ctype: string?): any
	return {
		status = status or 200,
		headers = { ["content-type"] = ctype or "application/json" },
		body = text,
		timed_out = false,
	}
end

describe("JSON API requests", function()
	it("appends the target's params, then queryParams, encodeURIComponent'ed, after the macros", function()
		local reqs = requests({
			target({
				urlPath = "//data///$path/",
				params = {
					{ "from", "$__unixEpochFrom()" },
					{ "", "skipped" },
					{ "q", "a b&c!'()*" },
					{ "q", "$__isoTo()" },
				},
			}),
		}, ctx(API, { path = { values = { "x y" } } }))
		expect(reqs[1].request.method).toBe("GET")
		expect(reqs[1].request.path).toBe(
			"/api/datasources/proxy/uid/w/data/x y/?from=1700000000&q=a%20b%26c!'()*&q=2023-11-14T23%3A13%3A20.999Z"
				.. "&units=metric&appid="
				.. SECRET
		)
		expect(reqs[1].request.body).toBeNil()
	end)

	it("orders queryParams as a JavaScript object: index keys first, a repeated key keeps its first place", function()
		local d = ds("/api/datasources/proxy/uid/w", "b=1&7=x&a=2&b=3&n__4=y&2=z")
		local reqs = requests({ target({ urlPath = "/p?fixed=1" }) }, ctx(d))
		expect(reqs[1].request.path).toBe("/api/datasources/proxy/uid/w/p?fixed=1&2=z&7=x&b=3&a=2&n=y")
	end)

	it("posts the body with Grafana's default content type and moves Authorization to X-DS-Authorization", function()
		local reqs = requests({
			target({
				method = "POST",
				body = '{"from": $__unixEpochFrom()}',
				headers = { { "Authorization", "Bearer upstream" }, { "X-Team", "$team" }, { "", "dropped" } },
			}),
		}, ctx(API, { team = { values = { "a", "b" }, multi = true } }))
		local r = reqs[1].request
		expect(r.method).toBe("POST")
		expect(r.body).toBe('{"from": 1700000000}')
		expect(r.headers).toEqual({
			["X-DS-Authorization"] = "Bearer upstream",
			["X-Team"] = "{a,b}",
			Accept = "application/json, text/plain, */*",
			["Content-Type"] = "application/json",
		})
	end)

	it("refuses what the plugin refuses before any request", function()
		local function err(tg: any): string?
			local _, outcome = requests({ tg })
			return if outcome then outcome.data.errors[1] else nil
		end
		expect(err(target({ method = env.null }))).toBe("A: Invalid method undefined")
		expect(err(target({ method = "PUT" }))).toBe("A: Invalid method PUT")
		expect(err(target({ urlPath = "/a/.." }))).toBe("A: URL path contains unsafe characters")
		expect(err(target({ urlPath = "/a/%2e%2e/b" }))).toBe("A: URL path contains unsafe characters")
		expect(err(target({ urlPath = "/a\\..\\b" }))).toBe("A: URL path contains unsafe characters")
		expect(err(target({ urlPath = "/a", params = { { "x", "\t" } } }))).toBe(
			"A: URL path contains unsafe characters"
		)
		expect(err(target({ urlPath = "/a%zz" }))).toBe("A: URI malformed")
		expect(err(target({ urlPath = "/a/..b" }))).toBeNil()
	end)

	it("keeps JSONata fields and browser access on the ladder", function()
		local bctx: any = { scope = {}, datasources = { API }, ds = API }
		expect(mod.blocker(target({}), bctx, env)).toBeNil()
		local jsonata = target({ fields = { { jsonPath = "$sum(x)", language = "jsonata" } } })
		expect(mod.blocker(jsonata, bctx, env)).toBe("JSON API JSONata expressions run in the browser")
		local direct: any = { scope = {}, datasources = {}, ds = ds("https://api.example.com", nil) }
		expect(mod.blocker(target({}), direct, env)).toBe(
			"JSON API datasources with browser (direct) access are queried by the browser"
		)
	end)
end)

describe("JSON API shaping", function()
	it("types and parses values as moment and dayjs do in the plugin", function()
		-- Every case of jsonpath/field_types_*.json was typed and parsed once
		-- by the plugin's detectFieldType/parseValues code with moment 2.29.4
		-- and dayjs 1.11.10 in a UTC+05:30 browser. A time dayjs cannot parse
		-- is NaN there and null here (Tern frames carry no NaN times).
		local ref = json.decode(Fixtures.read("jsonpath/field_types_moment_2.29.4_dayjs_1.11.10.json"))
		local e = S.env()
		e.local_offset_min = ref.local_offset_min
		for i, c in ref.cases do
			local field: any = { jsonPath = "$.c" .. (i - 1) .. "[*]" }
			if c.type ~= json.null then
				field.type = c.type
			end
			local job = mod.start({ target({ fields = { field } }) }, ctx(API), e)
			local _, reqs = mod.step(job, {}, e)
			local _, _, outcome = mod.step(job, { [reqs[1].tag] = body(ref.doc) }, e)
			local want = json.decode(c.result)
			if want.error then
				expect(outcome.data.errors).toEqual({ "A: " .. want.error })
				continue
			end
			local f = outcome.data.frames[1].fields[1]
			expect(f.type).toBe(want.type)
			for k, v in want.values do
				local got = f.values[k]
				if v == "NaN" then
					expect(if want.type == "time" then got == JP.NULL else got ~= got).toBe(true)
				elseif v == json.null then
					expect(got).toBe(JP.NULL)
				else
					expect(got).toBe(v)
				end
			end
		end
	end)

	it("fails the whole panel on one failed target, as Promise.all does", function()
		local job = mod.start({
			target({ refId = "A" }),
			target({ refId = "B", fields = { { jsonPath = "$.v" }, { jsonPath = "$.w[*]" } } }),
		}, ctx(API), env)
		local _, reqs = mod.step(job, {}, env)
		local doc = body('{"v": 1, "w": [1, 2]}')
		local _, _, outcome = mod.step(job, { [reqs[1].tag] = doc, [reqs[2].tag] = doc }, env)
		expect(outcome.data.frames).toEqual({})
		expect(outcome.data.errors).toEqual({ "B: Fields have different lengths" })
	end)

	it("fails a falsy document as the plugin does", function()
		-- backendSrv parses a text body as JSON when it can; an empty one stays "".
		for _, text in { "null", "0", "false", '""', "" } do
			expect(answered(target({}), body(text, 200, "text/plain")).data.errors).toEqual({
				"A: Query returned empty data",
			})
		end
		-- With a JSON content type an empty body is a parse error.
		local empty = answered(target({}), body("")).data.errors[1]
		expect((string.find(empty, "^A: Unexpected end of JSON input"))).toBe(1)
		-- An empty object is a document: its fields are just empty.
		local fields = answered(target({}), body("{}")).data.frames[1].fields
		expect(fields[1].name).toBe("v")
		expect(fields[1].type).toBe("string")
		expect(#fields[1].values).toBe(0)
	end)

	it("reports HTTP errors with the message Grafana's backendSrv makes", function()
		local function message(text: string, status: number, ctype: string?): string
			return answered(target({}), body(text, status, ctype)).data.errors[1]
		end
		expect(message('{"message":"Invalid API key"}', 401)).toBe("A: Invalid API key")
		expect(message('{"error":"rate limited"}', 429)).toBe("A: rate limited")
		expect(message('{"message":"Query data error","error":"boom"}', 500)).toBe("A: boom")
		expect(message("[1]", 500)).toBe("A: Query error: 500 Internal Server Error")
		expect(message("", 502, "text/plain")).toBe("A: Bad Gateway")
		expect(message("upstream down", 503, "text/plain")).toBe("A: upstream down")
		for _, version in S.VERSIONS do
			local r = fixture(version, "s4_json_unknown_datasource.json", 404)
			expect(answered(target({}), r).data.errors).toEqual({ "A: Unable to find datasource" })
			local post = fixture(version, "s4_json_post.html", 501)
			expect(answered(target({ method = "POST" }), post).data.errors).toEqual({
				"A: " .. Fixtures.read(S.grafana(version, "s4_json_post.html")),
			})
		end
	end)

	it("never puts the queryParams values into error texts", function()
		local path = "/api/datasources/proxy/uid/w?units=metric&appid=" .. SECRET
		local failure = { status = 0, headers = {}, body = "", timed_out = false, error = "connect failed: " .. path }
		local echo = body('{"message":"bad key ' .. SECRET .. " for " .. path .. '"}', 401)
		for _, r in { failure, echo } do
			local line = answered(target({}), r).data.errors[1]
			expect((string.find(line, SECRET, 1, true))).toBeNil()
			expect((string.find(line, "A: ", 1, true))).toBe(1)
		end
	end)
end)

describe("JSON API query variables", function()
	local function options(query: any, response: any, d: any?): any
		local job = mod.variable(query, ctx(d or API), env)
		local _, reqs, outcome = mod.step(job, {}, env)
		if outcome then
			return outcome
		end
		local _, _, done = mod.step(job, { [reqs[1].tag] = response }, env)
		return done
	end

	it("takes text and value from the named fields, else the first field, as strings", function()
		local doc = body('{"items": [{"id": 1, "label": "one"}, {"id": 2, "label": null}]}')
		local q = target({
			fields = { { jsonPath = "$.items[*].id", name = "id" }, { jsonPath = "$.items[*].label", name = "label" } },
			experimentalVariableTextField = "label",
			experimentalVariableValueField = "id",
		})
		expect(options(q, doc).options).toEqual({ { text = "one", value = "1" }, { text = "2", value = "2" } })
		q.experimentalVariableTextField = nil
		q.experimentalVariableValueField = nil
		expect(options(q, doc).options).toEqual({ { text = "1", value = "1" }, { text = "2", value = "2" } })
		expect(options(target({ fields = {} }), doc).options).toEqual({})
	end)

	it("reports what the plugin cannot list", function()
		expect(options(target({ fields = { { jsonPath = "$x", language = "jsonata" } } }), nil).error).toBe(
			"JSON API JSONata expressions run in the browser"
		)
		expect(options("$.items", nil).error).toBe("Invalid method undefined")
	end)
end)

return nil
