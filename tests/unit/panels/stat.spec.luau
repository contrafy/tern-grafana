--!strict
-- The stat panel: getFieldDisplayValues (packages/grafana-data/src/field/
-- fieldDisplay.ts) for which values show, StatPanel.tsx + BigValueLayout.tsx
-- getTextValues for titles, panelcfg.cue for colorMode/graphMode.
local t = require("../../lib/test")
local S = require("./support")
local Stat = require("../../../plugin/lib/panels/stat")
local Values = require("../../../plugin/lib/panels/values")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env
local OPTS = { key = "s" }

local JOBS = { "alertmanager", "down", "loki", "node", "prometheus", "tempo" }

for _, version in S.VERSIONS do
	describe("stat on tern-panels, Grafana " .. version, function()
		-- Panel 5 "Targets up": sum(up) = 5, red below 5, green from 5,
		-- colorMode background, graphMode area, textMode auto.
		it("reduces with lastNotNull and tints the tile by threshold", function()
			local tiles = Stat.tiles(S.panel(version, 5), S.refFrames(version, "prom_range", "B"), env, OPTS)
			expect(#tiles).toBe(1)
			expect(tiles[1].value).toBe("5")
			expect(tiles[1].tone).toBe("success")
			expect(tiles[1].color_mode).toBe("background")
			-- auto with one value and a panel title: value only.
			expect(tiles[1].title).toBeNil()
		end)

		it("draws the field as a sparkline in graphMode area", function()
			local tiles = Stat.tiles(S.panel(version, 5), S.refFrames(version, "prom_range", "B"), env, OPTS)
			local spark: any = tiles[1].spark
			assert(spark, "spark")
			expect(spark.k).toBe("chart")
			expect(spark.p.kind).toBe("spark")
			expect(spark.p.token).toBe("success")
			expect(#spark.p.series).toBe(60)
		end)

		-- Panel 6 "Down targets": graphMode none, colorMode value; fed the
		-- per-job `up` series it shows one value per field, named.
		it("shows one named value per field, value-colored", function()
			local tiles = Stat.tiles(S.panel(version, 6), S.frames(version, "prom2_range"), env, OPTS)
			expect(#tiles).toBe(6)
			for i, job in JOBS do
				expect(tiles[i].title).toBe(job)
				expect(tiles[i].spark).toBeNil()
			end
			-- green base, red from 1: an up target is "red" here.
			expect(tiles[1].value).toBe("1")
			expect(tiles[1].tone).toBe("error")
			expect(tiles[2].value).toBe("0")
			expect(tiles[2].tone).toBe("success")
		end)

		it("renders value color as a span token and background as a class", function()
			local node = Stat.view(S.panel(version, 6), S.frames(version, "prom2_range"), env, OPTS)
			local value = S.find(node, function(n)
				return n.k == "text" and n.p.spans[1].t == "1"
			end)
			expect(value.p.spans[1].s).toBe("strong error")
			local bg = Stat.view(S.panel(version, 5), S.refFrames(version, "prom_range", "B"), env, OPTS)
			local tile = S.find(bg, function(n)
				return n.p and n.p.key == "s1"
			end)
			expect(tile.p.class).toBe("tgp-stat tgp-bg tgp-success")
		end)

		-- Panel 17: defaults {}, colorMode none: no tone token at all.
		it("leaves colorMode none uncolored", function()
			local node = Stat.view(S.panel(version, 17), S.refFrames(version, "prom_range", "B"), env, OPTS)
			local value = S.find(node, function(n)
				return n.k == "text" and n.p.spans[1].t == "5"
			end)
			expect(value.p.spans[1].s).toBe("strong")
		end)

		it("filters fields by reduceOptions.fields and caps by limit", function()
			local panel = S.clone(S.panel(version, 6))
			panel.options.reduceOptions.fields = "/^(alertmanager|loki)$/"
			local tiles = Stat.tiles(panel, S.frames(version, "prom2_range"), env, OPTS)
			expect(#tiles).toBe(2)
			expect(tiles[2].title).toBe("loki")
			panel.options.reduceOptions.fields = ""
			panel.options.reduceOptions.limit = 2
			expect(#Stat.tiles(panel, S.frames(version, "prom2_range"), env, OPTS)).toBe(2)
		end)

		it("shows a value per calc and per row when asked", function()
			local panel = S.clone(S.panel(version, 5))
			panel.options.reduceOptions.calcs = { "min", "max", "count" }
			local tiles = Stat.tiles(panel, S.refFrames(version, "prom_range", "B"), env, OPTS)
			expect(#tiles).toBe(3)
			expect(tiles[3].value).toBe("61")
			local rows = S.clone(S.panel(version, 5))
			rows.options.reduceOptions.values = true
			rows.options.textMode = "value_and_name"
			local perRow = Stat.tiles(rows, S.frames(version, "prom_instant"), env, OPTS)
			expect(#perRow).toBe(6)
		end)

		it("honors textMode name and none", function()
			local panel = S.clone(S.panel(version, 6))
			panel.options.textMode = "name"
			local named = Stat.tiles(panel, S.frames(version, "prom2_range"), env, OPTS)
			expect(named[1].value).toBe("alertmanager")
			expect(named[1].title).toBeNil()
			panel.options.textMode = "none"
			expect(Stat.tiles(panel, S.frames(version, "prom2_range"), env, OPTS)[1].value).toBe("")
		end)

		-- An explicit empty calcs list means last (fieldDisplay.ts).
		it("falls back to last for an empty calcs list", function()
			local panel = S.clone(S.panel(version, 5))
			panel.options.reduceOptions.calcs = {}
			expect(Values.calcsOf(panel, env)).toEqual({ "last" })
			panel.options.reduceOptions = nil
			expect(Values.calcsOf(panel, env)).toEqual({ "lastNotNull" })
		end)
	end)
end

describe("stat edge cases", function()
	it("shows No data (or noValue) without frames", function()
		local panel = { type = "stat", title = "x", fieldConfig = { defaults = {} }, options = {} }
		expect(Stat.tiles(panel, {}, env, OPTS)[1].value).toBe("No data")
		local nv = { type = "stat", title = "x", fieldConfig = { defaults = { noValue = "none yet" } }, options = {} }
		expect(Stat.tiles(nv, {}, env, OPTS)[1].value).toBe("none yet")
	end)

	-- percentChange: diffperc, up is good unless inverted.
	it("adds the percent change colored by direction", function()
		local panel = S.clone(S.panel("12.4.12", 2))
		panel.type = "stat"
		panel.options = { showPercentChange = true, graphMode = "none", reduceOptions = { calcs = { "lastNotNull" } } }
		local tiles = Stat.tiles(panel, S.refFrames("12.4.12", "prom_range", "A"), env, OPTS)
		local user: any = nil
		for _, tile in tiles do
			if tile.title == "user" then
				user = tile
			end
		end
		assert(user, "user tile")
		-- 0.10024 -> 0.2668: +166.16%.
		expect(user.change).toBe("+166.16%")
		expect(user.change_tone).toBe("success")
		panel.options.percentChangeColorMode = "inverted"
		for _, tile in Stat.tiles(panel, S.refFrames("12.4.12", "prom_range", "A"), env, OPTS) do
			if tile.title == "user" then
				expect(tile.change_tone).toBe("error")
			end
		end
	end)
end)

describe("stat sizing (BigValueLayout.tsx, VizRepeater.tsx)", function()
	local function classOf(node: any, key: string): string
		local n = S.find(node, function(x)
			return x.p and x.p.key == key and x.p.class ~= nil
		end)
		assert(n, "node " .. key)
		return n.p.class
	end
	local function has(class: string, token: string): boolean
		return string.find(" " .. class .. " ", " " .. token .. " ", 1, true) ~= nil
	end
	-- The value's font size in px: the SVG image's font-size (Stat.valueSvg).
	local function valuePx(node: any, assets: any): number
		local image = S.find(node, function(x)
			return x.k == "image"
		end)
		assert(image, "value image")
		local svg = assets[image.p.asset].bytes
		return assert(tonumber(string.match(svg, 'font%-size="(%d+)"')))
	end

	-- Grafana's 1000x500 render of panel 17 draws the lone "5" about 356 px
	-- tall: the box height (452 px less 12 px padding twice) over the line
	-- height 1.2. A fixed size would look tiny next to it.
	it("grows a lone value to the box height and centers it", function()
		local node, assets = Stat.view(
			S.panel("12.4.12", 17),
			S.refFrames("12.4.12", "prom_range", "B"),
			env,
			{ key = "s", size = { w = 1000, h = 500 } }
		)
		expect(valuePx(node, assets)).toBe(357)
		expect(has(classOf(node, "l"), "tgp-stat-center")).toBe(true)
		expect(has(classOf(node, "s1"), "tgp-stat-fit")).toBe(true)
	end)

	-- Panel 6 at its gridPos 4x4 (267x144 px) with six named values:
	-- autoGrid puts them 3 by 2, each box 81.7x46.5; the title takes 15% of
	-- the box height and the value the rest.
	it("lays many values in VizRepeater's grid and sizes them alike", function()
		local node, assets = Stat.view(
			S.panel("12.4.12", 6),
			S.frames("12.4.12", "prom2_range"),
			env,
			{ key = "s", size = { w = 267, h = 144 } }
		)
		expect(has(classOf(node, "g"), "tgp-stat-g3")).toBe(true)
		local sizes: { number } = {}
		for _, key in { "s1", "s6" } do
			local tile = S.find(node, function(x)
				return x.p and x.p.key == key
			end)
			table.insert(sizes, valuePx(tile, assets))
			expect(has(classOf(tile, "t"), "tgp-stat-fs10")).toBe(true)
		end
		-- The box height less its padding and the title line, over 1.2.
		expect(sizes).toEqual({ 20, 20 })
	end)

	-- A wide box (w/h > 2.5) with a sparkline gives the value 40% of the
	-- width and half the height (WideWithChartLayout).
	it("uses the wide layout for wide panels", function()
		local node, assets = Stat.view(
			S.panel("12.4.12", 5),
			S.refFrames("12.4.12", "prom_range", "B"),
			env,
			{ key = "s", size = { w = 267, h = 144 } }
		)
		expect(has(classOf(node, "l"), "tgp-stat-wide")).toBe(true)
		expect(valuePx(node, assets)).toBe(33)
	end)

	it("honors text.valueSize and text.titleSize", function()
		local panel = S.clone(S.panel("12.4.12", 6))
		panel.options.text = { valueSize = 40, titleSize = 12 }
		local node, assets =
			Stat.view(panel, S.frames("12.4.12", "prom2_range"), env, { key = "s", size = { w = 267, h = 144 } })
		expect(valuePx(node, assets)).toBe(40)
		expect(has(classOf(node, "t"), "tgp-stat-fs12")).toBe(true)
	end)

	-- A long value is limited by the box width, not its height: it must not
	-- spill out of the tile.
	it("shrinks a long value to the box width", function()
		local short = Stat.fit({ w = 300, h = 200, value = "5", spark = false, change = false })
		local long = Stat.fit({ w = 300, h = 200, value = "123456789.12 MB", spark = false, change = false })
		expect(short.value_px).toBe((200 - 24) / 1.2)
		expect(long.value_px < short.value_px / 3).toBe(true)
		expect(long.value_px * Stat.textEm("123456789.12 MB") <= 300 - 24).toBe(true)
	end)

	-- The value is one line of SVG text whose viewBox is its own box
	-- (textLength pins the drawn width to it), so a tile narrower than
	-- Grafana's scales it down instead of wrapping it, and the image's max
	-- height never lets it outgrow Grafana's size (smoke: "No targets"
	-- wrapped and was clipped in a wide pane).
	it("draws the value as one SVG line that only scales down", function()
		local svg, w, h = Stat.valueSvg("No targets", 70, "tgg-f-success")
		expect(w).toBe(math.ceil(10 * Stat.TEXT_EM * 70))
		expect(h).toBe(84)
		expect(string.find(svg, string.format('viewBox="0 0 %d %d"', w, h), 1, true) ~= nil).toBe(true)
		expect(string.find(svg, string.format('textLength="%d"', w), 1, true) ~= nil).toBe(true)
		expect(select(2, string.gsub(svg, "<text", ""))).toBe(1)
		local node = Stat.view(
			{ type = "stat", title = "x", fieldConfig = { defaults = { noValue = "No targets" } }, options = {} },
			{},
			env,
			{ key = "s", size = { w = 400, h = 296 } }
		)
		local image = S.find(node, function(x)
			return x.k == "image"
		end)
		expect(image.p.alt).toBe("No targets")
		local lines = assert(tonumber(string.match(image.p.max.h, "^(%d+)lines$")))
		expect(lines * 16 >= image.p.h and (lines - 1) * 16 < image.p.h).toBe(true)
	end)

	it("keeps the plain tile without a panel size", function()
		local node = Stat.view(S.panel("12.4.12", 5), S.refFrames("12.4.12", "prom_range", "B"), env, OPTS)
		expect(classOf(node, "s1")).toBe("tgp-stat tgp-bg tgp-success")
	end)
end)

return nil
