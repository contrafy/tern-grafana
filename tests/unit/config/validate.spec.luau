--!strict
-- The config file is hand-edited JSON that decides where tokens come from and
-- which servers receive them. A mistake must fail loudly with a message that
-- names the JSON path and says how to fix it, and a literal secret must never
-- be accepted, because the file is plain text that gets copied, synced and
-- pasted into issues.
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function parse(text: string): (any, { any })
	return Validate.parseFile(text, json.decode)
end

local function messages(problems: { any }): { string }
	local out = {}
	for i, p in problems do
		out[i] = Validate.format(p)
	end
	return out
end

-- One context named lab whose prometheus endpoint is `endpoint` (JSON text).
local function withProm(endpoint: string): (any, { string })
	local cfg, problems = parse('{"contexts": {"lab": {"prometheus": ' .. endpoint .. "}}}")
	return cfg, messages(problems)
end

local function withGrafana(endpoint: string): (any, { string })
	local cfg, problems = parse('{"contexts": {"lab": {"grafana": ' .. endpoint .. "}}}")
	return cfg, messages(problems)
end

describe("minimal config", function()
	it("fills every default so callers never handle missing fields", function()
		local cfg, problems = withProm('{"url": "http://localhost:9090"}')
		expect(problems).toEqual({})
		expect(cfg.version).toBe(1)
		local prom = cfg.contexts.lab.prometheus
		expect(prom.url).toBe("http://localhost:9090")
		expect(prom.timeout_ms).toBe(15000)
		expect(prom.timeout_ms).toBe(Validate.DEFAULT_TIMEOUT_MS)
		expect(prom.auth).toEqual({ type = "none" })
		expect(prom.headers).toEqual({})
		expect(prom.path_prefix).toBe("")
		expect(prom.tls).toBeNil()
		expect(cfg.contexts.lab.name).toBe("lab")
	end)

	it("makes the only context the default so a one-context setup needs no default_context", function()
		local cfg = withProm('{"url": "http://localhost:9090"}')
		expect(cfg.default_context).toBe("lab")
	end)

	it("leaves the default unset with several contexts rather than guessing", function()
		local cfg, problems = parse([[{"contexts": {
			"a": {"prometheus": {"url": "http://a:9090"}},
			"b": {"prometheus": {"url": "http://b:9090"}}}}]])
		expect(problems).toEqual({})
		expect(cfg.default_context).toBeNil()
	end)

	it("strips trailing slashes from urls so joined paths never double them", function()
		local cfg = withProm('{"url": "https://prom.example.com/"}')
		expect(cfg.contexts.lab.prometheus.url).toBe("https://prom.example.com")
	end)

	it("normalizes path_prefix to a leading slash and no trailing slash", function()
		expect((withProm('{"url": "http://h", "path_prefix": "prometheus/"}')).contexts.lab.prometheus.path_prefix).toBe(
			"/prometheus"
		)
		expect((withProm('{"url": "http://h", "path_prefix": "/"}')).contexts.lab.prometheus.path_prefix).toBe("")
	end)

	it("treats an all-default tls block as no tls, so it does not force curl", function()
		local cfg, problems = withProm('{"url": "http://h", "tls": {"ca_file": null, "insecure": false}}')
		expect(problems).toEqual({})
		expect(cfg.contexts.lab.prometheus.tls).toBeNil()
	end)

	it("accepts the architecture example verbatim", function()
		local cfg, problems = parse([[{
			"version": 1,
			"default_context": "lab",
			"contexts": {
				"lab": {
					"grafana": {
						"url": "http://localhost:3000",
						"auth": { "type": "bearer", "token_cmd": ["op", "read", "op://dev/grafana/token"] },
						"org_id": 1,
						"datasources": { "prometheus": "prom3", "loki": "loki", "tempo": "tempo", "alertmanager": "am" }
					},
					"prometheus": {
						"url": "http://localhost:9090",
						"auth": { "type": "none" },
						"headers": { "X-Scope-OrgID": "tenant-1" },
						"path_prefix": "",
						"tls": { "ca_file": null, "cert_file": null, "key_file": null, "insecure": false },
						"timeout_ms": 15000
					},
					"alertmanager": { "url": "http://localhost:9093" },
					"loki": { "url": "http://localhost:3100" },
					"tempo": { "url": "http://localhost:3200" }
				}
			}
		}]])
		expect(messages(problems)).toEqual({})
		local g = cfg.contexts.lab.grafana
		expect(g.auth).toEqual({
			type = "bearer",
			token = { from = "cmd", field = "token_cmd", argv = { "op", "read", "op://dev/grafana/token" } },
		})
		expect(g.org_id).toBe(1)
		expect(g.datasources).toEqual({ prometheus = "prom3", loki = "loki", tempo = "tempo", alertmanager = "am" })
		expect(cfg.contexts.lab.prometheus.headers).toEqual({ ["X-Scope-OrgID"] = "tenant-1" })
	end)
end)

describe("feature sections", function()
	it("keeps later-milestone sections untouched instead of rejecting them", function()
		local cfg, problems = parse([[{
			"contexts": {"lab": {"prometheus": {"url": "http://h"}}},
			"query": {"history": 50},
			"alerts": {"toasts": true},
			"annotations": {"patterns": ["helm upgrade"]},
			"impact": {"minutes": 10},
			"watches": [{"expr": "up == 0"}],
			"hosts": {"bastion": "lab"}
		}]])
		expect(problems).toEqual({})
		expect(cfg.query).toEqual({ history = 50 })
		expect(cfg.alerts).toEqual({ toasts = true })
		expect(cfg.annotations).toEqual({ patterns = { "helm upgrade" } })
		expect(cfg.impact).toEqual({ minutes = 10 })
		expect(cfg.watches).toEqual({ { expr = "up == 0" } })
		expect(cfg.hosts).toEqual({ bastion = "lab" })
	end)

	it("rejects other unknown top-level fields, so typos are caught", function()
		local cfg, problems = parse('{"contexts": {"lab": {"prometheus": {"url": "http://h"}}}, "contxts": {}}')
		expect(cfg).toBeNil()
		expect(messages(problems)).toEqual({
			"contxts: unknown field; expected one of alerts, annotations, contexts, dashboard, default_context, hosts, impact, query, version, watches",
		})
	end)
end)

describe("file-level errors", function()
	it("reports malformed JSON instead of raising", function()
		local cfg, problems = parse("{")
		expect(cfg).toBeNil()
		expect(#problems).toBe(1)
		expect(messages(problems)[1]).toContain("invalid JSON")
	end)

	it("requires an object at the top", function()
		local _, problems = parse("[1]")
		expect(messages(problems)).toEqual({ "config: the file must contain a JSON object" })
	end)

	it("rejects a version this plugin does not understand", function()
		local _, problems = parse('{"version": 2, "contexts": {"lab": {"prometheus": {"url": "http://h"}}}}')
		expect(messages(problems)).toEqual({ "version: unsupported version 2; this plugin reads version 1" })
	end)

	it("requires at least one context", function()
		expect(messages(select(2, parse("{}")))).toEqual({
			"contexts: is required: an object mapping context names to endpoints",
		})
		expect(messages(select(2, parse('{"contexts": {}}')))).toEqual({
			"contexts: must define at least one context",
		})
	end)

	it("requires at least one endpoint per context", function()
		local _, problems = parse('{"contexts": {"lab": {}}}')
		expect(messages(problems)).toEqual({
			"contexts.lab: must configure at least one of grafana, prometheus, alertmanager, loki, tempo",
		})
	end)

	it("names a misspelled endpoint and the valid choices", function()
		local _, problems = parse('{"contexts": {"lab": {"promethues": {"url": "http://h"}}}}')
		expect(messages(problems)).toEqual({
			"contexts.lab.promethues: unknown field; expected one of alertmanager, grafana, loki, prometheus, tempo",
			"contexts.lab: must configure at least one of grafana, prometheus, alertmanager, loki, tempo",
		})
	end)

	it("rejects context names that cannot be used in links and keys", function()
		local _, problems = parse('{"contexts": {"my lab": {"prometheus": {"url": "http://h"}}}}')
		expect(messages(problems)).toEqual({
			"contexts.my lab: context names may only contain letters, digits, '.', '_' and '-'",
		})
	end)

	it("requires default_context to name a defined context", function()
		local _, problems = parse([[{"default_context": "prod",
			"contexts": {"lab": {"prometheus": {"url": "http://h"}}, "dev": {"loki": {"url": "http://l"}}}}]])
		expect(messages(problems)).toEqual({ 'default_context: no context named "prod" (defined: dev, lab)' })
	end)

	it("reports every problem at once, in a stable order", function()
		local _, problems = parse([[{"contexts": {
			"b": {"prometheus": {"url": "ftp://x"}},
			"a": {"loki": {"url": "http://l", "timeout_ms": 0}}}}]])
		expect(messages(problems)).toEqual({
			"contexts.a.loki.timeout_ms: must be an integer between 1 and 600000 (milliseconds)",
			'contexts.b.prometheus.url: must be an http(s) URL, got "ftp://x"',
		})
	end)
end)

describe("endpoint fields", function()
	it("requires a url", function()
		local cfg, problems = withProm("{}")
		expect(cfg).toBeNil()
		expect(problems).toEqual({ "contexts.lab.prometheus.url: is required" })
	end)

	it("requires the url to be absolute http(s)", function()
		expect(select(2, withProm('{"url": "localhost:9090"}'))).toEqual({
			'contexts.lab.prometheus.url: must be an http(s) URL, got "localhost:9090"',
		})
		expect(select(2, withProm('{"url": 9090}'))).toEqual({
			"contexts.lab.prometheus.url: must be an http(s) URL",
		})
		expect(select(2, withProm('{"url": "http://"}'))).toEqual({
			'contexts.lab.prometheus.url: must be an http(s) URL, got "http://"',
		})
	end)

	it("rejects credentials in the url without echoing them", function()
		local _, problems = withProm('{"url": "https://admin:hunter2@prom.example.com"}')
		expect(problems).toEqual({
			'contexts.lab.prometheus.url: must not contain credentials; configure auth (type "basic" or "bearer") instead',
		})
	end)

	it("rejects a query or fragment, which would break path joining", function()
		expect(select(2, withProm('{"url": "http://h/?x=1"}'))).toEqual({
			"contexts.lab.prometheus.url: must not contain a query or fragment",
		})
	end)

	it("bounds timeout_ms", function()
		local msg = "contexts.lab.prometheus.timeout_ms: must be an integer between 1 and 600000 (milliseconds)"
		expect(select(2, withProm('{"url": "http://h", "timeout_ms": 1.5}'))).toEqual({ msg })
		expect(select(2, withProm('{"url": "http://h", "timeout_ms": 600001}'))).toEqual({ msg })
		expect((withProm('{"url": "http://h", "timeout_ms": 600000}')).contexts.lab.prometheus.timeout_ms).toBe(600000)
	end)

	it("rejects grafana-only fields on direct endpoints", function()
		expect(select(2, withProm('{"url": "http://h", "org_id": 2}'))).toEqual({
			"contexts.lab.prometheus.org_id: unknown field; expected one of auth, headers, path_prefix, timeout_ms, tls, url",
		})
	end)

	it("validates grafana extras", function()
		local _, problems = withGrafana([[{"url": "http://g", "org_id": 0, "browser_url": "g.example.com",
			"datasources": {"prometheus": "", "graphite": "x"}}]])
		expect(problems).toEqual({
			'contexts.lab.grafana.browser_url: must be an http(s) URL, got "g.example.com"',
			"contexts.lab.grafana.datasources.graphite: unknown field; expected one of alertmanager, loki, prometheus, tempo",
			"contexts.lab.grafana.datasources.prometheus: must be a non-empty datasource uid",
			"contexts.lab.grafana.org_id: must be a positive integer",
		})
	end)

	it("keeps browser_url normalized like url", function()
		local cfg = withGrafana('{"url": "http://grafana:3000", "browser_url": "https://grafana.example.com/"}')
		expect(cfg.contexts.lab.grafana.browser_url).toBe("https://grafana.example.com")
	end)

	it("rejects a path_prefix that carries a query", function()
		expect(select(2, withProm('{"url": "http://h", "path_prefix": "/p?x"}'))).toEqual({
			"contexts.lab.prometheus.path_prefix: must be a URL path without '?' or '#'",
		})
	end)
end)

describe("headers", function()
	it("keeps tenant headers verbatim", function()
		local cfg = withProm('{"url": "http://h", "headers": {"X-Scope-OrgID": "team-a|team-b"}}')
		expect(cfg.contexts.lab.prometheus.headers).toEqual({ ["X-Scope-OrgID"] = "team-a|team-b" })
	end)

	it("refuses an Authorization header in any case, since that would be a literal secret", function()
		expect(select(2, withProm('{"url": "http://h", "headers": {"authorization": "Bearer x"}}'))).toEqual({
			"contexts.lab.prometheus.headers.authorization: set credentials with auth, not a literal header",
		})
	end)

	it("refuses line breaks, which would inject extra headers", function()
		expect(select(2, withProm('{"url": "http://h", "headers": {"X-A": "a\\r\\nX-B: b"}}'))).toEqual({
			"contexts.lab.prometheus.headers.X-A: must not contain line breaks",
		})
	end)

	it("refuses invalid header names and non-string values", function()
		expect(select(2, withProm('{"url": "http://h", "headers": {"Bad Name": "x", "X-N": 1}}'))).toEqual({
			"contexts.lab.prometheus.headers.Bad Name: not a valid HTTP header name",
			"contexts.lab.prometheus.headers.X-N: must be a string",
		})
	end)
end)

describe("auth", function()
	it("accepts each bearer source", function()
		local env = withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token_env": "GRAFANA_TOKEN"}}')
		expect(env.contexts.lab.grafana.auth.token).toEqual({
			from = "env",
			field = "token_env",
			name = "GRAFANA_TOKEN",
		})
		local file = withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token_file": "~/.config/g/token"}}')
		expect(file.contexts.lab.grafana.auth.token).toEqual({
			from = "file",
			field = "token_file",
			path = "~/.config/g/token",
		})
	end)

	it("accepts basic auth with a password source", function()
		local cfg = withGrafana([[{"url": "http://g", "auth": {"type": "basic", "username": "123456",
			"password_cmd": ["security", "find-generic-password", "-s", "grafana", "-w"]}}]])
		expect(cfg.contexts.lab.grafana.auth).toEqual({
			type = "basic",
			username = "123456",
			password = {
				from = "cmd",
				field = "password_cmd",
				argv = { "security", "find-generic-password", "-s", "grafana", "-w" },
			},
		})
	end)

	it("rejects a literal token and points at the safe alternatives", function()
		local cfg, problems = withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token": "glsa_abc"}}')
		expect(cfg).toBeNil()
		expect(problems).toEqual({
			"contexts.lab.grafana.auth.token: secrets cannot be written in the config file; use token_cmd, token_env or token_file",
			"contexts.lab.grafana.auth: bearer auth needs one of token_cmd, token_env, token_file",
		})
	end)

	it("rejects a literal password and points at the safe alternatives", function()
		local _, problems =
			withGrafana('{"url": "http://g", "auth": {"type": "basic", "username": "u", "password": "p"}}')
		expect(problems).toEqual({
			"contexts.lab.grafana.auth.password: secrets cannot be written in the config file; use password_cmd, password_env or password_file",
			"contexts.lab.grafana.auth: basic auth needs one of password_cmd, password_env, password_file",
		})
	end)

	it("rejects literal secrets placed directly on the endpoint", function()
		local _, problems = withGrafana('{"url": "http://g", "token": "glsa_abc", "password": "p"}')
		expect(problems).toEqual({
			"contexts.lab.grafana.password: secrets cannot be written in the config file; set auth with password_cmd, password_env or password_file",
			"contexts.lab.grafana.token: secrets cannot be written in the config file; set auth with token_cmd, token_env or token_file",
		})
	end)

	it("never echoes a literal secret in a message", function()
		local _, problems = withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token": "glsa_SECRET"}}')
		for _, m in problems do
			expect((string.find(m, "SECRET", 1, true))).toBeNil()
		end
	end)

	it("requires exactly one source", function()
		expect(
			select(
				2,
				withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token_env": "A", "token_file": "/t"}}')
			)
		).toEqual({
			"contexts.lab.grafana.auth: set only one of token_cmd, token_env, token_file",
		})
	end)

	it("rejects source fields that do not belong to the auth type", function()
		expect(select(2, withGrafana('{"url": "http://g", "auth": {"type": "none", "token_env": "A"}}'))).toEqual({
			'contexts.lab.grafana.auth.token_env: not used by auth type "none"; expected one of type',
		})
		expect(
			select(
				2,
				withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token_env": "A", "password_env": "B"}}')
			)
		).toEqual({
			'contexts.lab.grafana.auth.password_env: not used by auth type "bearer"; expected one of token_cmd, token_env, token_file, type',
		})
	end)

	it("requires a known auth type", function()
		expect(select(2, withGrafana('{"url": "http://g", "auth": {"type": "oauth"}}'))).toEqual({
			'contexts.lab.grafana.auth.type: must be one of "none", "bearer", "basic"',
		})
		expect(select(2, withGrafana('{"url": "http://g", "auth": {"token_env": "A"}}'))).toEqual({
			'contexts.lab.grafana.auth.type: must be one of "none", "bearer", "basic"',
		})
	end)

	it("checks each source's shape", function()
		expect(select(2, withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token_cmd": []}}'))).toEqual({
			'contexts.lab.grafana.auth.token_cmd: must be a non-empty array of strings, for example ["op", "read", "op://vault/item/token"]',
		})
		expect(select(2, withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token_cmd": ["op", 1]}}'))).toEqual({
			'contexts.lab.grafana.auth.token_cmd: must be a non-empty array of strings, for example ["op", "read", "op://vault/item/token"]',
		})
		expect(select(2, withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token_env": "MY-TOKEN"}}'))).toEqual({
			"contexts.lab.grafana.auth.token_env: must be an environment variable name such as GRAFANA_TOKEN",
		})
		expect(select(2, withGrafana('{"url": "http://g", "auth": {"type": "bearer", "token_file": "token.txt"}}'))).toEqual({
			"contexts.lab.grafana.auth.token_file: must be an absolute path or start with ~/",
		})
	end)

	it("requires a basic username without a colon", function()
		expect(select(2, withGrafana('{"url": "http://g", "auth": {"type": "basic", "password_env": "P"}}'))).toEqual({
			"contexts.lab.grafana.auth.username: is required for basic auth",
		})
		expect(
			select(
				2,
				withGrafana('{"url": "http://g", "auth": {"type": "basic", "username": "a:b", "password_env": "P"}}')
			)
		).toEqual({
			"contexts.lab.grafana.auth.username: must not contain ':'",
		})
	end)
end)

describe("tls", function()
	it("keeps set fields", function()
		local cfg, problems = withProm([[{"url": "https://h",
			"tls": {"ca_file": "/etc/ca.pem", "cert_file": "~/c.pem", "key_file": "~/k.pem"}}]])
		expect(problems).toEqual({})
		expect(cfg.contexts.lab.prometheus.tls).toEqual({
			ca_file = "/etc/ca.pem",
			cert_file = "~/c.pem",
			key_file = "~/k.pem",
			insecure = false,
		})
	end)

	it("counts insecure alone as tls", function()
		local cfg = withProm('{"url": "https://h", "tls": {"insecure": true}}')
		expect(cfg.contexts.lab.prometheus.tls).toEqual({ insecure = true })
	end)

	it("requires a client certificate for a client key", function()
		expect(select(2, withProm('{"url": "https://h", "tls": {"key_file": "/k.pem"}}'))).toEqual({
			"contexts.lab.prometheus.tls.key_file: needs tls.cert_file",
		})
	end)

	it("requires usable paths and a boolean insecure", function()
		expect(select(2, withProm('{"url": "https://h", "tls": {"ca_file": "ca.pem", "insecure": "yes"}}'))).toEqual({
			"contexts.lab.prometheus.tls.ca_file: must be an absolute path or start with ~/",
			"contexts.lab.prometheus.tls.insecure: must be true or false",
		})
	end)
end)

describe("config path", function()
	it("prefers XDG_CONFIG_HOME, then ~/.config", function()
		expect(Validate.path({ XDG_CONFIG_HOME = "/x", HOME = "/home/u" })).toBe("/x/tern-grafana/config.json")
		expect(Validate.path({ HOME = "/home/u" })).toBe("/home/u/.config/tern-grafana/config.json")
		expect(Validate.path({})).toBeNil()
	end)
end)

return nil
