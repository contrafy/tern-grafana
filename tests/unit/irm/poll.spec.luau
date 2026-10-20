--!strict
-- The IRM status segment is a glance at a 0644 kv file: the poll must count
-- what is open per state without fetching alert content, keep showing the
-- last counts (marked) when a poll fails instead of claiming all is quiet,
-- stay silent for contexts without IRM, re-discover IRM when the Grafana
-- URL changes, and write nothing but counts and usernames.
local Poll = require("../../../plugin/lib/irm/poll")
local Segment = require("../../../plugin/lib/irm/segment")
local Settings = require("../../../plugin/lib/irm/settings")
local Summary = require("../../../plugin/lib/irm/summary")
local S = require("./support")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local V = S.V

local CAPTURED: { [string]: string } = {
	settings = "settings.json",
	["g:firing"] = "oncall_alert_groups_new_count.json",
	["g:acknowledged"] = "oncall_alert_groups_acknowledged_count.json",
	["g:silenced"] = "oncall_alert_groups_silenced_count.json",
	schedules = "oncall_schedules.json",
	users = "oncall_users.json",
	incidents = "incident_previews_open.json",
}

-- Runs one poll of `job`, answering each fetch with `respond(tag)`.
local function run(job: any, cache: any, env: any, respond: (string, any) -> any): { any }
	local sent = {}
	local fetches = Poll.step(job, cache, env)
	while #fetches > 0 do
		for _, f in fetches do
			table.insert(sent, f)
			job.responses[f.tag] = respond(f.tag, f)
		end
		fetches = Poll.step(job, cache, env)
	end
	return sent
end

local function captured(tag: string): any
	if string.match(tag, "^now:") then
		return S.ok(V .. "oncall_current_oncall.json")
	end
	return S.ok(V .. assert(CAPTURED[tag], tag))
end

-- The captured schedule `name 2` has user1..user5 on call until 22:00 UTC.
local SHIFT_END = 1792447200000

describe("settings", function()
	it("polls the default context every minute with names on by default", function()
		local s = Settings.read(S.config())
		expect(s.poll_s).toBe(60)
		expect(s.contexts).toEqual({ "cloud" })
		expect(s.names).toBe(true)
	end)

	it("reads irm.user as a lower-cased email and rejects anything else", function()
		expect(Settings.read(S.config('"irm": {"user": " Me@Example.COM "}')).user).toBe("me@example.com")
		local s, problems = Settings.read(S.config('"irm": {"user": "me"}'))
		expect(s.user).toBeNil()
		expect(problems[1].path).toBe("irm.user")
	end)

	it("keeps the default and names the path when a value is wrong", function()
		local s, problems =
			Settings.read(S.config('"irm": {"poll_s": 5, "contexts": ["prom", "nope"], "names": "yes", "x": 1}'))
		expect(s.poll_s).toBe(Settings.MIN_POLL_S)
		expect(s.contexts).toEqual({})
		expect(s.names).toBe(true)
		expect(#problems).toBe(5)
	end)
end)

describe("one poll", function()
	it("counts open alert groups by state and incidents by severity, one tiny page per state", function()
		local env = S.env()
		local jobs = Poll.jobs(env.config)
		local cache = {}
		local sent = run(jobs[1], cache, env, captured)
		for _, f in sent do
			if string.sub(f.tag, 1, 2) == "g:" then
				expect(f.request.query[2]).toEqual({ "perpage", "1" })
				expect(f.route.endpoint.url).toBe(S.ONCALL)
			end
		end
		local payload = Poll.payload(env, jobs, cache, nil, 60)
		local c = payload.contexts.cloud
		expect(c.firing).toBe(6)
		expect(c.acknowledged).toBe(6)
		expect(c.silenced).toBe(0)
		expect(c.incidents).toBe(10)
		local total = 0
		for _, n in c.severities do
			total += n
		end
		expect(total).toBe(10)
		expect(c.error).toBeNil()
		expect(#assert(c.oncall, "on-call names") > 0).toBe(true)
	end)

	-- Usernames may be emails (Grafana Cloud logins are); they are the names shown.
	it("writes no titles or ids to kv", function()
		local env = S.env()
		local jobs = Poll.jobs(env.config)
		local cache = {}
		run(jobs[1], cache, env, captured)
		local text = json.encode(Poll.payload(env, jobs, cache, nil, 60))
		expect(S.has(text, "title")).toBe(false)
		expect(S.has(text, "U0000")).toBe(false)
	end)

	it("does not ask for schedules and users when names are off", function()
		local env = S.env(S.config('"irm": {"names": false}'))
		local jobs = Poll.jobs(env.config)
		local sent = run(jobs[1], {}, env, captured)
		for _, f in sent do
			expect(f.tag ~= "schedules" and f.tag ~= "users").toBe(true)
		end
	end)

	it("reuses discovery between polls and re-discovers when the Grafana URL changes", function()
		local env = S.env()
		local cache = {}
		run(Poll.jobs(env.config)[1], cache, env, captured)
		local again = run(Poll.jobs(env.config)[1], cache, env, captured)
		for _, f in again do
			expect(f.tag ~= "settings").toBe(true)
		end
		local moved = S.env(S.config())
		moved.config.contexts.cloud.grafana.url = "https://other.example.grafana.net"
		local sent = run(Poll.jobs(moved.config)[1], cache, moved, captured)
		expect(sent[1].tag).toBe("settings")
	end)

	it("keeps the last counts, marked, when a poll fails", function()
		local env = S.env()
		local jobs = Poll.jobs(env.config)
		local cache = {}
		run(jobs[1], cache, env, captured)
		local before = Poll.payload(env, jobs, cache, nil, 60)
		local failing = Poll.jobs(env.config)
		run(failing[1], cache, env, function(tag)
			if tag == "incidents" or tag == "g:firing" then
				return S.raw("", 502)
			end
			return captured(tag)
		end)
		local after = Poll.payload(env, failing, cache, before, 60).contexts.cloud
		expect(after.firing).toBe(6)
		expect(after.incidents).toBe(10)
		expect(after.error).toBe("http")
		local segs = assert(Segment.segments(Poll.payload(env, failing, cache, before, 60), S.NOW))
		expect(S.has(segs[1].text, " ?")).toBe(true)
	end)

	it("stays silent for a Grafana without IRM", function()
		local env = S.env()
		local jobs = Poll.jobs(env.config)
		local cache = {}
		local sent = run(jobs[1], cache, env, function()
			return S.raw('{"message":"Plugin not found"}', 404)
		end)
		expect(#sent).toBe(1)
		local payload = Poll.payload(env, jobs, cache, nil, 60)
		expect(payload.contexts.cloud.unavailable ~= nil).toBe(true)
		expect(payload.contexts.cloud.error).toBeNil()
		expect(Segment.segments(payload, S.NOW)).toBeNil()
	end)
end)

describe("irm.user", function()
	local function poll(user: string, names: boolean?): (any, { any })
		local env = S.env(
			S.config(
				string.format('"irm": {"user": "%s", "names": %s}', user, if names == false then "false" else "true")
			)
		)
		local jobs = Poll.jobs(env.config)
		local cache = {}
		local sent = run(jobs[1], cache, env, captured)
		return Poll.payload(env, jobs, cache, nil, 60), sent
	end

	it("matches the email case-insensitively and reads when the shift ends", function()
		local payload, sent = poll("User2@Example.com")
		local you = assert(payload.contexts.cloud.you, "you")
		expect(you.known).toBe(true)
		expect(you.now).toBe(true)
		expect(you.schedules).toEqual({ "name 2" })
		expect(you.until_ms).toBe(SHIFT_END)
		-- Only the schedule the user is on call in is asked for its shift.
		local shifts = 0
		for _, f in sent do
			if string.match(f.tag, "^now:") then
				shifts += 1
			end
		end
		expect(shifts).toBe(1)
	end)

	it("reads schedules and users for it even with names off", function()
		local payload = poll("user2@example.com", false)
		expect(payload.contexts.cloud.oncall).toBeNil()
		expect(assert(payload.contexts.cloud.you, "you").now).toBe(true)
	end)

	it("knows a user who is not on call, and one OnCall does not know", function()
		local off = assert(poll("user6@example.com").contexts.cloud.you, "you")
		expect(off.known).toBe(true)
		expect(off.now).toBe(false)
		local stranger = assert(poll("nobody@example.com").contexts.cloud.you, "you")
		expect(stranger.known).toBe(false)
	end)

	it("puts it first in the status segment, in the viewer's zone", function()
		local payload = poll("user2@example.com")
		local segs = assert(Segment.segments(payload, S.NOW, 0), "segments")
		expect(segs[1].text).toBe("IRM: you are on call until 22:00, 12 alert groups, 10 incidents")
		-- Two hours east the shift ends after midnight: the day is named.
		local east = assert(Segment.segments(payload, S.NOW, 120), "segments")
		expect(east[1].text).toBe("IRM: you are on call until Tue 20 Oct 00:00, 12 alert groups, 10 incidents")
	end)
end)

describe("segment", function()
	local function payload(contexts: any, updated: number?): any
		return { v = Summary.VERSION, updated_ms = updated or S.NOW, poll_s = 60, contexts = contexts }
	end

	it("says how many alert groups and incidents are open, red while one fires", function()
		local segs = assert(
			Segment.segments(payload({ cloud = { firing = 1, acknowledged = 1, silenced = 3, incidents = 1 } }), S.NOW)
		)
		expect(segs[1].text).toBe("IRM: 2 alert groups, 1 incident")
		expect(segs[1].tone).toBe("error")
		expect(segs[1].command).toBe(Segment.COMMAND)
	end)

	it("is a warning when only acknowledged groups or incidents are open, and absent when quiet", function()
		local segs =
			assert(Segment.segments(payload({ cloud = { firing = 0, acknowledged = 1, incidents = 0 } }), S.NOW))
		expect(segs[1].text).toBe("IRM: 1 alert group")
		expect(segs[1].tone).toBe("warning")
		expect(
			Segment.segments(payload({ cloud = { firing = 0, acknowledged = 0, silenced = 2, incidents = 0 } }), S.NOW)
		).toBeNil()
	end)

	it("shows the user on call even when nothing is open, as info", function()
		local quiet =
			{ firing = 0, incidents = 0, you = { known = true, now = true, until_ms = SHIFT_END, schedules = { "x" } } }
		local segs = assert(Segment.segments(payload({ cloud = quiet }), S.NOW, 0), "segments")
		expect(segs[1].text).toBe("IRM: you are on call until 22:00")
		expect(segs[1].tone).toBe("info")
	end)

	it("names the context when several are polled", function()
		local segs = assert(Segment.segments(payload({ a = { incidents = 2 }, b = { firing = 1 } }), S.NOW))
		expect(segs[1].text).toBe("IRM a: 2 incidents")
		expect(segs[2].text).toBe("IRM b: 1 alert group")
	end)

	it("turns muted with a question mark when the poller stopped", function()
		local segs = assert(Segment.segments(payload({ cloud = { firing = 2 } }, S.NOW - 60 * 60 * 1000), S.NOW))
		expect(segs[1].text).toBe("IRM: 2 alert groups ?")
		expect(segs[1].tone).toBe("muted")
	end)
end)

return nil
