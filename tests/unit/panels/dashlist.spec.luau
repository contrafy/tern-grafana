--!strict
-- The dashboard list panel (public/app/plugins/panel/dashlist at v12.4.0:
-- DashList.tsx fetchDashboards and grouping, DashListItem.tsx;
-- features/search/service/sql.ts) over the /api/search answers both
-- Grafanas give for panel 31 of tern-all-panels.
local t = require("../../lib/test")
local S = require("./support")
local Dashlist = require("../../../plugin/lib/panels/dashlist")
local Fixtures = require("../../lib/fixtures")
local Registry = require("../../../plugin/lib/panels/registry")
local Scheme = require("../../../plugin/lib/links/scheme")
local describe, it, expect = t.describe, t.it, t.expect

local CTX = { time = { from_ms = 1791840751000, to_ms = 1791844351000 }, dashboard_uid = "tern-all-panels" }

local function panel(version: string): any
	for _, p in S.decode("grafana/" .. version .. "/dashboard_tern_all_panels.json").dashboard.panels do
		if p.id == 31 then
			return p
		end
	end
	error("no dashlist panel")
end

local function answer(version: string, name: string): any
	local body = Fixtures.read("grafana/" .. version .. "/" .. name .. ".json")
	return Dashlist.parse(nil, "", { status = 200, headers = {}, body = body, timed_out = false }, S.env)
end

local function extra(version: string): { [string]: any }
	return {
		starred = answer(version, "search_starred"),
		recent = answer(version, "search_recent"),
		search = answer(version, "search_tag"),
	}
end

local function titles(node: any): { string }
	local out: { string } = {}
	for _, n in
		S.findAll(node, function(x: any): boolean
			return x.k == "text" and x.p.key == "t"
		end)
	do
		table.insert(out, S.text(n))
	end
	return out
end

for _, version in S.VERSIONS do
	describe("dashlist " .. version, function()
		it("is native and needs no datasource query", function()
			expect((Registry.supports(panel(version), S.env))).toBe(true)
			expect(Registry.queries(panel(version), S.env)).toBe(false)
		end)

		it("searches starred, this dashboard as recently viewed, and the panel's search", function()
			local reqs = Registry.requests(panel(version), CTX, S.env)
			local byTag: { [string]: any } = {}
			for _, r in reqs do
				expect(r.signal).toBe("dashboards")
				expect(r.request.path).toBe("/api/search")
				byTag[r.tag] = r.request.query
			end
			expect(byTag.starred).toEqual({ { "limit", "10" }, { "starred", "true" } })
			expect(byTag.recent).toEqual({
				{ "limit", "10" },
				{ "type", "dash-db" },
				{ "dashboardUIDs", "tern-all-panels" },
			})
			expect(byTag.search).toEqual({ { "limit", "10" }, { "tag", "fixtures" }, { "type", "dash-db" } })
		end)

		it("lists each group under its heading, starred and search by name", function()
			local node = Registry.view(panel(version), {}, S.env, { key = "p", extra = extra(version) })
			local text = S.text(node)
			expect(text).toContain("Starred dashboards")
			expect(text).toContain("Recently viewed dashboards")
			expect(text).toContain("Tern has no Grafana view history")
			expect(text).toContain("Search")
			-- The recent capture asked for two uids; the panel asks for its own.
			expect(titles(node)).toEqual({
				"Tern All Panels",
				"Tern All Panels",
				"Tern Panels",
				"Tern All Panels",
				"Tern Logs and Traces",
				"Tern Panels",
				"Tern Variables",
			})
			expect(text).toContain("Tern Fixtures")
			expect(text).toContain("★")
			expect(text).toContain("☆")
		end)

		it("opens a dashboard in the native dashboard block, keeping the time when asked", function()
			local p = S.clone(panel(version))
			p.options.keepTime = true
			local node = Registry.view(p, {}, S.env, { key = "p", extra = extra(version), time = CTX.time })
			local first = S.find(node, function(x: any): boolean
				return x.k == "text" and x.p.key == "t"
			end)
			local l = Scheme.decode(first.p.spans[1].href) :: any
			expect(l.action).toBe("dashboard")
			expect(l.params).toEqual({ uid = "tern-all-panels", from = "1791840751000", to = "1791844351000" })
		end)
	end)
end

describe("dashlist", function()
	it("searches the General folder for an empty folderUID and drops a '*' query", function()
		local p =
			{ type = "dashlist", options = { showStarred = false, showSearch = true, query = "*", folderUID = "" } }
		local reqs = Registry.requests(p, CTX, S.env)
		expect(#reqs).toBe(1)
		expect(reqs[1].request.query).toEqual({ { "limit", "10" }, { "type", "dash-db" }, { "folderUIDs", "general" } })
	end)

	it("says when no group is shown", function()
		local p = { type = "dashlist", options = { showStarred = false } }
		expect(S.text((Registry.view(p, {}, S.env, { key = "p" })))).toBe("No dashboard groups configured")
	end)

	it("is not native when the search uses dashboard variables", function()
		local p = { type = "dashlist", options = { showSearch = true, query = "$team" } }
		local ok, why = Registry.supports(p, S.env)
		expect(ok).toBe(false)
		expect(why).toContain("variables")
	end)

	it("caps each group at maxItems and shows folderless dashboards under Dashboards", function()
		local hits = {
			{ uid = "b", title = "B", starred = true },
			{ uid = "a", title = "a", starred = true },
			{ uid = "c", title = "C", starred = true },
		}
		local p = { type = "dashlist", options = { maxItems = 2 } }
		local node = Registry.view(p, {}, S.env, { key = "p", extra = { starred = { hits = hits } } })
		expect(titles(node)).toEqual({ "a", "B" })
		expect(S.text(node)).toContain("Dashboards")
	end)
end)

return nil
