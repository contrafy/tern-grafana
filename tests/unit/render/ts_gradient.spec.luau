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

return nil
