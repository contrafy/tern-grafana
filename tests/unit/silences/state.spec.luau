--!strict
-- Creating or expiring a silence changes who gets paged, so nothing may be
-- written until the user confirmed exactly what will be written: no keystroke
-- or click short of the explicit confirmation sends a request, a cancel sends
-- nothing, a failed write is reported and never retried, and the comment (free
-- text that may hold anything) never reaches saved state or the audit log.
local Api = require("../../../plugin/lib/silences/api")
local Fixtures = require("../../lib/fixtures")
local Normalize = require("../../../plugin/lib/alerts/normalize")
local Render = require("../../../plugin/lib/silences/render")
local State = require("../../../plugin/lib/silences/state")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577860000

local CFG = (function(): any
	local cfg, problems = Validate.parseFile(
		[[{"default_context": "am", "contexts": {
		"am": {"alertmanager": {"url": "http://am:9093"}},
		"graf": {"grafana": {"url": "http://g"}},
		"prom": {"prometheus": {"url": "http://p:9090"}}}}]],
		json.decode
	)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end)()

local function makeEnv(): any
	return { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null, config = CFG }
end

local function ok(path: string, status: number?): any
	return { status = status or 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

local function key(text: string, name: string?): any
	return {
		name = name or text,
		text = if name then nil else text,
		ctrl = false,
		alt = false,
		shift = false,
		meta = false,
	}
end

local function find(effects: { any }, kind: string): any
	for _, e in effects do
		if e.kind == kind then
			return e
		end
	end
	return nil
end

-- Every write request among effects (anything but a GET).
local function writes(effects: { any }): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "http" and e.request.method ~= "GET" then
			table.insert(out, e)
		end
	end
	return out
end

-- Answers every load request with the fixture for its tag suffix.
local function answer(s: any, effects: { any }, env: any, bodies: { [string]: any }): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "http" and e.request.method == "GET" then
			local tag = string.match(e.tag, "^%d+:(.+)$") :: string
			local _, more = State.update(s, { kind = "http_done", tag = e.tag, response = bodies[tag] }, env)
			for _, m in more do
				table.insert(out, m)
			end
		end
	end
	return out
end

local AM_BODIES = {
	["a:am"] = ok("alertmanager/0.34.1/alerts_with_silenced.json"),
	sil = ok("alertmanager/0.34.1/silences_active.json"),
}

local function amAlert(name: string): any
	local parsed: any =
		Normalize.parseAlertmanager(makeEnv(), Fixtures.read("alertmanager/0.34.1/alerts.json"), "am", "alertmanager")
	for _, a in parsed.items do
		if a.labels.alertname == name then
			return a
		end
	end
	error("no alert " .. name)
end

local function typeText(s: any, env: any, text: string)
	for i = 1, #text do
		State.key(s, key(string.sub(text, i, i)), env)
	end
end

-- The form for TernTargetDown with a comment typed in.
local function filledForm(): (any, any)
	local env = makeEnv()
	local s: any, effects = State.init({ Api.linkFor(amAlert("TernTargetDown")) }, nil, env)
	answer(s, effects, env, AM_BODIES)
	State.update(s, { kind = "user", name = "ahmad" }, env)
	State.key(s, key("", "enter"), env) -- edit the comment (the starting row)
	typeText(s, env, "disk swap, token=abc123")
	State.key(s, key("", "enter"), env)
	return s, env
end

describe("from an alert", function()
	it("opens the form prefilled with the alert's labels and reads alerts and silences, writing nothing", function()
		local env = makeEnv()
		local s: any, effects = State.init({ Api.linkFor(amAlert("TernTargetDown")) }, nil, env)
		expect(s.page).toBe("form")
		expect(#s.form.matchers).toBe(5)
		expect(find(effects, "silence_user") ~= nil).toBe(true)
		expect(#writes(effects)).toBe(0)
		answer(s, effects, env, AM_BODIES)
		State.update(s, { kind = "user", name = "ahmad" }, env)
		expect(s.form.created_by).toBe("ahmad")
		local preview = assert(State.affected(s, s.form.matchers))
		expect(#preview).toBe(1)
		expect(preview[1].labels.alertname).toBe("TernTargetDown")
		local text = json.encode(Render.view(s, env))
		expect(string.find(text, "1 current alert matches", 1, true) ~= nil).toBe(true)
	end)

	it("refuses to stage a silence without a comment", function()
		local env = makeEnv()
		local s: any, effects = State.init({ Api.linkFor(amAlert("TernTargetDown")) }, nil, env)
		answer(s, effects, env, AM_BODIES)
		State.update(s, { kind = "user", name = "ahmad" }, env)
		local _, staged = State.key(s, key("S"), env)
		expect(s.confirm).toBeNil()
		expect(string.find(s.form.error, "comment is required", 1, true) ~= nil).toBe(true)
		expect(#writes(staged)).toBe(0)
	end)

	it("edits matchers in Alertmanager syntax and keeps a bad one in the editor with the reason", function()
		local s, env = filledForm()
		State.key(s, key("a"), env)
		typeText(s, env, "job=~(")
		State.key(s, key("", "enter"), env)
		expect(s.editing ~= nil).toBe(true)
		expect(string.find(s.editing.error, "bad regex", 1, true) ~= nil).toBe(true)
		State.key(s, key("", "escape"), env)
		expect(#s.form.matchers).toBe(5)
	end)
end)

describe("confirm gating", function()
	it("sends nothing until y, then exactly one POST with the staged body", function()
		local s, env = filledForm()
		local _, staged = State.key(s, key("S"), env)
		expect(s.confirm.kind).toBe("create")
		expect(#writes(staged)).toBe(0)
		expect(find(staged, "reveal").id).toBe("main.confirm")
		-- enter, space, j and a click elsewhere do not confirm.
		for _, k in { key("", "enter"), key("", "space"), key("j"), key("S") } do
			local _, e = State.key(s, k, env)
			expect(#writes(e)).toBe(0)
		end
		local _, clicked = State.update(s, { kind = "event", ev = { ev = "action", act = "submit" } }, env)
		expect(#writes(clicked)).toBe(0)
		expect(s.confirm ~= nil).toBe(true)
		local text = json.encode(Render.view(s, env))
		expect(string.find(text, "Create this silence?", 1, true) ~= nil).toBe(true)
		expect(string.find(text, "Alertmanager http://am:9093", 1, true) ~= nil).toBe(true)

		local _, sent = State.key(s, key("y"), env)
		local w = writes(sent)
		expect(#w).toBe(1)
		expect(w[1].request.method).toBe("POST")
		expect(w[1].request.path).toBe("/api/v2/silences")
		local body = json.decode(w[1].request.body)
		expect(body.comment).toBe("disk swap, token=abc123")
		expect(body.createdBy).toBe("ahmad")
		expect(#body.matchers).toBe(5)
		expect(body.startsAt).toBe("2026-10-09T20:31:00.000Z")
		expect(body.endsAt).toBe("2026-10-09T22:31:00.000Z")
		-- The audit line never carries the comment or matcher values.
		local audit = json.encode(find(sent, "silence_audit"))
		expect((string.find(audit, "abc123", 1, true))).toBeNil()
		expect((string.find(audit, "TernTargetDown", 1, true))).toBeNil()
		-- A second y while the write is in flight sends nothing.
		local _, again = State.key(s, key("y"), env)
		expect(#writes(again)).toBe(0)

		local _, after = State.update(
			s,
			{ kind = "http_done", tag = w[1].tag, response = ok("alertmanager/0.34.1/silence_create.json") },
			env
		)
		expect(s.page).toBe("list")
		expect(s.form).toBeNil()
		expect(string.find(s.note, "892a1c9d-e05b-4e32-8dad-b5b3860bc8c3 created", 1, true) ~= nil).toBe(true)
		expect(#writes(after)).toBe(0)
		answer(s, after, env, AM_BODIES)
		expect((State.selected(s) :: any).id).toBe("892a1c9d-e05b-4e32-8dad-b5b3860bc8c3")
		expect(State.silencing(s, "892a1c9d-e05b-4e32-8dad-b5b3860bc8c3")).toBe(1)
	end)

	it("cancels with n or esc and sends nothing", function()
		local s, env = filledForm()
		State.key(s, key("S"), env)
		local _, cancelled = State.key(s, key("", "escape"), env)
		expect(s.confirm).toBeNil()
		expect(#writes(cancelled)).toBe(0)
		expect(find(cancelled, "silence_audit").outcome).toBe("cancelled")
		expect(s.page).toBe("form")
		State.key(s, key("S"), env)
		local _, n = State.update(s, { kind = "event", ev = { ev = "action", act = "cancel" } }, env)
		expect(#writes(n)).toBe(0)
		expect(s.confirm).toBeNil()
	end)

	it("reports a failed write and never retries it", function()
		local s, env = filledForm()
		State.key(s, key("S"), env)
		local _, sent = State.key(s, key("y"), env)
		local w = writes(sent)[1]
		local _, after = State.update(s, {
			kind = "http_done",
			tag = w.tag,
			response = { status = 500, headers = {}, body = '{"message":"boom"}', timed_out = false },
		}, env)
		expect(#writes(after)).toBe(0)
		expect(find(after, "http")).toBeNil()
		expect(s.writing).toBeNil()
		expect(s.page).toBe("form")
		expect(s.form.comment).toBe("disk swap, token=abc123")
		expect(string.find(s.note, "boom", 1, true) ~= nil).toBe(true)
		expect(find(after, "silence_audit").outcome).toBe("failed")
	end)

	it("posts to Grafana's Alertmanager for a Grafana context", function()
		local env = makeEnv()
		local s: any, effects =
			State.init({ "tern-grafana://silence?context=graf&matchers=alertname%3DTernGrafanaAlwaysFiring" }, nil, env)
		answer(s, effects, env, {
			["a:am"] = ok("grafana/12.4.12/alerting_am_alerts.json"),
			["a:rules"] = ok("grafana/12.4.12/alerting_prom_alerts.json"),
			sil = ok("grafana/12.4.12/alerting_am_silences.json"),
		})
		State.update(s, { kind = "user", name = "ahmad" }, env)
		State.key(s, key("", "enter"), env)
		typeText(s, env, "maintenance")
		State.key(s, key("", "enter"), env)
		State.key(s, key("S"), env)
		local _, sent = State.key(s, key("y"), env)
		local w = writes(sent)
		expect(#w).toBe(1)
		expect(w[1].request.path).toBe("/api/alertmanager/grafana/api/v2/silences")
		local _, after = State.update(s, {
			kind = "http_done",
			tag = w[1].tag,
			response = ok("grafana/12.4.12/alerting_am_silence_create.json", 202),
		}, env)
		expect(string.find(s.note, "8f0c1a3e-04ac-4019-8be3-c80a6fba7640 created", 1, true) ~= nil).toBe(true)
		expect(find(after, "http").request.method).toBe("GET")
	end)
end)

describe("expire", function()
	it("stages the selected active silence and sends DELETE only on y", function()
		local env = makeEnv()
		local s: any, effects = State.init({}, nil, env)
		answer(s, effects, env, AM_BODIES)
		expect(#State.visible(s)).toBe(1)
		local _, staged = State.key(s, key("x"), env)
		expect(s.confirm.kind).toBe("expire")
		expect(#writes(staged)).toBe(0)
		local text = json.encode(Render.view(s, env))
		expect(string.find(text, "It mutes 1 alert now", 1, true) ~= nil).toBe(true)
		local _, sent = State.key(s, key("y"), env)
		local w = writes(sent)
		expect(#w).toBe(1)
		expect(w[1].request).toEqual({
			method = "DELETE",
			path = "/api/v2/silence/892a1c9d-e05b-4e32-8dad-b5b3860bc8c3",
		})
		local _, after = State.update(s, {
			kind = "http_done",
			tag = w[1].tag,
			response = {
				status = 200,
				headers = {},
				body = Fixtures.read("alertmanager/0.34.1/silence_expire.txt"),
				timed_out = false,
			},
		}, env)
		expect(string.find(s.note, "expired", 1, true) ~= nil).toBe(true)
		answer(s, after, env, {
			["a:am"] = ok("alertmanager/0.34.1/alerts.json"),
			sil = ok("alertmanager/0.34.1/silences_after_expire.json"),
		})
		expect(#State.visible(s)).toBe(0)
		State.key(s, key("m"), env)
		expect(#State.visible(s)).toBe(3)
		-- An expired silence cannot be expired again.
		State.key(s, key("x"), env)
		expect(s.confirm).toBeNil()
	end)

	for _, v in { "11.6.16", "12.4.12" } do
		it(v .. ": reads Grafana's expire answer as success", function()
			local env = makeEnv()
			local s: any, effects = State.init({ "tern-grafana://silence?context=graf" }, nil, env)
			answer(s, effects, env, {
				["a:am"] = ok("grafana/" .. v .. "/alerting_am_alerts_silenced.json"),
				["a:rules"] = ok("grafana/" .. v .. "/alerting_prom_alerts.json"),
				sil = ok("grafana/" .. v .. "/alerting_am_silences_active.json"),
			})
			State.key(s, key("x"), env)
			local _, sent = State.key(s, key("y"), env)
			local w = writes(sent)[1]
			expect(string.sub(w.request.path, 1, 41)).toBe("/api/alertmanager/grafana/api/v2/silence/")
			State.update(s, {
				kind = "http_done",
				tag = w.tag,
				response = ok("grafana/" .. v .. "/alerting_am_silence_expire.json"),
			}, env)
			expect(string.find(s.note, "expired", 1, true) ~= nil).toBe(true)
		end)
	end
end)

describe("state", function()
	it("never saves the draft", function()
		local s = filledForm()
		expect(State.save(s)).toEqual({ context = "am", show_expired = false })
	end)

	it("explains that Prometheus has no silences", function()
		local env = makeEnv()
		local s: any, effects = State.init({ "tern-grafana://silence?context=prom" }, nil, env)
		expect(find(effects, "http")).toBeNil()
		expect(string.find(s.problem, "no silences", 1, true) ~= nil).toBe(true)
	end)
end)

return nil
