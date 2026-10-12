--!strict
-- The traces panel (TracesPanel.tsx -> TraceView) on tern-all-panels
-- panel 27: a real Tempo trace by id through Grafana's Trace frame.
local S = require("./support")
local Traces = require("../../../plugin/lib/panels/traces")
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
	describe("traces " .. version, function()
		it("builds the trace from the Trace frame", function()
			local tr = Traces.trace(S.frames(version, "all_panels_27"), env)
			assert(tr, "trace")
			expect(#tr.spans > 1).toBe(true)
			expect(tr.spans[1].depth).toBe(0)
		end)

		-- Header facts, then one row per span with its service-colored bar.
		it("draws the header and a waterfall row per span", function()
			local frames = S.frames(version, "all_panels_27")
			local tr = Traces.trace(frames, env)
			assert(tr, "trace")
			local node = Traces.view(allPanels(version, 27), frames, env, { key = "tr", size = { w = 1000, h = 440 } })
			local text = S.text(node)
			expect(text).toContain(tr.root_service .. ": " .. tr.root_name)
			expect(text).toContain("Total spans " .. #tr.spans)
			local bars = S.findAll(node, function(n)
				return n.p and type(n.p.class) == "string" and string.find(n.p.class, "tg-tr-bar", 1, true) ~= nil
			end)
			expect(#bars).toBe(#tr.spans)
		end)

		-- A short panel shows the rows that fit and counts the rest.
		it("counts spans that do not fit", function()
			local frames = S.frames(version, "all_panels_27")
			local tr = Traces.trace(frames, env)
			assert(tr, "trace")
			local node = Traces.view(allPanels(version, 27), frames, env, { key = "tr", size = { w = 1000, h = 120 } })
			if #tr.spans > 3 then
				expect(S.text(node)).toContain(string.format("%d more spans", #tr.spans - 3))
			end
		end)
	end)
end

describe("traces without a trace", function()
	it("shows Grafana's message", function()
		local node = Traces.view(
			S.json([[{"type": "traces"}]]),
			{
				{ fields = { { name = "x", type = "number", values = { 1 } } } },
			} :: any,
			env,
			{ key = "tr" }
		)
		expect(S.text(node)).toBe("No data found in response")
	end)
end)

return nil
