--!strict
-- Rung C of the rendering ladder: `supports` must say no (with the reason the
-- dashboard shows) for anything Tern would draw differently from Grafana,
-- and `view` must draw everything it says yes to.
local t = require("../../lib/test")
local Registry = require("../../../plugin/lib/panels/registry")
local S = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

-- tern-panels: what each panel id is and whether it renders natively.
local EXPECTED: { [number]: { boolean | string } } = {
	[1] = { false, "a row is a layout element, not a panel" },
	[2] = { true },
	[3] = { true },
	[4] = { true },
	[5] = { true },
	[6] = { true },
	[7] = { true },
	[8] = { true },
	[9] = { true },
	[10] = { true },
	[11] = { false, "a row is a layout element, not a panel" },
	[12] = { true },
	[13] = { false, "heatmap panels are not rendered natively yet" },
	[14] = { false, "state-timeline panels are not rendered natively yet" },
	[15] = { false, "a row is a layout element, not a panel" },
	[16] = { true },
	[17] = { true },
	[18] = { false, "the library panel is not resolved" },
}

-- The capture each native panel is rendered from in these specs.
local DATA: { [number]: string } = {
	[2] = "prom_range",
	[3] = "prom_range",
	[4] = "prom_range",
	[5] = "prom_range",
	[6] = "prom2_range",
	[7] = "prom_instant",
	[8] = "prom2_range",
	[9] = "prom_table",
	[12] = "loki_logs",
	[16] = "prom2_range",
	[17] = "prom_range",
}

for _, version in S.VERSIONS do
	describe("registry on tern-panels, Grafana " .. version, function()
		it("supports the native panel types and explains the rest", function()
			for id, want in EXPECTED do
				local ok, reason = Registry.supports(S.panel(version, id), env)
				if ok ~= want[1] or reason ~= want[2] then
					error(string.format("panel %d: got %s %s", id, tostring(ok), tostring(reason)))
				end
			end
		end)

		it("draws every supported panel under its key", function()
			for id, capture in DATA do
				local key = "p" .. id
				local node, assets = Registry.view(S.panel(version, id), S.frames(version, capture), env, { key = key })
				local keyed = S.find(node, function(n)
					return n.p ~= nil and type(n.p.key) == "string" and string.sub(n.p.key, 1, #key) == key
				end)
				if keyed == nil then
					error("panel " .. id .. " has no keyed node")
				end
				local failed = S.find(node, function(n)
					return n.k == "text"
						and type(n.p.spans) == "table"
						and n.p.spans[1]
						and type(n.p.spans[1].t) == "string"
						and string.find(n.p.spans[1].t, "Panel failed", 1, true) ~= nil
				end)
				if failed then
					error("panel " .. id .. ": " .. S.text(failed))
				end
				local timeseries = S.panel(version, id).type == "timeseries"
				expect(assets[key] ~= nil).toBe(timeseries)
			end
		end)

		it("shows No data for panels without frames", function()
			for _, id in { 5, 7, 8, 9, 12 } do
				local node = Registry.view(S.panel(version, id), {}, env, { key = "k" })
				expect(S.text(node)).toBe("No data")
			end
			local _, assets = Registry.view(S.panel(version, 2), {}, env, { key = "k" })
			expect(string.find(assets.k.bytes, "No data", 1, true) ~= nil).toBe(true)
		end)
	end)
end

describe("registry unsupported reasons", function()
	local function reason(panel: any): string?
		local ok, why = Registry.supports(panel, env)
		expect(ok).toBe(false)
		return why
	end

	it("explains unknown and legacy panel types", function()
		expect(reason({ type = "graph" })).toBe(
			"the legacy graph panel (Grafana migrates it to time series in the browser) is not rendered natively"
		)
		expect(reason({ type = "piechart" })).toBe("panel type piechart is not rendered natively")
		expect(reason({ title = "x" })).toBe("the panel has no type")
		expect(reason("nope")).toBe("the panel is not an object")
	end)

	it("passes on transformation, field config and reducer reasons", function()
		expect(reason({ type = "table", transformations = { { id = "joinByField" } } })).toBe(
			"transformation joinByField is not supported"
		)
		expect(reason({ type = "stat", options = { reduceOptions = { calcs = { "allValues" } } } })).toBe(
			"reducer allValues is not supported"
		)
		expect(reason({
			type = "table",
			fieldConfig = { defaults = { custom = { cellOptions = { type = "sparkline" } } } },
		})).toBe("table cell type sparkline is not supported")
	end)

	it("works without an env for a first look", function()
		expect((Registry.supports({ type = "stat" }))).toBe(true)
	end)
end)

return nil
