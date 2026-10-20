--!strict
-- prepareTimeSeries, as public/app/features/transformers/prepareTimeSeries/
-- prepareTimeSeries.test.ts pins it (https://raw.githubusercontent.com/
-- grafana/grafana/main/public/app/features/transformers/prepareTimeSeries/
-- prepareTimeSeries.test.ts, snapshots in __snapshots__/), plus the time
-- series a grouped Prometheus table feeds.
local t = require("../../../lib/test")
local T = require("./support")
local Registry = require("../../../../plugin/lib/panels/registry")
local Transform = require("../../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

local function prepare(format: string, frames: { any }): { any }
	return T.one("prepareTimeSeries", { format = format }, frames)
end

-- A frame as "name|refId|meta type" plus each field as
-- "name{labels} type: v1, v2, ...".
local function shape(frame: any): { string }
	local out: { string } = {
		string.format(
			"%s|%s|%s",
			tostring(frame.name),
			tostring(frame.refId),
			tostring(frame.meta and frame.meta.type)
		),
	}
	for _, f in frame.fields do
		local values: { string } = {}
		for _, v in f.values do
			table.insert(values, tostring(v))
		end
		local labels: { string } = {}
		for k, v in f.labels or {} do
			table.insert(labels, k .. "=" .. v)
		end
		table.sort(labels)
		local l = if f.labels then "{" .. table.concat(labels, ",") .. "}" else ""
		table.insert(out, f.name .. l .. " " .. f.type .. ": " .. table.concat(values, ", "))
	end
	return out
end

local function shapes(frames: { any }): { { string } }
	local out: { { string } } = {}
	for _, f in frames do
		table.insert(out, shape(f))
	end
	return out
end

local function longFrame(name: string?, kind: string?): any
	local f = T.frame({
		T.f("time", "time", { 1, 1, 2, 2, 3, 3 }),
		T.f("value", "number", { 10, 20, 30, 40, 50, 60 }),
		T.f("region", "string", { "a", "b", "a", "b", "a", "b" }),
	}, "X", name)
	if kind then
		f.meta = { type = kind }
	end
	return f
end

describe("prepareTimeSeries (prepareTimeSeries.test.ts)", function()
	it("should transform wide to multi", function()
		local source = T.frame({
			T.f("time", "time", { 1, 2, 3, 4, 5, 6 }),
			T.f("count", "number", { 10, 20, 30, 40, 50, 60 }),
			T.f("more", "number", { 2, 3, 4, 5, 6, 7 }),
		}, "A", "wide")
		expect(shapes(prepare("multi", { source }))).toEqual({
			{ "wide|A|timeseries-multi", "time time: 1, 2, 3, 4, 5, 6", "count number: 10, 20, 30, 40, 50, 60" },
			{ "wide|A|timeseries-multi", "time time: 1, 2, 3, 4, 5, 6", "more number: 2, 3, 4, 5, 6, 7" },
		})
	end)

	it("should treat string fields as labels", function()
		local source = T.frame({
			T.f("time", "time", { 1, 1, 2, 2 }),
			T.f("region", "string", { "a", "b", "a", "b" }),
			T.f("count", "number", { 10, 20, 30, 40 }),
			T.f("more", "number", { 2, 3, 4, 5 }),
		}, "A", "wide")
		expect(shapes(prepare("multi", { source }))).toEqual({
			{ "wide|A|timeseries-multi", "time time: 1, 2", "count{region=a} number: 10, 30" },
			{ "wide|A|timeseries-multi", "time time: 1, 2", "count{region=b} number: 20, 40" },
			{ "wide|A|timeseries-multi", "time time: 1, 2", "more{region=a} number: 2, 4" },
			{ "wide|A|timeseries-multi", "time time: 1, 2", "more{region=b} number: 3, 5" },
		})
	end)

	it("should transform all wide to multi when mixed", function()
		local wide = T.frame({
			T.f("time", "time", { 0, 1, 2, 3, 4, 5 }),
			T.f("count", "number", { 10, 20, 30, 40, 50, 60 }),
			T.f("another", "number", { 2, 3, 4, 5, 6, 7 }),
		}, "A", "wide")
		local long = T.frame({
			T.f("time", "time", { 4, 5, 6, 7, 8, 9 }),
			T.f("value", "number", { 2, 3, 4, 5, 6, 7 }),
		}, "B", "long")
		-- Value fields come out sorted by name.
		expect(shapes(prepare("multi", { wide, long }))).toEqual({
			{ "wide|A|timeseries-multi", "time time: 0, 1, 2, 3, 4, 5", "another number: 2, 3, 4, 5, 6, 7" },
			{ "wide|A|timeseries-multi", "time time: 0, 1, 2, 3, 4, 5", "count number: 10, 20, 30, 40, 50, 60" },
			{ "long|B|timeseries-multi", "time time: 4, 5, 6, 7, 8, 9", "value number: 2, 3, 4, 5, 6, 7" },
		})
	end)

	it("should transform none when source only has long frames", function()
		local function long(ref: string): any
			return T.frame({
				T.f("time", "time", { 1, 2, 3, 4, 5, 6 }),
				T.f("count", "number", { 10, 20, 30, 40, 50, 60 }),
			}, ref, "long")
		end
		expect(shapes(prepare("multi", { long("A"), long("B") }))).toEqual({
			{ "long|A|timeseries-multi", "time time: 1, 2, 3, 4, 5, 6", "count number: 10, 20, 30, 40, 50, 60" },
			{ "long|B|timeseries-multi", "time time: 1, 2, 3, 4, 5, 6", "count number: 10, 20, 30, 40, 50, 60" },
		})
	end)

	it("should return empty array when no timeseries exist", function()
		local function text(ref: string): any
			local v = { "a", "z", "b", "x", "c", "b" }
			return T.frame(
				{ T.f("text", "string", v), T.f("text", "string", v), T.f("text", "string", v) },
				ref,
				"wide"
			)
		end
		expect(#prepare("multi", { text("A"), text("B") })).toBe(0)
	end)

	it("should convert long to multi", function()
		expect(shapes(prepare("multi", { longFrame("long") }))).toEqual({
			{ "long|X|timeseries-multi", "time time: 1, 2, 3", "value{region=a} number: 10, 30, 50" },
			{ "long|X|timeseries-multi", "time time: 1, 2, 3", "value{region=b} number: 20, 40, 60" },
		})
	end)

	it("should migrate many to multi and still convert correctly", function()
		expect(shapes(prepare("many", { longFrame("wants-to-be-many") }))).toEqual({
			{ "wants-to-be-many|X|timeseries-multi", "time time: 1, 2, 3", "value{region=a} number: 10, 30, 50" },
			{ "wants-to-be-many|X|timeseries-multi", "time time: 1, 2, 3", "value{region=b} number: 20, 40, 60" },
		})
	end)

	local function sensors(): any
		local f = T.frame({
			T.f("time", "time", { 1, 1, 2, 2, 3, 3 }),
			T.f("speed", "number", { 4, 5, 6, 7, 8, 9 }),
			T.f("sensor", "string", { "a", "b", "a", "b", "a", "b" }),
		}, "A")
		f.meta = { type = "timeseries-long" }
		return f
	end

	it("should handle long to wide", function()
		expect(shapes(prepare("wide", { sensors() }))).toEqual({
			{
				"nil|nil|timeseries-wide",
				"time{sensor=a} time: 1, 2, 3",
				"speed{sensor=a} number: 4, 6, 8",
				"speed{sensor=b} number: 5, 7, 9",
			},
		})
	end)

	it("should handle long to multi", function()
		expect(shapes(prepare("multi", { sensors() }))).toEqual({
			{ "nil|A|timeseries-multi", "time time: 1, 2, 3", "speed{sensor=a} number: 4, 6, 8" },
			{ "nil|A|timeseries-multi", "time time: 1, 2, 3", "speed{sensor=b} number: 5, 7, 9" },
		})
	end)
end)

describe("prepareTimeSeries as Grafana reads it", function()
	it("defaults to wide: separate series joined on time into one frame", function()
		local a = T.frame({ T.f("time", "time", { 1, 2 }), T.f("a", "number", { 1, 2 }) }, "A")
		local b = T.frame({ T.f("time", "time", { 2, 3 }), T.f("b", "number", { 5, 6 }) }, "B")
		local out = T.one("prepareTimeSeries", {}, { a, b })
		expect(#out).toBe(1)
		expect((out[1].meta :: any).type).toBe("timeseries-wide")
		expect(T.fieldNames(out[1])).toEqual({ "time", "a", "b" })
		expect(out[1].fields[1].values).toEqual({ 1, 2, 3 })
		expect(out[1].fields[3].values).toEqual({ T.NULL, 5, 6 })
	end)

	it("long: rows sorted by time, one per label set, labels as string columns, config dropped", function()
		local source = T.frame({
			T.f("time", "time", { 2, 1 }),
			T.f("Value", "number", { 20, 10 }, { job = "api" }, { unit = "ms" }),
			T.f("Value", "number", { 21, 11 }, { job = "db" }, { unit = "ms" }),
		}, "A")
		local out = prepare("long", { source })
		expect(shapes(out)).toEqual({
			{
				"nil|A|timeseries-long",
				"time time: 1, 1, 2, 2",
				"Value number: 10, 11, 20, 21",
				"job string: api, db, api, db",
			},
		})
		expect(out[1].fields[2].config).toEqual({})
	end)

	it("multi skips the gaps a join left and frames without a time field", function()
		local source = T.frame({
			T.f("time", "time", { 1, 2, 3 }),
			T.f("host", "string", { "a", "a", "a" }),
			T.f("v", "number", { 1, T.NULL, 3 }),
		}, "A")
		local noTime = T.frame({ T.f("v", "number", { 1 }) }, "B")
		-- A null is a value; only undefined (a join gap) is skipped.
		expect(shapes(prepare("multi", { source, noTime }))).toEqual({
			{ "nil|A|timeseries-multi", "time time: 1, 2, 3", "v{host=a} number: 1, " .. tostring(T.NULL) .. ", 3" },
		})
	end)
end)

-- Busy CPU time by mode: the range query as a table, grouped by time and
-- mode, back to one series per mode.
describe("prepareTimeSeries in practice", function()
	for _, version in T.panels.VERSIONS do
		it("a time series draws one line per mode from a grouped table, Grafana " .. version, function()
			local panel = {
				type = "timeseries",
				targets = { { refId = "A", format = "table" } },
				transformations = {
					{
						id = "groupBy",
						options = {
							fields = {
								Time = { operation = "groupby" },
								mode = { operation = "groupby" },
								Value = { operation = "aggregate", aggregations = { "sum" } },
							},
						},
					} :: any,
					{ id = "prepareTimeSeries", options = { format = "multi" } } :: any,
				},
			}
			expect((Registry.supports(panel, T.env))).toBe(true)
			local source = T.panels.refFrames(version, "prom_range", "A")
			local frames = Transform.prepare(panel, source, T.env)
			expect(#frames).toBe(#source)
			expect(T.names(frames[1], frames)).toEqual({ "Time", "Value (sum) idle" })
			expect(frames[1].fields[2].values).toEqual(source[1].fields[2].values)
			local node, assets = Registry.view(panel, source, T.env, { key = "p" })
			local legend = T.panels.text(T.panels.find(node, function(n)
				return n.p and n.p.role == "tern-grafana.legend"
			end))
			expect(string.find(legend, "Value (sum) idle", 1, true) ~= nil).toBe(true)
			expect(#(assets :: any).p.bytes > 0).toBe(true)
		end)

		it("wide joins the per-mode series into one frame, Grafana " .. version, function()
			local source = T.panels.refFrames(version, "prom_range", "A")
			local out = T.one("prepareTimeSeries", { format = "wide" }, source)
			expect(#out).toBe(1)
			expect(#out[1].fields).toBe(1 + #source)
			expect(T.names(out[1])[2]).toBe("idle")
		end)
	end
end)

return nil
