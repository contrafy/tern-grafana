--!strict
-- Exemplars reach the chart from two shapes: Prometheus' /api/v1/query_exemplars
-- (2.53 and 3.x, series labels apart from the exemplar's own) and Grafana's
-- "exemplar" frame (labels merged into string columns). What matters: both
-- give the same time/value/trace id, the exemplar frame never shows up as a
-- series, and the trace id is found under the names tracing setups use.
local Fixtures = require("../../lib/fixtures")
local FrameGrafana = require("../../../plugin/lib/frame/grafana")
local FrameProm = require("../../../plugin/lib/frame/prom")
local Frame = require("../../../plugin/lib/frame/types")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local env: any = { now_ms = 0, decode = json.decode, encode = json.encode, null = json.null }

-- Recorded totals (MANIFEST.tsv window 1791576998..1791577898).
local PROM: { [string]: number } = { ["2.53.5"] = 420, ["3.15.0"] = 413 }

for version, count in PROM do
	describe("Prometheus " .. version .. " query_exemplars", function()
		local list =
			FrameProm.exemplars(json.decode(Fixtures.read("prometheus/" .. version .. "/query_exemplars.json")), env)

		it("reads every exemplar with ms time, numeric value and both label sets", function()
			expect(#list).toBe(count)
			local first = list[1]
			expect(first.time_ms).toBe(1791577008629)
			expect(first.value).toBe(0.04)
			expect(first.labels).toEqual({ traceID = "3e5dfa736abf8d76554df10772603f10" })
			expect(first.series.service).toBe("frontend")
			expect(first.series.le).toBe("0.064")
		end)

		it("sorts by time so the chart and the x key walk them in order", function()
			for i = 2, #list do
				expect(list[i - 1].time_ms <= list[i].time_ms).toBe(true)
			end
		end)

		it("finds the trace id under Tempo's traceID label", function()
			local id, label = FrameProm.traceId(list[1].labels)
			expect(id).toBe("3e5dfa736abf8d76554df10772603f10")
			expect(label).toBe("traceID")
		end)
	end)
end

for _, version in { "11.6.16", "12.4.12" } do
	describe("Grafana " .. version .. " exemplar frames", function()
		local doc = json.decode(Fixtures.read("grafana/" .. version .. "/ds_query_prom_exemplars.json"))
		local result = FrameGrafana.parseResults(doc, env).A :: any

		it("splits the exemplar frame from the series frames", function()
			local frames, exemplars = FrameGrafana.splitExemplars(result.frames)
			expect(#frames).toBe(2)
			for _, f in frames do
				expect(FrameGrafana.isExemplarFrame(f)).toBe(false)
				expect(#Frame.numberFields(f)).toBe(1)
			end
			expect(#exemplars).toBe(120)
			for i = 2, #exemplars do
				expect(exemplars[i - 1].time_ms <= exemplars[i].time_ms).toBe(true)
			end
		end)

		it("keeps every string column as a label, the trace id included", function()
			local _, exemplars = FrameGrafana.splitExemplars(result.frames)
			for _, e in exemplars do
				expect(e.value > 0).toBe(true)
				expect(e.labels.le ~= nil).toBe(true)
				expect(e.labels.service == "payments" or e.labels.service == "frontend").toBe(true)
				local id, label = FrameProm.traceId(e.labels)
				expect(label).toBe("traceID")
				expect(string.match(id :: string, "^%x+$") ~= nil).toBe(true)
			end
		end)
	end)
end

describe("FrameProm.traceId", function()
	it("tries the configured label, then trace_id, traceID and traceId", function()
		expect((FrameProm.traceId({ trace_id = "a", traceID = "b" }))).toBe("a")
		expect((FrameProm.traceId({ traceId = "c" }))).toBe("c")
		expect((FrameProm.traceId({ otel = "d", trace_id = "a" }, "otel"))).toBe("d")
		-- An empty configured label falls back to the defaults.
		expect((FrameProm.traceId({ otel = "", traceID = "b" }, "otel"))).toBe("b")
		expect((FrameProm.traceId({ span = "x" }))).toBeNil()
	end)
end)

return nil
