--!strict
-- The settings block rewrites a file people also edit by hand. A rewrite must
-- keep the documented key order (so a diff shows only the edit), keep every
-- feature section exactly as written (later milestones own them), and the
-- content hash must change with any byte so a concurrent edit is detected.
local Json = require("../../../plugin/lib/settings/json")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local FILE = [[
{
  "query": {"history": {"max": 50, "tags": ["a", "b"]}, "presets": [{"name": "up", "expr": "up"}]},
  "contexts": {
    "lab": {
      "prometheus": {"timeout_ms": 30000, "url": "http://localhost:9090", "auth": {"token_cmd": ["op", "read", "op://v/i/t"], "type": "bearer"}},
      "grafana": {"datasources": {"prometheus": "prom3"}, "url": "http://localhost:3000", "org_id": 1}
    }
  },
  "default_context": "lab",
  "version": 1,
  "watches": {"rules": [{"expr": "up == 0", "for": "5m", "note": "a \"quoted\" value, with: punctuation {}"}]}
}
]]

describe("encode", function()
	it("round-trips the decoded document, feature sections included", function()
		local raw = json.decode(FILE)
		local text = Json.encode(raw, json.encode)
		expect(json.decode(text)).toEqual(raw)
	end)

	it("writes the documented key order, not alphabetical or random", function()
		local text = Json.encode(json.decode(FILE), json.encode)
		local function at(needle: string): number
			return (string.find(text, needle, 1, true)) :: number
		end
		expect(at('"version"') < at('"default_context"')).toBe(true)
		expect(at('"default_context"') < at('"contexts"')).toBe(true)
		expect(at('"contexts"') < at('"query"')).toBe(true)
		-- grafana before prometheus inside a context, url first inside an endpoint.
		expect(at('"grafana"') < at('"prometheus": {')).toBe(true)
		expect(at('"url": "http://localhost:9090"') < at('"timeout_ms"')).toBe(true)
		expect(at('"type": "bearer"') < at('"token_cmd"')).toBe(true)
	end)

	it("keeps a command line on one line and indents nested sections", function()
		local text = Json.encode(json.decode(FILE), json.encode)
		expect(text).toContain('"token_cmd": ["op", "read", "op://v/i/t"]')
		expect(text).toContain('\n  "watches": {\n    "rules": [\n      {\n')
		expect(string.sub(text, -2)).toBe("}\n")
	end)

	it("keeps empty containers of feature sections as written by the runtime encoder", function()
		-- tern.json.encode keeps an empty decoded array as []; the test codec cannot tag arrays, so a
		-- stand-in encoder shows the text is passed through untouched apart from indentation.
		local raw = { version = 1, contexts = {}, hosts = { list = {} } }
		local text = Json.encode(raw, function(_v: any): string
			return '{"list":[]}'
		end)
		expect(text).toContain('"hosts": {\n    "list": []\n  }')
	end)
end)

describe("hash", function()
	it("is stable for the same text and changes with any byte", function()
		expect(Json.hash(FILE)).toBe(Json.hash(FILE))
		expect(Json.hash(FILE) == Json.hash(FILE .. " ")).toBe(false)
		expect(Json.hash('{"a":1}') == Json.hash('{"a":2}')).toBe(false)
	end)
end)

return nil
