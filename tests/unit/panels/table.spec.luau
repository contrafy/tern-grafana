--!strict
-- The table panel (public/app/plugins/panel/table/panelcfg.cue and its cell
-- renderers): columns are the transformed frame's visible fields, cells go
-- through the display processor, cellOptions pick color-text,
-- color-background or gauge cells, sortBy orders rows, the footer reduces.
local t = require("../../lib/test")
local S = require("./support")
local Table = require("../../../plugin/lib/panels/table")
local Transform = require("../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env
local OPTS = { key = "t" }

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
			expect(column(tbl, "up")).toEqual({ "UP", "UP", "DOWN", "UP", "UP", "UP" })
			expect(column(tbl, "job")[3]).toBe("down")
			local down = tbl.rows[3][4]
			expect(down.kind).toBe("color-background")
			expect(down.tone).toBe("error")
			expect(tbl.rows[1][4].tone).toBe("success")
			expect(tbl.rows[1][1].kind).toBe("auto")
			expect(tbl.columns[4].numeric).toBe(true)
			expect(tbl.columns[1].numeric).toBe(false)
		end)

		it("renders a grid with tinted background cells", function()
			local panel = S.panel(version, 9)
			local node = Table.view(panel, Transform.prepare(panel, S.frames(version, "prom_table"), env), env, OPTS)
			local tinted = S.findAll(node, function(n)
				return n.p and n.p.class == "tgp-bg tgp-error"
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

return nil
