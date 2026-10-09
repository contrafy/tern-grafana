--!strict
-- The inbox is only trustworthy if its filter means what the same text means
-- in Alertmanager (users paste matchers between the two), and if what needs
-- attention sorts first: a silenced critical must not push a firing warning
-- off screen.
local Fixtures = require("../../lib/fixtures")
local Group = require("../../../plugin/lib/alerts/group")
local Normalize = require("../../../plugin/lib/alerts/normalize")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env: any = { now_ms = 1791577860000, decode = json.decode, encode = json.encode, null = json.null }

local function alerts(): { any }
	local am: any = Normalize.parseAlertmanager(
		env,
		Fixtures.read("alertmanager/0.34.1/alerts_with_silenced.json"),
		"lab",
		"alertmanager"
	)
	local prom: any =
		Normalize.parsePrometheusAlerts(env, Fixtures.read("prometheus/3.15.0/alerts.json"), "lab", "prometheus")
	return Normalize.merge(am.items, prom.items)
end

local function names(list: { any }): { string }
	local out = {}
	for _, a in list do
		table.insert(out, a.labels.alertname)
	end
	table.sort(out)
	return out
end

local function filtered(text: string): { string }
	local f, err = Group.parseFilter(text)
	assert(f, err)
	return names(Group.apply(f, alerts()))
end

describe("filter matchers", function()
	it("anchors regex matchers on both ends like Alertmanager", function()
		expect(filtered("alertname=~Tern")).toEqual({})
		expect(filtered("alertname=~Target")).toEqual({})
		expect(filtered("alertname=~TernTarget.*")).toEqual({ "TernTargetDown" })
		expect(filtered("alertname=~Tern.*Down")).toEqual({ "TernGrafanaTargetDown", "TernTargetDown" })
		expect(filtered("alertname!~Tern.*Firing")).toEqual({ "TernGrafanaTargetDown", "TernPending", "TernTargetDown" })
	end)

	it("matches equality exactly and treats a missing label as empty", function()
		expect(filtered("severity=warning")).toEqual({ "TernGrafanaTargetDown", "TernTargetDown" })
		expect(filtered("severity!=warning")).toEqual({ "TernAlwaysFiring", "TernGrafanaAlwaysFiring", "TernPending" })
		expect(filtered('grafana_folder=""')).toEqual({ "TernAlwaysFiring", "TernPending", "TernTargetDown" })
		expect(filtered("instance=~.+")).toEqual({ "TernGrafanaTargetDown", "TernTargetDown" })
	end)

	it("accepts Alertmanager's braced, quoted, comma-separated form", function()
		expect(filtered('{severity="warning", job="down"}')).toEqual({ "TernGrafanaTargetDown", "TernTargetDown" })
		expect(filtered('grafana_folder="Tern Alerts"')).toEqual({ "TernGrafanaAlwaysFiring", "TernGrafanaTargetDown" })
	end)

	it("matches free words case-insensitively against summary and labels, all words required", function()
		expect(filtered("always")).toEqual({ "TernAlwaysFiring", "TernGrafanaAlwaysFiring" })
		expect(filtered("always grafana")).toEqual({ "TernGrafanaAlwaysFiring" })
		expect(filtered("node-exporter:9999 severity=warning")).toEqual({ "TernGrafanaTargetDown", "TernTargetDown" })
	end)

	it("reports a broken regex or quote instead of matching nothing silently", function()
		local f, err = Group.parseFilter("alertname=~(")
		expect(f).toBeNil()
		expect(string.find(err :: string, "bad regex", 1, true) ~= nil).toBe(true)
		f, err = Group.parseFilter('alertname="x')
		expect(f).toBeNil()
		expect(err).toBe("unterminated quote")
	end)
end)

describe("sort", function()
	it("puts firing and pending above muted alerts, then by severity, then state", function()
		local order = {}
		for _, a in Group.sort(alerts()) do
			table.insert(order, a.labels.alertname .. ":" .. a.state)
		end
		expect(order).toEqual({
			"TernGrafanaAlwaysFiring:firing",
			"TernTargetDown:firing",
			"TernGrafanaTargetDown:firing",
			"TernPending:pending",
			"TernAlwaysFiring:silenced",
		})
	end)

	it("shows the newest alert first among equals", function()
		local list = alerts()
		local a, b = table.clone(list[1]), table.clone(list[1])
		a.fingerprint, b.fingerprint = "a", "b"
		a.state, b.state = "firing", "firing"
		a.starts_at_ms, b.starts_at_ms = 1000, 2000
		expect(Group.before(b, a)).toBe(true)
		expect(Group.before(a, b)).toBe(false)
	end)
end)

describe("group", function()
	it("groups by alertname by default and ranks groups by their most urgent alert", function()
		local groups = Group.group(alerts(), { "alertname" })
		local keys = {}
		for _, g in groups do
			table.insert(keys, g.key)
		end
		expect(keys[1]).toBe("TernGrafanaAlwaysFiring")
		expect(keys[#keys]).toBe("TernAlwaysFiring")
		expect(groups[#groups].worst).toBe("none")
		expect(groups[#groups].counts).toEqual({ silenced = 1 })
	end)

	it("puts alerts sharing the group_by labels together and counts their states", function()
		local groups = Group.group(alerts(), { "team" })
		expect(#groups).toBe(2)
		expect(groups[1].labels).toEqual({ { name = "team", value = "platform" } })
		expect(groups[1].worst).toBe("critical")
		expect(groups[1].counts).toEqual({ firing = 3, silenced = 1 })
		-- TernPending has no team label: its own group, with no labels to show.
		expect(groups[2].labels).toEqual({})
		expect(groups[2].counts).toEqual({ pending = 1 })
	end)

	it("puts every alert alone with group_by {'...'}", function()
		expect(#Group.group(alerts(), { "..." })).toBe(5)
	end)
end)

return nil
