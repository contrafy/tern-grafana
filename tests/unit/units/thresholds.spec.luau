--!strict
-- Grafana semantics from packages/grafana-data/src/field/thresholds.ts
-- (getActiveThreshold), field/scale.ts (percent) and
-- themes/createVisualizationColors.ts (named palette).
local t = require("../../lib/test")
local thresholds = require("../../../plugin/lib/units/thresholds")
local describe, it, expect = t.describe, t.it, t.expect

local JSON_NULL = newproxy(false)

local TRAFFIC: thresholds.Thresholds = {
	mode = "absolute",
	steps = {
		{ value = nil, color = "green" },
		{ value = 50, color = "orange" },
		{ value = 80, color = "red" },
	},
}

local function stepName(value: number?, spec: thresholds.Thresholds?, min: number?, max: number?): string
	return thresholds.active(value, spec, min, max).name
end

describe("thresholds.active absolute", function()
	-- A step applies from its value upward: 80 is already red.
	it("includes the step's own value", function()
		expect(stepName(49.999, TRAFFIC)).toBe("green")
		expect(stepName(50, TRAFFIC)).toBe("orange")
		expect(stepName(79.999, TRAFFIC)).toBe("orange")
		expect(stepName(80, TRAFFIC)).toBe("red")
		expect(stepName(1e300, TRAFFIC)).toBe("red")
	end)

	it("lets the base step catch everything below the first value", function()
		expect(stepName(-1e300, TRAFFIC)).toBe("green")
		expect(stepName(-math.huge, TRAFFIC)).toBe("green")
	end)

	-- Grafana renders NaN and no-value cells in the base color.
	it("uses the base step for nil and NaN", function()
		expect(stepName(nil, TRAFFIC)).toBe("green")
		expect(stepName(0 / 0, TRAFFIC)).toBe("green")
	end)

	-- Grafana sorts steps when it loads a dashboard; raw JSON may be unsorted
	-- and carries the base value as JSON null.
	it("does not depend on step order or the null representation", function()
		local shuffled: thresholds.Thresholds = {
			mode = "absolute",
			steps = {
				{ value = 80, color = "red" },
				{ value = JSON_NULL, color = "green" },
				{ value = 50, color = "orange" },
			},
		}
		expect(stepName(10, shuffled)).toBe("green")
		expect(stepName(50, shuffled)).toBe("orange")
		expect(stepName(95, shuffled)).toBe("red")
	end)

	it("lets the later of two equal steps win, as after a stable sort", function()
		local spec: thresholds.Thresholds = {
			mode = "absolute",
			steps = {
				{ value = nil, color = "green" },
				{ value = 10, color = "blue" },
				{ value = 10, color = "purple" },
			},
		}
		expect(stepName(10, spec)).toBe("purple")
	end)

	it("reports the step index and the value's percent of min..max", function()
		local a = thresholds.active(80, TRAFFIC, 0, 200)
		expect(a.index).toBe(3)
		expect(a.percent).toBe(0.4)
	end)

	it("falls back to Grafana's grey when no steps are configured", function()
		expect(thresholds.active(5, nil)).toEqual({
			index = 0,
			name = "",
			color = "#808080",
			tone = "neutral",
			percent = 0.05,
		})
		expect(thresholds.active(5, { mode = "absolute", steps = {} }).color).toBe("#808080")
	end)
end)

describe("thresholds.active percentage", function()
	local PCT: thresholds.Thresholds = {
		mode = "percentage",
		steps = { { value = nil, color = "green" }, { value = 50, color = "yellow" }, { value = 90, color = "red" } },
	}

	-- Steps are percents of min..max, so the same value changes color when
	-- the range changes.
	it("compares the value's position in min..max against the steps", function()
		expect(stepName(99, PCT, 0, 200)).toBe("green")
		expect(stepName(100, PCT, 0, 200)).toBe("yellow")
		expect(stepName(180, PCT, 0, 200)).toBe("red")
		expect(stepName(100, PCT, 100, 200)).toBe("green")
		expect(stepName(150, PCT, 100, 200)).toBe("yellow")
	end)

	it("assumes 0..100 when no range is known", function()
		expect(stepName(50, PCT)).toBe("yellow")
	end)

	it("treats a zero-width range at the bound as 0 percent", function()
		expect(thresholds.active(5, PCT, 5, 5).percent).toBe(0)
		expect(stepName(5, PCT, 5, 5)).toBe("green")
	end)
end)

describe("thresholds.color", function()
	it("resolves palette names to Grafana's dark-theme hex by default", function()
		expect(thresholds.color("green")).toBe("#73BF69")
		expect(thresholds.color("red")).toBe("#F2495C")
		expect(thresholds.color("semi-dark-orange")).toBe("#FF780A")
		expect(thresholds.color("super-light-blue")).toBe("#C0D8FF")
		expect(thresholds.color("dark-purple")).toBe("#8F3BB8")
		expect(thresholds.color("light-yellow")).toBe("#FFEE52")
	end)

	it("resolves the light theme's palette when asked", function()
		expect(thresholds.color("green", "light")).toBe("#56A64B")
		expect(thresholds.color("text", "light")).toBe("rgba(36, 41, 46, 1)")
		expect(thresholds.color("transparent", "light")).toBe("rgba(255, 255, 255, 0)")
	end)

	it("resolves text and transparent, and passes custom colors through", function()
		expect(thresholds.color("text")).toBe("rgb(204, 204, 220)")
		expect(thresholds.color("transparent")).toBe("rgba(0,0,0,0)")
		expect(thresholds.color("#EAB839")).toBe("#EAB839")
		expect(thresholds.color("rgba(237, 129, 40, 0.89)")).toBe("rgba(237, 129, 40, 0.89)")
		expect(thresholds.color("rebeccapurple")).toBe("rebeccapurple")
	end)

	it("falls back to grey for a missing color", function()
		expect(thresholds.color(nil)).toBe("#808080")
		expect(thresholds.color("")).toBe("#808080")
	end)
end)

describe("thresholds.tone", function()
	-- Severity, not hue fidelity: both orange and yellow mean "watch this".
	it("maps every shade of a palette hue to the same tone", function()
		for _, shade in { "super-light-", "light-", "", "semi-dark-", "dark-" } do
			expect(thresholds.tone(shade .. "green")).toBe("success")
			expect(thresholds.tone(shade .. "red")).toBe("error")
			expect(thresholds.tone(shade .. "orange")).toBe("warning")
			expect(thresholds.tone(shade .. "yellow")).toBe("warning")
			expect(thresholds.tone(shade .. "blue")).toBe("info")
			expect(thresholds.tone(shade .. "purple")).toBe("accent")
		end
	end)

	it("maps text, transparent and missing colors", function()
		expect(thresholds.tone("text")).toBe("neutral")
		expect(thresholds.tone("transparent")).toBe("muted")
		expect(thresholds.tone(nil)).toBe("neutral")
		expect(thresholds.tone("")).toBe("neutral")
		expect(thresholds.tone("rebeccapurple")).toBe("neutral")
	end)

	-- Older dashboards store explicit colors (Grafana 6 defaults #EAB839,
	-- #E24D42, #508642, rgba(...)); classify them by hue.
	it("classifies hex and rgb colors by hue", function()
		expect(thresholds.tone("#E24D42")).toBe("error")
		expect(thresholds.tone("#EF843C")).toBe("warning")
		expect(thresholds.tone("#EAB839")).toBe("warning")
		expect(thresholds.tone("#508642")).toBe("success")
		expect(thresholds.tone("#6ED0E0")).toBe("info")
		expect(thresholds.tone("#1F78C1")).toBe("info")
		expect(thresholds.tone("#BA43A9")).toBe("accent")
		expect(thresholds.tone("#f00")).toBe("error")
		expect(thresholds.tone("rgba(237, 129, 40, 0.89)")).toBe("warning")
		expect(thresholds.tone("rgb(50, 172, 45)")).toBe("success")
	end)

	it("treats greys as neutral and fully transparent colors as muted", function()
		expect(thresholds.tone("#808080")).toBe("neutral")
		expect(thresholds.tone("#FFFFFF")).toBe("neutral")
		expect(thresholds.tone("rgba(255, 0, 0, 0)")).toBe("muted")
		expect(thresholds.tone("#zzz")).toBe("neutral")
	end)

	it("carries tone and resolved color on the active step", function()
		local a = thresholds.active(90, TRAFFIC)
		expect(a.name).toBe("red")
		expect(a.color).toBe("#F2495C")
		expect(a.tone).toBe("error")
		expect(thresholds.active(90, TRAFFIC, nil, nil, "light").color).toBe("#E02F44")
	end)
end)

return nil
