--!strict
-- Volume bars show how many lines each bucket holds and of which level; the
-- per-level totals drive the level chips. Loki and Grafana answer the same
-- metric query with differently shaped series; both must count the same.
local Loki = require("../../../plugin/lib/source/loki")
local S = require("../source/support")
local Volume = require("../../../plugin/lib/logs/volume")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local direct = table.clone(S.direct)
direct.signal = "logs"
local grafana = table.clone(S.datasource)
grafana.signal = "logs"
grafana.datasource_uid = "loki"

local function sums(frames: { any }): ({ [string]: number }, number)
	local by: { [string]: number } = {}
	local total = 0
	for _, f in frames do
		for _, v in f.fields[2].values do
			local level = f.fields[2].labels.level
			by[level] = (by[level] or 0) + v
			total += v
		end
	end
	return by, total
end

describe("buckets", function()
	it("adds every series into per-bucket totals and per-level totals", function()
		local r: any = Loki.parse(direct, S.response("loki/3.7.8/query_range_matrix.json"), S.env)
		local v = Volume.build(r.frames, S.START * 1000, S.END * 1000 + 60000, 60000)
		local by, total = sums(r.frames)
		expect(v.total).toBe(total)
		expect(v.totals).toEqual({ debug = by.debug, error = by.error, info = by.info, warning = by.warn })
		local sum = 0
		for _, b in v.buckets do
			sum += b.total
		end
		expect(sum).toBe(total)
		-- Loki stamps a count at its bucket's end: 1791577020 counts 1791576960..1791577020.
		expect(v.buckets[1].t_ms).toBe(1791576960000)
		expect(v.buckets[1].levels.debug).toBe(23)
	end)

	for _, ver in { "11.6.16", "12.4.12" } do
		it("counts Grafana " .. ver .. "'s frames the same way", function()
			local r: any = Loki.parse(grafana, S.response("grafana/" .. ver .. "/ds_query_loki_metric.json"), S.env)
			local first = r.frames[1].fields[1].values[1]
			local v = Volume.build(r.frames, first - 60000, first + 15 * 60000, 60000)
			local _, total = sums(r.frames)
			expect(v.total).toBe(total)
			expect(v.max > 0).toBe(true)
		end)
	end
end)

describe("step", function()
	it("picks a round bucket width for about 60 bars", function()
		expect(Volume.step(60 * 60 * 1000)).toBe(60000)
		expect(Volume.step(15 * 60 * 1000)).toBe(15000)
		expect(Volume.step(1000)).toBe(1000)
		expect(Volume.query('{a="b"}', 60000)).toBe('sum by (level, detected_level) (count_over_time({a="b"} [1m]))')
	end)
end)

return nil
