--!strict
-- Grafana resolves named colors per theme (createVisualizationColors): the
-- class of a dark-theme named color switches to its light shade under Tern's
-- light theme in CSS, while a literal color keeps its value (tg-hex).
local TsGradient = require("../../../plugin/lib/render/ts_gradient")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function hasHex(class: string): boolean
	return string.find(class, "tg-hex", 1, true) ~= nil
end

describe("ts_gradient color classes per theme", function()
	it("leaves named colors on their themed class", function()
		expect(hasHex(TsGradient.stopClass("dark-blue"))).toBe(false)
		-- A threshold or mapping color arrives resolved to its dark shade.
		expect(TsGradient.stopClass("#1F60C4")).toBe(TsGradient.stopClass("dark-blue"))
	end)

	it("keeps a literal color that only has a nearest class", function()
		local class = TsGradient.stopClass("#ad46ff")
		expect(hasHex(class)).toBe(true)
	end)

	-- A fixedColor typed as a hex equal to a named dark shade is still the
	-- user's literal color in Grafana's light theme.
	it("keeps a literal fixed color even when it equals a named shade", function()
		expect(hasHex(TsGradient.fixedClass("#1F60C4"))).toBe(true)
		expect(hasHex(TsGradient.fixedClass("dark-blue"))).toBe(false)
	end)
end)

-- Grafana's pie slice is a radial gradient; Tern draws it as rings, which
-- show as bands unless neighbouring rings are at most one 8-bit step apart.
describe("ts_gradient pie rings", function()
	local function channels(hex: string): { number }
		return {
			tonumber(string.sub(hex, 2, 3), 16) :: number,
			tonumber(string.sub(hex, 4, 5), 16) :: number,
			tonumber(string.sub(hex, 6, 7), 16) :: number,
		}
	end

	it("steps at most one 8-bit level between neighbouring rings", function()
		for _, color in { "#97aab3", "#e97659", "#ffc859", "green", "dark-red" } do
			for _, theme in { "dark", "light" } do
				local rings = TsGradient.pieRings(color, theme :: any, 1000)
				expect(#rings >= 15).toBe(true)
				for i = 2, #rings do
					local a, b = channels(rings[i - 1]), channels(rings[i])
					for j = 1, 3 do
						expect(math.abs(a[j] - b[j]) <= 1).toBe(true)
					end
				end
			end
		end
	end)

	it("uses no more rings than allowed", function()
		local rings = TsGradient.pieRings("#97aab3", "dark", 6)
		expect(#rings).toBe(6)
		expect(rings[1]).toBe("#607684")
		expect(rings[6]).toBe("#7a949d")
	end)
end)

-- fieldColor.ts: a classic palette series takes colors[seriesIndex % 64]
-- of getClassicPalette, so the eleventh series onward gets the darker,
-- lighter and literal colors, not the first ten again (public 11074: the
-- twelfth series, eth0_transmit, is dark-purple in Grafana, not yellow).
describe("ts_gradient classic palette", function()
	it("cycles the whole classic palette", function()
		expect(TsGradient.paletteClass(2)).toBe("tg-s2")
		expect(TsGradient.paletteClass(10)).toBe("tg-s10")
		expect(TsGradient.paletteClass(11)).toBe(TsGradient.stopClass("dark-red"))
		expect(TsGradient.paletteClass(12)).toBe(TsGradient.stopClass("dark-purple"))
		expect(TsGradient.paletteClass(19)).toBe(TsGradient.stopClass("#447EBC"))
		expect(TsGradient.paletteClass(65)).toBe("tg-s1")
		expect(TsGradient.paletteColor(12)).toBe("dark-purple")
	end)
end)

return nil
