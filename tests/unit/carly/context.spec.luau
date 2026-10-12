--!strict
-- Carly's request context is a single line Tern caps at 400 characters per
-- plugin: it must say what fires (or that a poll failed, never "all clear"
-- for an outage), put the contexts that need attention first, stay within
-- the cap however many contexts there are, and say nothing before the
-- poller wrote a summary.
local CarlyContext = require("../../../plugin/lib/carly/context")
local Summary = require("../../../plugin/lib/alerts/summary")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577860000

local function summary(firing: number, sev: { [string]: number }, pending: number?, err: any?): any
	local s = Summary.empty(NOW)
	s.firing = firing
	s.by_severity = sev
	s.pending = pending or 0
	s.error = err
	return s
end

local function text(contexts: { [string]: any }, now: number?, updated: number?): string?
	local payload = Summary.payload(contexts, updated or NOW - 30000, 60)
	return CarlyContext.text(json.decode(json.encode(payload)), now or NOW)
end

describe("context", function()
	it("says nothing until a summary exists", function()
		expect(CarlyContext.text(nil, NOW)).toBeNil()
		expect(CarlyContext.text({ v = 99 }, NOW)).toBeNil()
	end)

	it("lists firing contexts first with their severities", function()
		local s = text({
			dev = summary(0, {}),
			prod = summary(3, { critical = 1, warning = 2 }, 1),
		}) :: string
		expect(s).toBe(
			'Tern Grafana alerts (as of 30s ago): prod: 3 firing (1 critical, 2 warning), 1 pending; dev: 0 firing. Details: plugins["tern-grafana"].alerts(context)'
		)
	end)

	it("reports a failed poll as unknown, not as all clear", function()
		local s = text({ lab = summary(0, {}, 0, "auth") }) :: string
		expect(s).toContain("lab: unknown (poll failed: auth)")
	end)

	it("marks a summary the poller stopped updating as stale", function()
		expect(text({ lab = summary(1, { warning = 1 }) }, NOW + 3600000) :: string).toContain(", stale)")
	end)

	it("stays within 400 characters however many contexts fire", function()
		local many = {}
		for i = 1, 60 do
			many[string.format("context-%02d", i)] = summary(i, { critical = i })
		end
		local s = text(many) :: string
		expect(#s <= CarlyContext.MAX_CHARS).toBe(true)
		expect(s).toContain("more")
		expect(s).toContain("context-60: 60 firing")
	end)
end)

return nil
