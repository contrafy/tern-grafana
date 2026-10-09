--!strict
-- Frames between query and visualization: the Prometheus datasource's
-- frontend post-processing (packages/grafana-prometheus/src/
-- result_transformer.ts transformV2, transformDFToTable) and the panel
-- transformations organize, filterFieldsByName, filterByRefId
-- (packages/grafana-data/src/transformations/transformers/*.ts). Without
-- them a "format: table" query renders as N one-row frames and an
-- organize'd table shows the columns its author removed.
local t = require("../../lib/test")
local FieldConfig = require("../../../plugin/lib/panels/fieldconfig")
local Frame = require("../../../plugin/lib/frame/types")
local S = require("./support")
local Transform = require("../../../plugin/lib/panels/transform")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local function names(frame: Frame.Frame, frames: { Frame.Frame }): { string }
	local out: { string } = {}
	for _, f in frame.fields do
		table.insert(out, FieldConfig.displayName(f, frame, frames))
	end
	return out
end

for _, version in S.VERSIONS do
	describe("transform on tern-panels, Grafana " .. version, function()
		-- Panel 9 "Targets": `up` with format table, then organize.
		it("merges a format=table refId into one table frame (transformDFToTable)", function()
			local panel = S.clone(S.panel(version, 9))
			panel.transformations = {}
			local out = Transform.prepare(panel, S.frames(version, "prom_table"), env)
			expect(#out).toBe(1)
			expect(names(out[1], out)).toEqual({ "Time", "__name__", "instance", "job", "env", "Value" })
			expect(#out[1].fields[1].values).toBe(6)
			-- A series without the label gets "" (getLabelValue).
			expect(out[1].fields[5].values[1]).toBe("")
			expect(out[1].fields[5].values[2]).toBe("dev")
		end)

		it("applies organize: excludeByName drops columns, renameByName renames", function()
			local panel = S.panel(version, 9)
			local out = Transform.prepare(panel, S.frames(version, "prom_table"), env)
			expect(names(out[1], out)).toEqual({ "instance", "job", "env", "up" })
		end)

		-- getValueText: "Value #<refId>" once several refIds are tables.
		it("names value columns by refId when several queries are tables", function()
			local panel = {
				type = "table",
				targets = { { refId = "A", format = "table" }, { refId = "B", format = "table" } },
			}
			local out = Transform.prepare(panel, S.frames(version, "prom_range"), env)
			expect(#out).toBe(2)
			local a = out[1].fields
			expect(a[#a].name).toBe("Value #A")
			-- 8 series x 61 samples, ordered by time (sortDataFrame).
			expect(#a[1].values).toBe(8 * 61)
			local times = a[1].values
			for i = 2, #times do
				assert(times[i - 1] <= times[i], "times must be sorted")
			end
			expect(out[2].fields[#out[2].fields].name).toBe("Value #B")
		end)

		-- Exemplars are annotations (dataTopic), not series.
		it("drops exemplar frames from the panel data", function()
			local panel = { type = "timeseries", targets = { { refId = "A" } } }
			local frames = S.frames(version, "prom_exemplars")
			expect(#frames).toBe(3)
			local out = Transform.prepare(panel, frames, env)
			expect(#out).toBe(2)
		end)

		it("filters frames by refId and fields by name", function()
			local byRef = {
				transformations = { { id = "filterByRefId", options = { include = "B" } } },
			}
			local out = Transform.prepare(byRef, S.frames(version, "prom_range"), env)
			expect(#out).toBe(1)
			expect(out[1].refId).toBe("B")
			local pipe = { transformations = { { id = "filterByRefId", options = { exclude = "A|B" } } } }
			expect(#Transform.prepare(pipe, S.frames(version, "prom_range"), env)).toBe(0)
			local byName = {
				transformations = {
					{ id = "filterFieldsByName", options = { include = { pattern = "^(Time|idle)$" } } },
				},
			}
			local kept = Transform.prepare(byName, S.refFrames(version, "prom_range", "A"), env)
			expect(#kept).toBe(8)
			local idle = 0
			for _, f in kept do
				if #f.fields == 2 then
					idle += 1
				end
			end
			expect(idle).toBe(1)
		end)
	end)
end

describe("transform support", function()
	it("names the first transformation it cannot apply", function()
		local panel = S.json([[{"transformations": [
			{"id": "merge", "disabled": true},
			{"id": "organize", "options": {}},
			{"id": "reduce", "options": {}}
		]}]])
		expect(Transform.unsupported(panel, env)).toBe("transformation reduce is not supported")
		expect(Transform.unsupported({ transformations = { { id = "organize" } } }, env)).toBeNil()
		local filtered = {
			transformations = { { id = "organize", filter = { id = "byValue", options = {} } } },
		}
		expect(Transform.unsupported(filtered, env)).toBe(
			"transformation organize with a byValue filter is not supported"
		)
	end)
end)

return nil
