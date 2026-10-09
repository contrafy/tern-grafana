--!strict
-- Routing decides which server receives a query and its credentials. A direct
-- endpoint is the user's explicit choice and must win over Grafana; without
-- one, Grafana is used only through the datasource the user named, so a query
-- is never sent to an arbitrary datasource. Anything unroutable must come back
-- as an error that says what to configure, never as a silent nil.
local Route = require("../../../plugin/lib/config/route")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function config(text: string): any
	local cfg, problems = Validate.parseFile(text, json.decode)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end

local FULL = config([[{"contexts": {"lab": {
	"grafana": {"url": "http://g", "datasources": {"prometheus": "prom", "loki": "lk", "tempo": "tp", "alertmanager": "am"}},
	"prometheus": {"url": "http://p"},
	"alertmanager": {"url": "http://a"},
	"loki": {"url": "http://l"},
	"tempo": {"url": "http://t"}}}}]])

local GRAFANA_ONLY = config(
	[[{"contexts": {"lab": {
	"grafana": {"url": "http://g", "datasources": {"prometheus": "prom", "loki": "lk", "tempo": "tp", "alertmanager": "am"}}}}}]]
)

local GRAFANA_BARE = config('{"contexts": {"lab": {"grafana": {"url": "http://g"}}}}')

local DIRECT_ONLY = config([[{"contexts": {"lab": {
	"prometheus": {"url": "http://p"}, "alertmanager": {"url": "http://a"},
	"loki": {"url": "http://l"}, "tempo": {"url": "http://t"}}}}]])

local function summary(cfg: any, signal: any, context: string?): any
	local r, err = Route.route(cfg, context or "lab", signal)
	if not r then
		return err
	end
	return { via = r.via, endpoint = r.endpoint_name, uid = r.datasource_uid, url = r.endpoint.url }
end

describe("direct endpoints win", function()
	for _, case in
		{
			{ "metrics", "prometheus", "http://p" },
			{ "logs", "loki", "http://l" },
			{ "traces", "tempo", "http://t" },
			{ "alerts", "alertmanager", "http://a" },
		}
	do
		local signal, endpoint, url = case[1], case[2], case[3]
		it(signal .. " goes to " .. endpoint .. " even when grafana could serve it", function()
			expect(summary(FULL, signal)).toEqual({ via = "direct", endpoint = endpoint, url = url })
		end)
	end
end)

describe("grafana fallback", function()
	for _, case in { { "metrics", "prom" }, { "logs", "lk" }, { "traces", "tp" }, { "alerts", "am" } } do
		local signal, uid = case[1], case[2]
		it(signal .. " uses the configured datasource uid", function()
			expect(summary(GRAFANA_ONLY, signal)).toEqual({
				via = "datasource",
				endpoint = "grafana",
				uid = uid,
				url = "http://g",
			})
		end)
	end

	it("alerts without an alertmanager datasource use Grafana-managed alerting", function()
		expect(summary(GRAFANA_BARE, "alerts")).toEqual({ via = "grafana", endpoint = "grafana", url = "http://g" })
	end)

	it("metrics without a datasource uid are unroutable rather than guessed", function()
		expect(summary(GRAFANA_BARE, "metrics")).toEqual({
			kind = "unroutable",
			message = 'context "lab" has no prometheus endpoint and grafana.datasources.prometheus is not set',
		})
		expect(summary(GRAFANA_BARE, "logs")).toEqual({
			kind = "unroutable",
			message = 'context "lab" has no loki endpoint and grafana.datasources.loki is not set',
		})
		expect(summary(GRAFANA_BARE, "traces")).toEqual({
			kind = "unroutable",
			message = 'context "lab" has no tempo endpoint and grafana.datasources.tempo is not set',
		})
	end)
end)

describe("grafana-only signals", function()
	for _, signal in { "dashboards", "annotations" } do
		it(signal .. " always go to grafana itself", function()
			expect(summary(FULL, signal)).toEqual({ via = "grafana", endpoint = "grafana", url = "http://g" })
		end)

		it(signal .. " are unroutable without grafana", function()
			expect(summary(DIRECT_ONLY, signal)).toEqual({
				kind = "unroutable",
				message = 'context "lab" has no grafana endpoint, which ' .. signal .. " require",
			})
		end)
	end
end)

describe("signals without any backend", function()
	it("says which endpoint is missing", function()
		local cfg = config('{"contexts": {"lab": {"loki": {"url": "http://l"}}}}')
		expect(summary(cfg, "metrics")).toEqual({
			kind = "unroutable",
			message = 'context "lab" has no prometheus or grafana endpoint',
		})
		expect(summary(cfg, "alerts")).toEqual({
			kind = "unroutable",
			message = 'context "lab" has no alertmanager or grafana endpoint',
		})
	end)
end)

describe("context selection", function()
	it("uses default_context when no context is given", function()
		local cfg = config([[{"default_context": "b", "contexts": {
			"a": {"prometheus": {"url": "http://a"}}, "b": {"prometheus": {"url": "http://b"}}}}]])
		local r = Route.route(cfg, nil, "metrics")
		expect(r and r.context).toBe("b")
		expect(r and r.endpoint.url).toBe("http://b")
	end)

	it("refuses to guess between several contexts without a default", function()
		local cfg = config([[{"contexts": {
			"a": {"prometheus": {"url": "http://a"}}, "b": {"prometheus": {"url": "http://b"}}}}]])
		local r, err = Route.route(cfg, nil, "metrics")
		expect(r).toBeNil()
		expect(err).toEqual({
			kind = "no_context",
			message = "no context given and default_context is not set (contexts: a, b)",
		})
	end)

	it("names the known contexts when the requested one is missing", function()
		expect(summary(FULL, "metrics", "prod")).toEqual({
			kind = "unknown_context",
			message = 'no context named "prod" (contexts: lab)',
		})
	end)
end)

return nil
