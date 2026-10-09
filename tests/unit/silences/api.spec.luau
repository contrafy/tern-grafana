--!strict
-- The same Alertmanager v2 silence API lives at three roots (a direct
-- Alertmanager, Grafana's own Alertmanager, Grafana's proxy to an
-- Alertmanager datasource); a request sent to the wrong root silences
-- nothing or the wrong thing. Bodies must be what the real servers accepted
-- when the fixtures were captured, and lists from both servers and both
-- Grafana versions must read the same way.
local Api = require("../../../plugin/lib/silences/api")
local Fixtures = require("../../lib/fixtures")
local Range = require("../../../plugin/lib/time/range")
local Sources = require("../../../plugin/lib/alerts/sources")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577860000
local env: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null }

local CFG = (function(): any
	local cfg, problems = Validate.parseFile(
		[[{"default_context": "am", "contexts": {
		"am": {"alertmanager": {"url": "http://am:9093"}, "grafana": {"url": "http://g"}},
		"ext": {"grafana": {"url": "http://g", "datasources": {"alertmanager": "my am"}}},
		"graf": {"grafana": {"url": "http://g"}},
		"prom": {"prometheus": {"url": "http://p:9090"}}}}]],
		json.decode
	)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end)()

local function target(context: string): any
	return Api.target((assert(Sources.plan(CFG, context))))
end

local function ms(text: string): number
	return assert(Range.parse(text, false, { now_ms = NOW }))
end

describe("target", function()
	it("puts each server's silences at its own API root", function()
		local am, graf, ext = target("am"), target("graf"), target("ext")
		expect(Api.listRequest(am)).toEqual({ method = "GET", path = "/api/v2/silences" })
		expect(Api.listRequest(graf).path).toBe("/api/alertmanager/grafana/api/v2/silences")
		expect(Api.listRequest(ext).path).toBe("/api/alertmanager/my%20am/api/v2/silences")
		expect(Api.expireRequest(am, "892a1c9d-e05b-4e32-8dad-b5b3860bc8c3")).toEqual({
			method = "DELETE",
			path = "/api/v2/silence/892a1c9d-e05b-4e32-8dad-b5b3860bc8c3",
		})
		expect(Api.expireRequest(graf, "8f0c1a3e-04ac-4019-8be3-c80a6fba7640").path).toBe(
			"/api/alertmanager/grafana/api/v2/silence/8f0c1a3e-04ac-4019-8be3-c80a6fba7640"
		)
	end)

	it("says Prometheus has no silences", function()
		local tg, why = Api.target((assert(Sources.plan(CFG, "prom"))))
		expect(tg).toBeNil()
		expect(string.find(why :: string, "no silences", 1, true) ~= nil).toBe(true)
	end)
end)

describe("create", function()
	local cases = {
		{ context = "am", fixture = "alertmanager/0.34.1/silence_create.request.json", name = "TernAlwaysFiring" },
		{
			context = "graf",
			fixture = "grafana/12.4.12/alerting_am_silence_create.request.json",
			name = "TernGrafanaAlwaysFiring",
		},
		{
			context = "graf",
			fixture = "grafana/11.6.16/alerting_am_silence_create.request.json",
			name = "TernGrafanaAlwaysFiring",
		},
	}
	for _, c in cases do
		it(c.fixture .. ": sends the body the server accepted", function()
			local recorded = json.decode(Fixtures.read(c.fixture))
			local draft: any = {
				matchers = { { name = "alertname", op = "=", value = c.name } },
				duration_s = 3600,
				comment = "Fixture capture silence",
				created_by = "tern-grafana capture",
			}
			local request =
				Api.createRequest(target(c.context), Api.createBody(draft, ms(recorded.startsAt)), json.encode)
			expect(request.method).toBe("POST")
			expect((request.headers :: any)["Content-Type"]).toBe("application/json")
			local body = json.decode(request.body :: string)
			expect(body.matchers).toEqual(recorded.matchers)
			expect(body.createdBy).toBe(recorded.createdBy)
			expect(body.comment).toBe(recorded.comment)
			expect(ms(body.startsAt)).toBe(ms(recorded.startsAt))
			expect(ms(body.endsAt)).toBe(ms(recorded.endsAt))
		end)
	end

	it("reads the new silence's id from both servers", function()
		expect(Api.parseCreated(env, Fixtures.read("alertmanager/0.34.1/silence_create.json"))).toBe(
			"892a1c9d-e05b-4e32-8dad-b5b3860bc8c3"
		)
		expect(Api.parseCreated(env, Fixtures.read("grafana/12.4.12/alerting_am_silence_create.json"))).toBe(
			"8f0c1a3e-04ac-4019-8be3-c80a6fba7640"
		)
		expect(Api.parseCreated(env, Fixtures.read("grafana/11.6.16/alerting_am_silence_create.json"))).toBe(
			"055ee28b-5294-4101-957d-8d742de35e7c"
		)
		expect(Api.parseCreated(env, "")).toBeNil()
	end)
end)

describe("list", function()
	it("reads Alertmanager's silences, active first", function()
		local list = assert(Api.parseList(env, Fixtures.read("alertmanager/0.34.1/silences_active.json")))
		expect(list[1].id).toBe("892a1c9d-e05b-4e32-8dad-b5b3860bc8c3")
		expect(list[1].state).toBe("active")
		expect(list[1].matchers).toEqual({ { name = "alertname", op = "=", value = "TernAlwaysFiring" } })
		expect(list[1].created_by).toBe("tern-grafana capture")
		expect(list[1].ends_ms > list[1].starts_ms).toBe(true)
		for i = 2, #list do
			expect(list[i].state).toBe("expired")
		end
	end)

	it("shows an expired silence as expired after DELETE", function()
		local list = assert(Api.parseList(env, Fixtures.read("alertmanager/0.34.1/silences_after_expire.json")))
		for _, x in list do
			expect(x.state).toBe("expired")
		end
	end)

	for _, v in { "11.6.16", "12.4.12" } do
		it(v .. ": reads Grafana's silences the same way", function()
			local list =
				assert(Api.parseList(env, Fixtures.read("grafana/" .. v .. "/alerting_am_silences_active.json")))
			expect(list[1].state).toBe("active")
			expect(list[1].matchers[1].value).toBe("TernGrafanaAlwaysFiring")
			expect(#list).toBe(3)
		end)
	end

	it("reports a body that is not a list", function()
		local list, err = Api.parseList(env, Fixtures.read("alertmanager/0.34.1/silence_invalid_id.json"))
		expect(list).toBeNil()
		expect(err).toBe("expected a JSON array of silences")
	end)
end)

return nil
