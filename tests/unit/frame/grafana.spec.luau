--!strict
-- Grafana's /api/ds/query frames feed the same renderers as direct
-- Prometheus results. What matters: per-refId errors stay per refId (one bad
-- panel target must not blank the others), Grafana's series names
-- (legendFormat applied server-side) reach the legend, and the JSON
-- workarounds Grafana uses (NaN/Inf in `entities`, sub-ms time in `nanos`)
-- are undone so values are what the server computed.
local Fixtures = require("../../lib/fixtures")
local Frame = require("../../../plugin/lib/frame/types")
local FrameGrafana = require("../../../plugin/lib/frame/grafana")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local VERSIONS = { "11.6.16", "12.4.12" }

local env: any = { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null }

local function results(version: string, name: string): { [string]: any }
	local doc = json.decode(Fixtures.read("grafana/" .. version .. "/" .. name .. ".json"))
	return FrameGrafana.parseResults(doc, env)
end

local function value(frame: Frame.Frame): any
	return Frame.numberFields(frame)[1]
end

for _, v in VERSIONS do
	describe("Grafana " .. v .. " /api/ds/query", function()
		it("returns each refId's range frames with Grafana's legend names", function()
			local r = results(v, "ds_query_prom_range")
			expect(r.A.ok).toBe(true)
			expect(r.B.ok).toBe(true)
			-- legendFormat "{{mode}}", applied by Grafana.
			local names: { string } = {}
			for _, frame in r.A.frames do
				expect(frame.refId).toBe("A")
				expect(frame.meta.type).toBe("timeseries-multi")
				expect(frame.meta.custom.resultType).toBe("matrix")
				table.insert(names, Frame.displayName(value(frame), frame))
			end
			expect(names).toEqual({ "idle", "iowait", "irq", "nice", "softirq", "steal", "system", "user" })
			local time = Frame.timeField(r.A.frames[1]) :: Frame.Field
			expect(#time.values).toBe(61)
			expect((time.config :: Frame.FieldConfig).interval).toBe(15000)
			-- No legend: Grafana names the series by its expression.
			expect(Frame.displayName(value(r.B.frames[1]), r.B.frames[1])).toBe("sum(up)")
		end)

		it("returns instant vector frames with labels, one row each", function()
			local r = results(v, "ds_query_prom_instant")
			expect(#r.A.frames).toBe(6)
			for _, frame in r.A.frames do
				expect(frame.meta.type).toBe("numeric-multi")
				local f = value(frame)
				expect(#f.values).toBe(1)
				expect(f.labels.__name__).toBe("up")
			end
		end)

		it("returns table-format queries as the same per-series frames", function()
			-- Grafana's backend does not reshape format=table; the client
			-- builds the table, so the renderer gets labelled series.
			local r = results(v, "ds_query_prom_table")
			expect(#r.A.frames).toBe(6)
			expect(value(r.A.frames[1]).labels.job ~= nil).toBe(true)
		end)

		it("turns a per-ref error into a query error with Grafana's message", function()
			local r = results(v, "ds_query_prom_error")
			expect(r.A.ok).toBe(false)
			expect(r.A.error).toEqual({
				kind = "query",
				status = 400,
				message = 'bad_data: invalid parameter "query": 1:17: parse error: unclosed left parenthesis',
			})
		end)

		it("restores NaN, +Inf and -Inf from entities", function()
			local r = results(v, "ds_query_prom_nan_inf")
			local byKind: { [string]: any } = {}
			for _, frame in r.A.frames do
				local f = value(frame)
				expect(#f.values).toBe(#(Frame.timeField(frame) :: Frame.Field).values)
				byKind[(f.labels :: any).kind] = f.values
			end
			expect(byKind.inf[1]).toBe(math.huge)
			expect(byKind.neginf[#byKind.neginf]).toBe(-math.huge)
			expect(byKind.nan[1] ~= byKind.nan[1]).toBe(true)
		end)

		it("keeps non-numeric fields (Loki labels) as decoded values", function()
			local r = results(v, "ds_query_loki_logs")
			local frame = r.A.frames[1]
			expect(frame.fields[1].name).toBe("labels")
			expect(frame.fields[1].type).toBe("other")
			expect(frame.fields[1].values[1].job).toBe("loggen")
			expect(frame.fields[3].type).toBe("string")
		end)
	end)
end

describe("nanos", function()
	it("adds the sub-millisecond part to time values", function()
		local raw = json.decode(Fixtures.read("grafana/12.4.12/ds_query_tempo_search.json"))
		local rawFrame = raw.results.A.frames[1]
		local ms = rawFrame.data.values[2][1]
		local ns = rawFrame.data.nanos[2][1]
		local frame = FrameGrafana.frame(rawFrame, env)
		expect(frame.fields[2].type).toBe("time")
		expect(frame.fields[2].values[1]).toBe(ms + ns / 1e6)
	end)
end)

return nil
