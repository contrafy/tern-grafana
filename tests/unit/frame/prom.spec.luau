--!strict
-- Prometheus results become the same frames Grafana's own Prometheus
-- datasource produces, so a query renders identically whether a context
-- talks to Prometheus directly or through Grafana. NaN and +-Inf are real
-- sample values (division by zero, empty histograms) and must survive as
-- numbers, not as gaps or parse failures.
local Fixtures = require("../../lib/fixtures")
local Frame = require("../../../plugin/lib/frame/types")
local FrameProm = require("../../../plugin/lib/frame/prom")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local VERSIONS = { "2.53.5", "3.15.0" }

local env: any = { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null }

local function result(version: string, name: string): any
	local doc = json.decode(Fixtures.read("prometheus/" .. version .. "/" .. name .. ".json"))
	return FrameProm.result(doc, env)
end

local function value(frame: Frame.Frame): any
	return Frame.numberFields(frame)[1]
end

for _, v in VERSIONS do
	describe("Prometheus " .. v .. " range (matrix)", function()
		it("gives one time series frame per series with its labels", function()
			local r = result(v, "query_range_multi")
			expect(r.ok).toBe(true)
			-- 10 CPUs x 3 modes (user|system|idle) in the dev stack.
			expect(#r.frames).toBe(30)
			local first = r.frames[1]
			expect(first.meta.type).toBe("timeseries-multi")
			local f = value(first)
			expect(f.labels.mode ~= nil).toBe(true)
			expect(f.labels.job).toBe("node")
			local time = Frame.timeField(first) :: Frame.Field
			-- 15 min at 15 s steps, both ends included.
			expect(#time.values).toBe(61)
			expect(#f.values).toBe(61)
			expect(time.values[1]).toBe(1791576998000)
			expect(time.values[61]).toBe(1791577898000)
			expect(type(f.values[1])).toBe("number")
		end)

		it("keeps NaN, +Inf and -Inf as numbers the renderer can skip", function()
			local r = result(v, "query_range_nan_inf")
			expect(#r.frames).toBe(3)
			local byKind: { [string]: any } = {}
			for _, frame in r.frames do
				local f = value(frame)
				byKind[f.labels.kind] = f.values[1]
			end
			expect(byKind.inf).toBe(math.huge)
			expect(byKind.neginf).toBe(-math.huge)
			expect(byKind.nan ~= byKind.nan).toBe(true)
			expect(Frame.finite(byKind.nan)).toBeNil()
		end)

		it("keeps a series with gaps as only its present samples", function()
			local r = result(v, "query_range_gaps")
			expect(#r.frames).toBe(1)
			expect(#value(r.frames[1]).values).toBe(30)
			expect(value(r.frames[1]).labels).toEqual({})
		end)

		it("is ok with no frames for an empty result", function()
			local r = result(v, "query_range_empty")
			expect(r.ok).toBe(true)
			expect(#r.frames).toBe(0)
			expect(r.warnings).toEqual({})
		end)
	end)

	describe("Prometheus " .. v .. " instant", function()
		it("gives one single-row frame per vector sample, __name__ kept for display", function()
			local r = result(v, "query_vector")
			expect(#r.frames).toBe(6)
			local names: { string } = {}
			for _, frame in r.frames do
				expect(frame.meta.type).toBe("numeric-multi")
				local f = value(frame)
				expect(#f.values).toBe(1)
				expect((Frame.timeField(frame) :: Frame.Field).values[1]).toBe(1791577898000)
				table.insert(names, Frame.displayName(f, frame))
			end
			expect(names).toContain('up{instance="node-exporter:9999", job="down"}')
		end)

		it("rounds fractional-second sample times to whole ms", function()
			-- An instant query of a range selector returns a matrix with raw scrape times.
			local r = result(v, "query_matrix")
			local times = (Frame.timeField(r.frames[1]) :: Frame.Field).values
			expect(#times).toBe(6)
			for _, ms in times do
				expect(ms).toBe(math.floor(ms))
			end
		end)

		it("gives a scalar as one unlabelled row", function()
			local r = result(v, "query_scalar")
			expect(#r.frames).toBe(1)
			expect(value(r.frames[1]).values).toEqual({ 5 })
			expect(value(r.frames[1]).labels).toEqual({})
		end)

		it("gives a string as a string Value field", function()
			local r = result(v, "query_string")
			expect(#r.frames).toBe(1)
			local f = r.frames[1].fields[2]
			expect(f.type).toBe("string")
			expect(f.values).toEqual({ "tern" })
		end)

		it("is ok with no frames for an empty vector", function()
			local r = result(v, "query_empty")
			expect(r.ok).toBe(true)
			expect(#r.frames).toBe(0)
		end)

		-- The user must see why a query is suspicious (rate() of a gauge,
		-- histogram_quantile without le) even when it returned data.
		it("reports PromQL warnings and infos", function()
			local info = result(v, "query_info")
			expect(#info.frames).toBe(1)
			expect(#info.warnings).toBe(1)
			expect(string.find(info.warnings[1], "might not be a counter", 1, true) ~= nil).toBe(true)
			local warning = result(v, "query_warning")
			expect(#warning.warnings).toBe(1)
			expect(string.find(warning.warnings[1], 'bucket label "le"', 1, true) ~= nil).toBe(true)
		end)
	end)
end

describe("native histograms", function()
	-- The dev stack scrapes no native histograms, so this takes a recorded
	-- vector and gives one sample a native histogram (the API's documented
	-- `histogram` member instead of `value`). The query must still render
	-- its float series and say what it left out.
	it("skips histogram samples with a warning instead of failing", function()
		local doc = json.decode(Fixtures.read("prometheus/3.15.0/query_vector.json"))
		local sample = doc.data.result[1]
		sample.histogram = { sample.value[1], { count = "3", sum = "1.5", buckets = {} } }
		sample.value = nil
		local r: any = FrameProm.result(doc, env)
		expect(r.ok).toBe(true)
		expect(#r.frames).toBe(5)
		expect(r.warnings).toEqual({ string.format(FrameProm.HISTOGRAM_WARNING, 1) })
	end)
end)

describe("sample", function()
	it("parses Prometheus' special values and leaves non-numbers missing", function()
		expect(FrameProm.sample("1e3")).toBe(1000)
		expect(FrameProm.sample("+Inf")).toBe(math.huge)
		expect(FrameProm.sample("-Inf")).toBe(-math.huge)
		expect(FrameProm.sample("bogus")).toBe(Frame.NULL)
	end)
end)

return nil
