--!strict
-- Which command lines our lenses take over (docs/sdk-capability-matrix.md row
-- 11a: Tern matches the unquoted argv joined by spaces, after wrappers, env
-- assignments and stderr redirects are dropped; pipelines and stdout
-- redirects are never lensed). A claim also hides Tern's built-in lens for
-- the command, so the globs must take exactly what the lenses can read, and
-- the first lens in manifest order wins.
local Check = require("../../../plugin/lib/lens/promtool_check")
local Curl = require("../../../plugin/lib/lens/curl")
local Promtool = require("../../../plugin/lib/lens/promtool_query")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

-- plugin.toml [[lenses]] in manifest order.
local LENSES: { S.LensClaim } = {
	{ id = "promtool-query", match = Promtool.MATCH },
	{ id = "promtool-check", match = Check.MATCH },
	{ id = "curl", match = Curl.MATCH },
}

local function claim(program: string, args: { string }): string?
	return S.claim(LENSES, program, args)
end

describe("lens claims", function()
	it("matches globs the way Tern does", function()
		expect(S.globMatch("du *", "du .")).toBe(true)
		expect(S.globMatch("du *", "du")).toBe(false)
		expect(S.globMatch("terraform plan*", "terraform plan")).toBe(true)
		expect(S.globMatch("a?c", "abc")).toBe(true)
		expect(S.globMatch("a.c", "abc")).toBe(false)
	end)

	it("claims the matrix's curl forms after quote removal", function()
		expect(claim("curl", { "-s", "http://127.0.0.1:18080/api/v1/query?query=up" })).toBe("curl")
		expect(claim("curl", { "-s", "http://127.0.0.1:18080/api/v1/query_range?query=up" })).toBe("curl")
		expect(claim("curl", { "-s", "-XPOST", "http://localhost:13001/api/ds/query" })).toBe("curl")
		expect(claim("curl", { "http://localhost:3000/api/datasources/proxy/uid/prom3/api/v1/query?query=up" })).toBe(
			"curl"
		)
		expect(claim("curl", { "http://localhost:3100/loki/api/v1/query_range?query={job=a}" })).toBe("curl")
	end)

	it("leaves other API paths to Tern's built-in lens", function()
		expect(claim("curl", { "-s", "http://localhost:9090/api/v1/labels" })).toBeNil()
		expect(claim("curl", { "-s", "http://localhost:3000/api/health" })).toBeNil()
		expect(claim("curl", { "http://localhost:9090/api/v1/targets" })).toBeNil()
		expect(claim("curl", {})).toBeNil()
	end)

	it("claims promtool check and test runs, and query runs for the query lens", function()
		expect(claim("promtool", { "check", "rules", "a.yml", "b.yml" })).toBe("promtool-check")
		expect(claim("promtool", { "check", "rules" })).toBe("promtool-check")
		expect(claim("promtool", { "check", "rules", "--lint=none", "a.yml" })).toBe("promtool-check")
		expect(claim("promtool", { "check", "config", "prometheus.yml" })).toBe("promtool-check")
		expect(claim("promtool", { "test", "rules", "t.yml" })).toBe("promtool-check")
		expect(claim("promtool", { "query", "instant", "http://localhost:9090", "up" })).toBe("promtool-query")
	end)

	it("leaves promtool commands neither lens reads unclaimed", function()
		expect(claim("promtool", { "check", "web-config", "web.yml" })).toBeNil()
		expect(claim("promtool", { "check", "healthy" })).toBeNil()
		expect(claim("promtool", { "check", "metrics" })).toBeNil()
		expect(claim("promtool", { "test", "rules" })).toBeNil()
		expect(claim("promtool", { "tsdb", "list", "data" })).toBeNil()
		expect(claim("promtool", {})).toBeNil()
	end)
end)

return nil
