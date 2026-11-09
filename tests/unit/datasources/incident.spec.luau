--!strict
-- Grafana Incident's frontend, ported: the query string must reach the
-- backend exactly as Grafana sends it, or the backend answers "Invalid query
-- string" (an empty `or()` from a naive formatter does). "All" with the
-- `$__all` custom value goes in raw (the backend accepts it); a specific
-- selection becomes `label:'...'` / `severity:'...'` filters, keyed the way
-- the server's Grafana keys them: by variable name only on Grafana 12+
-- (scenes hands formatters no query), by query type first on Grafana 11.
-- Query variables list what the plugin's metricFindQuery lists. Fixtures are
-- synthetic (IRM is a Grafana Cloud app) in the recorded shapes.
local Incident = require("../../../plugin/lib/datasources/incident")
local Interpolate = require("../../../plugin/lib/dashboard/interpolate")
local Support = require("../../lib/support")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = Support.env()
local mod: any = Incident

local QUERY = "or($labels) or($severity) or(status:active status:resolved)"

local function labels(values: { string }, extra: { [string]: any }?): Interpolate.Var
	local v: any = {
		values = values,
		multi = true,
		include_all = true,
		name = "labels",
		query = { queryType = "labels" },
	}
	for k, x in (extra or {}) :: { [string]: any } do
		v[k] = x
	end
	return v
end

-- The user's dashboards name the severities variable `severity`.
local function severity(values: { string }, extra: { [string]: any }?): Interpolate.Var
	local v: any = labels(values, extra)
	v.name = "severity"
	v.query = { queryType = "severities" }
	return v
end

local ALL = { is_all = true, all_value = "$__all" }

local function ctx(major: number?, scope: Interpolate.Scope): any
	return {
		scope = scope,
		from_ms = 0,
		to_ms = 1,
		interval_ms = 1000,
		max_points = 100,
		now_ms = 1,
		datasources = {},
		ds = { uid = "inc", type = Incident.types[1], name = "Incident", is_default = false },
		grafana_major = major,
	}
end

local function queryString(major: number?, scope: Interpolate.Scope, target: any?): any
	local q = mod.shape(target or { refId = "A", queryType = "incidents", queryString = QUERY }, ctx(major, scope), env)
	return q.queryString
end

describe("Grafana Incident query strings", function()
	for _, major in { 11, 12, 13 } do
		it("sends All with the $__all custom value raw on Grafana " .. major, function()
			local scope = { labels = labels({ "a", "b" }, ALL), severity = severity({ "Critical" }, ALL) }
			expect(queryString(major, scope)).toBe("or($__all) or($__all) or(status:active status:resolved)")
		end)

		it("writes label filters for a labels variable on Grafana " .. major, function()
			local scope = { labels = labels({ "team:payments", "security" }), severity = severity({}, ALL) }
			expect(queryString(major, scope)).toBe(
				"or(label:'team:payments' label:'security') or($__all) or(status:active status:resolved)"
			)
		end)
	end

	it("keys on the variable name on Grafana 12+, as scenes gives formatters no query", function()
		-- Grafana itself sends this and shows the backend's "Invalid query string".
		local scope = { labels = labels({}, ALL), severity = severity({ "Critical", "Minor" }) }
		for _, major in { 12, 13 } do
			expect(queryString(major, scope)).toBe(
				"or($__all) or(unsupported query name) or(status:active status:resolved)"
			)
		end
		local named: any = severity({ "Critical" })
		named.name = "severities"
		expect(queryString(13, { labels = labels({}, ALL), severity = named })).toBe(
			"or($__all) or(severity:'Critical') or(status:active status:resolved)"
		)
	end)

	it("keys on the variable's query type first on Grafana 11 (legacy dashboards)", function()
		local scope = { labels = labels({}, ALL), severity = severity({ "Critical", "Minor" }) }
		expect(queryString(11, scope)).toBe(
			"or($__all) or(severity:'Critical' severity:'Minor') or(status:active status:resolved)"
		)
		local statuses: any = labels({ "active" })
		statuses.name, statuses.query = "state", { queryType = "statuses" }
		expect(queryString(11, { s = statuses }, { queryString = "$s" })).toBe("status:active")
		expect(queryString(13, { s = statuses }, { queryString = "$s" })).toBe("unsupported query name")
	end)

	it("writes role and status filters by name, and drops empty and $__all values", function()
		local roles: any = labels({ "commander", "", "$__all" })
		roles.name, roles.query = "roles", "roles"
		local statuses: any = labels({ "active", "resolved" })
		statuses.name, statuses.query = "statuses", nil
		expect(queryString(13, { roles = roles, statuses = statuses }, { queryString = "$roles $statuses" })).toBe(
			"role:commander status:active status:resolved"
		)
	end)

	it("sends originalQueryString when the query string interpolates to nothing", function()
		local scope = { labels = labels({ "" }) }
		expect(queryString(13, scope, { queryString = "$labels", originalQueryString = "status:active" })).toBe(
			"status:active"
		)
		expect(queryString(13, scope, { queryString = "$labels" })).toBeNil()
		expect(queryString(13, scope, { queryType = "incidents", originalQueryString = "or(status:active)" })).toBe(
			"or(status:active)"
		)
	end)

	it("keeps the other target fields as written", function()
		local q = mod.shape(
			{ refId = "A", queryType = "incidents", queryString = "$labels", hide = json.null, legend = "$labels" },
			ctx(13, { labels = labels({ "x" }) }),
			env
		)
		expect(q).toEqual({ refId = "A", queryType = "incidents", queryString = "label:'x'", legend = "$labels" })
	end)
end)

local function runVariable(queryType: string?, fixture: string?, status: number?): (any, { any })
	local job = mod.variable(if queryType then { queryType = queryType } else "", ctx(13, {}), env)
	local requests: { any } = {}
	local j, reqs, outcome = mod.step(job, {}, env)
	if outcome then
		return outcome, requests
	end
	requests = reqs
	local _, _, done = mod.step(j, { vars = Support.response(fixture :: string, status) }, env)
	return done, requests
end

describe("Grafana Incident query variables", function()
	it("asks /api/ds/query for the variable's query type, without a range", function()
		local _, requests = runVariable("labels", "incident/var_labels.json")
		expect(#requests).toBe(1)
		expect(requests[1].request.method).toBe("POST")
		expect(requests[1].request.path).toBe("/api/ds/query")
		expect(json.decode(requests[1].request.body)).toEqual({
			queries = {
				{
					datasource = { type = "grafana-incident-datasource", uid = "inc" },
					queryType = "labels",
					refId = "metricFindQuery-labels",
				},
			},
		})
	end)

	it("lists label keys by their label (no value field) and severities by value", function()
		local outcome = runVariable("labels", "incident/var_labels.json")
		expect(outcome.options).toEqual({
			{ text = "team:payments", value = "team:payments" },
			{ text = "region:eu-west", value = "region:eu-west" },
			{ text = "security", value = "security" },
			{ text = "postmortem", value = "postmortem" },
		})
		local sev = runVariable("severities", "incident/var_severities.json")
		expect(sev.options).toEqual({
			{ text = "Pending", value = "Pending" },
			{ text = "Critical", value = "Critical" },
			{ text = "Minor", value = "Minor" },
		})
		local st = runVariable("statuses", "incident/var_statuses.json")
		expect(st.options[2]).toEqual({ text = "resolved", value = "resolved" })
	end)

	it("shows the backend's error and has no options for other query types", function()
		local roles = runVariable("roles", "incident/var_roles_error.json", 400)
		expect(roles.error).toBe("Unknown or invalid Query Type")
		local other, requests = runVariable("incidents")
		expect(other.options).toEqual({})
		expect(#requests).toBe(0)
		local none = runVariable(nil)
		expect(none.options).toEqual({})
	end)
end)

return nil
