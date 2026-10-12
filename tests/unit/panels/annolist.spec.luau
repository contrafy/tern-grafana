--!strict
-- The annotation list panel (public/app/plugins/panel/annolist at v12.4.0:
-- AnnoListPanel.tsx doSearch/onAnnoClick/_timeOffset, AnnotationListItem.tsx,
-- grafana-ui utils/tags.ts) over the /api/annotations answers both Grafanas
-- give for panel 30 of tern-all-panels.
local t = require("../../lib/test")
local S = require("./support")
local Annolist = require("../../../plugin/lib/panels/annolist")
local Fixtures = require("../../lib/fixtures")
local Registry = require("../../../plugin/lib/panels/registry")
local Scheme = require("../../../plugin/lib/links/scheme")
local describe, it, expect = t.describe, t.it, t.expect

local MIN = 60000
-- An annotation time (2026-10-12T21:53:34Z).
local T = 1791842014000

local function panel(version: string): any
	for _, p in S.decode("grafana/" .. version .. "/dashboard_tern_all_panels.json").dashboard.panels do
		if p.id == 30 then
			return p
		end
	end
	error("no annolist panel")
end

local function answer(version: string, name: string): any
	local body = Fixtures.read("grafana/" .. version .. "/" .. name .. ".json")
	return Annolist.parse(nil, "annotations:", { status = 200, headers = {}, body = body, timed_out = false }, S.env)
end

local function byId(list: { any }, id: number): any
	for _, a in list do
		if a.id == id then
			return a
		end
	end
	error("no annotation " .. id)
end

local CTX = { time = { from_ms = 1791840751000, to_ms = 1791844351000 }, dashboard_uid = "tern-all-panels" }

for _, version in S.VERSIONS do
	describe("annolist " .. version, function()
		it("is native and queries only Grafana's annotations API", function()
			local p = panel(version)
			expect((Registry.supports(p, S.env))).toBe(true)
			expect(Registry.queries(p, S.env)).toBe(false)
		end)

		it("asks for the panel's tags and limit, annotations only, as the capture did", function()
			local reqs = Registry.requests(panel(version), CTX, S.env)
			expect(#reqs).toBe(1)
			expect(reqs[1].signal).toBe("annotations")
			expect(reqs[1].tag).toBe("annotations:tern-all-panels")
			expect(reqs[1].request.path).toBe("/api/annotations")
			-- MANIFEST: /api/annotations?tags=tern-seed&limit=10&type=annotation
			expect(reqs[1].request.query).toEqual({
				{ "tags", "tern-seed" },
				{ "limit", "10" },
				{ "type", "annotation" },
			})
		end)

		it("adds this dashboard and the panel's time range when asked", function()
			local p = S.clone(panel(version))
			p.options.onlyFromThisDashboard = true
			p.options.onlyInTimeRange = true
			local q = Registry.requests(p, CTX, S.env)[1].request.query
			expect(q).toEqual({
				{ "tags", "tern-seed" },
				{ "limit", "10" },
				{ "type", "annotation" },
				{ "dashboardUID", "tern-all-panels" },
				{ "from", "1791840751000" },
				{ "to", "1791844351000" },
			})
		end)

		it("reads organization-wide annotations as belonging to no dashboard or panel", function()
			local list = answer(version, "annotations_annolist").annotations
			expect(#list).toBe(3)
			local org = byId(list, 3)
			expect(org.dashboard_uid).toBeNil()
			expect(org.panel_id).toBeNil()
			expect(org.time_end - org.time).toBe(5 * MIN)
			expect(byId(list, 2).tags).toEqual({ "tern-seed", "deploy" })
		end)

		it("shows text, time range, author and colored tags", function()
			local node = Registry.view(panel(version), {}, S.env, {
				key = "p",
				timezone = "utc",
				extra = { ["annotations:tern-all-panels"] = answer(version, "annotations_annolist") },
			})
			local text = S.text(node)
			expect(text).toContain("helm upgrade checkout --version 1.4.2")
			expect(text).toContain("2026-10-12 21:28:34  -  2026-10-12 21:33:34")
			expect(text).toContain("sa-1-tern-dev")
			local tags = S.findAll(node, function(n: any): boolean
				return n.k == "el"
					and type(n.p.class) == "string"
					and string.find(n.p.class, "tgl-tag ", 1, true) ~= nil
			end)
			local classes: { [string]: string } = {}
			for _, n in tags do
				classes[S.text(n)] = n.p.class
			end
			-- Grafana's reference render: tern-seed gray, deploy red, maintenance purple.
			expect(classes["tern-seed"]).toBe("tgl-tag tgl-tag-9")
			expect(classes.deploy).toBe("tgl-tag tgl-tag-15")
			expect(classes.maintenance).toBe("tgl-tag tgl-tag-17")
		end)

		it("hides time, user and tags when switched off", function()
			local p = S.clone(panel(version))
			p.options.showTime, p.options.showUser, p.options.showTags = false, false, false
			local node = Registry.view(p, {}, S.env, {
				key = "p",
				extra = { ["annotations:tern-all-panels"] = answer(version, "annotations_annolist_dashboard") },
			})
			expect(S.text(node)).toBe("CPU spike on checkout")
		end)
	end)
end

describe("annolist", function()
	local o = Annolist.options({ options = {} }, S.env)

	it("opens another dashboard's annotation there, without its panel", function()
		local a = { time = T, time_end = T, dashboard_uid = "tern-panels", panel_id = 2, tags = {} }
		local l = Scheme.decode(Annolist.link(a :: any, o, "tern-all-panels") :: string) :: any
		expect(l.action).toBe("dashboard")
		expect(l.params).toEqual({
			uid = "tern-panels",
			from = tostring(T - 10 * MIN),
			to = tostring(T + 10 * MIN),
		})
	end)

	it("opens this dashboard on the annotation's panel, organization-wide ones here too", function()
		local a = { time = T, time_end = T + 5 * MIN, dashboard_uid = "tern-all-panels", panel_id = 1 }
		local l = Scheme.decode(Annolist.link(a :: any, o, "tern-all-panels") :: string) :: any
		expect(l.params).toEqual({
			uid = "tern-all-panels",
			panel = "1",
			from = tostring(T - 10 * MIN),
			to = tostring(T + 15 * MIN),
		})
		local org = Scheme.decode(Annolist.link({ time = T } :: any, o, "tern-all-panels") :: string) :: any
		expect(org.params.uid).toBe("tern-all-panels")
		expect(Annolist.link({ time = T } :: any, o, nil)).toBeNil()
	end)

	it("moves by navigateBefore/After like _timeOffset", function()
		expect(Annolist.timeOffset(T, "1h", true)).toBe(T - 60 * MIN)
		expect(Annolist.timeOffset(T, "oops", false)).toBe(T + 5 * MIN)
		expect(Annolist.timeOffset(T, "5x", false)).toBe(0)
		-- 2024-01-31 + 1M is 2024-02-29.
		expect(Annolist.timeOffset(1706659200000, "1M", false)).toBe(1709164800000)
	end)

	it("hashes tag names like grafana-ui getTagColorIndexFromName", function()
		expect(Annolist.tagColor("incident")).toBe(15)
		expect(Annolist.tagColor("Deploy")).toBe(15)
		-- A non-BMP character counts as two UTF-16 units.
		expect(Annolist.tagColor("😀x")).toBe(4)
	end)

	it("is not native when tags use dashboard variables", function()
		local ok, why = Registry.supports({ type = "annolist", options = { tags = { "$env" } } }, S.env)
		expect(ok).toBe(false)
		expect(why).toContain("variables")
	end)

	it("says when nothing matches", function()
		local node = Registry.view({ type = "annolist", options = {} }, {}, S.env, {
			key = "p",
			extra = { ["annotations:"] = { annotations = {} } },
		})
		expect(S.text(node)).toBe("No annotations found")
	end)
end)

return nil
