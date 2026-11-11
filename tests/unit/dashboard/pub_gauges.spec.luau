--!strict
-- tern-pub-gauges in the dashboard block (synthetic copies of public
-- dashboards' small gauges and stats): a bar gauge's names sit whole
-- inside their column, a gauge saved by Grafana 13 keeps its gradient,
-- sparkline and threshold ring there, and the 2-row stats draw their
-- values at Grafana's size.
local S = require("./support")
local Stat = require("../../../plugin/lib/panels/stat")
local State = require("../../../plugin/lib/dashboard/state")
local View = require("../../../plugin/lib/dashboard/view")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function fixtureFor(version: string, tag: string): string?
	if string.match(tag, "^dash/") then
		return S.grafana(version, "dashboard_tern_pub_gauges.json")
	elseif string.match(tag, "^fs/") then
		return S.grafana(version, "frontend_settings.json")
	elseif string.match(tag, "^flag/") then
		return S.grafana(version, "ofrep_table_auto_column_widths.json")
	elseif string.match(tag, "^user/") then
		return S.grafana(version, "user.json")
	end
	local id = string.match(tag, "^q/%d+/%d+/p(%d+)$")
	return if id then S.grafana(version, "ds_query_pub_gauges_" .. id .. ".json") else nil
end

-- Every panel's SVG, by asset key.
local function render(version: string): { [string]: string }
	local env = S.env()
	local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=tern-pub-gauges" }, nil, env)
	local h = S.harness(s, env, function(e: any): any
		local path = fixtureFor(version, e.tag)
		return if path then S.response(path) else nil
	end, true)
	S.drive(h, effects)
	local _, assets = View.view(h.s, h.env)
	local out: { [string]: string } = {}
	for k, a in assets :: any do
		out[k] = a.bytes
	end
	return out
end

type Text = { x: number, size: number, anchor: string, s: string }

local function texts(svg: string, class: string): { Text }
	local out: { Text } = {}
	for a, body in string.gmatch(svg, "<text ([^>]*)>([^<]*)</text>") do
		local attrs: string, s: string = a :: string, body :: string
		if string.match(attrs, 'class="([^"]*)"') == class then
			local text: Text = {
				x = assert(tonumber(string.match(attrs, ' x="([%d.%-]+)"'))),
				size = assert(tonumber(string.match(attrs, 'font%-size="([%d.]+)"'))),
				anchor = assert(string.match(attrs, 'text%-anchor="(%a+)"')) :: string,
				s = s,
			}
			table.insert(out, text)
		end
	end
	return out
end

for _, version in S.VERSIONS do
	describe("tern-pub-gauges on Grafana " .. version, function()
		-- Panel 1 "Pressure" (public 1860): a 3x4 bar gauge, names left of
		-- the bars. The name column is the widest name's drawn width: "Mem"
		-- (M is Geist's widest capital) lost its M when the column assumed
		-- 0.55 em per glyph and was set by "CPU", the first 3-letter name.
		it("draws every bar gauge name whole inside the panel", function()
			local svg = render(version).p1
			local names = texts(svg, "tgg-text")
			local seen: { string } = {}
			for _, n in names do
				table.insert(seen, n.s)
				expect(n.anchor).toBe("end")
				expect(n.x - Stat.textEm(n.s) * n.size >= 0).toBe(true)
			end
			expect(seen).toEqual({ "CPU", "Mem", "I/O" })
			-- The column fits the names only: the bars start right after it.
			local barX = assert(tonumber(string.match(svg, '<rect class="tgb%-empty tg%-bar" x="([%d.]+)"')))
			expect(barX).toBe(names[1].x + 10)
			expect(barX <= Stat.textEm("Mem") * names[1].size + 15 + 0.05).toBe(true)
		end)

		-- Panel 5: names above lcd bars, the longest cut to the panel width.
		it("fits names above the bars into the panel width", function()
			local svg = render(version).p5
			local width = assert(tonumber(string.match(svg, 'viewBox="0 0 ([%d.]+)')))
			local names = texts(svg, "tgg-text")
			expect(#names).toBe(4)
			for _, n in names do
				expect(n.anchor).toBe("start")
				expect(n.x + Stat.textEm(n.s) * n.size <= width).toBe(true)
			end
			expect(names[1].s).toBe("CPU Busy")
		end)

		-- Panel 7 "Memory Usage" (node-mixin), saved with pluginVersion
		-- "v13.0.0" and no options: gaugePanelMigrationHandler leaves it
		-- alone (parseFloat("v13.0.0") is NaN), so 13 draws gauge/v2's
		-- defaults; 11.6 and 12.4 without newGauge draw gauge/v1.
		it("keeps a v13 gauge's gradient, sparkline and threshold ring on 13 only", function()
			local svg = render(version)["p7.g1"]
			local v2 = version == "13.3.1"
			expect(string.find(svg, 'stroke="url(#tgq', 1, true) ~= nil).toBe(v2)
			expect(string.find(svg, "tg-area", 1, true) ~= nil).toBe(v2)
			-- The ring: the threshold steps' colors outside the bar.
			for _, gc in { "tg-gc93", "tg-gc160", "tg-gc12" } do
				expect(string.find(svg, gc, 1, true) ~= nil).toBe(true)
			end
		end)

		-- Panels 2-4: 2x2 stats. 11.6's 32 px header leaves BigValue a 15 px
		-- value; 12.4's newPanelPadding and 13's 40 px header leave 8.
		it("sizes the 2-row stat values like Grafana", function()
			local svgs = render(version)
			local px = if version == "11.6.16" then 15 else 8
			local want: { [string]: string } = { ["p2.v1"] = "23 hours", ["p3.v1"] = "10", ["p4.v1"] = "8 GiB" }
			for key, text in want do
				local svg = svgs[key]
				local s = assert(string.match(svg, ">([^<]+)</text>"))
				expect(s).toBe(text)
				expect(tonumber(string.match(svg, 'font%-size="([%d.]+)"'))).toBe(px)
				local w = assert(tonumber(string.match(svg, 'viewBox="0 0 (%d+)')))
				expect(w >= Stat.textEm(text) * px).toBe(true)
			end
		end)
	end)
end

return nil
