--!strict
-- Value mappings as in packages/grafana-data/src/utils/valueMappings.ts
-- getValueMappingResult. Mappings turn status codes into words and colors
-- ("1" -> UP in green); a mapping that misses or matches the wrong value
-- reports the opposite state.
local t = require("../../lib/test")
local Frame = require("../../../plugin/lib/frame/types")
local Mappings = require("../../../plugin/lib/panels/mappings")
local S = require("./support")
local describe, it, expect = t.describe, t.it, t.expect

local env = S.env

local function parse(raw: any): { Mappings.Mapping }
	return Mappings.parse(raw, env)
end

for _, version in S.VERSIONS do
	describe("mappings from the tern-panels dashboard, Grafana " .. version, function()
		-- Panel 9 "Targets": override on `up` maps 0/1 to DOWN/UP.
		it("maps the up values of the Targets table to UP/DOWN with colors", function()
			local panel = S.panel(version, 9)
			local m = parse(panel.fieldConfig.overrides[1].properties[2].value)
			local up = Mappings.apply(m, 1)
			assert(up, "1 must map")
			expect(up.text).toBe("UP")
			expect(up.color).toBe("green")
			local down = Mappings.apply(m, 0)
			assert(down, "0 must map")
			expect(down.text).toBe("DOWN")
			expect(down.color).toBe("red")
			expect(Mappings.apply(m, 2)).toBeNil()
		end)

		-- Value maps key on String(value): 1.0 is "1", and "1" matches too.
		it("matches numbers and numeric strings by their JavaScript string", function()
			local m = parse(S.panel(version, 14).fieldConfig.defaults.mappings)
			local a = Mappings.apply(m, 1.0)
			local b = Mappings.apply(m, "1")
			assert(a and b, "both must map")
			expect(a.text).toBe("Up")
			expect(b.text).toBe("Up")
			expect(Mappings.apply(m, Frame.NULL)).toBeNil()
		end)
	end)
end

describe("mappings range/regex/special (valueMappings.ts)", function()
	-- `from` absent on the third mapping: open below.
	local raw = S.json([[ [
		{"type": "special", "options": {"match": "null", "result": {"text": "N/A", "color": "gray", "index": 0}}},
		{"type": "range", "options": {"from": 0, "to": 10, "result": {"text": "low", "color": "green"}}},
		{"type": "range", "options": {"from": null, "to": 0, "result": {"text": "negative"}}},
		{"type": "regex", "options": {"pattern": "/^pod-(\\w+)-\\d+$/", "result": {"text": "pod $1"}}},
		{"type": "special", "options": {"match": "nan", "result": {"text": "not a number"}}},
		{"type": "special", "options": {"match": "true", "result": {"text": "yes"}}},
		{"type": "special", "options": {"match": "empty", "result": {"text": "(empty)"}}}
	] ]])

	it("tries mappings in order and returns the first hit", function()
		local m = parse(raw)
		expect((Mappings.apply(m, Frame.NULL) :: any).text).toBe("N/A")
		expect((Mappings.apply(m, 0) :: any).text).toBe("low")
		expect((Mappings.apply(m, 10) :: any).text).toBe("low")
		expect((Mappings.apply(m, -3) :: any).text).toBe("negative")
		expect(Mappings.apply(m, 11)).toBeNil()
	end)

	-- RangeToText parses strings with parseFloat: "7ms" is 7.
	it("reads numeric prefixes of strings for ranges", function()
		local m = parse(raw)
		expect((Mappings.apply(m, "7ms") :: any).text).toBe("low")
	end)

	-- RegexToText replaces the match with the result text ($1 expands).
	it("rewrites regex matches with capture groups", function()
		local m = parse(raw)
		expect((Mappings.apply(m, "pod-api-42") :: any).text).toBe("pod api")
		expect(Mappings.apply(m, "node-1")).toBeNil()
	end)

	it("matches NaN, true and empty specials", function()
		local m = parse(raw)
		expect((Mappings.apply(m, 0 / 0) :: any).text).toBe("not a number")
		expect((Mappings.apply(m, true) :: any).text).toBe("yes")
		expect((Mappings.apply(m, "true") :: any).text).toBe("yes")
		expect((Mappings.apply(m, "") :: any).text).toBe("(empty)")
	end)

	it("keys values like JavaScript String()", function()
		expect(Mappings.key(1)).toBe("1")
		expect(Mappings.key(0.5)).toBe("0.5")
		expect(Mappings.key(1e21)).toBe("1e+21")
		expect(Mappings.key(true)).toBe("true")
	end)

	it("ignores malformed entries instead of failing the panel", function()
		local bad = S.json('[{"type": "value"}, {"type": "nope", "options": {}}, 3, null]')
		local m = parse(bad)
		expect(#m).toBe(0)
	end)
end)

return nil
