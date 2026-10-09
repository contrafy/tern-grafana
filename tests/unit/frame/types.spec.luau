--!strict
-- The Frame model is the contract between every source converter and every
-- renderer; names must read like Grafana's so users recognize their series.
local t = require("../../lib/test")
local Frame = require("../../../plugin/lib/frame/types")
local describe, it, expect = t.describe, t.it, t.expect

describe("Frame.NULL", function()
	-- Dense value arrays keep index alignment with the time field; nil would
	-- end `#values` early and shift every later sample.
	it("is the missing sample, distinct from numbers and nil", function()
		expect(Frame.isNull(Frame.NULL)).toBe(true)
		expect(Frame.isNull(nil)).toBe(true)
		expect(Frame.isNull(0)).toBe(false)
		expect(Frame.isNull(0 / 0)).toBe(false)
		local values = { 1, Frame.NULL, 3 }
		expect(#values).toBe(3)
	end)

	-- Prometheus NaN and +-Inf are real samples but cannot be plotted.
	it("finite() accepts only plottable numbers", function()
		expect(Frame.finite(1.5)).toBe(1.5)
		expect(Frame.finite(Frame.NULL)).toBeNil()
		expect(Frame.finite(0 / 0)).toBeNil()
		expect(Frame.finite(math.huge)).toBeNil()
		expect(Frame.finite(-math.huge)).toBeNil()
		expect(Frame.finite("1")).toBeNil()
	end)
end)

describe("Frame.timeSeries", function()
	it("is one time field and one labelled number field", function()
		local f = Frame.timeSeries({ job = "api" }, { 1000, 2000 }, { 1, Frame.NULL }, { unit = "s" })
		expect(#f.fields).toBe(2)
		expect((Frame.timeField(f) :: Frame.Field).values).toEqual({ 1000, 2000 })
		local nums = Frame.numberFields(f)
		expect(#nums).toBe(1)
		expect(nums[1].labels).toEqual({ job = "api" })
		expect((nums[1].config :: Frame.FieldConfig).unit).toBe("s")
	end)
end)

describe("Frame.displayName", function()
	local function series(
		labels: { [string]: string },
		config: Frame.FieldConfig?,
		name: string?
	): (Frame.Field, Frame.Frame)
		local f = Frame.timeSeries(labels, {}, {}, config, name)
		return f.fields[2], f
	end

	-- The Prometheus datasource default legend: metric{labels}, labels sorted.
	it('defaults to metric{a="b", ...} with sorted labels', function()
		local field, frame = series({ __name__ = "up", job = "node", instance = "h:9100" })
		expect(Frame.displayName(field, frame)).toBe('up{instance="h:9100", job="node"}')
	end)

	it("shows only the metric when it has no other labels", function()
		local field, frame = series({ __name__ = "up" })
		expect(Frame.displayName(field, frame)).toBe("up")
	end)

	it("shows the labels alone for aggregated series without a metric name", function()
		local field, frame = series({ job = "node" })
		expect(Frame.displayName(field, frame)).toBe('{job="node"}')
	end)

	it("falls back to the frame name, then the field name, without labels", function()
		local field, frame = series({}, nil, "sum(rate(x[5m]))")
		expect(Frame.displayName(field, frame)).toBe("sum(rate(x[5m]))")
		local bare, bareFrame = series({})
		expect(Frame.displayName(bare, bareFrame)).toBe("Value")
	end)

	it("prefers an explicit displayName over everything", function()
		local field, frame = series({ __name__ = "up" }, { displayName = "Targets up" })
		expect(Frame.displayName(field, frame, "{{job}}")).toBe("Targets up")
	end)

	-- legendFormat is how dashboards name series; "__auto" means the default.
	it("applies a legend format, treating __auto as the default", function()
		local field, frame = series({ __name__ = "up", job = "node" })
		expect(Frame.displayName(field, frame, "{{job}} up")).toBe("node up")
		expect(Frame.displayName(field, frame, "__auto")).toBe('up{job="node"}')
	end)
end)

describe("Frame.legendFormat", function()
	it("replaces {{ label }} with spaces allowed and missing labels as empty", function()
		local labels = { instance = "a:1", job = "api" }
		expect(Frame.legendFormat("{{ instance }} / {{job}}", labels)).toBe("a:1 / api")
		expect(Frame.legendFormat("{{nope}}-x", labels)).toBe("-x")
		expect(Frame.legendFormat("plain", labels)).toBe("plain")
	end)
end)

return nil
