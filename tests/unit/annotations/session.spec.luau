--!strict
-- Pending deploy-annotation drafts live only in host memory: an approve link
-- older than an hour, or pushed out by newer ones, must read as gone rather
-- than post a stale draft. Problems toast once per session. The audit lines
-- are what operators grep for, so their text must not drift.
local Audit = require("../../../plugin/lib/audit")
local Session = require("../../../plugin/lib/annotations/session")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function draft(context: string): any
	return { context = context, kind = "helm upgrade", text = "secret-ish text" }
end

local function counter(): () -> number
	local n = 0
	return function()
		n += 1
		return n
	end
end

describe("pending drafts", function()
	it("loads a stored draft until it expires", function()
		local s = Session.new()
		local id = Session.store(s, draft("prod"), 1000, counter())
		expect(id).toBe(string.format("%x%06x", 1000, 1))
		expect(Session.load(s, id, 1000 + Session.PENDING_TTL_MS)).toEqual(draft("prod"))
		expect(Session.load(s, id, 1001 + Session.PENDING_TTL_MS)).toBe(nil)
		expect(s.pending[id]).toBe(nil)
	end)

	it("drops the oldest draft when the cap is reached", function()
		local s = Session.new()
		local rand = counter()
		local first = Session.store(s, draft("a"), 1000, rand)
		for i = 1, Session.MAX_PENDING - 1 do
			Session.store(s, draft("b"), 1000 + i, rand)
		end
		expect(Session.load(s, first, 2000)).toEqual(draft("a"))
		Session.store(s, draft("c"), 3000, rand)
		expect(Session.load(s, first, 3000)).toBe(nil)
	end)

	it("never reuses a live id", function()
		local s = Session.new()
		local values = { 7, 7, 8 }
		local i = 0
		local function rand(): number
			i += 1
			return values[i]
		end
		local a = Session.store(s, draft("a"), 5, rand)
		local b = Session.store(s, draft("b"), 5, rand)
		expect(a ~= b).toBe(true)
		Session.forget(s, a)
		expect(Session.load(s, a, 5)).toBe(nil)
	end)
end)

describe("problems", function()
	it("toasts each problem once per session", function()
		local s = Session.new()
		expect(Session.fresh(s, { "x", "y" })).toEqual({ "x", "y" })
		expect(Session.fresh(s, { "y", "z" })).toEqual({ "z" })
	end)
end)

describe("audit lines", function()
	it("matches the lines the host logged before", function()
		local d = draft("prod")
		expect(Session.sentLine(d)).toBe("action=post outcome=sent context=prod choice=always")
		local line, toast = Session.outcome(d, 500, { message = "boom" }, nil)
		expect(line).toBe("action=post outcome=failed context=prod choice=always status=500")
		expect(toast).toEqual({ level = "error", text = "Deploy annotation failed (prod)", sub = "boom" })
		line, toast = Session.outcome(d, 200, nil, nil)
		expect(line).toBe("action=post outcome=ok context=prod choice=always id=nil status=200")
		expect(toast).toEqual({ level = "info", text = "Deploy annotated in Grafana (prod)", sub = "helm upgrade" })
		expect(Session.auditLine({ action = "post", outcome = "denied", context = "prod", id = 12 })).toBe(
			"action=post outcome=denied context=prod id=12"
		)
	end)

	it("writes silence and IRM fields in the order they always had", function()
		expect(Audit.line({
			action = "create",
			outcome = "ok",
			context = "c",
			target = "am",
			matchers = 2,
			id = "abc",
			status = 200,
		}, { "action", "outcome", "context", "target" }, { "matchers", "duration_s", "id", "status" })).toBe(
			"action=create outcome=ok context=c target=am matchers=2 id=abc status=200"
		)
		expect(Audit.line({ action = "ack", outcome = "sent" }, { "block", "action", "outcome" }, { "duration_s" })).toBe(
			"block=nil action=ack outcome=sent"
		)
	end)
end)

return nil
