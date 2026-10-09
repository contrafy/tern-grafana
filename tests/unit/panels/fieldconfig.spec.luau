--!strict
-- Field config resolution and the display processor, as in
-- packages/grafana-data/src/field/fieldOverrides.ts (applyFieldOverrides,
-- setFieldConfigDefaults), field/fieldState.ts (calculateFieldDisplayName),
-- field/displayProcessor.ts + scale.ts (unit text, threshold color, percent)
-- and transformations/matchers/nameMatcher.ts. These decide what every
-- native panel prints and in which color.
local t = require("../../lib/test")
local FieldConfig = require("../../../plugin/lib/panels/fieldconfig")
local Frame = require("../../../plugin/lib/frame/types")
local S = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local function itemNamed(items: { FieldConfig.Item }, name: string): FieldConfig.Item
	for _, item in items do
		if item.name == name then
			return item
		end
	end
	error("no item " .. name)
end

local function text(item: FieldConfig.Item, v: any): string
	return FieldConfig.joined(FieldConfig.display(item, v))
end

for _, version in S.VERSIONS do
	describe("fieldconfig on tern-panels, Grafana " .. version, function()
		-- Panel 2 "CPU by mode": unit short, thresholds green / red at 4.
		it("formats with the panel unit and colors by the active threshold step", function()
			local items = FieldConfig.resolve(S.panel(version, 2), S.refFrames(version, "prom_range", "A"), env)
			local idle = itemNamed(items, "idle")
			expect(text(idle, 1500)).toBe("1.50 K")
			expect(FieldConfig.display(idle, 3.99).tone).toBe("success")
			-- A step applies from its own value up (getActiveThreshold).
			expect(FieldConfig.display(idle, 4).tone).toBe("error")
		end)

		-- Panel 3 "Memory": bytes, orange from 4 GiB.
		it("formats bytes with binary prefixes and reads orange as warning", function()
			local items = FieldConfig.resolve(S.panel(version, 3), S.refFrames(version, "prom_range", "A"), env)
			local d = FieldConfig.display(items[2], 4294967296)
			expect(FieldConfig.joined(d)).toBe("4 GiB")
			expect(d.tone).toBe("warning")
		end)

		-- Panel 4: decimals 2, three steps (green, yellow 0.5, red 2) and
		-- color mode palette-classic: values take the series palette color
		-- (fieldColor.ts), the steps only matter once colors are by threshold.
		it("applies fixed decimals, palette colors and multi-step thresholds", function()
			local frames = S.refFrames(version, "prom_range", "A")
			local items = FieldConfig.resolve(S.panel(version, 4), frames, env)
			local d = FieldConfig.display(items[2], 0.6)
			expect(FieldConfig.joined(d)).toBe("0.60 req/s")
			expect(d.class).toBe("tg-s1")
			expect(FieldConfig.display(items[4], 0.6).class).toBe("tg-s2")
			local panel = S.clone(S.panel(version, 4))
			panel.fieldConfig.defaults.color.mode = "thresholds"
			local byValue = FieldConfig.resolve(panel, frames, env)
			expect(FieldConfig.display(byValue[2], 0.6).tone).toBe("warning")
			expect(FieldConfig.display(byValue[2], 2).tone).toBe("error")
			expect(FieldConfig.display(byValue[2], 0.1).tone).toBe("success")
		end)

		-- The Prometheus datasource names series by legendFormat
		-- (displayNameFromDS); a panel displayName replaces it.
		it("names fields by legend, and lets a panel displayName win", function()
			local frames = S.refFrames(version, "prom_range", "A")
			local items = FieldConfig.resolve(S.panel(version, 2), frames, env)
			expect((itemNamed(items, "user").field.labels :: any).mode).toBe("user")
			local panel = S.clone(S.panel(version, 2))
			panel.fieldConfig.defaults.displayName = "CPU"
			local renamed = FieldConfig.resolve(panel, frames, env)
			expect(renamed[2].name).toBe("CPU")
		end)

		-- byName matches the display name; the override's color applies to
		-- that series only (panel 4's fixed purple, retargeted at `user`).
		it("applies byName and byRegexp overrides to matching fields only", function()
			local panel = S.clone(S.panel(version, 4))
			panel.fieldConfig.overrides[1].matcher.options = "user"
			table.insert(panel.fieldConfig.overrides, {
				matcher = { id = "byRegexp", options = "/^(idle|system)$/" },
				properties = { { id = "unit", value = "percent" } :: any, { id = "decimals", value = 0 } },
			})
			local items = FieldConfig.resolve(panel, S.refFrames(version, "prom_range", "A"), env)
			local user = itemNamed(items, "user")
			expect(user.config.color_mode).toBe("fixed")
			expect(FieldConfig.seriesColor(user).tone).toBe("accent")
			expect(itemNamed(items, "idle").config.color_mode).toBe("palette-classic")
			expect(text(itemNamed(items, "system"), 12.6)).toBe("13%")
			expect(text(itemNamed(items, "user"), 12.6)).toBe("12.60 req/s")
		end)

		-- Without min/max the scale spans every number field of the panel
		-- (findNumericFieldMinMax), so percents compare series fairly.
		it("uses the global data range when min/max are unset", function()
			local items = FieldConfig.resolve(S.panel(version, 2), S.refFrames(version, "prom_range", "A"), env)
			local idle = itemNamed(items, "idle")
			local nice = itemNamed(items, "nice")
			expect(idle.range_min).toBe(0)
			expect(nice.range_max).toBe(idle.range_max)
			expect(FieldConfig.display(nice, idle.range_max).percent).toBe(1)
		end)

		-- Panel 7: min 0 / max 1 fix the range regardless of the data.
		it("uses configured min/max for percent", function()
			local items = FieldConfig.resolve(S.panel(version, 7), S.frames(version, "prom_instant"), env)
			local d = FieldConfig.display(items[2], 0.25)
			expect(d.percent).toBe(0.25)
			expect(FieldConfig.joined(d)).toBe("25%")
		end)

		it("formats time fields as dates", function()
			local items = FieldConfig.resolve(S.panel(version, 2), S.refFrames(version, "prom_range", "A"), env)
			expect(items[1].field.type).toBe("time")
			expect(text(items[1], 0)).toBe("1970-01-01 00:00:00")
		end)
	end)
end

describe("fieldconfig display edge cases (displayProcessor.ts)", function()
	local frame: Frame.Frame = {
		fields = {
			Frame.field("Time", "time", { 0 }),
			Frame.field("Value", "number", { 1 }, { job = "api" }),
			Frame.field("state", "string", { "ok" }),
			Frame.field("ok", "boolean", { true }),
		},
	}

	local function resolve(defaults: any, overrides: any?): { FieldConfig.Item }
		return FieldConfig.resolve(
			{ fieldConfig = { defaults = defaults, overrides = overrides or {} } },
			{ frame },
			env
		)
	end

	it("shows noValue for missing values and keeps the base color", function()
		local items = resolve({ noValue = "n/a" })
		local d = FieldConfig.display(items[2], Frame.NULL)
		expect(d.text).toBe("n/a")
		expect(d.tone).toBe("success")
	end)

	it("applies Grafana's default thresholds (green, red at 80) when none are set", function()
		local items = resolve({})
		expect(FieldConfig.display(items[2], 79).tone).toBe("success")
		expect(FieldConfig.display(items[2], 80).tone).toBe("error")
	end)

	-- ThresholdsMode.Percentage compares percent * 100 of the field range.
	it("supports percentage thresholds against min/max", function()
		local items = resolve({
			min = 0,
			max = 200,
			thresholds = { mode = "percentage", steps = { { color = "green" }, { color = "red", value = 50 } } },
		})
		expect(FieldConfig.display(items[2], 99).tone).toBe("success")
		expect(FieldConfig.display(items[2], 100).tone).toBe("error")
	end)

	it("lets a mapping's color replace the threshold color", function()
		local items = resolve({
			mappings = { { type = "value", options = { ["1"] = { text = "one", color = "blue" } } } },
		})
		local d = FieldConfig.display(items[2], 1)
		expect(d.text).toBe("one")
		expect(d.tone).toBe("info")
	end)

	it("prints strings as-is and booleans as True/False", function()
		local items = resolve({})
		expect(FieldConfig.display(items[3], "ok").text).toBe("ok")
		expect(FieldConfig.display(items[4], true).text).toBe("True")
		expect(FieldConfig.display(items[4], false).text).toBe("False")
	end)

	it("names a single-label series by its label value (getSingleLabelName)", function()
		local items = resolve({})
		expect(items[2].name).toBe("api")
		expect(items[3].name).toBe("state")
	end)

	it("matches byType and byFrameRefID overrides", function()
		local items = resolve({}, {
			{ matcher = { id = "byType", options = "string" }, properties = { { id = "displayName", value = "S" } } },
			{ matcher = { id = "byFrameRefID", options = "Z" }, properties = { { id = "unit", value = "s" } } },
		})
		expect(items[3].name).toBe("S")
		expect(items[2].config.unit).toBeNil()
	end)

	it("reports overrides it cannot honor", function()
		local panel = {
			fieldConfig = {
				defaults = {},
				overrides = { { matcher = { id = "byValue", options = {} }, properties = {} } },
			},
		}
		expect(FieldConfig.unsupported(panel, env)).toBe("override matcher byValue is not supported")
		local negY = {
			fieldConfig = {
				defaults = {},
				overrides = {
					{
						matcher = { id = "byName", options = "tx" },
						properties = { { id = "custom.transform", value = "negative-Y" } },
					},
				},
			},
		}
		expect(FieldConfig.unsupported(negY, env)).toBe("override custom.transform negative-Y is not supported")
		local log = { fieldConfig = { defaults = { custom = { scaleDistribution = { type = "log", log = 2 } } } } }
		expect(FieldConfig.unsupported(log, env)).toBe("field config custom.scaleDistribution log is not supported")
	end)
end)

return nil
