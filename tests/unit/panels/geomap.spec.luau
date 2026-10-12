--!strict
-- The geomap panel's native markers layer (geomap/GeomapPanel.tsx,
-- layers/data/markersLayer.tsx, dimensions/scale.ts) on tern-all-panels
-- panel 33: four regions sized and colored by `requests` (thresholds
-- green, orange at 100, red at 250; unit reqps), labeled by `region`.
local Geomap = require("../../../plugin/lib/panels/geomap")
local S = require("./support")
local SvgGeomap = require("../../../plugin/lib/render/svg_geomap")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local function allPanels(version: string, id: number): any
	local doc = S.decode("grafana/" .. version .. "/dashboard_tern_all_panels.json")
	for _, p in doc.dashboard.panels do
		if p.id == id then
			return p
		end
	end
	error("no panel " .. id)
end

for _, version in S.VERSIONS do
	describe("geomap " .. version, function()
		it("is native for markers layers", function()
			expect((Geomap.supports(allPanels(version, 33), env))).toBe(true)
		end)

		-- Size scales requests 45..310 into radius 4..20; colors follow the
		-- thresholds; labels sit 14 px above in the marker color.
		it("draws sized, colored and labeled markers over the outline", function()
			local node, assets = Geomap.view(allPanels(version, 33), S.frames(version, "all_panels_33"), env, {
				key = "gm",
				size = { w = 1000, h = 460 },
			})
			local svg = (assets :: any).gm.bytes
			expect(#svg <= 262144).toBe(true)
			expect(string.find(svg, 'class="tgm-land"', 1, true) ~= nil).toBe(true)
			expect(string.find(svg, 'r="20.0" fill="#F2495C" fill-opacity="0.60"', 1, true) ~= nil).toBe(true)
			expect(string.find(svg, 'r="4.0" fill="#73BF69"', 1, true) ~= nil).toBe(true)
			expect(string.find(svg, 'fill="#FF9830">virginia</text>', 1, true) ~= nil).toBe(true)
			local legend = S.find(node, function(n)
				return n.p and n.p.role == "tern-grafana.legend"
			end)
			expect(S.text(legend)).toBe("< 100 req/s100 req/s+250 req/s+")
		end)
	end)
end

describe("geomap view", function()
	-- The "zero" view centers 0,0; the world spans at least the panel.
	it("places Frankfurt east of the center and north of the equator", function()
		local panel = allPanels("12.4.12", 33)
		local lon, lat, world = Geomap.viewOf(panel, env, {}, 1000, 460)
		expect(lon).toBe(0)
		expect(lat).toBe(0)
		expect(world).toBe(1000)
		local x, y = SvgGeomap.project(8.68, 50.11)
		expect(math.floor(500 + (x - 0.5) * world + 0.5)).toBe(524)
		expect(y < 0.5).toBe(true)
	end)

	it("fits the view to the markers", function()
		local panel = S.clone(allPanels("12.4.12", 33))
		panel.options.view = { id = "fit", padding = 5 }
		local ms = {
			{ lon = 0, lat = 0, radius = 1, color = "#000000", opacity = 1 },
			{ lon = 90, lat = 0, radius = 1, color = "#000000", opacity = 1 },
		}
		local lon, _, world = Geomap.viewOf(panel, env, ms :: any, 1000, 460)
		expect(lon).toBe(45)
		expect(math.abs(world - 4000 / 1.05) < 1e-6).toBe(true)
	end)

	it("decodes geohashes", function()
		local lat, lon = Geomap.geohash("u0yjjd0xf")
		expect(math.abs((lat :: number) - 50.11) < 0.001).toBe(true)
		expect(math.abs((lon :: number) - 8.68) < 0.001).toBe(true)
	end)

	it("keeps other layer types on the ladder", function()
		local panel = S.clone(allPanels("12.4.12", 33))
		panel.options.layers[1].type = "heatmap"
		local ok, why = Geomap.supports(panel, env)
		expect(ok).toBe(false)
		expect(why).toBe("geomap heatmap layers are not drawn natively")
	end)
end)

return nil
