--!strict
-- Acknowledging, resolving or silencing an alert group changes who gets
-- paged, so nothing may be written until the user confirmed exactly what
-- will be written: no keystroke or click short of the explicit `y` sends a
-- request, a cancel sends nothing, a failed write is reported and never
-- retried, the confirmation says the action is recorded under the service
-- account, and an account Grafana says cannot act is refused up front with
-- the permission it lacks. Reads run against the scrubbed IRM 0.128 capture.
local Render = require("../../../plugin/lib/irm/oncall_render")
local State = require("../../../plugin/lib/irm/oncall_state")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local V = S.V

local WRITER = '{"grafana-irm-app.alert-groups:read":["*"],"grafana-irm-app.alert-groups:write":["*"]}'

local function bodies(perms: string?): (string, any) -> any
	local map: { [string]: any } = {
		settings = S.ok(V .. "settings.json"),
		perms = if perms then S.raw(perms, 200) else S.ok(V .. "grafana_permissions.json"),
		user = S.ok(V .. "grafana_user.json"),
		["g:firing"] = S.ok(V .. "oncall_alert_groups_new.json"),
		["g:acknowledged"] = S.ok(V .. "oncall_alert_groups_acknowledged.json"),
		["g:silenced"] = S.ok(V .. "oncall_alert_groups_silenced_count.json"),
		integrations = S.ok(V .. "oncall_integrations.json"),
		schedules = S.ok(V .. "oncall_schedules.json"),
	}
	return function(name: string): any
		if string.match(name, "^now:") then
			return S.ok(V .. "oncall_current_oncall.json")
		elseif string.match(name, "^next:") then
			return S.ok(V .. "oncall_next_oncall.json")
		elseif string.match(name, "^d:") then
			return S.ok(V .. "oncall_alerts.json")
		end
		return map[name]
	end
end

local function opened(perms: string?): (any, any)
	local env = S.env()
	local s: any, effects = State.init({}, nil, env)
	S.drive(State.update, s, effects, env, bodies(perms))
	return s, env
end

local function press(s: any, env: any, text: string, name: string?): { any }
	local _, effects = State.key(s, S.key(text, name), env)
	return effects
end

local function viewText(s: any, env: any): string
	return S.text(Render.view(s, env))
end

describe("reading", function()
	it("lists open alert groups, firing first, and writes nothing", function()
		local env = S.env()
		local s: any, effects = State.init({}, nil, env)
		local more = S.drive(State.update, s, effects, env, bodies(WRITER))
		expect(#S.writes(effects) + #S.writes(more)).toBe(0)
		expect(#s.groups).toBe(12)
		expect(s.groups[1].state).toBe("firing")
		expect(s.groups[#s.groups].state).toBe("acknowledged")
		expect(s.can_write).toBe(true)
		expect(s.loading).toBe(false)
		local text = viewText(s, env)
		expect(S.has(text, "6 firing")).toBe(true)
		expect(S.has(text, "IRM 0.128.0")).toBe(true)
	end)

	it("shows who is on call now and next per schedule", function()
		local s, env = opened(WRITER)
		local effects = press(s, env, "", "tab")
		S.drive(State.update, s, effects, env, bodies(WRITER))
		expect(s.view).toBe("schedules")
		local rows = assert(s.schedules, "schedules")
		expect(#rows).toBe(5)
		local text = viewText(s, env)
		expect(S.has(text, "until")).toBe(true)
		expect(S.has(text, "from")).toBe(true)
	end)
end)

describe("writing", function()
	it("stages an acknowledgement on a key and sends it only on y, once", function()
		local s, env = opened(WRITER)
		local g = s.groups[1]
		local effects = press(s, env, "a")
		expect(#S.writes(effects)).toBe(0)
		expect(s.confirm.action).toBe("acknowledge")
		local text = viewText(s, env)
		expect(S.has(text, "Acknowledge alert group")).toBe(true)
		expect(S.has(text, "Sent as service account login 1")).toBe(true)
		expect(S.has(text, "not under you")).toBe(true)
		-- enter must not confirm (a repeated enter would send).
		expect(#S.writes(press(s, env, "", "enter"))).toBe(0)
		local sent = press(s, env, "y")
		local writes = S.writes(sent)
		expect(#writes).toBe(1)
		expect(writes[1].request.method).toBe("POST")
		expect(writes[1].request.path).toBe("api/v1/alert_groups/" .. g.id .. "/acknowledge")
		expect(writes[1].route.endpoint.url).toBe(S.ONCALL)
		local audit = assert(S.find(sent, "irm_audit"))
		expect(audit.outcome).toBe("sent")
		expect(audit.target).toBe(g.id)
		expect(S.has(S.text(audit), g.title)).toBe(false)
		expect(#S.writes(press(s, env, "y"))).toBe(0)
	end)

	it("sends nothing when cancelled", function()
		local s, env = opened(WRITER)
		press(s, env, "x")
		local effects = press(s, env, "n")
		expect(#S.writes(effects)).toBe(0)
		expect(s.confirm).toBeNil()
		expect(S.find(effects, "irm_audit").outcome).toBe("cancelled")
	end)

	it("reports a refused write with the missing permission and never retries it", function()
		local s, env = opened(WRITER)
		press(s, env, "a")
		local sent = press(s, env, "y")
		local write = S.writes(sent)[1]
		local _, after = State.update(
			s,
			{ kind = "http_done", tag = write.tag, response = S.ok(V .. "oncall_forbidden.json", 403) },
			env
		)
		expect(#S.writes(after)).toBe(0)
		expect(S.find(after, "irm_audit").outcome).toBe("failed")
		expect(s.note_tone).toBe("error")
		expect(S.has(s.note, "grafana-irm-app.alert-groups:write")).toBe(true)
		expect(s.writing).toBeNil()
	end)

	it("reloads after a write IRM accepted", function()
		local s, env = opened(WRITER)
		press(s, env, "a")
		local write = S.writes(press(s, env, "y"))[1]
		local _, after = State.update(s, { kind = "http_done", tag = write.tag, response = S.raw("", 200) }, env)
		expect(s.note_tone).toBe("ok")
		expect(S.find(after, "irm_audit").outcome).toBe("ok")
		local reads = 0
		for _, e in after do
			if e.kind == "http" and e.request.method == "GET" then
				reads += 1
			end
		end
		expect(reads > 0).toBe(true)
	end)

	it("asks how long to silence and sends that duration", function()
		local s, env = opened(WRITER)
		press(s, env, "s")
		expect(s.picking ~= nil).toBe(true)
		expect(s.confirm).toBeNil()
		press(s, env, "4")
		expect(#S.writes(press(s, env, "", "enter"))).toBe(0)
		expect(s.confirm.delay_s).toBe(6 * 3600)
		expect(S.has(viewText(s, env), "for 6h")).toBe(true)
		local write = S.writes(press(s, env, "y"))[1]
		expect(env.decode(write.request.body).delay).toBe(6 * 3600)
	end)

	it("warns that unacknowledging restarts escalation", function()
		local s, env = opened(WRITER)
		for _ = 1, 6 do
			press(s, env, "j")
		end
		expect(s.groups[s.sel].state).toBe("acknowledged")
		press(s, env, "a")
		expect(s.confirm).toBeNil()
		press(s, env, "A")
		expect(s.confirm.action).toBe("unacknowledge")
		expect(S.has(viewText(s, env), "people may be paged")).toBe(true)
	end)

	it("refuses to stage anything for an account without alert-groups:write (the captured Viewer)", function()
		local s, env = opened(nil)
		expect(s.can_write).toBe(false)
		local effects = press(s, env, "a")
		expect(s.confirm).toBeNil()
		expect(#S.writes(effects)).toBe(0)
		expect(S.has(s.note, "grafana-irm-app.alert-groups:write")).toBe(true)
		expect(S.has(viewText(s, env), "Read-only")).toBe(true)
	end)

	it("shows irm.user as you, on call until the shift ends, in every schedule they are in", function()
		local env = S.env(S.config('"irm": {"user": "USER3@example.com"}'))
		local s: any, effects = State.init({}, nil, env)
		S.drive(State.update, s, effects, env, bodies(WRITER))
		-- Schedules load for `you` even on the alert-groups view.
		expect(s.view).toBe("groups")
		local you = assert(State.you(s), "you")
		expect(you.now).toBe(true)
		expect(you.until_ms).toBe(1792447200000)
		expect(S.has(viewText(s, env), "you: on call until 22:00")).toBe(true)
		S.drive(State.update, s, press(s, env, "", "tab"), env, bodies(WRITER))
		local text = viewText(s, env)
		expect(S.has(text, "you (")).toBe(true)
		local opened2 = opened(WRITER)
		expect(State.you(opened2)).toBeNil()
	end)

	it("keeps saved state to the context and view", function()
		local s = opened(WRITER)
		press(s, S.env(), "a")
		local saved = State.save(s)
		expect(saved).toEqual({ context = "cloud", view = "groups", show_resolved = false })
	end)
end)

return nil
