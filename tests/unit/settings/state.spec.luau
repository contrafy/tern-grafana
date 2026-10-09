--!strict
-- The settings block writes the file that decides which servers get which
-- credentials. It must never write a file the validator rejects, never
-- overwrite a file someone changed since the block read it, keep sections it
-- does not understand, and its connection test must say what is wrong and
-- how to fix it, using real server answers.
local Fixtures = require("../../lib/fixtures")
local Json = require("../../../plugin/lib/settings/json")
local State: any = require("../../../plugin/lib/settings/state")
local Validate: any = require("../../../plugin/lib/config/validate")
local View = require("../../../plugin/lib/settings/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ENV: any = { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null }
local PATH = "/home/u/.config/tern-grafana/config.json"

local FILE = [[
{
  "version": 1,
  "default_context": "lab",
  "contexts": {
    "lab": {
      "grafana": {"url": "http://localhost:3000", "auth": {"type": "bearer", "token_env": "GRAFANA_TOKEN"}, "datasources": {"prometheus": "prom3", "loki": "loki"}},
      "prometheus": {"url": "http://localhost:9090"},
      "alertmanager": {"url": "http://localhost:9093"},
      "loki": {"url": "http://localhost:3100"},
      "tempo": {"url": "http://localhost:3200"}
    }
  },
  "query": {"history": {"max": 50}},
  "watches": {"rules": [{"expr": "up == 0", "for": "5m"}]}
}
]]

local function key(name: string, mods: { [string]: any }?): any
	local k: any =
		{ name = name, text = if #name == 1 then name else nil, ctrl = false, alt = false, shift = false, meta = false }
	if mods then
		for m, v in mods do
			k[m] = v
		end
	end
	return k
end

local function press(s: any, ...: string): (any, { any })
	local all = {}
	for _, name in { ... } do
		local effects
		s, effects = State.key(s, key(name), ENV)
		for _, e in effects do
			table.insert(all, e)
		end
	end
	return s, all
end

local function typeText(s: any, text: string): any
	for i = 1, #text do
		local ch = string.sub(text, i, i)
		s = State.key(s, { name = ch, text = ch, ctrl = false, alt = false, shift = false, meta = false } :: any, ENV)
	end
	return s
end

local function update(s: any, msg: any): (any, { any })
	return State.update(s, msg, ENV)
end

local function loaded(text: string?): any
	local s, effects = State.init({}, nil, ENV)
	expect(effects).toEqual({ { kind = "config_read" } })
	s = update(s, { kind = "config_file", path = PATH, text = text, exists = text ~= nil })
	return s
end

local function writes(effects: { any }): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "config_write" then
			table.insert(out, e)
		end
	end
	return out
end

local function selectRow(s: any, rowKey: string): any
	local next = update(s, { kind = "event", ev = { ev = "action", act = "sel", value = rowKey } })
	expect(State.selectedRow(next).key).toBe(rowKey)
	return next
end

-- Moves the form selection to field `id`.
local function toField(s: any, id: string): any
	for i, f in State.formFields(s) do
		if f.id == id then
			s = table.clone(s)
			s.form_sel = i
			return s
		end
	end
	error("no field " .. id)
end

describe("editing through the form", function()
	it("writes a validated file computed from the loaded text, keeping unknown sections", function()
		local s = selectRow(loaded(FILE), "lab/prometheus")
		s = press(s, "enter")
		expect(s.page).toBe("form")
		s = toField(s, "url")
		s = press(s, "enter")
		s = State.key(s, key("u", { ctrl = true }), ENV)
		s = typeText(s, "http://localhost:9091")
		s = press(s, "enter")
		local after, effects = press(s, "w")
		local w = writes(effects)
		expect(#w).toBe(1)
		expect(w[1].path).toBe(PATH)
		expect(w[1].base_hash).toBe(Json.hash(FILE))
		local cfg, problems = Validate.parseFile(w[1].text, json.decode)
		expect(problems).toEqual({})
		expect(cfg.contexts.lab.prometheus.url).toBe("http://localhost:9091")
		local doc = json.decode(w[1].text)
		expect(doc.query).toEqual({ history = { max = 50 } })
		expect(doc.watches).toEqual({ rules = { { expr = "up == 0", ["for"] = "5m" } } })
		expect(after.writing).toBe(true)
		-- A second save while the first is in flight writes nothing.
		local _, again = press(after, "w")
		expect(#writes(again)).toBe(0)
	end)

	it("blocks an invalid edit with the path-specific message and writes nothing", function()
		local s = selectRow(loaded(FILE), "lab/prometheus")
		s = press(s, "enter")
		s = toField(s, "timeout_ms")
		s = press(s, "enter")
		s = typeText(s, "999999999")
		s = press(s, "enter")
		local after, effects = press(s, "w")
		expect(#writes(effects)).toBe(0)
		expect(after.form_problems).toEqual({
			{
				path = "contexts.lab.prometheus.timeout_ms",
				message = "must be an integer between 1 and 600000 (milliseconds)",
			},
		})
		expect(after.page).toBe("form")
	end)

	it("closes the form once the host confirms the write and re-reads the file", function()
		local s = selectRow(loaded(FILE), "lab/tempo")
		s = press(s, "enter")
		s = toField(s, "timeout_ms")
		s = press(s, "enter")
		s = typeText(s, "60000")
		s = press(s, "enter", "w")
		expect(s.writing).toBe(true)
		local after, effects = update(s, { kind = "config_written", ok = true })
		expect(after.page).toBe("list")
		expect(after.form).toBeNil()
		expect(after.writing).toBe(false)
		expect(effects).toEqual({ { kind = "config_read" } })
	end)
end)

describe("concurrent changes", function()
	it("keeps the form after a conflict and saves again against the reloaded text", function()
		local s = selectRow(loaded(FILE), "lab/loki")
		s = press(s, "enter")
		s = toField(s, "path_prefix")
		s = press(s, "enter")
		s = typeText(s, "/loki")
		s = press(s, "enter")
		local effects
		s, effects = press(s, "w")
		expect(#writes(effects)).toBe(1)
		s, effects = update(s, { kind = "config_written", ok = false, conflict = true })
		expect(s.conflict).toBe(true)
		expect(s.page).toBe("form")
		expect(s.message.text).toContain("changed on disk")
		expect(effects).toEqual({ { kind = "config_read" } })
		-- Someone else added a context meanwhile; the retry must keep it.
		local changed =
			string.gsub(FILE, '"contexts": {', '"contexts": {\n    "extra": {"tempo": {"url": "http://t:3200"}},', 1)
		s = update(s, { kind = "config_file", path = PATH, text = changed, exists = true })
		local _, retry = press(s, "w")
		local w = writes(retry)
		expect(#w).toBe(1)
		expect(w[1].base_hash).toBe(Json.hash(changed))
		local cfg = Validate.parseFile(w[1].text, json.decode) :: any
		expect(cfg.contexts.extra.tempo.url).toBe("http://t:3200")
		expect(cfg.contexts.lab.loki.path_prefix).toBe("/loki")
	end)
end)

describe("list actions", function()
	it("asks before removing and writes the file without the context", function()
		local text = string.gsub(
			FILE,
			'"contexts": {',
			'"contexts": {\n    "spare": {"prometheus": {"url": "http://p:9090"}},',
			1
		)
		local s = selectRow(loaded(text), "spare")
		local effects
		s, effects = press(s, "x")
		expect(s.page).toBe("confirm")
		expect(#writes(effects)).toBe(0)
		s, effects = press(s, "y")
		local w = writes(effects)
		expect(#w).toBe(1)
		local cfg = Validate.parseFile(w[1].text, json.decode) :: any
		expect(cfg.contexts.spare).toBeNil()
		expect(cfg.contexts.lab ~= nil).toBe(true)
	end)

	it("refuses to remove the last endpoint of a context and says why", function()
		local text = string.gsub(
			FILE,
			'"contexts": {',
			'"contexts": {\n    "spare": {"prometheus": {"url": "http://p:9090"}},',
			1
		)
		local s = selectRow(loaded(text), "spare/prometheus")
		s = press(s, "x")
		local after, effects = press(s, "y")
		expect(#writes(effects)).toBe(0)
		expect(after.message.text).toContain(
			"contexts.spare: must configure at least one of grafana, prometheus, alertmanager, loki, tempo"
		)
	end)

	it("does not edit a file that is not JSON, and points at the editor", function()
		local s = loaded("{ not json")
		expect(s.decode_error ~= nil).toBe(true)
		local after, effects = press(s, "n")
		expect(after.page).toBe("list")
		expect(#effects).toBe(0)
		expect(after.message.text).toContain("o opens the file")
	end)
end)

describe("starter templates", function()
	it("offers templates when the file is missing and writes a valid one only for a missing file", function()
		local s = loaded(nil)
		expect(s.page).toBe("templates")
		local after, effects = press(s, "j", "j", "j", "enter")
		local w = writes(effects)
		expect(#w).toBe(1)
		expect(w[1].base_hash).toBeNil()
		local cfg, problems = Validate.parseFile(w[1].text, json.decode)
		expect(problems).toEqual({})
		expect(cfg.default_context).toBe("mimir")
		expect(after.writing).toBe(true)
	end)

	it("renders a preview of the selected template", function()
		local view = View.view(loaded(nil), ENV)
		local found = false
		for _, n in (view.main :: any).c do
			if n.k == "code" then
				found = true
				expect(n.p.text).toContain('"default_context": "lab"')
			end
		end
		expect(found).toBe(true)
	end)
end)

describe("connection test", function()
	-- Runs the test of `row` and answers each request with the fixture for its path.
	local function run(s: any, row: string, answer: (path: string, e: any) -> any): any
		s = selectRow(s, row)
		local effects
		s, effects = press(s, "t")
		expect(#effects > 0).toBe(true)
		for _, e in effects do
			expect(e.kind).toBe("http")
			s = update(s, { kind = "http_done", tag = e.tag, response = answer(e.request.path, e) })
		end
		return s
	end

	local function ok(path: string): any
		return { status = 200, headers = {}, body = Fixtures.read(path), timed_out = false }
	end

	local function results(s: any, context: string, endpoint: string): { any }
		local out = {}
		for i, st in s.tests[State.testKey(context, endpoint)].steps do
			out[i] = st.result
		end
		return out
	end

	for _, version in { "2.53.5", "3.15.0" } do
		it("reports the Prometheus " .. version .. " version", function()
			local s = run(loaded(FILE), "lab/prometheus", function()
				return ok("prometheus/" .. version .. "/buildinfo.json")
			end)
			expect(results(s, "lab", "prometheus")).toEqual({ { ok = true, text = "Prometheus " .. version } })
		end)
	end

	for _, version in { "11.6.16", "12.4.12" } do
		it("checks Grafana " .. version .. " health, the token and the configured datasource uids", function()
			local s = run(loaded(FILE), "lab/grafana", function(path: string)
				local name = ({
					["/api/health"] = "health",
					["/api/user"] = "user",
					["/api/datasources"] = "datasources",
				})[path]
				return ok("grafana/" .. version .. "/" .. name .. ".json")
			end)
			local r = results(s, "lab", "grafana")
			expect(r[1]).toEqual({ ok = true, text = "Grafana " .. version })
			expect(r[2]).toEqual({ ok = true, text = "signed in as sa-1-tern-dev" })
			expect(r[3].ok).toBe(true)
			expect(r[3].text).toContain("prometheus=prom3")
			expect(State.testStatus(s.tests[State.testKey("lab", "grafana")])).toBe("ok")
		end)

		it("explains a rejected Grafana " .. version .. " token", function()
			local s = run(loaded(FILE), "lab/grafana", function(path: string)
				if path == "/api/user" then
					local r = ok("grafana/" .. version .. "/user_bad_token.json")
					r.status = 401
					return r
				end
				return ok(
					"grafana/" .. version .. (if path == "/api/health" then "/health.json" else "/datasources.json")
				)
			end)
			local r = results(s, "lab", "grafana")
			expect(r[2].ok).toBe(false)
			expect(r[2].error).toContain("Invalid API key")
			expect(r[2].hint).toContain("rejected")
		end)
	end

	it("names a configured datasource uid Grafana does not have", function()
		local text = string.gsub(FILE, '"loki": "loki"', '"loki": "no-such-uid"', 1)
		local s = run(loaded(text), "lab/grafana", function(path: string)
			local name = ({ ["/api/health"] = "health", ["/api/user"] = "user", ["/api/datasources"] = "datasources" })[path]
			return ok("grafana/12.4.12/" .. name .. ".json")
		end)
		local r = results(s, "lab", "grafana")[3]
		expect(r.ok).toBe(false)
		expect(r.error).toBe('datasources.loki: no datasource with uid "no-such-uid"')
		expect(r.hint).toContain("prom3")
	end)

	it("tells an unauthenticated Grafana endpoint to configure auth", function()
		local text = string.gsub(FILE, '"auth": {"type": "bearer", "token_env": "GRAFANA_TOKEN"}, ', "", 1)
		local s = run(loaded(text), "lab/grafana", function(path: string)
			if path == "/api/user" then
				local r = ok("grafana/12.4.12/user_unauthorized.json")
				r.status = 401
				return r
			end
			return ok("grafana/12.4.12/" .. (if path == "/api/health" then "health" else "datasources") .. ".json")
		end)
		expect(results(s, "lab", "grafana")[2].hint).toContain("set auth")
	end)

	it("reads Alertmanager, Loki and Tempo versions from their build info", function()
		local s = loaded(FILE)
		local fixtures: { [string]: { string } } = {
			alertmanager = { "alertmanager/0.34.1/status.json", "Alertmanager 0.34.1" },
			loki = { "loki/3.7.8/buildinfo.json", "Loki 3.7.8" },
			tempo = { "tempo/2.10.8/buildinfo.json", "Tempo v2.10.8" },
		}
		for name, f in fixtures do
			s = run(s, "lab/" .. name, function()
				return ok(f[1])
			end)
			expect(results(s, "lab", name)).toEqual({ { ok = true, text = f[2] } })
		end
	end)

	it("turns a TLS UnknownIssuer failure into the ca_file remedy", function()
		local s = run(loaded(FILE), "lab/prometheus", function()
			-- What tern.fetch reports for a private CA (docs/sdk-capability-matrix.md, row 1e).
			return {
				status = 0,
				headers = {},
				body = "",
				error = "io: invalid peer certificate: UnknownIssuer",
				timed_out = false,
			}
		end)
		local r = results(s, "lab", "prometheus")[1]
		expect(r.ok).toBe(false)
		expect(r.hint).toContain("tls.ca_file")
	end)

	it("drops answers to a superseded test", function()
		local s = selectRow(loaded(FILE), "lab/prometheus")
		local first, second
		s, first = press(s, "t")
		s, second = press(s, "t")
		local stale = update(s, {
			kind = "http_done",
			tag = first[1].tag,
			response = ok("prometheus/3.15.0/buildinfo.json"),
		})
		expect(stale).toBe(s)
		expect(second[1].tag == first[1].tag).toBe(false)
	end)

	it("tests only the saved config: an invalid file is reported, not sent", function()
		local text = string.gsub(FILE, '"url": "http://localhost:9090"', '"url": "localhost:9090"', 1)
		local s = selectRow(loaded(text), "lab/prometheus")
		local after, effects = press(s, "t")
		expect(#effects).toBe(0)
		expect(after.tests[State.testKey("lab", "prometheus")].error).toContain("fix them first")
	end)
end)

describe("view", function()
	it("never renders a sensitive header value", function()
		local text = string.gsub(
			FILE,
			'{"url": "http://localhost:9090"}',
			'{"url": "http://localhost:9090", "headers": {"X-Api-Key": "k-SECRETMARK"}}',
			1
		)
		local s = loaded(text)
		local list = json.encode(View.view(s, ENV))
		expect((string.find(list, "SECRETMARK", 1, true))).toBeNil()
		s = selectRow(s, "lab/prometheus")
		s = press(s, "enter")
		s = toField(s, "header:X-Api-Key")
		local form = json.encode(View.view(s, ENV))
		expect((string.find(form, "SECRETMARK", 1, true))).toBeNil()
		s = press(s, "enter")
		expect((string.find(json.encode(View.view(s, ENV)), "SECRETMARK", 1, true))).toBeNil()
	end)
end)

return nil
