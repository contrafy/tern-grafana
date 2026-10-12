--!strict
-- Posting an annotation writes to a shared Grafana, so it only ever happens
-- after the user chose Always or Once for that exact draft: never from init
-- (restored blocks re-run it), never from a stray key, never twice by
-- itself after a failure. Always and Never are remembered per context in kv;
-- Once is not. The trigger honors those decisions and `on = "success"`.
local Approval = require("../../../plugin/lib/annotations/approval")
local Api = require("../../../plugin/lib/annotations/api")
local Command = require("../../../plugin/lib/annotations/command")
local Fixtures = require("../../lib/fixtures")
local Pairing = require("../../../plugin/lib/annotations/pairing")
local Render = require("../../../plugin/lib/annotations/render")
local Scheme = require("../../../plugin/lib/links/scheme")
local Settings = require("../../../plugin/lib/annotations/settings")
local State = require("../../../plugin/lib/annotations/state")
local Trigger = require("../../../plugin/lib/annotations/trigger")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function config(extra: string): any
	local cfg, problems = Validate.parseFile([[{"default_context": "lab", "contexts": {
		"lab": {"grafana": {"url": "http://localhost:3000"}, "prometheus": {"url": "http://localhost:9090"}},
		"prom": {"prometheus": {"url": "http://p:9090"}}}]] .. extra .. "}", json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

local ENABLED = config([[, "annotations": {"enabled": true}]])

local function makeEnv(kv: { [string]: any }?, cfg: any?): any
	local store = kv or {}
	return {
		now_ms = 1791577900000,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		config = cfg or ENABLED,
		kv_get = function(key: string): any
			return store[key]
		end,
	}
end

local function run(line: string, status: number): Pairing.Run
	return Pairing.finished(Pairing.new(), 1, line, status, 1000, 1791577900000)
end

local function draft(context: string?): Api.Draft
	local r = run("helm upgrade web ./chart -n shop", 0)
	local m = Command.match(r.line, Command.compileAll(Command.DEFAULT_PATTERNS)) :: Command.Match
	return Api.draft(r, m, (Settings.read(ENABLED)), context or "lab", { user = "me" })
end

local function key(text: string?, name: string?): any
	return { name = name or text, text = text, ctrl = false, alt = false, shift = false, meta = false }
end

local function kinds(effects: { any }, kind: string): { any }
	local out = {}
	for _, e in effects do
		if e.kind == kind then
			table.insert(out, e)
		end
	end
	return out
end

local function link(id: string): string
	return Scheme.encode({ action = "annotate", params = { id = id, context = "lab" }, vars = {} })
end

-- An approve block for a loaded draft.
local function asking(env: any): State.State
	local s, effects = State.init({ link("abc123") }, nil, env)
	expect(kinds(effects, "annotate_load")[1].id).toBe("abc123")
	expect(#kinds(effects, "http")).toBe(0)
	s = State.update(s, { kind = "annotate_pending", draft = draft() }, env)
	expect(s.phase).toBe("ask")
	return s
end

local function act(s: State.State, value: string, env: any): { any }
	local _, effects = State.update(s, { kind = "event", ev = { ev = "action", act = "choose", value = value } }, env)
	return effects
end

local function created(): any
	return {
		status = 200,
		headers = {},
		body = Fixtures.read("grafana/12.4.12/annotation_create.json"),
		timed_out = false,
	}
end

describe("annotations approval decisions", function()
	it("asks when nothing is remembered, posts on always, skips on never", function()
		expect(Approval.decide({}, "lab")).toBe("ask")
		expect(Approval.decide(Approval.read({ lab = "always" }), "lab")).toBe("post")
		expect(Approval.decide(Approval.read({ lab = "never" }), "lab")).toBe("skip")
		expect(Approval.decide(Approval.read({ lab = "always" }), "prom")).toBe("ask")
	end)

	it("remembers always and never per context, and never remembers once", function()
		expect(Approval.apply({ prod = "never" }, "lab", "always")).toEqual({ prod = "never", lab = "always" })
		expect(Approval.apply({ lab = "always" }, "lab", "never")).toEqual({ lab = "never" })
		expect(Approval.apply({ lab = "always" }, "lab", "once")).toBeNil()
		expect(Approval.forget({ lab = "always", prod = "never" }, "lab")).toEqual({ prod = "never" })
	end)

	it("drops malformed kv entries", function()
		expect(Approval.read({ lab = "yes", prod = "never", [1] = "always" })).toEqual({ prod = "never" })
		expect(Approval.read("always")).toEqual({})
	end)
end)

describe("annotations trigger", function()
	it("does nothing until annotations or impact are enabled", function()
		expect(Trigger.plan(config(""), run("helm upgrade web .", 0), nil)).toBeNil()
		expect(Trigger.plan(config([[, "annotations": {"enabled": false}]]), run("helm upgrade web .", 0), nil)).toBeNil()
	end)

	it("asks on the first deploy in a context and posts once it is always", function()
		local p = Trigger.plan(ENABLED, run("helm upgrade web .", 0), nil) :: Trigger.Plan
		expect(p.annotate and (p.annotate :: any).decision).toBe("ask")
		expect(p.annotate and (p.annotate :: any).context).toBe("lab")
		p = Trigger.plan(ENABLED, run("helm upgrade web .", 0), { lab = "always" }) :: Trigger.Plan
		expect(p.annotate and (p.annotate :: any).decision).toBe("post")
		expect(Trigger.plan(ENABLED, run("helm upgrade web .", 0), { lab = "never" })).toBeNil()
	end)

	it("annotates only successful commands by default, any status with on=always", function()
		expect(Trigger.plan(ENABLED, run("helm upgrade web .", 1), nil)).toBeNil()
		local always = config([[, "annotations": {"enabled": true, "on": "always"}]])
		local p = Trigger.plan(always, run("helm upgrade web .", 1), nil) :: Trigger.Plan
		expect(p.annotate ~= nil).toBe(true)
	end)

	it("ignores commands that are not deploys", function()
		expect(Trigger.plan(ENABLED, run("kubectl get pods", 0), nil)).toBeNil()
	end)

	it("says why when the context has no Grafana to annotate", function()
		local cfg = config([[, "annotations": {"enabled": true, "context": "prom"}]])
		local p = Trigger.plan(cfg, run("helm upgrade web .", 0), nil) :: Trigger.Plan
		expect(p.annotate).toBeNil()
		expect(string.find(p.problems[1], "no grafana endpoint", 1, true) ~= nil).toBe(true)
	end)

	it("opens an impact watch with the command's times and names when impact is enabled", function()
		local cfg = config([[, "impact": {"enabled": true}]])
		local p = Pairing.new()
		Pairing.started(p, 2, "helm upgrade web ./chart -n shop", "/srv/shop", 1791577800000)
		local r = Pairing.finished(p, 2, "helm upgrade web ./chart -n shop", 0, 60000, 1791577860000)
		local plan = Trigger.plan(cfg, r, nil) :: Trigger.Plan
		expect(plan.annotate).toBeNil()
		local l = Scheme.decode(plan.impact :: string) :: Scheme.Link
		expect(l.action).toBe("impact")
		expect(l.params).toEqual({
			context = "lab",
			start = "1791577800000",
			finish = "1791577860000",
			kind = "helm-upgrade",
			ns = "shop",
			svc = "web",
			dir = "shop",
		})
	end)
end)

describe("annotations approve block", function()
	it("never posts from init, also when restored without the pending draft", function()
		local env = makeEnv()
		local s, effects = State.init({ link("abc123") }, nil, env)
		expect(#kinds(effects, "http")).toBe(0)
		s = State.update(s, { kind = "annotate_pending", draft = nil }, env)
		expect(s.phase).toBe("missing")
		expect(#kinds(act(s, "once", env), "http")).toBe(0)
	end)

	it("Once posts the draft and remembers nothing", function()
		local env = makeEnv()
		local s = asking(env)
		local effects = act(s, "once", env)
		local http = kinds(effects, "http")
		expect(#http).toBe(1)
		expect(http[1].request.method).toBe("POST")
		expect(http[1].request.path).toBe("/api/annotations")
		expect(http[1].route.endpoint.url).toBe("http://localhost:3000")
		expect(json.decode(http[1].request.body).text).toBe(draft().text)
		expect(#kinds(effects, "kv_set")).toBe(0)
		local _, done = State.update(s, { kind = "http_done", tag = http[1].tag, response = created() }, env)
		expect(s.phase).toBe("posted")
		expect(s.posted_id).toBe(9)
		expect(kinds(done, "annotate_forget")[1].id).toBe("abc123")
	end)

	it("Always remembers the context and posts", function()
		local env = makeEnv({ [Approval.KEY] = { prod = "never" } })
		local s = asking(env)
		local effects = act(s, "always", env)
		expect(kinds(effects, "kv_set")[1].value).toEqual({ prod = "never", lab = "always" })
		expect(#kinds(effects, "http")).toBe(1)
	end)

	it("Never remembers the context and posts nothing", function()
		local env = makeEnv()
		local s = asking(env)
		local effects = act(s, "never", env)
		expect(kinds(effects, "kv_set")[1].value).toEqual({ lab = "never" })
		expect(#kinds(effects, "http")).toBe(0)
		expect(s.phase).toBe("declined")
		expect(#kinds(act(s, "once", env), "http")).toBe(0)
	end)

	it("sends one request per choice and ignores choices while it is in flight", function()
		local env = makeEnv()
		local s = asking(env)
		expect(#kinds(act(s, "once", env), "http")).toBe(1)
		expect(#kinds(act(s, "once", env), "http")).toBe(0)
		expect(#kinds(act(s, "always", env), "http")).toBe(0)
	end)

	it("reports a failed post and does not retry it by itself", function()
		local env = makeEnv()
		local s = asking(env)
		local http = kinds(act(s, "once", env), "http")
		local _, effects = State.update(s, {
			kind = "http_done",
			tag = http[1].tag,
			response = { status = 403, headers = {}, body = '{"message":"Permissions needed"}', timed_out = false },
		}, env)
		expect(#kinds(effects, "http")).toBe(0)
		expect(s.phase).toBe("ask")
		expect(s.note_tone).toBe("error")
		-- A late duplicate answer changes nothing.
		State.update(s, { kind = "http_done", tag = http[1].tag, response = created() }, env)
		expect(s.phase).toBe("ask")
	end)

	it("needs a picked choice and an explicit y: typed shell keys never decide", function()
		local env = makeEnv()
		local s = asking(env)
		local sent = 0
		for _, k in
			{ key("l"), key("s"), key(" "), key("a"), key("o"), key("n"), key("y"), key(nil, "enter"), key("y") }
		do
			local _, effects = State.key(s, k, env)
			sent += #kinds(effects, "http") + #kinds(effects, "kv_set")
		end
		expect(sent).toBe(0)
		local _, moved = State.key(s, key(nil, "right"), env)
		expect(kinds(moved, "reveal")[1].id).toBe("main.choices.calways")
		State.key(s, key(nil, "right"), env)
		expect(State.CHOICES[s.sel :: number]).toBe("once")
		local _, enter = State.key(s, key(nil, "enter"), env)
		expect(#kinds(enter, "http")).toBe(0)
		local _, yes = State.key(s, key("y"), env)
		expect(#kinds(yes, "http")).toBe(1)
		expect(#kinds(yes, "kv_set")).toBe(0)
	end)

	it("dismiss posts nothing, drops the pending draft and closes", function()
		local env = makeEnv()
		local s = asking(env)
		local _, effects = State.key(s, key(nil, "escape"), env)
		expect(#kinds(effects, "http")).toBe(0)
		expect(#kinds(effects, "annotate_forget")).toBe(1)
		expect(#kinds(effects, "exit")).toBe(1)
	end)

	it("logs decisions without the annotation text", function()
		local env = makeEnv()
		local s = asking(env)
		for _, e in kinds(act(s, "always", env), "annotate_audit") do
			for _, v in e do
				expect((string.find(tostring(v), "helm", 1, true))).toBeNil()
			end
		end
	end)

	it("shows the remembered decisions without an id and forgets one on x", function()
		local env = makeEnv({ [Approval.KEY] = { lab = "always", prod = "never" } })
		local s, effects = State.init({}, nil, env)
		expect(#effects).toBe(0)
		expect(s.phase).toBe("manage")
		expect(#s.approvals).toBe(2)
		local _, down = State.key(s, key(nil, "down"), env)
		expect(kinds(down, "reveal")[1].id).toBe("main.list.r2")
		local _, x = State.key(s, key("x"), env)
		expect(kinds(x, "kv_set")[1].value).toEqual({ lab = "always" })
		expect(#s.approvals).toBe(1)
	end)

	it("renders the draft, the choices and the target Grafana", function()
		local env = makeEnv()
		local s = asking(env)
		local view = Render.view(s, env)
		local text = json.encode(view)
		expect(string.find(text, "http://localhost:3000", 1, true) ~= nil).toBe(true)
		expect(string.find(text, "choose=always", 1, true) ~= nil).toBe(true)
		expect(string.find(text, "choose=never", 1, true) ~= nil).toBe(true)
	end)
end)

return nil
