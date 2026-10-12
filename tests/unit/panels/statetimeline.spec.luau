--!strict
-- State timeline and status history (StateTimelinePanel.tsx,
-- StatusHistoryPanel.tsx, TimelineChart/utils.ts, timeline.ts) on the
-- tern-all-panels panels 24 and 25: `sum by (job) (up)` with value
-- mappings 0 -> down (red), 1 -> up (green) and thresholds red / green at 1.
local Frame = require("../../../plugin/lib/frame/types")
local S = require("./support")
local StateTimeline = require("../../../plugin/lib/panels/statetimeline")
local SvgTimeline = require("../../../plugin/lib/render/svg_timeline")
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

local function range(version: string, id: number): { from_ms: number, to_ms: number }
	local r = S.decode("grafana/" .. version .. "/ds_query_all_panels_" .. id .. ".request.json")
	return { from_ms = tonumber(r.from) :: number, to_ms = tonumber(r.to) :: number }
end

local function count(s: string, needle: string): number
	local n, at = 0, 1
	while true do
		local i = string.find(s, needle, at, true)
		if i == nil then
			return n
		end
		n += 1
		at = i + #needle
	end
end

for _, version in S.VERSIONS do
	describe("state timeline " .. version, function()
		-- One lane per job, named by legendFormat (displayNameFromDS).
		it("draws one lane per series in display name order", function()
			local lanes = StateTimeline.lanes(allPanels(version, 24), S.frames(version, "all_panels_24"), env)
			expect(#lanes).toBe(6)
			expect(lanes[1].item.name).toBe("alertmanager")
			expect(lanes[2].item.name).toBe("down")
		end)

		-- mergeValues with thresholds color mode: values become threshold
		-- steps, so the always-1 jobs are one "1+" box and the down job one
		-- "< 1" box, as in Grafana's render; value mappings do not apply.
		it("merges equal threshold steps into one labeled box per lane", function()
			local time = range(version, 24)
			local node, assets = StateTimeline.view(allPanels(version, 24), S.frames(version, "all_panels_24"), env, {
				key = "st",
				size = { w = 1000, h = 440 },
				time = time,
			})
			local svg = (assets :: any).st.bytes
			expect(count(svg, ">1+</text>")).toBe(5)
			expect(count(svg, ">&lt; 1</text>")).toBe(1)
			expect((string.find(svg, ">up<", 1, true))).toBeNil()
			expect(string.find(svg, 'class="tgp-fx tgp-success tg-bar" fill-opacity="0.70"', 1, true) ~= nil).toBe(true)
			expect(string.find(svg, 'class="tgp-fx tgp-error tg-bar"', 1, true) ~= nil).toBe(true)
			-- lineWidth 0: no outlines.
			expect((string.find(svg, "tg-line", 1, true))).toBeNil()
			local legend = S.find(node, function(n)
				return n.p and n.p.role == "tern-grafana.legend"
			end)
			expect(S.text(legend)).toBe("< 11+")
		end)
	end)

	describe("status history " .. version, function()
		-- No merging: one column per sample, mapped texts cut to what fits.
		it("draws a column per sample with the mapped value text", function()
			local frames = S.frames(version, "all_panels_25")
			local samples = 0
			for _, f in frames do
				local labels = f.fields[2].labels
				if labels and labels.job == "node" then
					samples = #f.fields[2].values
				end
			end
			local _, assets = StateTimeline.view(allPanels(version, 25), frames, env, {
				key = "sh",
				size = { w = 1000, h = 440 },
				time = range(version, 25),
			})
			local svg = (assets :: any).sh.bytes
			expect(samples > 20).toBe(true)
			-- The first sample lies before the panel range and the second
			-- straddles its start: the columns on the plot print, the down
			-- job's as much of "down" as fits a 26 px column.
			local ups = count(svg, ">up</text>")
			expect(ups % 5).toBe(0)
			expect(ups // 5 >= samples - 2).toBe(true)
			expect(count(svg, ">dow</text>")).toBe(ups // 5)
			-- Only the lane label reads "down" in full.
			expect(count(svg, ">down</text>")).toBe(1)
			-- lineWidth 1: outlines at full color.
			expect(string.find(svg, 'class="tgp-fx tgp-success tg-line" stroke-width="1"', 1, true) ~= nil).toBe(true)
		end)
	end)
end

describe("timeline lanes", function()
	-- uPlot distribute, space-between: rowHeight of the plot for lanes,
	-- the rest split into the gaps between them.
	it("spreads lanes like uPlot distribute", function()
		local off1, wid = SvgTimeline.lane(2, 0.9, 1)
		local off2 = SvgTimeline.lane(2, 0.9, 2)
		expect(off1).toBe(0)
		expect(wid).toBe(0.45)
		expect(math.abs(off2 - 0.55) < 1e-9).toBe(true)
	end)

	-- A null ends the state before it; equal values after it start anew.
	it("ends a merged state at a null", function()
		local panel = S.json([[{"type": "state-timeline", "options": {"mergeValues": true, "showValue": "always"},
			"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}}, "overrides": []}}]])
		local f: { Frame.Frame } = {
			{
				fields = {
					Frame.field("Time", "time", { 0, 1000, 2000, 3000 }),
					Frame.field("v", "string", { "a", "a", Frame.NULL, "a" }),
				},
			},
		}
		local _, assets = StateTimeline.view(panel, f, env, {
			key = "n",
			size = { w = 600, h = 120 },
			time = { from_ms = 0, to_ms = 4000 },
		})
		local svg = (assets :: any).n.bytes
		expect(count(svg, ">a</text>")).toBe(2)
	end)

	it("reports frames without time", function()
		local panel = S.json([[{"type": "state-timeline"}]])
		local node = StateTimeline.view(
			panel,
			{ { fields = { Frame.field("v", "number", { 1 }) } } },
			env,
			{ key = "x" }
		)
		expect(S.text(node)).toBe("Data does not have a time field")
	end)
end)

return nil
