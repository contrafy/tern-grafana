--!strict
-- renameByRegex, as packages/grafana-data/src/transformations/transformers/
-- renameByRegex.test.ts pins it (https://raw.githubusercontent.com/grafana/
-- grafana/main/packages/grafana-data/src/transformations/transformers/
-- renameByRegex.test.ts), plus the legend names it gives Prometheus series.
local t = require("../../../lib/test")
local T = require("./support")
local Registry = require("../../../../plugin/lib/panels/registry")
local Transform = require("../../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

local function data(): any
	return T.frame({
		T.f("Time", "time", { 3000, 4000, 5000, 6000 }),
		T.f("Value", "number", { 10000.3, 10000.4, 10000.5, 10000.6 }, nil, { displayName = "web-01.example.com" }),
	}, nil, "web-01.example.com")
end

local function rename(regex: string, pattern: string): { string }
	local out = T.one("renameByRegex", { regex = regex, renamePattern = pattern }, { data() })
	return T.names(out[1])
end

describe("renameByRegex (renameByRegex.test.ts)", function()
	it("should rename matches using references", function()
		local out = T.one("renameByRegex", { regex = "([^.]+).example.com", renamePattern = "$1" }, { data() })
		expect(T.names(out[1])).toEqual({ "Time", "web-01" })
		expect(out[1].fields[1].config).toBeNil()
		expect(out[1].fields[2].config).toEqual({ displayName = "web-01" })
		expect(out[1].fields[2].values).toEqual({ 10000.3, 10000.4, 10000.5, 10000.6 })
	end)

	it("should be able to replace globally", function()
		expect(rename("/e/g", "E")).toEqual({ "TimE", "wEb-01.ExamplE.com" })
	end)

	it("should not rename misses", function()
		expect(rename("([^.]+).bad-domain.com", "$1")).toEqual({ "Time", "web-01.example.com" })
	end)

	it("should not rename with empty regex and repacement pattern", function()
		local out = T.one("renameByRegex", { regex = "", renamePattern = "" }, { data() })
		expect(T.names(out[1])).toEqual({ "Time", "web-01.example.com" })
		expect(out[1].fields[1].config).toBeNil()
	end)
end)

describe("renameByRegex as Grafana reads it", function()
	it("replaces only the first match without the g flag, case-insensitively with i", function()
		expect(rename("/e/", "E")).toEqual({ "TimE", "wEb-01.example.com" })
		expect(rename("/WEB-(\\d+)/i", "host $1")).toEqual({ "Time", "host 01.example.com" })
	end)

	it("defaults to regex (.*) and pattern $1, which keeps every name", function()
		local out = T.one("renameByRegex", {}, { data() })
		expect(T.names(out[1])).toEqual({ "Time", "web-01.example.com" })
		expect((out[1].fields[1].config :: any).displayName).toBe("Time")
	end)

	it("leaves the panel on the ladder for a regex Tern cannot compile", function()
		expect(T.unsupported("renameByRegex", { regex = "/(?<=a)b/" })).toContain("renameByRegex")
		-- A variable is only known once interpolated.
		expect(T.unsupported("renameByRegex", { regex = "$pattern(" })).toBeNil()
		local source = data()
		local out = T.run({ { id = "renameByRegex", options = { regex = "$pattern(" } } }, { source })
		expect(T.names(out[1])).toEqual({ "Time", "web-01.example.com" })
	end)
end)

describe("renameByRegex in practice", function()
	for _, version in T.panels.VERSIONS do
		it("renames the matching series for the legend and leaves the rest, Grafana " .. version, function()
			local panel = {
				type = "timeseries",
				targets = { { refId = "A" } },
				transformations = { { id = "renameByRegex", options = { regex = "(i.*)", renamePattern = "cpu $1" } } },
			}
			expect((Registry.supports(panel, T.env))).toBe(true)
			local source = T.panels.refFrames(version, "prom_range", "A")
			local out = Transform.prepare(panel, source, T.env)
			local names = {}
			for i = 1, 4 do
				table.insert(names, T.names(out[i], out)[2])
			end
			expect(names).toEqual({ "cpu idle", "cpu iowait", "cpu irq", "nice" })
			expect(T.names(out[1], out)[1]).toBe("Time")
		end)
	end
end)

return nil
