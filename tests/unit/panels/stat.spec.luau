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

return nil
