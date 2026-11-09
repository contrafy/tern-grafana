--!strict
-- The table panel (public/app/plugins/panel/table/panelcfg.cue and the
-- grafana-ui TableNG cell renderers): columns are the transformed frame's
-- visible fields, cells go through the display processor, cellOptions pick
-- the cell renderer, sortBy orders rows, the footer reduces. Cell types are
-- checked on tern-cells (TestData CSV) against Grafana 13's own render of
-- the same panels.
local t = require("../../lib/test")
local S = require("./support")
local Table = require("../../../plugin/lib/panels/table")
local Transform = require("../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env
local OPTS = { key = "t" }

-- Row order follows the series order of each prom_table capture: the `down`
-- target's row and a row of an up target.
local DOWN_ROW = { ["11.6.16"] = 3, ["12.4.12"] = 3, ["13.3.0"] = 1 }
local UP_ROW = { ["11.6.16"] = 1, ["12.4.12"] = 1, ["13.3.0"] = 2 }

local function build(panel: any, version: string): Table.Table
	return Table.build(panel, Transform.prepare(panel, S.frames(version, "prom_table"), env), env, OPTS)
end

local function heads(tbl: Table.Table): { string }
	local out: { string } = {}
	for _, c in tbl.columns do
		table.insert(out, c.head)
	end
	return out
end

local function column(tbl: Table.Table, head: string): { string }
	local idx = table.find(heads(tbl), head)
	assert(idx, "no column " .. head)
	local out: { string } = {}
	for _, row in tbl.rows do
		table.insert(out, row[idx].text)
	end
	return out
end

for _, version in S.VERSIONS do
	describe("table on tern-panels, Grafana " .. version, function()
		-- Panel 9 "Targets": `up` as a table, organize hides Time/__name__,
		-- renames Value to up; the up override maps 0/1 to DOWN/UP on a
		-- colored background.
		it("shows the organized columns with mapped, colored up cells", function()
			local tbl = build(S.panel(version, 9), version)
			expect(heads(tbl)).toEqual({ "instance", "job", "env", "up" })
			expect(#tbl.rows).toBe(6)
			local ups = { "UP", "UP", "UP", "UP", "UP", "UP" }
			ups[DOWN_ROW[version]] = "DOWN"
			expect(column(tbl, "up")).toEqual(ups)
			expect(column(tbl, "job")[DOWN_ROW[version]]).toBe("down")
			local down = tbl.rows[DOWN_ROW[version]][4]
			expect(down.kind).toBe("color-background")
			expect(down.tone).toBe("error")
			expect(tbl.rows[UP_ROW[version]][4].tone).toBe("success")
			expect(tbl.rows[UP_ROW[version]][1].kind).toBe("auto")
			expect(tbl.columns[4].numeric).toBe(true)
			expect(tbl.columns[1].numeric).toBe(false)
		end)

		-- color-background without a mode is Grafana's gradient fill.
		it("renders a grid with filled background cells", function()
			local panel = S.panel(version, 9)
			local node = Table.view(panel, Transform.prepare(panel, S.frames(version, "prom_table"), env), env, OPTS)
			local tinted = S.findAll(node, function(n)
				return n.p and n.p.class == "tgp-cbg tgp-error tgp-cbg-grad"
			end)
			expect(#tinted).toBe(1)
			expect(S.text(tinted[1])).toBe("DOWN")
		end)

		it("sorts rows by options.sortBy", function()
			local panel = S.clone(S.panel(version, 9))
			panel.options.sortBy = { { displayName = "instance", desc = true } }
			local tbl = build(panel, version)
			expect(column(tbl, "instance")[1]).toBe("tempo:3200")
			expect(column(tbl, "instance")[6]).toBe("alertmanager:9093")
		end)

		it("adds a footer row reduced by options.footer", function()
			local panel = S.clone(S.panel(version, 9))
			panel.options.footer.show = true
			local tbl = build(panel, version)
			assert(tbl.footer, "footer")
			expect(tbl.footer).toEqual({ "", "", "", "5" })
		end)

		it("hides columns with custom.hidden and draws gauge and color-text cells", function()
			local panel = S.clone(S.panel(version, 9))
			table.insert(panel.fieldConfig.overrides, {
				matcher = { id = "byName", options = "env" },
				properties = { { id = "custom.hidden", value = true } },
			})
			panel.fieldConfig.overrides[1].properties[1].value = { type = "gauge", mode = "lcd" }
			local tbl = build(panel, version)
			expect(heads(tbl)).toEqual({ "instance", "job", "up" })
			local cell = tbl.rows[1][3]
			expect(cell.kind).toBe("gauge")
			expect(cell.gauge_mode).toBe("lcd")
			local node = Table.view(panel, Transform.prepare(panel, S.frames(version, "prom_table"), env), env, OPTS)
			local meters = S.findAll(node, function(n)
				return n.k == "meter"
			end)
			expect(#meters).toBe(6)
			expect(meters[1].p.style).toBe("blocks")
			-- LCD cells light up in their threshold band's color.
			expect(type(meters[1].p.parts)).toBe("table")
			panel.fieldConfig.overrides[1].properties[1].value = { type = "color-text" }
			local text = Table.view(panel, Transform.prepare(panel, S.frames(version, "prom_table"), env), env, OPTS)
			local up = S.find(text, function(n)
				return n.k == "text" and n.p.spans[1].t == "DOWN"
			end)
			expect(up.p.spans[1].s).toBe("error")
		end)

		-- Without format=table each series is its own frame; Grafana shows
		-- the first with a frame picker.
		it("shows the first frame and counts the rest", function()
			local panel = S.clone(S.panel(version, 9))
			panel.targets[1].format = "time_series"
			panel.transformations = {}
			local tbl = Table.build(panel, Transform.prepare(panel, S.frames(version, "prom_table"), env), env, OPTS)
			expect(tbl.more_frames).toBe(5)
			expect(#tbl.rows).toBe(1)
		end)
	end)
end

local function cellsPanel(version: string, id: number): any
	for _, p in S.decode("grafana/" .. version .. "/dashboard_tern_cells.json").dashboard.panels do
		if p.id == id then
			return p
		end
	end
	error("no panel " .. id)
end

local function cells(version: string, id: number): (any, { any })
	local panel = cellsPanel(version, id)
	return panel, Transform.prepare(panel, S.frames(version, "cells_" .. id), env)
end

local function col(tbl: Table.Table, head: string): number
	local idx = table.find(heads(tbl), head)
	assert(idx, "no column " .. head)
	return idx
end

local function tokens(parts: any): { string }
	local out: { string } = {}
	for _, p in parts do
		table.insert(out, p.token)
	end
	return out
end

-- The gauge cells of a view (their wrappers), row by row.
local function gaugeCells(node: any): { any }
	return S.findAll(node, function(n)
		return n.p and n.p.class == "tgp-gc"
	end)
end

for _, version in S.VERSIONS do
	describe("table cells on tern-cells, Grafana " .. version, function()
		-- Panel 1 reproduces the battery tables of the user's dashboards:
		-- Charge (percentunit, 0..1, gradient gauge with red/orange/green
		-- thresholds) and Load (basic gauge) by override, Health and AC lost
		-- color-background by mapping. Grafana draws a bar and the value
		-- after it; Tern drew "..." because the meter had no width and the
		-- value hid in its label.
		it("draws gauge cells as a bar with the value after it", function()
			local panel, frames = cells(version, 1)
			local tbl = Table.build(panel, frames, env, OPTS)
			local charge = col(tbl, "Charge")
			expect(column(tbl, "Charge")).toEqual({ "100%", "83%", "52%", "21%", "5%" })
			local c = tbl.rows[2][charge]
			expect(c.kind).toBe("gauge")
			expect(c.gauge_mode).toBe("gradient")
			expect(c.value_mode).toBe("text")
			-- The gradient runs red, orange, green up to 83%.
			expect(tokens(c.parts)).toEqual({ "error", "warning", "success" })
			local load = tbl.rows[1][col(tbl, "Load")]
			expect(load.gauge_mode).toBe("basic")
			expect(load.parts).toBeNil()
			expect(load.tone).toBe("success")
			local node = Table.view(panel, frames, env, OPTS)
			local gauges = gaugeCells(node)
			expect(#gauges).toBe(10)
			local meter = gauges[1].c[1]
			expect(meter.k).toBe("meter")
			expect(meter.p.value).toBe(1)
			expect(meter.p.label).toBeNil()
			-- valueDisplayMode text: the value in the plain text color.
			local value = gauges[1].c[2]
			expect(value.p.class).toBe("tgp-gc-v")
			expect(value.c[1].p.spans[1]).toEqual({ t = "100%" })
		end)

		it("fills color-background cells by mode", function()
			local panel, frames = cells(version, 1)
			local tbl = Table.build(panel, frames, env, OPTS)
			local health = tbl.rows[4][col(tbl, "Health")]
			expect(health.text).toBe("Bad")
			expect(health.bg_tone).toBe("error")
			expect(health.bg_mode).toBe("gradient")
			local ac = tbl.rows[3][col(tbl, "AC lost")]
			expect(ac.text).toBe("LOST")
			expect(ac.bg_mode).toBe("basic")
			local node = Table.view(panel, frames, env, OPTS)
			local solid = S.findAll(node, function(n)
				return n.p and n.p.class == "tgp-cbg tgp-error"
			end)
			expect(#solid).toBe(2)
		end)

		-- Panel 2: gauge defaults with valueDisplayMode color, overrides for
		-- lcd/text, hidden and a continuous-GrYlRd MTTR, no max (the range
		-- spans every number field, so 92 groups is a sliver of 5400).
		it("follows valueDisplayMode and the field range", function()
			local panel, frames = cells(version, 2)
			local tbl = Table.build(panel, frames, env, OPTS)
			local groups = tbl.rows[1][col(tbl, "Groups")]
			expect(groups.value_mode).toBe("color")
			expect(groups.tone).toBe("error")
			expect(math.abs(groups.percent - 92 / 5400) < 1e-12).toBe(true)
			expect(tbl.rows[1][col(tbl, "LCD")].gauge_mode).toBe("lcd")
			local mttr = tbl.rows[1][col(tbl, "MTTR")]
			expect(mttr.text).toBe("2 hours")
			expect(tokens(mttr.parts)).toEqual({ "success", "warning", "error" })
			expect(tokens(tbl.rows[4][col(tbl, "MTTR")].parts)).toEqual({ "success" })
			local node = Table.view(panel, frames, env, OPTS)
			local gauges = gaugeCells(node)
			-- Four gauge columns, four rows; hidden draws no value.
			expect(#gauges).toBe(16)
			local first = gauges[1]
			expect(first.c[2].c[1].p.spans[1]).toEqual({ t = "92", s = "error" })
			expect(gauges[2].c[1].p.style).toBe("blocks")
			expect(gauges[3].c[2]).toBeNil()
		end)

		-- Panel 3: pill tags, markdown notes, a json-view payload, color-text
		-- errors and Load as color-background with applyToRow.
		it("draws pill, markdown and json-view cells", function()
			local panel, frames = cells(version, 3)
			local tbl = Table.build(panel, frames, env, OPTS)
			local tags = tbl.rows[1][col(tbl, "Tags")]
			expect(tags.kind).toBe("pill")
			-- getColorByStringHash over classicColors, as Grafana colored
			-- them: prod #F29191, eu #1F78C1, web #052B51.
			expect(tags.pills).toEqual({
				{ text = "prod", class = "tgp-pill-20" },
				{ text = "eu", class = "tgp-pill-5" },
				{ text = "web", class = "tgp-pill-45" },
			})
			expect(tbl.rows[3][col(tbl, "Tags")].pills).toEqual({ { text = "dev", class = "tgp-pill-26" } })
			expect(column(tbl, "Payload")).toEqual({ '{ "v": 1 }', "[ 1, 2 ]", "{}" })
			local node = Table.view(panel, frames, env, OPTS)
			local md = S.find(node, function(n)
				return n.k == "md"
			end)
			expect(md.p.text).toBe("**hot** path")
		end)

		-- applyToRow fills every cell of the row in Load's color except
		-- pills (Grafana's PillCell keeps its own background); color-text
		-- keeps its own text color on it.
		it("fills rows by an applyToRow column", function()
			local panel, frames = cells(version, 3)
			local tbl = Table.build(panel, frames, env, OPTS)
			local row = tbl.rows[2]
			for _, head in { "Service", "Notes", "Payload", "Errors", "Usage" } do
				expect(row[col(tbl, head)].bg_tone).toBe("error")
				expect(row[col(tbl, head)].bg_mode).toBe("gradient")
			end
			expect(row[col(tbl, "Tags")].bg_tone).toBeNil()
			expect(tbl.rows[1][col(tbl, "Service")].bg_tone).toBe("success")
			local node = Table.view(panel, frames, env, OPTS)
			local errors = S.find(node, function(n)
				return n.k == "text" and n.p.spans[1].t == "91"
			end)
			expect(errors.p.spans[1].s).toBe("error")
		end)
	end)
end

describe("table cell options", function()
	local function panelWith(defaults: any, overrides: any?): any
		return {
			type = "table",
			fieldConfig = { defaults = { custom = defaults }, overrides = overrides or {} },
		}
	end

	-- Cell types whose text fallback would misrepresent the cell ladder
	-- with their name, from defaults, overrides or a legacy displayMode.
	it("ladders the cell types it does not draw", function()
		for _, kind in { "sparkline", "image", "data-links", "actions", "custom" } do
			expect(Table.unsupported(panelWith({ cellOptions = { type = kind } }), env)).toBe(
				"table cell type " .. kind .. " is not supported"
			)
		end
		local override = panelWith({}, {
			{
				matcher = { id = "byName", options = "url" },
				properties = { { id = "custom.displayMode", value = "image" } },
			},
		})
		expect(Table.unsupported(override, env)).toBe("table cell type image is not supported")
		for _, kind in { "auto", "color-text", "color-background", "gauge", "pill", "markdown", "json-view" } do
			expect(Table.unsupported(panelWith({ cellOptions = { type = kind } }), env)).toBeNil()
		end
	end)

	-- getCellOptions: a legacy displayMode wins and migrates; pill and
	-- markdown only draw string fields.
	it("migrates legacy display modes and falls back like getCellRenderer", function()
		local panel, frames = cells(S.VERSIONS[#S.VERSIONS], 1)
		panel = S.clone(panel)
		panel.fieldConfig.defaults.custom.displayMode = "lcd-gauge"
		local tbl = Table.build(panel, frames, env, OPTS)
		expect(tbl.rows[1][col(tbl, "Device")].kind).toBe("gauge")
		expect(tbl.rows[1][col(tbl, "Charge")].gauge_mode).toBe("lcd")
		panel.fieldConfig.defaults.custom.displayMode = "color-background-solid"
		tbl = Table.build(panel, frames, env, OPTS)
		expect(tbl.rows[1][col(tbl, "Device")].bg_mode).toBe("basic")
		panel.fieldConfig.defaults.custom.displayMode = nil
		panel.fieldConfig.defaults.custom.cellOptions = { type = "pill" }
		tbl = Table.build(panel, frames, env, OPTS)
		expect(tbl.rows[1][col(tbl, "Device")].kind).toBe("pill")
		expect(tbl.rows[1][col(tbl, "Remaining")].kind).toBe("auto")
	end)
end)

return nil
