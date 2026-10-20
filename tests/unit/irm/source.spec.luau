--!strict
-- IRM is reached with the context's Grafana service-account token, so the
-- parsers must read what a real IRM 0.128 stack answers (scrubbed captures),
-- send that token only to the OnCall host IRM itself names (and only over
-- https), and turn a 403 into the permission the account is missing, since
-- "permission denied" alone leaves the user guessing which role to grant.
local Irm = require("../../../plugin/lib/source/irm")
local Target = require("../../../plugin/lib/irm/target")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local V, DOCS = S.V, S.DOCS

describe("discovery", function()
	it("reads the OnCall API URL and the IRM version from the plugin settings", function()
		local d, err = Irm.parseDiscovery(S.ok(V .. "settings.json"), S.env(), S.GRAFANA)
		expect(err).toBeNil()
		local disc = assert(d, "discovery")
		expect(disc.oncall_url).toBe(S.ONCALL)
		expect(disc.version).toBe("0.128.0")
	end)

	it("says IRM is not installed on a 404", function()
		local d, err = Irm.parseDiscovery(S.raw('{"message":"Plugin not found"}', 404), S.env(), S.GRAFANA)
		expect(d).toBeNil()
		expect(assert(err).kind).toBe("unsupported")
		expect(S.has(assert(err).message, "not installed")).toBe(true)
	end)

	it("refuses an OnCall URL over plain http when Grafana is https, so the token never travels in clear", function()
		local body = '{"enabled":true,"jsonData":{"onCallApiUrl":"http://oncall.example/oncall"}}'
		local d = assert(Irm.parseDiscovery(S.raw(body, 200), S.env(), S.GRAFANA))
		expect(d.oncall_url).toBeNil()
		expect(S.has(assert(d.oncall_problem, "problem"), "not https")).toBe(true)
		local lab = assert(Irm.parseDiscovery(S.raw(body, 200), S.env(), "http://localhost:3000"))
		expect(lab.oncall_url).toBe("http://oncall.example/oncall")
	end)

	it("sends OnCall requests with the Grafana credential, X-Grafana-URL and no Grafana org header", function()
		local env = S.env()
		local grafana = assert(Target.grafana(env.config, "cloud"))
		local route = Irm.oncallRoute(grafana, S.ONCALL)
		expect(route.endpoint.url).toBe(S.ONCALL)
		expect(route.endpoint.headers["X-Grafana-URL"]).toBe(S.GRAFANA)
		expect(route.endpoint.auth).toBe(grafana.endpoint.auth)
		-- Same context and endpoint name: the transport's credential cache is shared.
		expect(route.endpoint_name).toBe("grafana")
		expect(route.endpoint.org_id).toBeNil()
		expect(grafana.endpoint.headers["X-Grafana-URL"]).toBeNil()
	end)
end)

describe("OnCall", function()
	it("reads firing alert groups with their integration, alert count and last alert", function()
		local groups, count = Irm.parseGroups(S.ok(V .. "oncall_alert_groups_new.json"), S.env())
		local list = assert(groups, "groups")
		expect(count).toBe(6)
		expect(#list).toBe(6)
		local g = list[1]
		-- OnCall's filter says `new`, its answers say `firing`.
		expect(g.state).toBe("firing")
		expect(g.integration_id ~= nil).toBe(true)
		expect(g.alerts_count > 0).toBe(true)
		expect(g.created_ms ~= nil).toBe(true)
		expect(#assert(g.last).alerts > 0).toBe(true)
	end)

	it("takes the total from `count` even when the page holds one group", function()
		local _, count = Irm.parseGroups(S.ok(V .. "oncall_alert_groups_acknowledged_count.json"), S.env())
		expect(count).toBe(6)
		local _, silenced = Irm.parseGroups(S.ok(V .. "oncall_alert_groups_silenced_count.json"), S.env())
		expect(silenced).toBe(0)
	end)

	it("names who is on call now from the users list", function()
		local env = S.env()
		local schedules = assert(Irm.parseSchedules(S.ok(V .. "oncall_schedules.json"), env))
		local users = assert(Irm.parseUsers(S.ok(V .. "oncall_users.json"), env))
		local staffed = 0
		for _, s in schedules do
			for _, id in s.on_call_now do
				expect(users[id] ~= nil).toBe(true)
				staffed += 1
			end
		end
		expect(staffed > 0).toBe(true)
	end)

	it("reads next shift users and times", function()
		local oc = assert(Irm.parseOnCall(S.ok(V .. "oncall_next_oncall.json"), S.env()))
		expect(#oc.users > 0).toBe(true)
		expect(oc.shifts[1].start_ms ~= nil).toBe(true)
		expect((oc.shifts[1].end_ms :: number) > (oc.shifts[1].start_ms :: number)).toBe(true)
	end)

	it("names the missing permission when an alert-group action is refused", function()
		local qe = assert(Irm.failure(S.ok(V .. "oncall_forbidden.json", 403), S.env(), "alert_group_write"))
		expect(qe.kind).toBe("auth")
		expect(S.has(qe.message, "You do not have permission")).toBe(true)
		expect(S.has(qe.message, "grafana-irm-app.alert-groups:write")).toBe(true)
		expect(S.has(qe.message, "OnCaller")).toBe(true)
	end)

	it("sends a silence with its duration in seconds and refuses one without", function()
		local r = Irm.groupActionRequest("I1", "silence", 7200, S.env().encode)
		expect(r.method).toBe("POST")
		expect(r.path).toBe("api/v1/alert_groups/I1/silence")
		expect(S.env().decode(assert(r.body, "body")).delay).toBe(7200)
		expect(function()
			Irm.groupActionRequest("I1", "silence", nil, S.env().encode)
		end).toThrow("duration")
		local ack = Irm.groupActionRequest("I1", "acknowledge", nil, S.env().encode)
		expect(ack.body).toBeNil()
	end)
end)

describe("Incident API", function()
	it("reads open incidents with severity labels and statuses", function()
		local list, more = Irm.parseIncidents(S.ok(V .. "incident_previews_open.json"), S.env())
		local xs = assert(list, "incidents")
		expect(#xs > 0).toBe(true)
		expect(more).toBe(false)
		for _, x in xs do
			expect(x.status ~= "resolved").toBe(true)
			expect(x.severity ~= "").toBe(true)
		end
	end)

	it("orders statuses for the picker and maps custom ones to their category", function()
		local list = assert(Irm.parseStatuses(S.ok(V .. "incident_statuses.json"), S.env()))
		expect(list[1].slug).toBe("active")
		expect(list[#list].slug).toBe("resolved")
		expect(list[#list].category).toBe("resolved")
		for _, st in list do
			if st.slug ~= "resolved" then
				expect(st.category).toBe("active")
			end
		end
	end)

	it("treats a missing GetOrgSeverities (IRM 0.128 answers 404) as unknown, not empty", function()
		expect(Irm.parseSeverities(S.ok(V .. "incident_severities_404.txt", 404), S.env())).toBeNil()
	end)

	it("reads an incident, its roles and timeline", function()
		local x = assert(Irm.parseIncident(S.ok(V .. "incident_get.json"), S.env()))
		expect(x.status).toBe("active")
		expect(x.severity).toBe("Critical")
		expect(#x.roles > 0).toBe(true)
		local items = assert(Irm.parseActivity(S.ok(V .. "incident_activity.json"), S.env()))
		expect(#items > 0).toBe(true)
		expect(items[1].time_ms ~= nil).toBe(true)
	end)

	it("keeps the server's problem detail and hint", function()
		local qe = assert(Irm.failure(S.ok(V .. "incident_not_found.json", 404), S.env(), "incident_write"))
		expect(S.has(qe.message, "Incident not found")).toBe(true)
		expect(S.has(qe.message, "Check the incident ID")).toBe(true)
	end)

	it("treats a 200 with a non-empty error as a failure", function()
		local qe = Irm.failure(S.raw('{"error":"severity not found"}', 200), S.env(), "incident_write")
		expect(assert(qe).message).toBe("severity not found")
		expect(Irm.failure(S.ok(DOCS .. "incident_update_status.json"), S.env(), "incident_write")).toBeNil()
	end)

	it("reads the incident a documented write returns", function()
		local x = assert(Irm.parseIncident(S.ok(DOCS .. "incident_create.json"), S.env(), "incident_write"))
		expect(x.id ~= "").toBe(true)
		expect(Irm.parseNoteAdded(S.ok(DOCS .. "activity_add.json"), S.env()) ~= nil).toBe(true)
	end)

	it("says the Editor role is needed when an incident write is refused", function()
		local qe = assert(Irm.failure(S.raw('{"title":"Forbidden","status":403}', 403), S.env(), "incident_write"))
		expect(S.has(qe.message, "Editor basic role")).toBe(true)
	end)
end)

return nil
