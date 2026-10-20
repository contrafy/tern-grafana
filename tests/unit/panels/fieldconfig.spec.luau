--!strict
-- Field config resolution and the display processor, as in
-- packages/grafana-data/src/field/fieldOverrides.ts (applyFieldOverrides,
-- setFieldConfigDefaults), field/fieldState.ts (calculateFieldDisplayName),
-- field/displayProcessor.ts + scale.ts (unit text, threshold color, percent)
-- and transformations/matchers/nameMatcher.ts. These decide what every
-- native panel prints and in which color.
local t = require("../../lib/test")
local FieldConfig = require("../../../plugin/lib/panels/fieldconfig")
local Interpolate = require("../../../plugin/lib/dashboard/interpolate")
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

		-- A legend written with field macros (fieldOverrides.ts
		-- stringOverrideProcessor with the field's scopedVars, resolved by
		-- public/app/features/templating/dataMacros.ts fieldMacro and
		-- seriesNameMacro): every series reads its own labels next to the
		-- dashboard variables, never the template text.
		it("resolves ${__field.*} and ${__series.name} per field in displayName, with dashboard variables", function()
			local panel = S.clone(S.panel(version, 7))
			panel.fieldConfig.defaults.displayName = "${__field.labels.job} on $env (${__field.name})"
			panel.fieldConfig.overrides = {
				{
					matcher = { id = "byName", options = 'up{env="dev", instance="node-exporter:9100", job="node"}' },
					properties = {
						{
							id = "displayName",
							value = "${__field.labels}|${__field.labels.missing}|${__field.labels.__values}|${__series.name}",
						},
					},
				},
				{
					matcher = { id = "byName", options = 'up{instance="node-exporter:9999", job="down"}' },
					properties = { { id = "displayName", value = "${__field.labels.missing}" } },
				},
			}
			local scope = { env = Interpolate.value("prod") }
			local replaced = FieldConfig.withVariables(panel, env, function(s: string): string
				return Interpolate.replace(s, scope)
			end)
			local items = FieldConfig.resolve(replaced, S.frames(version, "prom_instant"), env)
			expect(items[2].name).toBe("alertmanager on prod (up)")
			expect(items[4].name).toBe(
				'__name__="up", env="dev", instance="node-exporter:9100", job="node"|'
					.. '|dev, node, node-exporter:9100, up|up{env="dev", instance="node-exporter:9100", job="node"}'
			)
			-- A name that reads "" is no displayName: the series keeps its own.
			expect(items[6].name).toBe('up{instance="node-exporter:9999", job="down"}')
			-- The dashboard JSON itself is left as written.
			expect(panel.fieldConfig.defaults.displayName).toBe("${__field.labels.job} on $env (${__field.name})")
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

	-- calculateFieldDisplayName ends with getUniqueFieldName: a joined
	-- table's repeated columns are "Time 1"/"Time 2", the names organize,
	-- renameByName and sortBy refer to. A time field without labels keeps
	-- its plain name (the early return comes first, as in Grafana).
	it("numbers repeated field names within a frame (getUniqueFieldName)", function()
		local joined: Frame.Frame = {
			fields = {
				Frame.field("Time", "time", { 0 }, {}),
				Frame.field("x", "number", { 1 }),
				Frame.field("Time", "time", { 0 }, {}),
			},
		}
		expect(FieldConfig.displayName(joined.fields[1], joined, { joined })).toBe("Time 1")
		expect(FieldConfig.displayName(joined.fields[2], joined, { joined })).toBe("x")
		expect(FieldConfig.displayName(joined.fields[3], joined, { joined })).toBe("Time 2")
		local plain: Frame.Frame =
			{ fields = { Frame.field("Time", "time", { 0 }), Frame.field("Time", "time", { 0 }) } }
		expect(FieldConfig.displayName(plain.fields[2], plain, { plain })).toBe("Time")
	end)

	it("matches byType and byFrameRefID overrides", function()
		local items = resolve({}, {
			{ matcher = { id = "byType", options = "string" }, properties = { { id = "displayName", value = "S" } } },
			{ matcher = { id = "byFrameRefID", options = "Z" }, properties = { { id = "unit", value = "s" } } },
		})
		expect(items[3].name).toBe("S")
		expect(items[2].config.unit).toBeNil()
	end)

	-- Panels go down the ladder only for what their renderer cannot draw:
	-- the time series renderer honors custom.transform and log/symlog
	-- scales (lib/render/svg_timeseries), the other panels do not.
	it("reports overrides it cannot honor", function()
		local unknown = {
			fieldConfig = {
				defaults = {},
				overrides = { { matcher = { id = "byFieldIndex", options = 1 }, properties = {} } },
			},
		}
		expect(FieldConfig.unsupported(unknown, env)).toBe("override matcher byFieldIndex is not supported")
		local reducer = {
			fieldConfig = {
				defaults = {},
				overrides = {
					{
						matcher = { id = "byValue", options = { reducer = "nope", op = "gt", value = 1 } },
						properties = {},
					},
				},
			},
		}
		expect(FieldConfig.unsupported(reducer, env)).toBe("override matcher byValue reducer nope is not supported")
		local function negY(kind: string): any
			return {
				type = kind,
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
		end
		expect(FieldConfig.unsupported(negY("trend"), env)).toBe(
			"override custom.transform negative-Y is not supported"
		)
		expect(FieldConfig.unsupported(negY("timeseries"), env)).toBeNil()
		local function dist(kind: string, d: string): any
			return {
				type = kind,
				fieldConfig = { defaults = { custom = { scaleDistribution = { type = d, log = 2 } } } },
			}
		end
		expect(FieldConfig.unsupported(dist("xychart", "log"), env)).toBe(
			"field config custom.scaleDistribution log is not supported"
		)
		expect(FieldConfig.unsupported(dist("timeseries", "log"), env)).toBeNil()
		expect(FieldConfig.unsupported(dist("timeseries", "symlog"), env)).toBeNil()
		expect(FieldConfig.unsupported(dist("timeseries", "ordinal"), env)).toBe(
			"field config custom.scaleDistribution ordinal is not supported"
		)
	end)

	-- applyFieldOverrides starts from the frame's field config: what a
	-- datasource or transformation set (configFromData, rowsToFields) beats
	-- the panel defaults, and overrides still apply last.
	it("lets datasource thresholds beat panel defaults, overrides beat both", function()
		local f: Frame.Frame = {
			fields = {
				Frame.field("Time", "time", { 0 }),
				Frame.field("v", "number", { 6 }),
			},
		}
		f.fields[2].config = {
			thresholds = { mode = "absolute", steps = { { color = "green" }, { color = "red", value = 5 } } },
		} :: any
		local panel = { fieldConfig = { defaults = {}, overrides = {} } }
		local items = FieldConfig.resolve(panel, { f }, env)
		expect(FieldConfig.display(items[2], 6).tone).toBe("error")
		expect(FieldConfig.display(items[2], 4).tone).toBe("success")
		panel.fieldConfig.overrides = {
			{
				matcher = { id = "byName", options = "v" },
				properties = {
					{
						id = "thresholds",
						value = { mode = "absolute", steps = { { color = "blue" }, { color = "red", value = 9 } } },
					},
				},
			},
		} :: any
		items = FieldConfig.resolve(panel, { f }, env)
		expect(FieldConfig.display(items[2], 6).tone).toBe("info")
	end)
end)

-- The byValue override matcher (transformations/matchers/
-- fieldValueMatcher.ts, compareValues.ts): a field matches when its
-- reduction compares true against the configured value. Dashboards use it
-- to color or hide series by what they hold (Grafana's hideZero migration
-- is byValue allIsZero).
describe("fieldconfig byValue matcher (fieldValueMatcher.ts)", function()
	local frame: Frame.Frame = {
		fields = {
			Frame.field("Time", "time", { 0, 1, 2 }),
			Frame.field("low", "number", { 1, 2, 3 }),
			Frame.field("high", "number", { 40, 90, 60 }),
			Frame.field("zero", "number", { 0, 0, 0 }),
			Frame.field("empty", "number", { Frame.NULL, Frame.NULL, Frame.NULL }),
		},
	}

	local function unitOf(options: any): { [string]: string? }
		local items = FieldConfig.resolve({
			fieldConfig = {
				defaults = {},
				overrides = {
					{ matcher = { id = "byValue", options = options }, properties = { { id = "unit", value = "X" } } },
				},
			},
		}, { frame }, env)
		local out: { [string]: string? } = {}
		for _, item in items do
			out[item.name] = item.config.unit
		end
		return out
	end

	it("compares the reduced field with gt, gte, lt, lte, eq and neq", function()
		local gt = unitOf({ reducer = "max", op = "gt", value = 50 })
		expect(gt.high).toBe("X")
		expect(gt.low).toBeNil()
		expect(gt.zero).toBeNil()
		expect(unitOf({ reducer = "mean", op = "gte", value = 2 }).low).toBe("X")
		expect(unitOf({ reducer = "mean", op = "lt", value = 2 }).low).toBeNil()
		expect(unitOf({ reducer = "last", op = "lte", value = 3 }).low).toBe("X")
		expect(unitOf({ reducer = "lastNotNull", op = "eq", value = 60 }).high).toBe("X")
		local neq = unitOf({ reducer = "lastNotNull", op = "neq", value = 60 })
		expect(neq.high).toBeNil()
		expect(neq.low).toBe("X")
	end)

	it("defaults the operator to eq and compares eq as text", function()
		expect(unitOf({ reducer = "max", value = 90 }).high).toBe("X")
		-- `${left}` === `${right}`: 90 equals "90".
		expect(unitOf({ reducer = "max", op = "eq", value = "90" }).high).toBe("X")
	end)

	it("matches allIsZero and allIsNull on their own truth, whatever op and value say", function()
		local zero = unitOf({ reducer = "allIsZero", op = "gte", value = 0 })
		expect(zero.zero).toBe("X")
		expect(zero.low).toBeNil()
		expect(unitOf({ reducer = "allIsNull", op = "lt", value = -1 }).empty).toBe("X")
	end)

	-- compareValues: a missing reduction reads as "null"; gte/lte fall back
	-- to equality, and an ordering against "null" is never true.
	it("treats a missing reduction as null", function()
		local gte = unitOf({ reducer = "max", op = "gte", value = 0 })
		expect(gte.empty).toBeNil()
		expect(gte.zero).toBe("X")
		expect(unitOf({ reducer = "max", op = "gt", value = -1 }).empty).toBeNil()
		expect(FieldConfig.compareValues(nil, "eq", nil)).toBe(true)
		expect(FieldConfig.compareValues(nil, "lte", nil)).toBe(true)
	end)

	it("never matches without a reducer", function()
		local none = unitOf({ op = "gt", value = 0 })
		expect(none.high).toBeNil()
		expect(none.low).toBeNil()
	end)

	-- The override sees the data the panel draws: stat, gauge, bar gauge and
	-- table resolve their field config from their frames.
	it("applies byValue overrides in stat, gauge, bar gauge and table", function()
		local Gauge = require("../../../plugin/lib/panels/gauge")
		local Stat = require("../../../plugin/lib/panels/stat")
		local Table = require("../../../plugin/lib/panels/table")
		local panel = {
			options = { reduceOptions = { calcs = { "lastNotNull" } } },
			fieldConfig = {
				defaults = { unit = "short" },
				overrides = {
					{
						matcher = { id = "byValue", options = { reducer = "max", op = "gt", value = 50 } },
						properties = { { id = "unit", value = "percent" } },
					},
				},
			},
		}
		local frames = { frame }
		local tiles = Stat.tiles(panel, frames, env, { key = "s" })
		local texts: { string } = {}
		for _, tile in tiles do
			table.insert(texts, tile.value)
		end
		expect(table.concat(texts, " ")).toContain("60%")
		expect((string.find(table.concat(texts, " "), "3%", 1, true))).toBeNil()
		local meters = Gauge.meters(panel, frames, env, { key = "g" }, false)
		local labels: { string } = {}
		for _, m in meters do
			table.insert(labels, m.label or "")
		end
		expect(table.concat(labels, " ")).toContain("60%")
		local bars = Gauge.meters(panel, frames, env, { key = "b" }, true)
		expect(#bars).toBe(#meters)
		local tbl = Table.build(panel, frames, env, { key = "t" })
		local units: { [string]: string? } = {}
		for _, c in tbl.columns do
			units[c.head] = c.item.config.unit
		end
		expect(units.high).toBe("percent")
		expect(units.low).toBe("short")
	end)
end)

return nil
