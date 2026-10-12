--!strict
-- The alert list panel (public/app/plugins/panel/alertlist at v12.4.0:
-- UnifiedAlertList.tsx filterRules/sortRules, UngroupedView.tsx,
-- GroupedView.tsx, AlertInstances.tsx, util.ts filterAlerts; rules sources
-- from alerting/unified/utils/datasource.ts getRulesDataSources) over the
-- Grafana-managed rules both Grafanas answer for panel 29 of tern-all-panels,
-- Prometheus 3's own rules read through Grafana, and the data source catalog
-- of their frontend settings.
local t = require("../../lib/test")
local S = require("./support")
local Alertlist = require("../../../plugin/lib/panels/alertlist")
local Fixtures = require("../../lib/fixtures")
local Registry = require("../../../plugin/lib/panels/registry")
local Scheme = require("../../../plugin/lib/links/scheme")
local Queries = require("../../../plugin/lib/dashboard/queries")
local describe, it, expect = t.describe, t.it, t.expect

-- 6m 12s after the firing rules' activeAt (2026-10-12T22:13:30Z).
local NOW = 1791843582000

local function env(): any
	local e = table.clone(S.env :: any)
	e.now_ms = NOW
	return e
end

local function panel(version: string): any
	for _, p in S.decode("grafana/" .. version .. "/dashboard_tern_all_panels.json").dashboard.panels do
		if p.id == 29 then
			return p
		end
	end
	error("no alertlist panel")
end

local function withOptions(version: string, patch: { [string]: any }): any
	local p = S.clone(panel(version))
	for k, v in patch do
		p.options[k] = v
	end
	return p
end

local function answer(version: string): any
	local body = Fixtures.read("grafana/" .. version .. "/alertlist_rules.json")
	return Alertlist.parse(nil, "rules:", { status = 200, headers = {}, body = body, timed_out = false }, env())
end

local function dsAnswer(version: string, uid: string): any
	local body = Fixtures.read("grafana/" .. version .. "/alerting_ds_prom_rules.json")
	return Alertlist.parse(nil, "ds:" .. uid, { status = 200, headers = {}, body = body, timed_out = false }, env())
end

-- The data sources of the frontend settings, as the dashboard block reads them.
local function catalog(version: string): { any }
	local body = Fixtures.read("grafana/" .. version .. "/frontend_settings_all_panels.json")
	return Queries.frontendDatasources({ status = 200, headers = {}, body = body, timed_out = false }, S.env) :: any
end

local function view(version: string, p: any, uid: string?): any
	local extra = { ["rules:0:" .. (uid or "tern-all-panels")] = answer(version) }
	return Registry.view(p, {}, env(), { key = "p", extra = extra })
end

local function ruleNames(node: any): { string }
	local out: { string } = {}
	for _, n in
		S.findAll(node, function(x: any): boolean
			return x.k == "text" and x.p.key == "n"
		end)
	do
		table.insert(out, S.text(n))
	end
	return out
end

for _, version in S.VERSIONS do
	describe("alertlist " .. version, function()
		it("is native for Grafana-managed rules and needs no datasource query", function()
			local p = panel(version)
			expect((Registry.supports(p, S.env))).toBe(true)
			expect(Registry.queries(p, S.env)).toBe(false)
		end)

		it("asks Grafana's rules API with the panel's instance limit, tagged with the dashboard", function()
			local reqs = Registry.requests(panel(version), {
				time = { from_ms = 0, to_ms = 1 },
				dashboard_uid = "tern-all-panels",
			}, S.env)
			expect(#reqs).toBe(1)
			expect(reqs[1].signal).toBe("alerts")
			expect(reqs[1].tag).toBe("rules:0:tern-all-panels")
			expect(reqs[1].request.path).toBe("/api/prometheus/grafana/api/v1/rules")
			expect(reqs[1].request.query).toEqual({ { "limit_alerts", "15" } })
		end)

		it("lists alerting rules by name with state, active time and instance count", function()
			local node = view(version, panel(version))
			expect(ruleNames(node)).toEqual({
				"TernGrafanaAlwaysFiring",
				"TernGrafanaNormal",
				"TernGrafanaPending",
				"TernGrafanaTargetDown",
			})
			local text = S.text(node)
			expect(text).toContain("Firing for 6m 12s")
			expect(text).toContain("Pending for 6m 12s")
			expect(text).toContain("Firing for 5m 42s")
			-- A normal rule shows no active time.
			expect(text).toContain("TernGrafanaNormalView alert ruleNormal1 instance")
		end)

		it("drops rules whose state the state filter excludes", function()
			local p = withOptions(version, {
				stateFilter = { firing = true, pending = false, normal = false, recovering = true, error = true },
			})
			expect(ruleNames(view(version, p))).toEqual({ "TernGrafanaAlwaysFiring", "TernGrafanaTargetDown" })
		end)

		it("filters by alert name and instance labels", function()
			expect(ruleNames(view(version, withOptions(version, { alertName = "target" })))).toEqual({
				"TernGrafanaTargetDown",
			})
			local p = withOptions(version, { alertInstanceLabelFilter = '{severity="warning"}' })
			expect(ruleNames(view(version, p))).toEqual({ "TernGrafanaTargetDown" })
			local none = view(version, withOptions(version, { alertInstanceLabelFilter = 'team="nobody"' }))
			expect(S.text(none)).toBe("No alerts matching filters")
		end)

		it("keeps only rules linked to this dashboard when asked", function()
			local p = withOptions(version, { dashboardAlerts = true })
			expect(ruleNames(view(version, p, "tern-panels"))).toEqual({ "TernGrafanaAlwaysFiring" })
			expect(#ruleNames(view(version, p, "tern-all-panels"))).toBe(0)
		end)

		it("sorts by importance and caps the list at maxItems", function()
			local p = withOptions(version, { sortOrder = 3 })
			expect(ruleNames(view(version, p))).toEqual({
				"TernGrafanaAlwaysFiring",
				"TernGrafanaTargetDown",
				"TernGrafanaPending",
				"TernGrafanaNormal",
			})
			local desc = withOptions(version, { sortOrder = 2, maxItems = 2 })
			expect(ruleNames(view(version, desc))).toEqual({ "TernGrafanaTargetDown", "TernGrafanaPending" })
		end)

		it("shows the matching rule count in stat mode", function()
			local node = view(version, withOptions(version, { viewMode = "stat" }))
			expect(S.text(node)).toBe("4")
		end)

		it("groups instances by label in custom group mode", function()
			local p = withOptions(version, { groupMode = "custom", groupBy = { "severity" } })
			local text = S.text(view(version, p))
			expect(text).toContain("severity=critical")
			expect(text).toContain("severity=warning")
			expect(text).toContain("severity=info")
			expect(text).toContain("Alerting")
		end)

		it("shows instances with their labels when showInstances is on", function()
			local text = S.text(view(version, withOptions(version, { showInstances = true })))
			expect(text).toContain("instance=node-exporter:9999")
		end)

		it("reads Grafana-managed rules and every alert-managing Prometheus or Loki data source by default", function()
			local p = withOptions(version, { datasource = S.json("null") })
			local ctx = { time = { from_ms = 0, to_ms = 1 }, dashboard_uid = "tern-all-panels" }
			-- Before the frontend settings arrive nothing is asked.
			expect(#Registry.requests(p, ctx, S.env)).toBe(0)
			local withCatalog = table.clone(ctx) :: any
			withCatalog.datasources = catalog(version)
			local paths: { string } = {}
			for _, r in Registry.requests(p, withCatalog, S.env) do
				expect(r.signal).toBe("alerts")
				table.insert(paths, r.tag .. " " .. r.request.path)
			end
			expect(paths).toEqual({
				"rules:0:tern-all-panels /api/prometheus/grafana/api/v1/rules",
				"ds:loki /api/prometheus/loki/api/v1/rules",
				"ds:prom2 /api/prometheus/prom2/api/v1/rules",
				"ds:prom3 /api/prometheus/prom3/api/v1/rules",
			})
		end)

		it("merges data source rules with Grafana-managed ones before sorting and filtering", function()
			local p = withOptions(version, { datasource = S.json("null") })
			local extra = {
				["rules:0:tern-all-panels"] = answer(version),
				["ds:prom3"] = dsAnswer(version, "prom3"),
				["ds:loki"] = { error = "404 from rule state endpoint" },
			}
			local node = Registry.view(p, {}, env(), { key = "p", extra = extra })
			-- TernInactive has no instance and showInactiveAlerts is off; the
			-- failed Loki source is left out as Grafana leaves it out.
			expect(ruleNames(node)).toEqual({
				"TernAlwaysFiring",
				"TernGrafanaAlwaysFiring",
				"TernGrafanaNormal",
				"TernGrafanaPending",
				"TernGrafanaTargetDown",
				"TernPending",
				"TernTargetDown",
			})
			local folder = withOptions(version, { datasource = S.json("null"), folder = { uid = "nope" } })
			expect(S.text((Registry.view(folder, {}, env(), { key = "p", extra = extra })))).toBe(
				"No alerts matching filters"
			)
		end)

		it("reads only the named data source's rules", function()
			local p = withOptions(version, { datasource = "Prometheus 3" })
			local ctx = { time = { from_ms = 0, to_ms = 1 }, datasources = catalog(version) }
			local reqs = Registry.requests(p, ctx :: any, S.env)
			expect(#reqs).toBe(1)
			expect(reqs[1].tag).toBe("ds:prom3")
			expect(reqs[1].request.query).toBeNil()
			local node = Registry.view(
				p,
				{},
				env(),
				{ key = "p", extra = { ["ds:prom3"] = dsAnswer(version, "prom3") } }
			)
			expect(ruleNames(node)).toEqual({ "TernAlwaysFiring", "TernPending", "TernTargetDown" })
			expect(S.text(node)).toContain("1 instance")
		end)
	end)
end

describe("alertlist", function()
	it("skips data sources that do not manage alerts and caps how many are read", function()
		local list = {}
		for i = 1, Alertlist.MAX_EXTERNAL + 2 do
			table.insert(list, { uid = "p" .. i, type = "prometheus", name = string.format("P%02d", i) })
		end
		table.insert(list, { uid = "off", type = "prometheus", name = "A off", manage_alerts = false })
		table.insert(list, { uid = "tempo", type = "tempo", name = "Tempo" })
		local p = { type = "alertlist", options = {} }
		local reqs = Registry.requests(p, { time = { from_ms = 0, to_ms = 1 }, datasources = list } :: any, S.env)
		expect(#reqs).toBe(1 + Alertlist.MAX_EXTERNAL)
		expect(reqs[1].tag).toBe("rules:2:")
		expect(reqs[2].tag).toBe("ds:p1")
		local node = Registry.view(p, {}, S.env, { key = "p", extra = { ["rules:2:"] = { rules = {} } } })
		expect(S.text(node)).toContain("2 more data sources manage alert rules; Tern reads at most 8")
	end)

	it("shows an error only when no rules source answered", function()
		local p = { type = "alertlist", options = {} }
		local extra = { ["rules:0:"] = { error = "forbidden" }, ["ds:prom3"] = { error = "down" } }
		expect(S.text((Registry.view(p, {}, S.env, { key = "p", extra = extra })))).toBe("forbidden")
	end)

	it("reads manageAlerts from the frontend settings", function()
		for _, version in S.VERSIONS do
			for _, d in catalog(version) do
				expect(d.manage_alerts).toBe(true)
			end
		end
	end)

	it("links a rule to the native alerts block's rules view", function()
		local link = Alertlist.ruleLink({ name = 'A "b"' } :: any) :: string
		local l = Scheme.decode(link) :: any
		expect(l.action).toBe("alerts")
		expect(l.params).toEqual({ view = "rules", filter = 'alertname="A \\"b\\""' })
	end)

	it("prints durations the way date-fns intervalToDuration does", function()
		expect(Alertlist.duration(0, 372000)).toBe("6m 12s")
		-- 2024-01-31 to 2024-03-01: one calendar month and a day.
		expect(Alertlist.duration(1706659200000, 1709251200000)).toBe("1M 1d")
		expect(Alertlist.duration(5, 5)).toBe("")
	end)

	it("reads a failed rules request as an error line", function()
		local a =
			Alertlist.parse(nil, "rules:", { status = 0, headers = {}, body = "", timed_out = false }, S.env) :: any
		expect(type(a.error)).toBe("string")
	end)
end)

return nil
