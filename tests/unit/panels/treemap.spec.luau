--!strict
-- The treemap panel (marcusolsson-treemap-panel 2.1.1) on synthetic frames
-- shaped like the dev stack's tern-s4-treemap panels (TestData csv_content
-- "label,count" and "job,metric,count") and the Cardinality "details"
-- frames the user's treemaps draw.
local Frame = require("../../../plugin/lib/frame/types")
local Layout = require("../../../plugin/lib/panels/treemap_layout")
local Links = require("../../../plugin/lib/dashboard/links")
local Registry = require("../../../plugin/lib/panels/registry")
local S = require("./support")
local Scheme = require("../../../plugin/lib/links/scheme")
local Treemap = require("../../../plugin/lib/panels/treemap")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local REF = S.decode("treemap/d3_hierarchy_3.1.2.json")

local function refCase(name: string): any
	for _, c in REF.cases do
		if c.name == name then
			return c
		end
	end
	error("no d3 case " .. name)
end

-- tern-s4-treemap panel 1: percentage thresholds and a data link.
local LABELS_PANEL = [[{
	"id": 1, "type": "marcusolsson-treemap-panel", "title": "Label cardinality",
	"options": {"tiling": "treemapSquarify"},
	"fieldConfig": {"defaults": {
		"color": {"mode": "thresholds"},
		"links": [{"title": "Scope to ${__data.fields[0]}",
			"url": "d/tern-s4-treemap/?${datasource:queryparam}&var-filter=${__data.fields[0]}"}],
		"thresholds": {"mode": "percentage", "steps": [
			{"color": "blue", "value": null}, {"color": "yellow", "value": 50}, {"color": "red", "value": 100}]}
	}, "overrides": []}
}]]

local LABELS = { "job", "instance", "__name__", "le", "quantile", "code", "method", "handler" }
local COUNTS = { 5120, 4800, 3100, 2900, 1250, 800, 420, 390 }

local function labelFrames(): { Frame.Frame }
	return {
		{ refId = "A", fields = { Frame.field("label", "string", LABELS), Frame.field("count", "number", COUNTS) } },
	}
end

-- The content box of a 999 x 386 titled panel (1 px borders, 40 px header)
-- is the d3 case's 997 x 344.
local function opts(extra: { [string]: any }?): any
	local o: { [string]: any } = { key = "p", size = { w = 999, h = 386 }, base_url = "http://grafana.test" }
	if extra then
		for k, v in extra do
			o[k] = v
		end
	end
	return o
end

local function leaves(tiles: { any }): { any }
	local out = {}
	for _, tile in tiles do
		if tile.class then
			table.insert(out, tile)
		end
	end
	return out
end

describe("treemap panel", function()
	-- The panel lays its rows out exactly as d3 does in Grafana: same
	-- rectangles for the same content box.
	it("draws the rows where d3 puts them", function()
		local panel = S.json(LABELS_PANEL)
		local views = Treemap.views(panel, labelFrames(), env)
		local W, H = Treemap.size(panel, env, opts())
		expect({ W, H }).toEqual({ 997, 344 })
		local tiles = Treemap.tiles(panel, views, labelFrames(), env, opts(), W, H)
		local want = refCase("labels treemapSquarify").tiles
		expect(#tiles).toBe(#want - 1)
		for i, tile in tiles do
			local w = want[i + 1]
			expect({ tile.x0, tile.y0, tile.x1, tile.y1 }).toEqual({ w.x0, w.y0, w.x1, w.y1 })
		end
	end)

	-- Percentage thresholds scale between the frames' smallest and largest
	-- numbers: the largest is red, the upper half yellow, the rest blue, each
	-- the saturated color Grafana fills the tile with (tern-grafana.css:
	-- tg-gc8 #F2495C, tg-gc56 #FADE2A, tg-gc103 #5794F2, switched to
	-- Grafana's light shades under Tern's light theme), not Tern's muted
	-- status tones.
	it("fills each leaf with its color field's threshold color", function()
		local panel = S.json(LABELS_PANEL)
		local tiles =
			Treemap.tiles(panel, Treemap.views(panel, labelFrames(), env), labelFrames(), env, opts(), 997, 344)
		expect(tiles[1].class).toBe("tg-gc8")
		expect(tiles[2].class).toBe("tg-gc56")
		expect(tiles[8].class).toBe("tg-gc103")
	end)

	-- A fixed color fills every leaf with it (a literal hex as its nearest
	-- class, kept in both themes); a continuous scheme fills by the value's
	-- position in it.
	it("fills leaves with a fixed color or a continuous scheme's color", function()
		local function classes(color: string): { string? }
			local panel = S.json([[{"type": "marcusolsson-treemap-panel",
				"fieldConfig": {"defaults": {"color": ]] .. color .. [[}, "overrides": []}}]])
			local tiles =
				Treemap.tiles(panel, Treemap.views(panel, labelFrames(), env), labelFrames(), env, opts(), 997, 344)
			return { tiles[1].class, tiles[8].class }
		end
		-- purple #B877D9 (tg-gc127).
		expect(classes([[{"mode": "fixed", "fixedColor": "purple"}]])).toEqual({ "tg-gc127", "tg-gc127" })
		expect(classes([[{"mode": "fixed", "fixedColor": "#123456"}]])[1]).toBe("tg-gc178 tg-hex")
		-- GrYlRd ends at red #F2495C (tg-gc8) for the largest value.
		expect(classes([[{"mode": "continuous-GrYlRd"}]])[1]).toBe("tg-gc8")
	end)

	it("labels a tile only when the name fits", function()
		local panel = S.json(LABELS_PANEL)
		local tiles =
			Treemap.tiles(panel, Treemap.views(panel, labelFrames(), env), labelFrames(), env, opts(), 997, 344)
		expect(tiles[1].label).toBe("job")
		local small =
			Treemap.tiles(panel, Treemap.views(panel, labelFrames(), env), labelFrames(), env, opts(), 160, 120)
		local labelled, bare = 0, 0
		for _, tile in small do
			if tile.label then
				labelled += 1
			else
				bare += 1
			end
		end
		expect(labelled > 0).toBe(true)
		expect(bare > 0).toBe(true)
	end)

	-- Grafana's click menu lists the size field's data links with the row's
	-- values URI-encoded; "d/..." is relative to Grafana's root.
	it("links each leaf to its interpolated data link", function()
		local panel = S.json(LABELS_PANEL)
		local frames = labelFrames()
		frames[1].fields[1].values[3] = "a b/c"
		local o = opts({
			replace = function(text: string): string
				return (string.gsub(text, "%${datasource:queryparam}", "var-datasource=prom3"))
			end,
		})
		local _, hits = Treemap.tiles(panel, Treemap.views(panel, frames, env), frames, env, o, 997, 344)
		expect(hits[1].href).toBe("http://grafana.test/d/tern-s4-treemap/?var-datasource=prom3&var-filter=job")
		expect(hits[1].title).toBe("job\n5120\nScope to job")
		expect(hits[3].href).toBe("http://grafana.test/d/tern-s4-treemap/?var-datasource=prom3&var-filter=a%20b%2Fc")
		expect(hits[3].title).toBe("a b/c\n3100\nScope to a b/c")
	end)

	-- A click on a tile's overlay element reaches the dashboard's `dlink`
	-- action, which opens the link in the browser pane.
	it("opens a tile's link from its click action", function()
		local panel = S.json(LABELS_PANEL)
		local frames = labelFrames()
		local _, hits = Treemap.tiles(panel, Treemap.views(panel, frames, env), frames, env, opts(), 997, 344)
		local single = Treemap.overlay({ hits[1] }, 997, 344) :: any
		local node = single.c[1]
		while node.k ~= "el" or node.p.actions == nil do
			node = node.c[#node.c]
		end
		local act, value = string.match(node.p.actions.click, "^(%w+)=(.*)$")
		expect(act).toBe("dlink")
		local effects: { any } = {}
		Links.openDataLink(value :: string, effects)
		expect(assert(Scheme.decode(effects[1].target)).params.url).toBe(hits[1].href)
	end)

	-- The overlay's nested bases put every hit element on its tile.
	it("lays the overlay hits over their tiles", function()
		local panel = S.json(LABELS_PANEL)
		local frames = labelFrames()
		local W, H = 997, 344
		local _, hits = Treemap.tiles(panel, Treemap.views(panel, frames, env), frames, env, opts(), W, H)
		local over = Treemap.overlay(hits, W, H) :: any
		local found: { [string]: { number } } = {}
		local function walk(node: any, x0: number, y0: number, x1: number, y1: number)
			if node.k == "el" then
				if node.p.title then
					found[node.p.title] = { x0, y0, x1, y1 }
				end
				return
			end
			local at = if node.k == "row" then x0 else y0
			for _, c in node.c do
				local b = c.p.basis
				if node.k == "row" then
					local w = b * (x1 - x0)
					walk(c, at, y0, at + w, y1)
					at += w
				else
					local h = b * (y1 - y0)
					walk(c, x0, at, x1, at + h)
					at += h
				end
			end
		end
		walk(over.c[1], 0, 0, W, H)
		expect(#hits).toBe(8)
		for _, h in hits do
			local r = found[h.title]
			expect(r ~= nil).toBe(true)
			for k, v in { h.x0, h.y0, h.x1, h.y1 } do
				expect(math.abs(r[k] - v) < 1e-6).toBe(true)
			end
		end
	end)

	-- groupByField adds a level: groups are drawn under their rows.
	it("groups rows by the group field", function()
		local panel = S.json([[{
			"type": "marcusolsson-treemap-panel", "title": "",
			"options": {"tiling": "treemapBinary", "groupByField": "job", "textField": "metric", "sizeField": "count"},
			"fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}}, "overrides": []}
		}]])
		local frames = {
			{
				refId = "A",
				fields = {
					Frame.field("job", "string", { "prometheus", "node", "prometheus", "node" }),
					Frame.field("metric", "string", { "up", "cpu", "http", "load1" }),
					Frame.field("count", "number", { 10, 160, 320, 3 }),
				},
			},
		}
		local views = Treemap.views(panel, frames, env)
		local root = Treemap.hierarchy(views)
		expect(#(root.children :: { any })).toBe(2)
		local tiles = Treemap.tiles(panel, views, frames, env, opts(), 600, 300)
		-- prometheus (330) and node (163) first, then their rows.
		expect(tiles[1].class).toBeNil()
		expect(tiles[1].label).toBe("prometheus")
		expect(tiles[2].class).toBeNil()
		expect(#leaves(tiles)).toBe(4)
		-- palette-classic colors every row with the count field's color.
		expect(leaves(tiles)[1].class).toBe("tg-s3")
	end)

	-- custom.separator splits a label into a path; a trailing one is
	-- dropped; the single top-level node ("" frame name) collapses.
	it("splits labels by the separator", function()
		local panel = S.json([[{
			"type": "marcusolsson-treemap-panel",
			"fieldConfig": {"defaults": {"custom": {"separator": "."}}, "overrides": []}
		}]])
		local frames = {
			{
				fields = {
					Frame.field("name", "string", { "a.b", "a.c.", "d" }),
					Frame.field("v", "number", { 1, 2, 3 }),
				},
			},
		}
		local root = Treemap.hierarchy(Treemap.views(panel, frames, env))
		local kids = root.children :: { Layout.Input }
		expect(#kids).toBe(2)
		expect(kids[1].name).toBe("a")
		local a = kids[1].children :: { Layout.Input }
		expect(a[1].name).toBe("b")
		expect(a[2].name).toBe("c")
		expect(a[2].value).toBe(2)
		expect(kids[2].name).toBe("d")
	end)

	it("asks for a label and a size field when no frame has them", function()
		local panel = S.json([[{"type": "marcusolsson-treemap-panel"}]])
		local frames = { { fields = { Frame.field("v", "number", { 1 }) } } }
		local node = Treemap.view(panel, frames, env, opts())
		expect(node.k).toBe("text")
		local node2 = Treemap.view(panel, labelFrames(), env, opts())
		expect(node2.k).toBe("image")
	end)

	it("is native unless the tiling is unknown", function()
		local native = Registry.supports(S.json(LABELS_PANEL), env)
		expect(native).toBe(true)
		local ok, why = Registry.supports(
			S.json([[{
			"type": "marcusolsson-treemap-panel", "options": {"tiling": "treemapResquarify"}
		}]]),
			env
		)
		expect(ok).toBe(false)
		expect(why).toBe("tiling treemapResquarify is not supported")
	end)
end)

return nil
