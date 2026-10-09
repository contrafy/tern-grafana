--!strict
-- A silence is a standing order to drop notifications: if the preview's
-- matching differs from Alertmanager's, the user confirms one set of alerts
-- and silences another. Matching must be Alertmanager's: regexes anchored on
-- both ends, `!=`/`!~` negate, a missing label is the empty string. A silence
-- from an alert must target that alert (Grafana's rule uid included, internal
-- labels left out), and Alertmanager's own refusals are said before sending.
local Fixtures = require("../../lib/fixtures")
local Matchers = require("../../../plugin/lib/silences/matchers")
local Normalize = require("../../../plugin/lib/alerts/normalize")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env: any = { now_ms = 1791577860000, decode = json.decode, encode = json.encode, null = json.null }

local function alerts(path: string, source: any): { [string]: any }
	local parsed: any = Normalize.parseAlertmanager(env, Fixtures.read(path), "lab", source)
	assert(parsed.ok, parsed.error)
	local out = {}
	for _, a in parsed.items do
		out[a.labels.alertname] = a
	end
	return out
end

local function names(list: { any }): { string }
	local out = {}
	for _, a in list do
		table.insert(out, a.labels.alertname)
	end
	table.sort(out)
	return out
end

local AM = alerts("alertmanager/0.34.1/alerts.json", "alertmanager")
local ALL = (function()
	local out = {}
	for _, a in AM do
		table.insert(out, a)
	end
	return out
end)()

local function affected(text: string): { string }
	local list = assert(Matchers.parseList(text))
	return names((assert(Matchers.affected(list, ALL))))
end

describe("from an alert", function()
	it("matches every label with equality, sorted", function()
		expect(Matchers.formatList(Matchers.fromLabels(AM.TernTargetDown))).toBe(
			'{alertname="TernTargetDown", instance="node-exporter:9999", job="down", severity="warning", team="platform"}'
		)
	end)

	for _, v in { "11.6.16", "12.4.12" } do
		it(v .. ": keeps Grafana's rule uid, which scopes the silence to that rule", function()
			local g = alerts("grafana/" .. v .. "/alerting_am_alerts.json", "grafana")
			local list = Matchers.fromLabels(g.TernGrafanaAlwaysFiring)
			expect(list[1]).toEqual({ name = "__alert_rule_uid__", op = "=", value = "tern-g-firing" })
			expect(Matchers.formatList(list)).toBe(
				'{__alert_rule_uid__="tern-g-firing", alertname="TernGrafanaAlwaysFiring", grafana_folder="Tern Alerts", severity="critical", team="platform"}'
			)
		end)
	end

	it("matches exactly the alert it came from", function()
		local list = Matchers.fromLabels(AM.TernTargetDown)
		expect(names((assert(Matchers.affected(list, ALL))))).toEqual({ "TernTargetDown" })
	end)

	it("round-trips through the link text, quotes and escapes included", function()
		local list = { { name = "msg", op = "!=", value = 'a "b"\\c' }, { name = "x", op = "=", value = "line\nnext" } }
		expect((Matchers.parseList(Matchers.formatList(list :: any)))).toEqual(list)
	end)
end)

describe("preview matching", function()
	it("anchors regexes on both ends, as Alertmanager does", function()
		expect(affected("alertname=~Tern")).toEqual({})
		expect(affected('alertname=~"TernAlways.*"')).toEqual({ "TernAlwaysFiring" })
		expect(affected('alertname=~"Tern.*Firing|TernTargetDown"')).toEqual({
			"TernAlwaysFiring",
			"TernGrafanaAlwaysFiring",
			"TernTargetDown",
		})
	end)

	it("negates with != and !~, and needs every matcher to match", function()
		expect(affected('team="platform" severity!="critical"')).toEqual({ "TernGrafanaTargetDown", "TernTargetDown" })
		expect(affected('team="platform" alertname!~"Tern.*Firing"')).toEqual({
			"TernGrafanaTargetDown",
			"TernTargetDown",
		})
		expect(affected('severity="warning" alertname!~"TernGrafana.*"')).toEqual({ "TernTargetDown" })
	end)

	it("treats a missing label as the empty string", function()
		expect(affected('alertname="TernTargetDown" cluster=""')).toEqual({ "TernTargetDown" })
		expect(affected('alertname="TernTargetDown" cluster!=""')).toEqual({})
	end)
end)

describe("validation", function()
	it("refuses what Alertmanager would refuse, before anything is sent", function()
		expect(Matchers.validate({})).toBe("add at least one matcher")
		expect(
			string.find(
				Matchers.validate({ { name = "a", op = "=~", value = ".*" } }) :: string,
				"empty string",
				1,
				true
			) ~= nil
		).toBe(true)
		expect(
			string.find(
				Matchers.validate({ { name = "a", op = "!=", value = "x" } }) :: string,
				"empty string",
				1,
				true
			) ~= nil
		).toBe(true)
		expect(
			string.find(Matchers.validate({ { name = "a-b", op = "=", value = "x" } }) :: string, "label name", 1, true)
				~= nil
		).toBe(true)
		expect(
			string.find(Matchers.validate({ { name = "a", op = "=~", value = "(" } }) :: string, "bad regex", 1, true)
				~= nil
		).toBe(true)
		expect(Matchers.validate({ { name = "a", op = "=~", value = ".*" }, { name = "b", op = "=", value = "x" } })).toBeNil()
	end)

	it("parses one matcher at a time in the form, and refuses free words", function()
		expect((Matchers.parse('job=~"node.*"'))).toEqual({ name = "job", op = "=~", value = "node.*" })
		local none, err = Matchers.parse("oops")
		expect(none).toBeNil()
		expect(string.find(err :: string, "not a matcher", 1, true) ~= nil).toBe(true)
		expect((Matchers.parse("a=1 b=2"))).toBeNil()
	end)
end)

describe("wire format", function()
	it("maps the four operators onto isRegex/isEqual and back", function()
		for _, op in { "=", "!=", "=~", "!~" } do
			local m: any = { name = "a", op = op, value = "v" }
			expect(Matchers.fromApi(Matchers.toApi(m))).toEqual(m)
		end
		expect(Matchers.toApi({ name = "a", op = "!~", value = "v" })).toEqual({
			name = "a",
			value = "v",
			isRegex = true,
			isEqual = false,
		})
		-- Servers before 0.22 omit isEqual.
		expect(Matchers.fromApi({ name = "a", value = "v", isRegex = false })).toEqual({
			name = "a",
			op = "=",
			value = "v",
		})
	end)
end)

return nil
