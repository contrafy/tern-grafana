--!strict
-- route.link answers decide what a click does. Private links must always be
-- claimed (never reach the OS), Grafana URLs open natively only when the
-- block exists (browser otherwise, so M1 never shows a dead end), and block
-- args are a canonical link that the block can decode and that holds no
-- secrets.
local Route = require("../../../plugin/lib/links/route")
local Scheme = require("../../../plugin/lib/links/scheme")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local cfg = Validate.parseFile(
	[[{"default_context": "prod", "contexts": {"prod": {"grafana": {"url": "https://g.example",
	"auth": {"type": "bearer", "token_env": "GRAFANA_TOKEN"}, "datasources": {"prometheus": "prom1"}}}}}]],
	json.decode
)
local CODEC = { decode = json.decode, encode = json.encode }
-- Only the query block exists (the M1 shape); routing must follow the table it is given.
local M1 = {
	query = true,
	dashboard = false,
	panel = false,
	alerts = false,
	silence = false,
	logs = false,
	trace = false,
	ops = false,
	settings = false,
}
local ALL = {
	query = true,
	dashboard = true,
	panel = true,
	alerts = true,
	silence = true,
	logs = true,
	trace = true,
	ops = true,
	settings = true,
}

local function decide(url: string, caps: any?): (any, string?)
	return Route.decide(url, cfg, caps or M1, CODEC)
end

local EXPLORE =
	"https://g.example/explore?schemaVersion=1&panes=%7B%22a%22:%7B%22datasource%22:%22prom1%22,%22queries%22:%5B%7B%22refId%22:%22A%22,%22expr%22:%22up%22%7D%5D,%22range%22:%7B%22from%22:%22now-1h%22,%22to%22:%22now%22%7D%7D%7D"

describe("route.decide Grafana URLs", function()
	it("opens explore links in the query block with decodable args", function()
		local d = decide(EXPLORE)
		expect(d.block).toBe("tern-grafana.query")
		local l = Scheme.decode(d.args[1])
		expect(l and l.params).toEqual({ context = "prod", expr = "up", ds = "prom1", from = "now-1h", to = "now" })
	end)

	it("keeps args free of secrets", function()
		local d = decide(EXPLORE)
		expect((string.find(d.args[1], "GRAFANA_TOKEN", 1, true))).toBeNil()
	end)

	it("sends dashboards to the browser until the block exists, natively after", function()
		local url = "https://g.example/d/abc/x?from=now-6h"
		expect((decide(url))).toEqual({ url = url })
		expect(decide(url, ALL).block).toBe("tern-grafana.dashboard")
	end)

	it("leaves unconfigured URLs to Tern", function()
		expect((decide("https://other.example/d/abc"))).toBeNil()
		expect((Route.decide("https://g.example/d/abc", nil, M1, CODEC))).toBeNil()
	end)
end)

describe("route.decide tern-grafana links", function()
	it("claims invalid links and explains why", function()
		local d, msg = decide("tern-grafana://nope")
		expect(d).toEqual({ handled = true })
		expect(msg).toContain("nope")
	end)

	it("answers browse with the decoded URL", function()
		expect((decide("tern-grafana://browse?url=https%3A%2F%2Fg.example%2Fd%2Fabc"))).toEqual({
			url = "https://g.example/d/abc",
		})
	end)

	it("falls back to the context's Grafana page when no block exists", function()
		expect((decide("tern-grafana://dashboard?uid=abc&panel=2"))).toEqual({
			url = "https://g.example/d/abc?viewPanel=2",
		})
		expect((decide("tern-grafana://alerts?context=prod"))).toEqual({ url = "https://g.example/alerting/list" })
	end)

	it("claims links without a native view or Grafana page", function()
		local d, msg = decide("tern-grafana://ops?view=targets")
		expect(d).toEqual({ handled = true })
		expect(msg).toContain("ops")
	end)

	it("rejects unknown contexts", function()
		local d, msg = decide("tern-grafana://query?context=staging&expr=up")
		expect(d).toEqual({ handled = true })
		expect(msg).toContain("staging")
	end)

	it("opens the block for capable actions", function()
		expect(decide("tern-grafana://query?expr=up").args).toEqual({ "tern-grafana://query?expr=up" })
	end)
end)

describe("route.fallback", function()
	it("never lets a link fall through to the OS when deciding failed", function()
		expect((Route.fallback("tern-grafana://query"))).toEqual({ handled = true })
		expect((Route.fallback("https://g.example/d/x"))).toEqual({ url = "https://g.example/d/x" })
		expect((Route.fallback("mailto:a@b"))).toBeNil()
	end)
end)

return nil
