--!strict
-- An investigation crosses from a block to the window through kv, and the
-- last step starts a paid agent. So: a draft is read once and deleted, a
-- send record is deleted before the agent starts, a stale or reused link
-- never starts anything, the preview sends only on an explicit Send, and a
-- restored preview shows the same prompt without the kv record.
local Handoff = require("../../../plugin/lib/investigate/handoff")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/investigate/state")
local Fixtures = require("../../lib/fixtures")
local Validate = require("../../../plugin/lib/config/validate")
local View = require("../../../plugin/lib/investigate/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577898000

local CFG = (function(): any
	local cfg, problems = Validate.parseFile(
		[[{"default_context": "lab", "contexts": {"lab": {"prometheus": {"url": "http://p:9090"}}},
		"investigate": {"range": "30m"}}]],
		json.decode
	)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end)()

local function makeEnv(kv: { [string]: any }, now: number?): any
	return {
		now_ms = now or NOW,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		config = CFG,
		kv_get = function(key: string): any
			return kv[key]
		end,
	}
end

local SUBJECT: any = {
	kind = "alert",
	context = "lab",
	title = "TernAlwaysFiring",
	alert = {
		name = "TernAlwaysFiring",
		state = "firing",
		severity = "critical",
		summary = "Always firing fixture alert",
		since_ms = NOW - 600000,
		labels = { team = "platform" },
		annotations = {},
		source = "prometheus",
	},
	queries = { { expr = "vector(1)" } },
	fetch = true,
	links = { { label = "Runbook", url = "https://example.com/runbooks/tern-always-firing" } },
}

-- Runs effects against a kv table the way block_runner would, returning
-- the links opened.
local function run(kv: { [string]: any }, effects: { any }): { string }
	local opened = {}
	for _, e in effects do
		if e.kind == "kv_set" then
			kv[e.key] = if e.value == nil then nil else json.decode(json.encode(e.value))
		elseif e.kind == "open" then
			table.insert(opened, e.target)
		end
	end
	return opened
end

local function idOf(link: string): string
	return assert((Scheme.decode(link))).params.id
end

local function find(effects: { any }, kind: string): any
	for _, e in effects do
		if e.kind == kind then
			return e
		end
	end
	return nil
end

describe("nonce and link", function()
	it("makes distinct lower-case keys the link scheme accepts", function()
		local a = Handoff.nonce(NOW, "x", 1)
		local b = Handoff.nonce(NOW, "x", 2)
		expect(a ~= b).toBe(true)
		expect(string.match(a, "^%x+%-%x%x%x%x%x%x%x%x$") ~= nil).toBe(true)
		expect(Handoff.link(a)).toBe("tern-grafana://investigate?id=" .. a)
		expect((Scheme.decode("tern-grafana://investigate?id=../../etc"))).toBeNil()
		expect((Scheme.decode("tern-grafana://investigate?id=ABCDEF0123"))).toBeNil()
		expect((Scheme.decode("tern-grafana://investigate?id=abcdef01&prompt=x"))).toBeNil()
	end)
end)

describe("lifecycle", function()
	it("source -> window -> preview -> window -> agent, deleting every record after use", function()
		local kv = {}
		-- The source block stores a draft and opens the link.
		local opened = run(kv, Handoff.start(SUBJECT, makeEnv(kv), 7))
		expect(#opened).toBe(1)
		local draftId = idOf(opened[1])
		expect(kv[Handoff.key(draftId)].stage).toBe("draft")
		-- The window answers with the preview block, leaving the draft for it.
		local d = Handoff.decide(draftId, kv[Handoff.key(draftId)], NOW + 1000) :: any
		expect(d).toEqual({ kind = "preview", link = opened[1] })
		-- The preview takes the draft and deletes it.
		local s, effects = State.init({ d.link }, nil, makeEnv(kv, NOW + 2000))
		expect(s.status).toBe("loading")
		run(kv, effects)
		expect(kv[Handoff.key(draftId)]).toBeNil()
		expect(s.prompt).toContain("Alert: TernAlwaysFiring")
		-- Nothing is sent until Send.
		expect(find(effects, "open")).toBeNil()
		local _, sendEffects, handled = State.key(s, { name = "enter" }, makeEnv(kv, NOW + 3000))
		expect(handled).toBe(true)
		local sent = run(kv, sendEffects)
		local sendId = idOf(sent[1])
		expect(sendId ~= draftId).toBe(true)
		local record = kv[Handoff.key(sendId)]
		expect(record.stage).toBe("send")
		expect(record.prompt).toBe(s.prompt)
		-- The window starts the agent with exactly the previewed prompt.
		local w = Handoff.decide(sendId, record, NOW + 4000) :: any
		expect(w.kind).toBe("send")
		expect(w.prompt).toBe(s.prompt)
		-- A second click on the same link finds nothing (the window deleted it).
		kv[Handoff.key(sendId)] = nil
		expect((Handoff.decide(sendId, nil, NOW + 5000) :: any).kind).toBe("refused")
	end)

	it("refuses stale, future and unreadable records, deleting them", function()
		local send = { v = 1, stage = "send", created_ms = NOW, prompt = "p", title = "t" }
		local stale = Handoff.decide("abcdef01", send, NOW + Handoff.SEND_TTL_MS + 1) :: any
		expect(stale.kind).toBe("refused")
		expect(stale.delete).toBe(true)
		expect((Handoff.decide("abcdef01", send, NOW - Handoff.SEND_TTL_MS - 1) :: any).kind).toBe("refused")
		local draft = { v = 1, stage = "draft", created_ms = NOW, subject = SUBJECT }
		expect((Handoff.decide("abcdef01", draft, NOW + Handoff.DRAFT_TTL_MS + 1) :: any).kind).toBe("refused")
		local bads: { any } = {
			{ v = 2, stage = "send", created_ms = NOW, prompt = "p", title = "t" },
			"x",
			{ v = 1, stage = "send", created_ms = NOW, prompt = "", title = "t" },
			{ v = 1, stage = "other", created_ms = NOW },
		}
		for _, bad in bads do
			local r = Handoff.decide("abcdef01", bad, NOW) :: any
			expect(r.kind).toBe("refused")
			expect(r.delete).toBe(true)
		end
	end)

	it("a preview opened on a stale draft shows why and still deletes it", function()
		local kv = {}
		local opened = run(kv, Handoff.start(SUBJECT, makeEnv(kv), 3))
		local s, effects = State.init({ opened[1] }, nil, makeEnv(kv, NOW + Handoff.DRAFT_TTL_MS + 1))
		expect(s.status).toBe("expired")
		expect(s.note).toBe("This investigation draft has expired.")
		run(kv, effects)
		expect(kv[Handoff.key(idOf(opened[1]))]).toBeNil()
		local _, sendEffects, handled = State.key(s, { name = "enter" }, makeEnv(kv))
		expect(handled).toBe(false)
		expect(#sendEffects).toBe(0)
	end)

	it("a restored preview rebuilds from saved state without the kv record", function()
		local kv = {}
		local opened = run(kv, Handoff.start(SUBJECT, makeEnv(kv), 5))
		local s, effects = State.init({ opened[1] }, nil, makeEnv(kv))
		run(kv, effects)
		local saved = json.decode(json.encode(State.save(s)))
		local restored, again = State.init({ opened[1] }, saved, makeEnv(kv))
		expect(restored.prompt).toBe(s.prompt)
		-- Restoring never sends; it only refetches the alert's recent values.
		expect(find(again, "open")).toBeNil()
		expect(find(again, "kv_set")).toBeNil()
		expect(find(again, "http").request.path).toBe("/api/v1/query_range")
	end)
end)

describe("preview", function()
	local function opened(): (any, any)
		local kv = {}
		local links = run(kv, Handoff.start(SUBJECT, makeEnv(kv), 9))
		local s, effects = State.init({ links[1] }, nil, makeEnv(kv))
		return s, effects
	end

	it("fetches the alert query's recent values over investigate.range and adds them to the prompt", function()
		local s, effects = opened()
		local http = find(effects, "http")
		expect(string.find(http.request.body, "query=vector%281%29", 1, true) ~= nil).toBe(true)
		expect(s.subject.range.to_ms - s.subject.range.from_ms).toBe(30 * 60000)
		State.update(s, {
			kind = "http_done",
			tag = http.tag,
			response = {
				status = 200,
				headers = {},
				body = Fixtures.read("prometheus/3.15.0/query_range_multi.json"),
				timed_out = false,
			},
		}, makeEnv({}))
		expect(s.status).toBe("ready")
		expect(s.prompt).toContain("Recent values (")
		expect(s.prompt).toContain("Time range: now-30m to now")
	end)

	it("says why values are missing when the fetch fails", function()
		local s, effects = opened()
		local http = find(effects, "http")
		State.update(s, {
			kind = "http_done",
			tag = http.tag,
			response = { status = 0, headers = {}, body = "", timed_out = false, error = "io: Connection refused" },
		}, makeEnv({}))
		expect(s.note).toContain("Recent values unavailable")
		expect((string.find(s.prompt, "Recent values (", 1, true))).toBeNil()
	end)

	it("enter sends once; the button sends again on purpose", function()
		local s = opened()
		local _, first = State.key(s, { name = "enter" }, makeEnv({}))
		expect(#first).toBe(2)
		local _, second, handled = State.key(s, { name = "enter" }, makeEnv({}))
		expect(handled).toBe(false)
		expect(#second).toBe(0)
		local _, again = State.update(s, { kind = "event", ev = { ev = "action", act = "send" } }, makeEnv({}))
		expect(find(again, "open").target ~= find(first, "open").target).toBe(true)
	end)

	it("copies the prompt and closes on q", function()
		local s = opened()
		local _, copy = State.key(s, { name = "y", text = "y" }, makeEnv({}))
		expect(find(copy, "copy").text).toBe(s.prompt)
		local _, close = State.key(s, { name = "q", text = "q" }, makeEnv({}))
		expect(find(close, "exit") ~= nil).toBe(true)
	end)

	it("shows the exact prompt it would send", function()
		local s = opened()
		local view = View.view(s, makeEnv({}))
		local shown: string? = nil
		for _, child in view.main.c do
			if child.p.key == "prompt" then
				local lines = {}
				for _, line in child.c do
					local text = line.p.spans[1].t
					table.insert(lines, if text == " " then "" else text)
				end
				shown = table.concat(lines, "\n")
			end
		end
		expect(shown).toBe(s.prompt)
	end)
end)

return nil
