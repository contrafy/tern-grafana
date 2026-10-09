--!strict
-- Forms are how most people will write their config. Every form edit must
-- produce a file the validator accepts (or be refused with the JSON path of
-- the bad field next to that field), no form may ever ask for a secret, and a
-- header that looks like a credential is never shown back. Starter templates
-- must validate as shipped: a template that fails would be the first thing a
-- new user sees.
local Json = require("../../../plugin/lib/settings/json")
local Model: any = require("../../../plugin/lib/settings/model")
local Validate: any = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local LAB = [[
{
  "version": 1,
  "default_context": "lab",
  "contexts": {
    "lab": {
      "grafana": {"url": "http://localhost:3000", "auth": {"type": "bearer", "token_env": "GRAFANA_TOKEN"}, "datasources": {"prometheus": "prom3"}},
      "prometheus": {"url": "http://localhost:9090", "headers": {"X-Scope-OrgID": "team-a", "X-Api-Key": "k-123"}}
    },
    "other": {"prometheus": {"url": "http://localhost:9091"}}
  },
  "alerts": {"toasts": true}
}
]]

local function lab(): any
	return json.decode(LAB)
end

-- Validates the document exactly as it would be written.
local function validate(raw: any): (any, { string })
	local cfg, problems = Validate.parseFile(Json.encode(raw, json.encode), json.decode)
	local out = {}
	for i, p in problems do
		out[i] = Validate.format(p)
	end
	return cfg, out
end

local function edit(form: any, id: string, text: string): any
	local out, problem = Model.setField(form, id, text)
	expect(problem).toBeNil()
	return out
end

local function fieldIds(form: any, raw: any): { string }
	local out = {}
	for i, f in Model.fields(form, raw) do
		out[i] = f.id
	end
	return out
end

describe("edit endpoint form", function()
	it("changes only the edited endpoint and keeps feature sections", function()
		local raw = lab()
		local form = Model.editForm(raw, "lab", "prometheus", json.encode)
		form = edit(form, "url", "https://mimir.internal")
		form = edit(form, "path_prefix", "/prometheus")
		local out, problems = Model.applyForm(raw, form, json.decode)
		expect(problems).toEqual({})
		local cfg, messages = validate(out)
		expect(messages).toEqual({})
		expect(cfg.contexts.lab.prometheus.url).toBe("https://mimir.internal")
		expect(cfg.contexts.lab.prometheus.path_prefix).toBe("/prometheus")
		expect(cfg.contexts.lab.prometheus.headers["X-Api-Key"]).toBe("k-123")
		expect(cfg.contexts.other.prometheus.url).toBe("http://localhost:9091")
		expect(cfg.alerts).toEqual({ toasts = true })
		-- The input document is not mutated (the block keeps it to compare and retry).
		expect(raw.contexts.lab.prometheus.url).toBe("http://localhost:9090")
	end)

	it("turns a typed command line into the argv the file stores", function()
		local form = Model.editForm(lab(), "lab", "prometheus", json.encode)
		form = edit(form, "auth.type", "bearer")
		form = edit(form, "auth.source", "cmd")
		form = edit(form, "auth.reference", 'op read "op://Private/Grafana lab/credential"')
		local out = Model.applyForm(lab(), form, json.decode)
		local cfg, messages = validate(out)
		expect(messages).toEqual({})
		expect(cfg.contexts.lab.prometheus.auth.token.argv).toEqual({
			"op",
			"read",
			"op://Private/Grafana lab/credential",
		})
	end)

	it("accepts a JSON array for a command and shows it back the way it was stored", function()
		local form = Model.editForm(lab(), "lab", "grafana", json.encode)
		form = edit(form, "auth.source", "cmd")
		form = edit(form, "auth.reference", '["sh", "-c", "pass show grafana/lab | head -n 1"]')
		local out = Model.applyForm(lab(), form, json.decode)
		local cfg = validate(out)
		expect(cfg.contexts.lab.grafana.auth.token.argv).toEqual({ "sh", "-c", "pass show grafana/lab | head -n 1" })
		local again = Model.editForm(out, "lab", "grafana", json.encode)
		expect(json.decode(again.values["auth.reference"])).toEqual({ "sh", "-c", "pass show grafana/lab | head -n 1" })
	end)

	it("offers only reference fields for credentials, never a secret value", function()
		local form = Model.editForm(lab(), "lab", "grafana", json.encode)
		form = edit(form, "auth.type", "basic")
		local ids = fieldIds(form, lab())
		expect(ids).toContain("auth.username")
		expect(ids).toContain("auth.reference")
		for _, id in ids do
			expect(id == "auth.password" or id == "auth.token").toBe(false)
		end
		form = edit(form, "auth.username", "admin")
		form = edit(form, "auth.source", "file")
		form = edit(form, "auth.reference", "~/.config/tern-grafana/lab.password")
		local cfg, messages = validate(Model.applyForm(lab(), form, json.decode))
		expect(messages).toEqual({})
		expect(cfg.contexts.lab.grafana.auth.password).toEqual({
			from = "file",
			field = "password_file",
			path = "~/.config/tern-grafana/lab.password",
		})
	end)

	it("shows grafana-only fields for grafana endpoints alone", function()
		local grafana = fieldIds(Model.editForm(lab(), "lab", "grafana", json.encode), lab())
		local prom = fieldIds(Model.editForm(lab(), "lab", "prometheus", json.encode), lab())
		expect(grafana).toContain("ds.prometheus")
		expect(grafana).toContain("org_id")
		expect(table.find(prom, "ds.prometheus")).toBeNil()
		expect(table.find(prom, "org_id")).toBeNil()
	end)
end)

describe("invalid edits", function()
	-- The problem lands on the field that caused it, by JSON path.
	local function problemsOn(form: any, raw: any): { [string]: { string } }
		local out = Model.applyForm(raw, form, json.decode)
		local _, problems = Validate.parseFile(Json.encode(out, json.encode), json.decode)
		local byField = Model.assign(Model.fields(form, raw), problems)
		return byField
	end

	it("puts a bad url, timeout and org id next to their fields", function()
		local form = Model.editForm(lab(), "lab", "grafana", json.encode)
		form = edit(form, "url", "localhost:3000")
		form = edit(form, "timeout_ms", "soon")
		form = edit(form, "org_id", "0")
		local byField = problemsOn(form, lab())
		expect(byField.url).toEqual({ 'must be an http(s) URL, got "localhost:3000"' })
		expect(byField.timeout_ms).toEqual({ "must be an integer between 1 and 600000 (milliseconds)" })
		expect(byField.org_id).toEqual({ "must be a positive integer" })
	end)

	it("puts a missing credential source on the reference field", function()
		local form = Model.editForm(lab(), "lab", "prometheus", json.encode)
		form = edit(form, "auth.type", "bearer")
		local byField = problemsOn(form, lab())
		expect(byField["auth.source"]).toEqual({ "bearer auth needs one of token_cmd, token_env, token_file" })
	end)

	it("reports an unparsable command at its JSON path without validating", function()
		local form = Model.editForm(lab(), "lab", "prometheus", json.encode)
		form = edit(form, "auth.type", "bearer")
		form = edit(form, "auth.source", "cmd")
		form = edit(form, "auth.reference", 'op read "unterminated')
		local out, problems = Model.applyForm(lab(), form, json.decode)
		expect(out).toBeNil()
		expect(problems).toEqual({
			{ path = "contexts.lab.prometheus.auth.token_cmd", message = "unbalanced quote in the command" },
		})
	end)

	it("refuses an Authorization header: credentials belong in auth", function()
		local form = Model.editForm(lab(), "lab", "prometheus", json.encode)
		local same, problem = Model.setField(form, "header_new", "Authorization: Bearer x")
		expect(problem).toBe("set credentials with auth, not an Authorization header")
		expect(same).toBe(form)
	end)

	it("refuses a new context whose name is taken or malformed", function()
		local form = Model.newContextForm()
		form = edit(form, "context", "other")
		form = edit(form, "url", "http://localhost:9090")
		local out, problems = Model.applyForm(lab(), form, json.decode)
		expect(out).toBeNil()
		expect(problems[1].path).toBe("contexts.other")
		local bad = edit(form, "context", "my lab")
		local raw = Model.applyForm(lab(), bad, json.decode)
		local _, messages = validate(raw)
		expect(messages).toContain("contexts.my lab: context names may only contain letters, digits, '.', '_' and '-'")
	end)
end)

describe("sensitive headers", function()
	it("masks values whose names look like credentials, in the list and the form", function()
		local summary = Model.summary(lab().contexts.lab.prometheus)
		expect(summary.headers).toEqual({ "X-Api-Key: " .. Model.MASK, "X-Scope-OrgID: team-a" })
		local form = Model.editForm(lab(), "lab", "prometheus", json.encode)
		for _, f in Model.fields(form, lab()) do
			if f.id == "header:X-Api-Key" then
				expect(f.sensitive).toBe(true)
				expect(Model.display(form, f)).toBe(Model.MASK)
				expect(Model.editText(form, f)).toBe("")
			elseif f.id == "header:X-Scope-OrgID" then
				expect(Model.display(form, f)).toBe("team-a")
			end
		end
	end)

	it("keeps a hidden value when the edit is left empty and replaces it when typed", function()
		local form = Model.editForm(lab(), "lab", "prometheus", json.encode)
		local kept = edit(form, "header:X-Api-Key", "")
		expect(validate(Model.applyForm(lab(), kept, json.decode)).contexts.lab.prometheus.headers["X-Api-Key"]).toBe(
			"k-123"
		)
		local replaced = edit(form, "header:X-Api-Key", "k-456")
		expect(validate(Model.applyForm(lab(), replaced, json.decode)).contexts.lab.prometheus.headers["X-Api-Key"]).toBe(
			"k-456"
		)
	end)

	it("flags common credential header names but not tenant headers", function()
		for _, name in { "X-Api-Key", "X-Auth-Token", "Cookie", "X-Grafana-Session", "Proxy-Authorization" } do
			expect(Model.isSensitiveHeader(name)).toBe(true)
		end
		for _, name in { "X-Scope-OrgID", "X-Grafana-Org-Id", "Accept" } do
			expect(Model.isSensitiveHeader(name)).toBe(false)
		end
	end)

	it("adds and removes headers through the form", function()
		local form = Model.editForm(lab(), "lab", "prometheus", json.encode)
		form = edit(form, "header_new", "X-Scope-OrgID: team-a|team-b")
		form = Model.removeHeader(form, "X-Api-Key")
		local cfg = validate(Model.applyForm(lab(), form, json.decode))
		expect(cfg.contexts.lab.prometheus.headers).toEqual({ ["X-Scope-OrgID"] = "team-a|team-b" })
	end)
end)

describe("context edits", function()
	it("creates a context with its first endpoint", function()
		local form = Model.newContextForm()
		form = edit(form, "context", "corp")
		form = edit(form, "url", "https://prometheus.corp.example")
		form = edit(form, "tls.ca_file", "/etc/ssl/corp-root.pem")
		local cfg, messages = validate(Model.applyForm(lab(), form, json.decode))
		expect(messages).toEqual({})
		expect(cfg.contexts.corp.prometheus.tls.ca_file).toBe("/etc/ssl/corp-root.pem")
	end)

	it("adds only endpoint kinds the context lacks", function()
		local form = Model.newEndpointForm(lab(), "lab") :: any
		local kinds
		for _, f in Model.fields(form, lab()) do
			if f.id == "kind" then
				kinds = f.values
			end
		end
		expect(kinds).toEqual({ "alertmanager", "loki", "tempo" })
		form = edit(form, "url", "http://localhost:9093")
		local cfg = validate(Model.applyForm(lab(), form, json.decode))
		expect(cfg.contexts.lab.alertmanager.url).toBe("http://localhost:9093")
	end)

	it("renaming the default context keeps it the default", function()
		local form = edit(Model.renameForm("lab"), "context", "home")
		local cfg, messages = validate(Model.applyForm(lab(), form, json.decode))
		expect(messages).toEqual({})
		expect(cfg.default_context).toBe("home")
		expect(cfg.contexts.home.grafana.url).toBe("http://localhost:3000")
	end)

	it("removing the default context unsets default_context instead of breaking the file", function()
		local cfg, messages = validate(Model.removeContext(lab(), "lab"))
		expect(messages).toEqual({})
		expect(cfg.default_context).toBe("other")
	end)

	it("removing a context's last endpoint is refused by validation with its path", function()
		local _, messages = validate(Model.removeEndpoint(lab(), "other", "prometheus"))
		expect(messages).toEqual({
			"contexts.other: must configure at least one of grafana, prometheus, alertmanager, loki, tempo",
		})
	end)
end)

describe("starter templates", function()
	it("every template is a valid config as written", function()
		expect(#Model.TEMPLATES).toBe(4)
		for _, tpl in Model.TEMPLATES do
			local cfg, messages = validate(tpl.raw)
			expect({ tpl.id, messages }).toEqual({ tpl.id, {} })
			expect(cfg.default_context ~= nil).toBe(true)
		end
	end)

	it("the Mimir template carries the tenant header on every endpoint", function()
		local cfg = validate((Model.template("mimir") :: any).raw)
		expect(cfg.contexts.mimir.prometheus.headers["X-Scope-OrgID"]).toBe("team-a")
		expect(cfg.contexts.mimir.alertmanager.headers["X-Scope-OrgID"]).toBe("team-a")
	end)
end)

return nil
