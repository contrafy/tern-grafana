--!strict
-- The status segment is the at-a-glance signal: its tone must follow the
-- worst firing severity, a failed or stopped poll must never look like "all
-- clear", and the chrome is refreshed only when the rendered segment changes
-- (a refresh per poll would redraw every window for nothing). The alerts
-- config must fall back to safe defaults on a typo instead of disabling
-- polling.
local Segment = require("../../../plugin/lib/alerts/segment")
local Settings = require("../../../plugin/lib/alerts/settings")
local Summary = require("../../../plugin/lib/alerts/summary")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577860000

local function summary(firing: number, worst: any, err: any?): any
	local s = Summary.empty(NOW)
	s.firing = firing
	s.worst = worst
	s.error = err
	return s
end

local function render(contexts: { [string]: any }, now: number?): any
	return Segment.segments(json.decode(json.encode(Summary.payload(contexts, NOW, 60))), now or NOW)
end

local function config(text: string): any
	local cfg, problems = Validate.parseFile(text, json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

describe("segments", function()
	it("shows nothing until the poller wrote a summary", function()
		expect(Segment.segments(nil, NOW)).toBeNil()
		expect(Segment.segments({ v = 99 }, NOW)).toBeNil()
	end)

	it("shows one firing count toned by the worst severity, opening the inbox", function()
		expect(render({ lab = summary(3, "critical") })).toEqual({
			{ text = "3 firing", icon = Segment.ICON, tone = "error", command = "plugin.tern-grafana.alerts" },
		})
		expect(render({ lab = summary(1, "warning") })[1].tone).toBe("warning")
		expect(render({ lab = summary(1, "info") })[1].tone).toBe("info")
		expect(render({ lab = summary(1, "none") })[1].tone).toBe("muted")
	end)

	it("names each context with firing alerts when several are polled", function()
		local segs = render({ prod = summary(2, "critical"), lab = summary(1, "warning"), dev = summary(0, "none") })
		expect(#segs).toBe(2)
		expect(segs[1].text).toBe("lab 1")
		expect(segs[1].tone).toBe("warning")
		expect(segs[2].text).toBe("prod 2")
		expect(segs[2].tone).toBe("error")
	end)

	it("says all clear quietly, and unknown when a poll failed", function()
		expect(render({ lab = summary(0, "none") })[1]).toEqual({
			text = "alerts 0",
			icon = Segment.ICON,
			tone = "muted",
			command = Segment.COMMAND,
		})
		expect(render({ lab = summary(0, "none", "auth") })[1].text).toBe("alerts ?")
		expect(render({ lab = summary(2, "critical", "network") })[1].text).toBe("2 firing ?")
	end)

	it("mutes a summary the poller stopped updating", function()
		local segs = render({ lab = summary(2, "critical") }, NOW + 10 * 60 * 1000)
		expect(segs[1].tone).toBe("muted")
		expect(segs[1].text).toBe("2 firing ?")
		expect(render({ lab = summary(0, "none") }, NOW + 10 * 60 * 1000)[1].text).toBe("alerts ?")
	end)

	it("changes its signature only when what is drawn changes", function()
		local a = render({ lab = summary(2, "critical") })
		local later = Segment.segments(
			json.decode(json.encode(Summary.payload({ lab = summary(2, "critical") }, NOW + 60000, 60))),
			NOW + 60000
		)
		expect(Segment.signature(a)).toBe(Segment.signature(later))
		expect(Segment.signature(a) ~= Segment.signature(render({ lab = summary(3, "critical") }))).toBe(true)
		expect(Segment.signature(a) ~= Segment.signature(render({ lab = summary(2, "warning") }))).toBe(true)
	end)
end)

describe("alerts settings", function()
	it("polls the default context every 60 s, grouped by alertname, when unset", function()
		local s, problems =
			Settings.read(config('{"default_context": "lab", "contexts": {"lab": {"grafana": {"url": "http://g"}}}}'))
		expect(s).toEqual({ group_by = { "alertname" }, poll_s = 60, contexts = { "lab" } })
		expect(problems).toEqual({})
		expect(Settings.read(nil).contexts).toEqual({})
	end)

	it("reads group_by, poll_s and contexts, and 0 turns polling off", function()
		local s = Settings.read(
			config([[{"contexts": {"a": {"grafana": {"url": "http://g"}}, "b": {"grafana": {"url": "http://g"}}},
			"alerts": {"group_by": ["alertname", "cluster"], "poll_s": 0, "contexts": ["b", "a"]}}]])
		)
		expect(s).toEqual({ group_by = { "alertname", "cluster" }, poll_s = 0, contexts = { "b", "a" } })
	end)

	it("raises a too-short interval to the minimum and keeps defaults on bad values, naming the path", function()
		local s, problems =
			Settings.read(config([[{"default_context": "a", "contexts": {"a": {"grafana": {"url": "http://g"}}},
			"alerts": {"group_by": "alertname", "poll_s": 5, "contexts": ["a", "zz"], "colour": 1}}]]))
		expect(s).toEqual({ group_by = { "alertname" }, poll_s = 15, contexts = { "a" } })
		local paths = {}
		for _, p in problems do
			table.insert(paths, p.path)
		end
		table.sort(paths)
		expect(paths).toEqual({ "alerts.colour", "alerts.contexts", "alerts.group_by", "alerts.poll_s" })
	end)
end)

return nil
