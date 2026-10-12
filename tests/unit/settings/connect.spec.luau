--!strict
-- Connect Grafana is how most users get a token into the plugin. The token
-- must never show up anywhere but the test requests' Authorization header
-- and the keychain store effect: not in the view, saved state, the config
-- file or messages. Nothing is stored before Grafana accepted the token, the
-- datasource picks must land on the stack's own datasources (Grafana Cloud
-- provisions several internal ones), and removing a context must offer to
-- delete the keychain item it leaves behind.
local Connect: any = require("../../../plugin/lib/settings/connect")
local Fixtures = require("../../lib/fixtures")
local State: any = require("../../../plugin/lib/settings/state")
local Validate: any = require("../../../plugin/lib/config/validate")
local View = require("../../../plugin/lib/settings/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ENV: any = { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null }
local PATH = "/home/u/.config/tern-grafana/config.json"
local TOKEN = "glsa_TOKENMARK_0123456789abcdef_9a8b7c6d"
local GRAFANA = "grafana/12.4.12/"

local EXISTING = [[
{
  "version": 1,
  "default_context": "lab",
  "contexts": {
    "lab": {
      "grafana": {"url": "http://localhost:3000", "auth": {"type": "bearer", "token_env": "GRAFANA_TOKEN"},
        "headers": {"X-Team": "ops"}, "org_id": 1, "datasources": {"prometheus": "prom2"}},
      "prometheus": {"url": "http://localhost:9090"}
    }
  }
}
]]

-- Every effect and message produced while driving the flow, checked for the token.
local seen: { any } = {}

local function key(name: string, text: string?): any
	return {
		name = name,
		text = text or (if #name == 1 then name else nil),
		ctrl = false,
		alt = false,
		shift = false,
		meta = false,
	}
end

local function record(effects: { any })
	for _, e in effects do
		table.insert(seen, e)
	end
end

local function press(s: any, ...: string): (any, { any })
	local all = {}
	for _, name in { ... } do
		local effects
		s, effects = State.key(s, key(name), ENV)
		record(effects)
		for _, e in effects do
			table.insert(all, e)
		end
	end
	return s, all
end

local function typeText(s: any, text: string): any
	for i = 1, #text do
		local ch = string.sub(text, i, i)
		local effects
		s, effects = State.key(s, key(ch, ch), ENV)
		record(effects)
	end
	return s
end

local function paste(s: any, text: string): (any, { any })
	local after, effects = State.key(s, key("paste", text), ENV)
	record(effects)
	return after, effects
end

local function update(s: any, msg: any): (any, { any })
	local after, effects = State.update(s, msg, ENV)
	record(effects)
	return after, effects
end

local function act(s: any, name: string, value: string?): (any, { any })
	return update(s, { kind = "event", ev = { ev = "action", act = name, value = value } })
end

local function loaded(text: string?, platform: string?): any
	local s = State.init({}, nil, ENV)
	s = update(s, { kind = "config_file", path = PATH, text = text, exists = text ~= nil })
	s = update(s, { kind = "credentials_platform", platform = platform })
	return s
end

local function ofKind(effects: { any }, kind: string): { any }
	local out = {}
	for _, e in effects do
		if e.kind == kind then
			table.insert(out, e)
		end
	end
	return out
end

local function ok(body: string, status: number?): any
	return { status = status or 200, headers = {}, body = body, timed_out = false }
end

local ACTIONS_EDITOR = '{"annotations:create": true, "alert.silences:create": true, "dashboards:read": true}'
local ACTIONS_VIEWER = '{"annotations:read": true, "alert.silences:read": true, "dashboards:read": true}'

-- Answers the test requests among `effects`.
local function answer(s: any, effects: { any }, bodies: { [string]: any }): any
	for _, e in ofKind(effects, "http") do
		local step = string.match(e.tag, "|(%a+)$") :: string
		s = update(s, { kind = "http_done", tag = e.tag, response = bodies[step] })
	end
	return s
end

local GOOD = {
	user = ok(Fixtures.read(GRAFANA .. "user.json")),
	frontend = ok(Fixtures.read(GRAFANA .. "frontend_settings.json")),
	actions = ok(ACTIONS_EDITOR),
}

-- Opens Connect on a missing file, types the URL and pastes the token.
local function filled(platform: string?): any
	local s = press(loaded(nil, platform), "enter")
	s = typeText(s, "localhost:3000/")
	s = press(s, "enter")
	expect(s.editing.id).toBe("token")
	s = paste(s, "  " .. TOKEN .. "\n")
	s = press(s, "enter")
	return s
end

local function tested(platform: string?, bodies: any?): any
	local s, effects = press(filled(platform), "t")
	return answer(s, effects, bodies or GOOD)
end

local function stripped(e: any): any
	local copy: any = table.clone(e)
	if copy.kind == "http" then
		expect(copy.request.headers.Authorization).toBe("Bearer " .. TOKEN)
		local request: any = table.clone(copy.request)
		request.headers = nil
		copy.request = request
	elseif copy.kind == "credential_store" then
		expect(copy.secret).toBe(TOKEN)
		copy.secret = nil
	end
	return copy
end

local function assertNoLeak(s: any)
	local function clean(what: string, text: string)
		if string.find(text, TOKEN, 1, true) or string.find(text, "TOKENMARK", 1, true) then
			error(what .. " leaks the token: " .. text)
		end
	end
	clean("view", json.encode(View.view(s, ENV)))
	clean("save", json.encode(State.save(s)))
	clean("title", tostring(State.title(s)))
	clean("message", json.encode(s.message or {}))
	for _, e in seen do
		clean("effect " .. tostring(e.kind), json.encode(stripped(e)))
	end
end

describe("connect: the token stays secret", function()
	it("never appears outside the test requests' header and the keychain store effect", function()
		table.clear(seen)
		local s = tested("macos")
		assertNoLeak(s)
		local after, effects = press(s, "w")
		expect(#ofKind(effects, "credential_store")).toBe(1)
		expect(#ofKind(effects, "config_write")).toBe(0)
		assertNoLeak(after)
		local written
		written, effects = update(after, { kind = "credential_stored", item = "localhost/grafana", ok = true })
		expect(written.connect.token).toBe("")
		local w = ofKind(effects, "config_write")
		expect(#w).toBe(1)
		assertNoLeak(written)
		local done = update(written, { kind = "config_written", ok = true })
		expect(done.connect).toBeNil()
		expect(done.page).toBe("list")
		assertNoLeak(done)
	end)

	it("masks the token while it is typed, in the input and the field", function()
		table.clear(seen)
		local s = press(loaded(nil, "macos"), "enter")
		s = press(s, "enter")
		expect(s.editing.id).toBe("token")
		s = typeText(s, "glsa_TOKENMARK")
		local view = json.encode(View.view(s, ENV))
		expect(view).toContain("••••••••••••••")
		expect((string.find(view, "TOKENMARK", 1, true))).toBeNil()
		expect(json.encode(State.save(s))).toBe(json.encode(State.save(loaded(nil, "macos"))))
	end)

	it("redacts the token from a transport error", function()
		table.clear(seen)
		local s, effects = press(filled("macos"), "t")
		local bad = {
			status = 0,
			headers = {},
			body = "",
			timed_out = false,
			failure = { kind = "network", message = "invalid header value Bearer " .. TOKEN },
		}
		s = answer(s, effects, { user = bad, frontend = bad, actions = bad })
		expect(s.connect.phase).toBe("edit")
		expect(s.connect.failure.message).toContain("[redacted]")
		assertNoLeak(s)
	end)
end)

describe("connect: paste", function()
	it("takes a pasted token whole, dropping whitespace and line breaks", function()
		local s = filled("macos")
		expect(s.connect.token).toBe(TOKEN)
	end)

	it("a paste on the selected token field replaces it without entering edit mode", function()
		local s = filled("macos")
		s = press(s, "k")
		expect(State.connectFields(s)[s.form_sel].id).toBe("token")
		s = paste(s, "glsa_other\r\n")
		expect(s.editing).toBeNil()
		expect(s.connect.token).toBe("glsa_other")
	end)
end)

describe("connect: test before store", function()
	it("stores nothing before Grafana accepted the token", function()
		local s, effects = press(filled("macos"), "w")
		expect(#ofKind(effects, "credential_store")).toBe(0)
		expect(#ofKind(effects, "config_write")).toBe(0)
		expect(s.message.text).toContain("test the token first")
	end)

	it("a rejected token is reported with the fix and blocks storing", function()
		local s = tested("macos", {
			user = ok(Fixtures.read(GRAFANA .. "user_unauthorized.json"), 401),
			frontend = ok(Fixtures.read(GRAFANA .. "user_unauthorized.json"), 401),
			actions = ok(Fixtures.read(GRAFANA .. "user_unauthorized.json"), 401),
		})
		expect(s.connect.phase).toBe("edit")
		expect(s.connect.failure.hint).toContain("rejected the token")
		local _, effects = press(s, "w")
		expect(#ofKind(effects, "credential_store")).toBe(0)
	end)

	it("changing the URL or token after a test needs a new test", function()
		local s = tested("macos")
		expect(s.connect.phase).toBe("tested")
		s = press(s, "k")
		expect(State.connectFields(s)[s.form_sel].id).toBe("token")
		s = paste(s, "glsa_new")
		local _, effects = press(s, "w")
		expect(#ofKind(effects, "credential_store")).toBe(0)
		s = press(s, "k")
		s = paste(s, "http://localhost:3011")
		expect(s.connect.phase).toBe("edit")
	end)

	it("drops answers to a superseded test", function()
		local s, first = press(filled("macos"), "t")
		s = press(s, "t")
		s = answer(s, first, GOOD)
		expect(s.connect.phase).toBe("testing")
	end)

	it("shows identity, version and role warnings for a Viewer token", function()
		local s = tested("macos", {
			user = GOOD.user,
			frontend = GOOD.frontend,
			actions = ok(ACTIONS_VIEWER),
		})
		local view = json.encode(View.view(s, ENV))
		expect(view).toContain("Signed in as sa-1-tern-dev")
		expect(view).toContain("Grafana 12.4.12")
		expect(view).toContain("silences or annotations (Viewer role)")
		local editor = json.encode(View.view(tested("macos"), ENV))
		expect((string.find(editor, "Viewer role", 1, true))).toBeNil()
	end)

	it("a failed keychain store keeps the token so the user can retry or switch to env", function()
		local s = press(tested("macos"), "w")
		s = update(s, { kind = "credential_stored", item = "localhost/grafana", ok = false, error = "keychain locked" })
		expect(s.connect.phase).toBe("tested")
		expect(s.connect.token).toBe(TOKEN)
		expect(s.message.text).toContain("keychain locked")
	end)
end)

describe("connect: datasource discovery", function()
	it("picks the default datasource and leaves Alertmanager on Grafana-managed alerting", function()
		local s = tested("macos")
		expect(s.connect.picks).toEqual({ prometheus = "prom3", loki = "loki", tempo = "tempo", alertmanager = "" })
	end)

	local CLOUD = [[{"datasources": {
		"grafanacloud-usage": {"uid": "grafanacloud-usage", "type": "prometheus", "name": "grafanacloud-usage", "isDefault": false},
		"grafanacloud-ml-metrics": {"uid": "grafanacloud-ml-metrics", "type": "prometheus", "name": "grafanacloud-ml-metrics", "isDefault": false},
		"grafanacloud-mystack-prom": {"uid": "grafanacloud-mystack-prom", "type": "prometheus", "name": "grafanacloud-mystack-prom", "isDefault": false},
		"grafanacloud-mystack-alert-state-history": {"uid": "grafanacloud-mystack-alert-state-history", "type": "loki", "name": "grafanacloud-mystack-alert-state-history", "isDefault": false},
		"grafanacloud-mystack-logs": {"uid": "grafanacloud-mystack-logs", "type": "loki", "name": "grafanacloud-mystack-logs", "isDefault": false},
		"grafanacloud-mystack-traces": {"uid": "grafanacloud-mystack-traces", "type": "tempo", "name": "grafanacloud-mystack-traces", "isDefault": false},
		"-- Grafana --": {"uid": "grafana", "type": "datasource", "name": "-- Grafana --", "isDefault": false},
		"-- Mixed --": {"type": "datasource", "name": "-- Mixed --", "isDefault": false}
	}}]]

	it("prefers a Grafana Cloud stack's own uids over its internal datasources", function()
		local candidates = Connect.discover(json.decode(CLOUD), ENV)
		expect(Connect.choose(candidates, {})).toEqual({
			prometheus = "grafanacloud-mystack-prom",
			loki = "grafanacloud-mystack-logs",
			tempo = "grafanacloud-mystack-traces",
			alertmanager = "",
		})
		expect(candidates.prometheus[3].uid).toBe("grafanacloud-usage")
	end)

	it("the default datasource wins over a Cloud uid", function()
		local doc =
			string.gsub(CLOUD, '"grafanacloud%-usage", "isDefault": false', '"grafanacloud-usage", "isDefault": true')
		local candidates = Connect.discover(json.decode(doc), ENV)
		expect(Connect.choose(candidates, {}).prometheus).toBe("grafanacloud-usage")
	end)

	it("lets the user cycle through several candidates and none", function()
		local s = tested("macos")
		local fields = State.connectFields(s)
		local at
		for i, f in fields do
			if f.id == "ds.prometheus" then
				at = i
				expect(f.values).toEqual({ "prom3", "prom2", "" })
			end
		end
		s = table.clone(s)
		s.form_sel = at
		s = press(s, "right")
		expect(s.connect.picks.prometheus).toBe("prom2")
		s = press(s, "right")
		expect(s.connect.picks.prometheus).toBe("")
		local after = press(s, "w")
		after = update(after, { kind = "credential_stored", item = "localhost/grafana", ok = true })
		local w = ofKind(seen, "config_write")
		local cfg = Validate.parseFile(w[#w].text, json.decode)
		expect(cfg.contexts.localhost.grafana.datasources.prometheus).toBeNil()
		expect(cfg.contexts.localhost.grafana.datasources.loki).toBe("loki")
		expect(after.connect_writing).toBe(true)
	end)
end)

describe("connect: storage", function()
	it("writes a keychain reference named after the context and makes it the default", function()
		table.clear(seen)
		local s = press(tested("macos"), "w")
		local store = ofKind(seen, "credential_store")[1]
		expect(store.item).toBe("localhost/grafana")
		update(s, { kind = "credential_stored", item = "localhost/grafana", ok = true })
		local w = ofKind(seen, "config_write")
		expect(#w).toBe(1)
		expect(w[1].base_hash).toBeNil()
		local cfg, problems = Validate.parseFile(w[1].text, json.decode)
		expect(problems).toEqual({})
		expect(cfg.default_context).toBe("localhost")
		expect(cfg.contexts.localhost.grafana.url).toBe("https://localhost:3000")
		expect(cfg.contexts.localhost.grafana.auth.token).toEqual({
			from = "keychain",
			field = "token_keychain",
			item = "localhost/grafana",
		})
	end)

	it("offers only an environment variable without a keychain tool, and validates its name", function()
		table.clear(seen)
		local s = tested(nil)
		expect(s.connect.storage).toBe("env")
		local c, problem = Connect.setField(s.connect, "env_name", "MY-TOKEN")
		expect(problem).toContain("letters, digits and '_'")
		expect(c.env_name).toBe("GRAFANA_TOKEN")
		c = Connect.setField(s.connect, "env_name", "GRAFANA_PROD_TOKEN")
		s = table.clone(s)
		s.connect = c
		local after, effects = press(s, "w")
		expect(#ofKind(effects, "credential_store")).toBe(0)
		local w = ofKind(effects, "config_write")
		expect(#w).toBe(1)
		expect(after.connect.token).toBe("")
		local cfg = Validate.parseFile(w[1].text, json.decode)
		expect(cfg.contexts.localhost.grafana.auth.token.name).toBe("GRAFANA_PROD_TOKEN")
		local done = update(after, { kind = "config_written", ok = true })
		expect(done.message.text).toContain("Set GRAFANA_PROD_TOKEN")
		assertNoLeak(done)
	end)

	it("refuses a context that already has a Grafana endpoint and points at Update token", function()
		local s = press(loaded(EXISTING, "macos"), "c")
		s = typeText(s, "http://localhost:3000")
		s = press(s, "enter")
		s = paste(s, TOKEN)
		s = press(s, "enter")
		s = table.clone(s)
		s.connect = Connect.setField(s.connect, "context", "lab")
		expect(s.connect.context).toBe("lab")
		local tagged, effects = press(s, "t")
		s = answer(tagged, effects, GOOD)
		local _, saved = press(s, "w")
		expect(#ofKind(saved, "credential_store")).toBe(0)
	end)
end)

describe("connect: normalizing what the user pastes", function()
	it("adds https, drops page paths of Cloud URLs and derives the context name", function()
		expect(Connect.normalizeUrl("you.grafana.net/d/abc/x?orgId=1")).toBe("https://you.grafana.net")
		expect(Connect.normalizeUrl("https://grafana.example.com/grafana/")).toBe("https://grafana.example.com/grafana")
		expect(select(2, Connect.normalizeUrl("ftp://x"))).toContain("http")
		expect(select(2, Connect.normalizeUrl("https://user:pw@x"))).toContain("credentials")
		expect(Connect.contextFromUrl("https://you.grafana.net")).toBe("you")
		expect(Connect.contextFromUrl("http://localhost:3000")).toBe("localhost")
	end)
end)

describe("update token", function()
	it("re-runs the flow for an existing endpoint and keeps its other settings", function()
		table.clear(seen)
		local s = loaded(EXISTING, "macos")
		s = act(s, "update_token", "lab")
		expect(s.page).toBe("connect")
		expect(s.connect.mode).toBe("update")
		expect(s.connect.storage).toBe("env")
		expect(s.editing.id).toBe("token")
		s = paste(s, TOKEN)
		s = press(s, "enter")
		local effects
		s, effects = press(s, "t")
		-- The test talks to the server the way the plugin will: saved headers and org apply.
		local http = ofKind(effects, "http")[1]
		expect(http.route.endpoint.headers["X-Team"]).toBe("ops")
		expect(http.route.endpoint.org_id).toBe(1)
		s = answer(s, effects, GOOD)
		-- A previous pick that still exists is kept.
		expect(s.connect.picks.prometheus).toBe("prom2")
		s = act(s, "cfield", "storage")
		expect(s.connect.storage).toBe("keychain")
		s = press(s, "w")
		s = update(s, { kind = "credential_stored", item = "lab/grafana", ok = true })
		local w = ofKind(seen, "config_write")
		local cfg = Validate.parseFile(w[#w].text, json.decode)
		local g = cfg.contexts.lab.grafana
		expect(g.auth.token.item).toBe("lab/grafana")
		expect(g.headers["X-Team"]).toBe("ops")
		expect(g.org_id).toBe(1)
		expect(cfg.contexts.lab.prometheus.url).toBe("http://localhost:9090")
		assertNoLeak(s)
	end)
end)

describe("removing a context whose token is in the keychain", function()
	local KEYCHAIN = [[
{
  "version": 1,
  "contexts": {
    "cloud": {"grafana": {"url": "https://you.grafana.net", "auth": {"type": "bearer", "token_keychain": "cloud/grafana"}}},
    "lab": {"grafana": {"url": "http://localhost:3000", "auth": {"type": "bearer", "token_keychain": "shared/grafana"}}},
    "lab2": {"grafana": {"url": "http://localhost:3011", "auth": {"type": "bearer", "token_keychain": "shared/grafana"}}}
  }
}
]]

	it("offers to delete the item and deletes it once the file no longer references it", function()
		local s = loaded(KEYCHAIN, "macos")
		s = act(s, "remove", "cloud")
		expect(s.confirm.items).toEqual({ "cloud/grafana" })
		expect(json.encode(View.view(s, ENV))).toContain("Remove and delete the keychain item")
		local effects
		s, effects = press(s, "y")
		expect(#ofKind(effects, "config_write")).toBe(1)
		expect(#ofKind(effects, "credential_delete")).toBe(0)
		s, effects = update(s, { kind = "config_written", ok = true })
		expect(ofKind(effects, "credential_delete")).toEqual({ { kind = "credential_delete", item = "cloud/grafana" } })
		s = update(s, { kind = "credential_deleted", item = "cloud/grafana", ok = true })
		expect(s.message.text).toContain("cloud/grafana deleted")
	end)

	it("keeps the item when asked, and when the write fails", function()
		local s, effects = press(act(loaded(KEYCHAIN, "macos"), "remove", "cloud"), "k")
		expect(#ofKind(effects, "config_write")).toBe(1)
		local _
		_, effects = update(s, { kind = "config_written", ok = true })
		expect(#ofKind(effects, "credential_delete")).toBe(0)
		s = press(act(loaded(KEYCHAIN, "macos"), "remove", "cloud"), "y")
		_, effects = update(s, { kind = "config_written", ok = false, conflict = true })
		expect(#ofKind(effects, "credential_delete")).toBe(0)
	end)

	it("does not offer an item another context still uses", function()
		local s = act(loaded(KEYCHAIN, "macos"), "remove", "lab")
		expect(s.confirm.items).toEqual({})
		expect((string.find(json.encode(View.view(s, ENV)), "keychain", 1, true))).toBeNil()
	end)
end)

return nil
