--!strict
-- Axis tick labels must read like Grafana's: UPlotAxisBuilder values() passes
-- guessDecimals(roundDecimals(tickIncr, 6)) to the field display processor
-- (displayProcessor.ts adjacentDecimals), which drops trailing zeros, and a
-- whole increment leaves every tick its unit's automatic decimals.
local t = require("../../lib/test")
local Kit = require("../../../plugin/lib/render/svg_kit")
local describe, it, expect = t.describe, t.it, t.expect

local MIB = 1024 * 1024

describe("Kit.tickLabels", function()
	it("gives each tick its own automatic decimals on a whole step", function()
		expect(Kit.tickLabels({ 1000, 1500, 2000, 2500 }, "watt")).toEqual({ "1 kW", "1.50 kW", "2 kW", "2.50 kW" })
		expect(Kit.tickLabels({ 0, 512 * MIB, 1024 * MIB, 1536 * MIB }, "bytes")).toEqual({
			"0 B",
			"512 MiB",
			"1 GiB",
			"1.50 GiB",
		})
		expect(Kit.tickLabels({ 0, 8, 16, 24 }, "gbytes")).toEqual({ "0 GiB", "8 GiB", "16 GiB", "24 GiB" })
	end)

	it("formats a fractional step with its decimals, trailing zeros dropped", function()
		expect(Kit.tickLabels({ 0, 0.25, 0.5, 0.75, 1 }, nil)).toEqual({ "0", "0.25", "0.5", "0.75", "1" })
		expect(Kit.tickLabels({ 0, 0.2, 0.4 }, "percentunit")).toEqual({ "0%", "20%", "40%" })
		-- The 0.2 s step asks for 1 decimal; ms ticks lose the excess zeros.
		expect(Kit.tickLabels({ 0.2, 0.4, 0.6 }, "s")).toEqual({ "200 ms", "400 ms", "600 ms" })
		-- Float noise in the step is rounded away at 6 decimals.
		expect(Kit.tickLabels({ 0.1, 0.30000000000000004 - 0.1, 0.3 }, nil)).toEqual({ "0.1", "0.2", "0.3" })
	end)

	-- Currency, locale, boolean and date units ignore the adjacent decimals.
	it("keeps automatic decimals for currency and locale units", function()
		expect(Kit.tickLabels({ 0, 0.5, 1 }, "currencyUSD")).toEqual({ "$0", "$0.500", "$1" })
		expect(Kit.tickLabels({ 0, 0.5, 1 }, "locale")).toEqual({ "0", "0.5", "1" })
	end)

	it("lets a panel's decimals win", function()
		expect(Kit.tickLabels({ 1000, 1500 }, "watt", 1)).toEqual({ "1.0 kW", "1.5 kW" })
	end)
end)

-- UPlotAxisBuilder: decimals 0 on a linear axis labels only whole ticks
-- (Grafana shows 0, 1, 2, 3 where rounding would print 0, 1, 1, 2, 2, 3).
describe("Kit.tickLabels decimals 0", function()
	it("leaves fractional ticks unlabeled", function()
		expect(Kit.tickLabels({ 0, 0.5, 1, 1.5, 2 }, nil, 0)).toEqual({ "0", "", "1", "", "2" })
	end)
end)

return nil
