--!strict
-- tern-legacy is saved the way dashboards were before Grafana 5
-- (schemaVersion 14, top-level `rows`), the format of popular public
-- dashboards (Prometheus 2.0 overview, Docker, Kubernetes cluster, Grafana
-- internals, the Loki and Tempo mixins). Grafana upgrades such a dashboard
-- when it loads it; without the same upgrade Tern draws nothing. Checked
-- against Grafana's own migration (the v1beta1 answer of 12 and 13) and the
-- frames recorded for the migrated panels:
-- - every panel keeps Grafana's id, type, title and gridPos; rows become row
--   panels, a collapsed row keeps its panels, left-over repeat copies go;
-- - the old table's styles hide Time and __name__ and name the value
--   columns of the one merged table;
-- - a graph's legend hideZero/hideEmpty leave the zero series out of the
--   legend, and an all-zero graph without any legend (as Grafana draws it);
-- - a flat singlestat sparkline lies at the bottom of its range.
local Analyze = require("../../../plugin/lib/compat/analyze")
local MigrateSchema = require("../../../plugin/lib/dashboard/migrate_schema")
local Model = require("../../../plugin/lib/dashboard/model")
local PS = require("../panels/support")
local Registry = require("../../../plugin/lib/panels/registry")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

-- What decides where and how a panel shows; Grafana's v1beta1 answer names
-- an auto-migrated panel's former type in autoMigrateFrom, and leaves out a
-- gridPos equal to PanelModel's default.
local function shape(p: any, oracle: boolean): any
	local out: any = {
		id = p.id,
		type = if oracle then p.autoMigrateFrom or p.type else p.type,
		title = p.title or "",
		gridPos = p.gridPos or { x = 0, y = 0, w = 6, h = 3 },
		collapsed = p.collapsed == true,
		maxPerRow = p.maxPerRow,
		links = p.links,
		styles = p.styles,
		transformations = p.transformations,
	}
	if p.type == "row" then
		local kids = {}
		for i, k in p.panels or {} do
			kids[i] = shape(k, oracle)
		end
		out.panels = kids
	end
	return out
end

local function shapes(panels: { any }, oracle: boolean): { any }
	local out = {}
	for i, p in panels do
		out[i] = shape(p, oracle)
	end
	return out
end

local function sections(d: Model.Dashboard): { any }
	local out = {}
	for _, s in d.sections do
		local ids = {}
		for _, p in s.panels do
			table.insert(ids, p.id)
		end
		table.insert(
			out,
			{ row = if s.row then s.row.title else nil, collapsed = s.row ~= nil and s.row.collapsed, ids = ids }
		)
	end
	return out
end

for _, version in S.VERSIONS do
	describe("legacy dashboard tern-legacy on Grafana " .. version, function()
		local env = S.env()
		local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_legacy.json")), env))

		it("turns top-level rows into row panels and drops left-over copies", function()
			expect(sections(d)).toEqual({
				{ row = "Single stats and an old table", collapsed = false, ids = { 1, 2, 3, 4 } },
				{ row = "Graphs with hideZero and hideEmpty", collapsed = false, ids = { 5, 6 } },
				{ row = "Collapsed notes", collapsed = true, ids = { 8 } },
			})
			expect(assert(Model.findPanel(d, 4)).type).toBe("table-old")
			expect(assert(Model.findPanel(d, 6)).repeat_by).toBeNil()
			expect(assert(Model.findPanel(d, 1)).grid).toEqual({ x = 0, y = 1, w = 4, h = 7 })
		end)

		it("counts its panels in the compatibility report instead of an empty dashboard", function()
			local r = Analyze.result(d.uid, d.title, nil, {}, nil)
			expect(r.note).toBe(Analyze.NO_PANELS)
			expect(#Model.panels(d)).toBe(7)
		end)
	end)
end

for _, version in { "12.4.12", "13.3.1" } do
	describe("legacy dashboard tern-legacy against Grafana " .. version .. "'s migration", function()
		local env = S.env()
		local raw = S.doc(S.grafana(version, "dashboard_tern_legacy.json")).dashboard
		local oracle = S.doc(S.grafana(version, "dashboard_v1beta1_tern_legacy.json")).spec
		local migrated = MigrateSchema.migrate(raw, env)
		local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_legacy.json")), env))
		local range = S.doc(S.grafana(version, "ds_query_tern_legacy_1.request.json"))
		local opts: any = {
			key = "p",
			width = 600,
			height = 300,
			from_ms = tonumber(range.from),
			to_ms = tonumber(range.to),
			time = { from_ms = tonumber(range.from), to_ms = tonumber(range.to) },
		}
		local function view(id: number): any
			local p = assert(Model.findPanel(d, id))
			local node = Registry.view(p.json, PS.frames(version, "tern_legacy_" .. id), env, opts)
			return node
		end

		it("places, names and types every panel as Grafana does", function()
			expect(shapes(migrated.panels, false)).toEqual(shapes(oracle.panels, true))
			local vars = {}
			for i, v in migrated.templating.list do
				vars[i] = { v.name, v.type, v.hide }
			end
			local want = {}
			for i, v in oracle.templating.list do
				want[i] = { v.name, v.type, v.hide }
			end
			expect(vars).toEqual(want)
		end)

		it("hides the old table's hidden columns and names its merged value columns", function()
			local text = PS.text(view(4))
			expect(string.find(text, "Up", 1, true) ~= nil).toBe(true)
			expect(string.find(text, "Scrape", 1, true) ~= nil).toBe(true)
			expect((string.find(text, "__name__", 1, true))).toBeNil()
			expect((string.find(text, "Value #A", 1, true))).toBeNil()
			expect((string.find(text, "more frames", 1, true))).toBeNil()
		end)

		it("leaves zero series out of the legend and the legend out when all are zero", function()
			local legend = function(n: any): boolean
				return type(n.p) == "table" and n.p.role == "tern-grafana.legend"
			end
			local some = PS.text(assert(PS.find(view(5), legend)))
			expect(string.find(some, "prometheus", 1, true) ~= nil).toBe(true)
			expect((string.find(some, "down", 1, true))).toBeNil()
			expect(PS.find(view(6), legend)).toBeNil()
		end)

		it("draws a flat singlestat sparkline at the bottom of its range, as getYRange does", function()
			for _, id in { 1, 2 } do
				local p = assert(Model.findPanel(d, id))
				local node, assets = Registry.view(p.json, PS.frames(version, "tern_legacy_" .. id), env, opts)
				local image = assert(PS.find(node, function(n: any): boolean
					return n.k == "image" and n.p.alt == "Sparkline"
				end))
				local svg = (assets :: any)[image.p.asset].bytes
				local h = tonumber(string.match(svg, 'viewBox="0 0 %d+ (%d+)"'))
				local path = assert(string.match(svg, 'tg%-line" fill="none" stroke%-width="1" d="([^"]*)"'))
				local ys = {}
				for y in string.gmatch(path, "[ML][%d.]+ ([%d.%-]+)") do
					table.insert(ys, tonumber(y))
				end
				expect(#ys > 1).toBe(true)
				for _, y in ys do
					expect(y).toBe(h)
				end
			end
		end)
	end)
end

return nil
