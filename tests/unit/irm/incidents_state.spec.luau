--!strict
-- Declaring an incident, changing its status or severity and adding a note
-- run the stack's incident hooks (chat posts, pages), so every write is
-- staged first and sent only on the explicit `y`; the confirmation says the
-- hooks may notify people and that IRM records the change under the service
-- account; a failure is reported and never retried; and free text (titles,
-- notes) stays out of saved state and the audit log. Reads run against the
-- scrubbed IRM 0.128 capture, write answers against the API reference.
local Render = require("../../../plugin/lib/irm/incidents_render")
local State = require("../../../plugin/lib/irm/incidents_state")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local V, DOCS = S.V, S.DOCS

local function respond(name: string): any
	if name == "list" then
		return S.ok(V .. "incident_previews_open.json")
	elseif name == "statuses" then
		return S.ok(V .. "incident_statuses.json")
	elseif name == "severities" then
		return S.ok(V .. "incident_severities_404.txt", 404)
	elseif name == "user" then
		return S.ok(V .. "grafana_user.json")
	elseif string.match(name, "incident$") then
		return S.ok(V .. "incident_get.json")
	elseif string.match(name, "activity$") then
		return S.ok(V .. "incident_activity.json")
	end
	return nil
end

local function opened(): (any, any)
	local env = S.env()
	local s: any, effects = State.init({}, nil, env)
	S.drive(State.update, s, effects, env, respond)
	return s, env
end

local function press(s: any, env: any, text: string, name: string?): { any }
	local _, effects = State.key(s, S.key(text, name), env)
	return effects
end

local function typeText(s: any, env: any, text: string)
	for i = 1, #text do
		press(s, env, string.sub(text, i, i))
	end
end

local function viewText(s: any, env: any): string
	return S.text(Render.view(s, env))
end

local function method(e: any): string
	return string.match(e.request.path, "%.(%a+)$") :: string
end

describe("reading", function()
	it("lists open incidents with their severities and writes nothing", function()
		local env = S.env()
		local s: any, effects = State.init({}, nil, env)
		local more = S.drive(State.update, s, effects, env, respond)
		expect(#S.writes(effects) + #S.writes(more)).toBe(0)
		expect(#s.incidents).toBe(10)
		expect(s.org_severities).toBeNil()
		expect(#s.statuses).toBe(3)
		expect(S.has(viewText(s, env), "10 open")).toBe(true)
	end)

	it("opens an incident's detail with its timeline", function()
		local s, env = opened()
		local effects = press(s, env, "", "enter")
		S.drive(State.update, s, effects, env, respond)
		expect(s.page).toBe("detail")
		expect(s.detail.incident ~= nil).toBe(true)
		expect(#s.detail.activity > 0).toBe(true)
		expect(S.has(viewText(s, env), "timeline")).toBe(true)
	end)
end)

describe("writing", function()
	it("declares an incident only after y, warning that hooks may notify people", function()
		local s, env = opened()
		press(s, env, "n")
		expect(s.page).toBe("declare")
		typeText(s, env, "Checkout errors after deploy")
		press(s, env, "", "enter") -- apply the title
		press(s, env, "", "right") -- severity row: next severity
		local effects = press(s, env, "D")
		expect(#S.writes(effects)).toBe(0)
		local text = viewText(s, env)
		expect(S.has(text, "Declare this incident?")).toBe(true)
		expect(S.has(text, "may post to chat, notify or page people")).toBe(true)
		expect(S.has(text, "Sent as service account login 1")).toBe(true)
		local sent = press(s, env, "y")
		local writes = S.writes(sent)
		expect(#writes).toBe(1)
		expect(method(writes[1])).toBe("CreateIncident")
		local body = env.decode(writes[1].request.body)
		expect(body.title).toBe("Checkout errors after deploy")
		expect(body.severity).toBe(State.severities(s)[2])
		expect(body.isDrill).toBe(false)
		local audit = S.find(sent, "irm_audit")
		expect(S.has(S.text(audit), "Checkout")).toBe(false)
		expect(S.has(S.text(State.save(s)), "Checkout")).toBe(false)
		local _, after = State.update(
			s,
			{ kind = "http_done", tag = writes[1].tag, response = S.ok(DOCS .. "incident_create.json") },
			env
		)
		expect(s.note_tone).toBe("ok")
		expect(s.page).toBe("detail")
		expect(#S.writes(after)).toBe(0)
	end)

	it("refuses to stage a declaration without a title", function()
		local s, env = opened()
		press(s, env, "n")
		press(s, env, "", "enter")
		press(s, env, "D")
		expect(s.confirm).toBeNil()
		expect(s.form.error).toBe("a title is required")
	end)

	it("changes the status through a picker, staged then confirmed", function()
		local s, env = opened()
		local x = s.incidents[1]
		press(s, env, "s")
		expect(s.picker.kind).toBe("status")
		press(s, env, "", "right")
		expect(#S.writes(press(s, env, "", "enter"))).toBe(0)
		expect(s.confirm.kind).toBe("status")
		local writes = S.writes(press(s, env, "y"))
		expect(#writes).toBe(1)
		expect(method(writes[1])).toBe("UpdateStatus")
		local body = env.decode(writes[1].request.body)
		expect(body.incidentID).toBe(x.id)
		expect(body.status ~= x.status).toBe(true)
	end)

	it("says the severity list is a fallback when the org's cannot be read", function()
		local s, env = opened()
		press(s, env, "v")
		expect(S.has(viewText(s, env), "IRM's defaults")).toBe(true)
		local options = State.severities(s)
		expect(table.find(options, "Critical") ~= nil).toBe(true)
	end)

	it("adds a note from the detail page, never keeping the text", function()
		local s, env = opened()
		S.drive(State.update, s, press(s, env, "", "enter"), env, respond)
		press(s, env, "a")
		typeText(s, env, "rolled back")
		expect(#S.writes(press(s, env, "", "enter"))).toBe(0)
		expect(s.confirm.kind).toBe("note")
		local sent = press(s, env, "y")
		local writes = S.writes(sent)
		expect(method(writes[1])).toBe("AddActivity")
		expect(env.decode(writes[1].request.body).body).toBe("rolled back")
		expect(S.has(S.text(S.find(sent, "irm_audit")), "rolled back")).toBe(false)
	end)

	it("reports an error answered with 200 and never retries it", function()
		local s, env = opened()
		press(s, env, "v")
		press(s, env, "", "right")
		press(s, env, "", "enter")
		local write = S.writes(press(s, env, "y"))[1]
		local _, after = State.update(
			s,
			{ kind = "http_done", tag = write.tag, response = S.raw('{"error":"unknown severity"}', 200) },
			env
		)
		expect(#S.writes(after)).toBe(0)
		expect(s.note_tone).toBe("error")
		expect(S.has(s.note, "unknown severity")).toBe(true)
	end)
end)

return nil
