--!strict
-- A watch toast interrupts: each start of firing and each resolution must be
-- announced once across every window and poll, pending must stay quiet, and
-- nothing that happened while Tern was closed is announced late. The status
-- segment must show firing watches by severity and stay out of the way while
-- every watch is ok.
local Segment = require("../../../plugin/lib/watches/segment")
local Toasts = require("../../../plugin/lib/watches/toasts")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577898000

local function entry(name: string, status: string, since: number, fields: { [string]: any }?): any
	local e: any = {
		name = name,
		context = "lab",
		expr = 'up{job="down"}',
		op = "<",
		threshold = 1,
		severity = "warning",
		status = status,
		since_ms = since,
		eval_ms = since,
		interval_ms = 60000,
		def = "d1",
		series = 1,
		matching = if status == "ok" then 0 else 1,
		value = if status == "ok" then 1 else 0,
		no_data = false,
	}
	if fields then
		for k, v in fields do
			e[k] = v
		end
	end
	return e
end

local function summary(entries: { any }, at: number): any
	return json.decode(json.encode({ v = 1, updated_ms = at, watches = entries }))
end

-- What every window would do in turn: check, then store the record.
local function window(raw: any, store: { [string]: any }, now: number): { any }
	local record, toasts = Toasts.check(raw, store.notified, now)
	if record then
		store.notified = json.decode(json.encode(record))
	end
	return toasts
end

describe("toasts", function()
	it("announces a start of firing once across windows and polls", function()
		local store = {}
		expect(#window(summary({ entry("down", "ok", NOW) }, NOW), store, NOW)).toBe(0)
		local firing = summary({ entry("down", "firing", NOW + 60000, { severity = "critical" }) }, NOW + 60000)
		local toasts = window(firing, store, NOW + 61000)
		expect(toasts).toEqual({
			{ level = "error", text = "Watch down is firing (lab)", sub = "critical: 0 < 1; 1 of 1 series" },
		})
		expect(#window(firing, store, NOW + 62000)).toBe(0)
		local later = summary({ entry("down", "firing", NOW + 60000) }, NOW + 120000)
		expect(#window(later, store, NOW + 121000)).toBe(0)
	end)

	it("announces resolution after firing, including no data", function()
		local store = {}
		window(summary({ entry("down", "firing", NOW) }, NOW), store, NOW)
		local resolved = summary({ entry("down", "ok", NOW + 60000, { no_data = true, value = nil }) }, NOW + 60000)
		expect(window(resolved, store, NOW + 61000)).toEqual({
			{ level = "success", text = "Watch down resolved (lab)", sub = "no data" },
		})
	end)

	it("keeps pending quiet, then toasts when it fires", function()
		local store = {}
		window(summary({ entry("down", "ok", NOW) }, NOW), store, NOW)
		expect(#window(summary({ entry("down", "pending", NOW + 60000) }, NOW + 60000), store, NOW + 60000)).toBe(0)
		local toasts = window(summary({ entry("down", "firing", NOW + 180000) }, NOW + 180000), store, NOW + 180000)
		expect(#toasts).toBe(1)
		expect(toasts[1].level).toBe("info")
	end)

	it("a pending watch that never fired does not toast a resolution", function()
		local store = {}
		window(summary({ entry("down", "pending", NOW) }, NOW), store, NOW)
		expect(#window(summary({ entry("down", "ok", NOW + 60000) }, NOW + 60000), store, NOW + 60000)).toBe(0)
	end)

	it("records without toasting what started firing long ago (Tern was closed)", function()
		local store = {}
		local old = summary({ entry("down", "firing", NOW - 60 * 60000) }, NOW)
		expect(#window(old, store, NOW)).toBe(0)
		expect(store.notified.watches.down.status).toBe("firing")
	end)

	it("forgets removed watches and does nothing without a summary", function()
		local store = {}
		window(summary({ entry("down", "firing", NOW) }, NOW), store, NOW)
		window(summary({}, NOW + 60000), store, NOW + 60000)
		expect(store.notified.watches.down).toBeNil()
		local record, toasts = Toasts.check(nil, store.notified, NOW)
		expect(record).toBeNil()
		expect(#toasts).toBe(0)
	end)
end)

describe("segment", function()
	it("is absent while every watch is ok or nothing is configured", function()
		expect(Segment.segments(summary({ entry("a", "ok", NOW) }, NOW), NOW)).toBeNil()
		expect(Segment.segments(nil, NOW)).toBeNil()
	end)

	it("names a single firing watch and counts several, toned by the worst severity", function()
		local one = Segment.segments(summary({ entry("down", "firing", NOW) }, NOW), NOW)
		expect(one).toEqual({
			{ text = "watch down", icon = Segment.ICON, tone = "warning", command = Segment.COMMAND },
		})
		local two = Segment.segments(
			summary({ entry("a", "firing", NOW), entry("b", "firing", NOW, { severity = "critical" }) }, NOW),
			NOW
		) :: any
		expect(two[1].text).toBe("2 watches")
		expect(two[1].tone).toBe("error")
	end)

	it("shows pending muted and marks failures and a stopped poller with ?", function()
		local pending = Segment.segments(summary({ entry("a", "pending", NOW) }, NOW), NOW) :: any
		expect(pending[1].text).toBe("1 pending")
		expect(pending[1].tone).toBe("muted")
		local failed = Segment.segments(summary({ entry("a", "ok", NOW, { error = "network" }) }, NOW), NOW) :: any
		expect(failed[1].text).toBe("watch ?")
		local stale = Segment.segments(summary({ entry("a", "firing", NOW) }, NOW), NOW + 60 * 60000) :: any
		expect(stale[1].text).toBe("watch a ?")
		expect(stale[1].tone).toBe("muted")
	end)

	it("follows the alerts segments in the one status formatter", function()
		local alerts = { { text = "alerts 0", tone = "muted" } }
		local watches = Segment.segments(summary({ entry("down", "firing", NOW) }, NOW), NOW)
		local both = Segment.append(alerts, watches) :: any
		expect(#both).toBe(2)
		expect(both[2].text).toBe("watch down")
		expect(#alerts).toBe(1)
		expect(Segment.append(alerts, nil)).toBe(alerts)
		expect(Segment.append(nil, nil)).toBeNil()
	end)

	it("a click opens the most urgent watch's query in its context", function()
		local raw = summary({
			entry("p", "pending", NOW, { expr = "pending_expr" }),
			entry("f", "firing", NOW, { expr = "firing_expr", context = "prod" }),
		}, NOW)
		local link = Segment.link(Segment.focus(raw) :: any)
		expect(link.params).toEqual({ expr = "firing_expr", context = "prod", from = "now-60m", to = "now" })
		expect(Segment.focus(summary({ entry("a", "ok", NOW) }, NOW))).toBeNil()
	end)
end)

return nil
