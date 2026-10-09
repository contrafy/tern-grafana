--!strict
-- A toast interrupts: it must announce each alert that starts firing once
-- (not once per window, not again on the next poll), never announce what was
-- already firing when Tern started or polling resumed, respect the severities
-- the user asked for, and stay silent unless toasts are turned on.
local Fixtures = require("../../lib/fixtures")
local Normalize = require("../../../plugin/lib/alerts/normalize")
local Summary = require("../../../plugin/lib/alerts/summary")
local Toasts = require("../../../plugin/lib/alerts/toasts")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577860000
local env: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null }

local function alerts(path: string): { any }
	local parsed: any = Normalize.parseAlertmanager(env, Fixtures.read(path), "lab", "alertmanager")
	assert(parsed.ok, parsed.error)
	return parsed.items
end

-- TernAlwaysFiring (critical) is silenced in the first capture and firing in the second.
local SILENCED = alerts("alertmanager/0.34.1/alerts_with_silenced.json")
local FIRING = alerts("alertmanager/0.34.1/alerts.json")

local SEVERITIES = { "critical", "error", "warning" }

local function payload(list: { any }, at: number, severities: { string }?): any
	return Summary.payload({ lab = Summary.summarize(list, at) }, at, 60, severities)
end

-- What every window would do in turn: check, then store the record.
local function window(summary: any, store: { [string]: any }): { any }
	local record, toasts = Toasts.check(summary, store.notified)
	if record then
		store.notified = json.decode(json.encode(record))
	end
	return toasts
end

describe("toasts", function()
	it("never toasts on the first poll, then announces what starts firing", function()
		local store = {}
		expect(window(payload(SILENCED, NOW, SEVERITIES), store)).toEqual({})
		expect(store.notified ~= nil).toBe(true)
		local toasts = window(payload(FIRING, NOW + 60000, SEVERITIES), store)
		expect(#toasts).toBe(1)
		expect(toasts[1].level).toBe("error")
		expect(toasts[1].text).toBe("lab: 1 alert started firing")
		expect(string.sub(toasts[1].sub, 1, 10)).toBe("1 critical")
	end)

	it("announces one poll once across windows and polls", function()
		local store = {}
		window(payload(SILENCED, NOW, SEVERITIES), store)
		local next = payload(FIRING, NOW + 60000, SEVERITIES)
		expect(#window(next, store)).toBe(1)
		-- A second window sees the same summary: already announced.
		expect(window(next, store)).toEqual({})
		-- The next poll with the same alerts firing: nothing new.
		expect(window(payload(FIRING, NOW + 120000, SEVERITIES), store)).toEqual({})
	end)

	it("only toasts the configured severities", function()
		local store = {}
		window(payload(SILENCED, NOW, { "warning" }), store)
		expect(window(payload(FIRING, NOW + 60000, { "warning" }), store)).toEqual({})
	end)

	it("seeds without toasting after a gap (Tern was closed, polling paused)", function()
		local store = {}
		window(payload(SILENCED, NOW, SEVERITIES), store)
		expect(window(payload(FIRING, NOW + 60 * 60000, SEVERITIES), store)).toEqual({})
	end)

	it("is silent and records nothing while toasts are off", function()
		local store = {}
		local record, toasts = Toasts.check(payload(FIRING, NOW, nil), nil)
		expect(record).toBeNil()
		expect(toasts).toEqual({})
		-- Turning toasts on later starts with a seed, not a burst.
		expect(window(payload(FIRING, NOW + 60000, SEVERITIES), store)).toEqual({})
	end)

	it("skips a failed poll and keeps what was announced", function()
		local store = {}
		window(payload(SILENCED, NOW, SEVERITIES), store)
		local failed = Summary.payload(
			{ lab = Summary.failed(Summary.summarize(SILENCED, NOW), "network", NOW + 60000) },
			NOW + 60000,
			60,
			SEVERITIES
		)
		expect(window(failed, store)).toEqual({})
		expect(#window(payload(FIRING, NOW + 120000, SEVERITIES), store)).toBe(1)
	end)

	it("keeps only fingerprints and times in its kv record", function()
		local store = {}
		window(payload(FIRING, NOW, SEVERITIES), store)
		local text = json.encode(store.notified)
		expect((string.find(text, "TernAlwaysFiring", 1, true))).toBeNil()
		expect((string.find(text, "platform", 1, true))).toBeNil()
	end)
end)

return nil
