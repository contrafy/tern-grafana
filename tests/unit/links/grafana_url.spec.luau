--!strict
-- Grafana URLs are claimed only under a configured Grafana base URL: claiming
-- anything else would hijack unrelated links. Within a base, dashboard,
-- panel, explore and alerting pages map to native views; everything Grafana
-- can only show itself (short links, admin pages) goes to the browser pane.
-- Explore URL states follow Grafana 11 (`left=`) and 12 (`panes=` with
-- schemaVersion=1), percent-encoded the way Grafana's frontend writes them.
local GrafanaUrl = require("../../../plugin/lib/links/grafana_url")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local cfg = Validate.parseFile(
	[[{"contexts": {
	"prod": {"grafana": {"url": "http://10.0.0.5:3000", "browser_url": "https://grafana.example.com/",
		"datasources": {"prometheus": "prom1", "loki": "loki1"}}},
	"sub": {"grafana": {"url": "https://ops.example.com:443/grafana"}},
	"root": {"grafana": {"url": "https://ops.example.com"}}}}]],
	json.decode
)
assert(cfg, "fixture config must validate")
local BASES = GrafanaUrl.bases(cfg)

local function rec(url: string): any
	return GrafanaUrl.recognize(url, BASES, json.decode)
end

describe("grafana_url.recognize base matching", function()
	it("leaves non-Grafana URLs alone", function()
		expect(rec("https://example.org/d/abc")).toBeNil()
		expect(rec("http://grafana.example.com/d/abc")).toBeNil() -- http is not https
		expect(rec("https://grafana.example.com:8443/d/abc")).toBeNil()
		expect(rec("mailto:a@b")).toBeNil()
	end)

	it("matches browser_url and the internal url, ignoring trailing slashes and default ports", function()
		expect(rec("https://grafana.example.com:443/d/abc").link.params.context).toBe("prod")
		expect(rec("http://10.0.0.5:3000/d/abc/").link.params.uid).toBe("abc")
		expect(rec("HTTPS://Grafana.Example.com/d/abc").link.params.context).toBe("prod")
	end)

	it("prefers the sub-path install over the host root", function()
		expect(rec("https://ops.example.com/grafana/d/abc").link.params.context).toBe("sub")
		expect(rec("https://ops.example.com/d/abc").link.params.context).toBe("root")
		-- /grafanax is not under /grafana
		expect(rec("https://ops.example.com/grafanax/d/abc").browser).toBe("https://ops.example.com/grafanax/d/abc")
	end)
end)

describe("grafana_url.recognize pages", function()
	it("maps dashboards with time, org, variables and Scenes viewPanel", function()
		local r = rec(
			"https://grafana.example.com/d/node-x/node-exporter?orgId=1&from=now-6h&to=now&var-job=node&var-job=api&viewPanel=panel-7&refresh=30s"
		)
		expect(r.link).toEqual({
			action = "dashboard",
			params = { context = "prod", uid = "node-x", org = "1", from = "now-6h", to = "now", panel = "7" },
			vars = { job = { "node", "api" } },
		})
	end)

	it("maps d-solo to a panel", function()
		local r =
			rec("https://grafana.example.com/d-solo/abc/slug?orgId=1&panelId=2&from=1710000000000&to=1710003600000")
		expect(r.link.action).toBe("panel")
		expect(r.link.params.panel).toBe("2")
		expect(r.link.params.from).toBe("1710000000000")
	end)

	it("maps Grafana 12 explore panes to a query", function()
		local r = rec(
			"https://grafana.example.com/explore?schemaVersion=1&panes=%7B%22x7k%22:%7B%22datasource%22:%22prom1%22,%22queries%22:%5B%7B%22refId%22:%22A%22,%22expr%22:%22rate%28http_requests_total%5B5m%5D%29%22,%22range%22:true,%22datasource%22:%7B%22type%22:%22prometheus%22,%22uid%22:%22prom1%22%7D%7D%5D,%22range%22:%7B%22from%22:%22now-1h%22,%22to%22:%22now%22%7D%7D%7D&orgId=1"
		)
		expect(r.link).toEqual({
			action = "query",
			params = {
				context = "prod",
				expr = "rate(http_requests_total[5m])",
				ds = "prom1",
				from = "now-1h",
				to = "now",
			},
			vars = {},
		})
	end)

	it("maps Grafana 11 explore left state, classifying by configured datasource uid", function()
		local r = rec(
			"https://grafana.example.com/explore?orgId=1&left=%7B%22datasource%22:%22loki1%22,%22queries%22:%5B%7B%22refId%22:%22A%22,%22expr%22:%22%7Bjob%3D%5C%22api%5C%22%7D%22%7D%5D,%22range%22:%7B%22from%22:1710000000000,%22to%22:1710003600000%7D%7D"
		)
		expect(r.link.action).toBe("logs")
		expect(r.link.params.expr).toBe('{job="api"}')
		expect(r.link.params.from).toBe("1710000000000")
	end)

	it("sends explore states it cannot classify to the browser", function()
		local tempo =
			"https://grafana.example.com/explore?panes=%7B%22a%22:%7B%22datasource%22:%22t1%22,%22queries%22:%5B%7B%22refId%22:%22A%22,%22query%22:%22abc%22%7D%5D%7D%7D"
		expect(rec(tempo).browser).toBe(tempo)
		expect(rec("https://grafana.example.com/explore?panes=%7Bbroken").browser).toBe(
			"https://grafana.example.com/explore?panes=%7Bbroken"
		)
	end)

	it("maps alerting list and rule pages", function()
		expect(rec("https://grafana.example.com/alerting/list?search=x").link.action).toBe("alerts")
		expect(rec("https://grafana.example.com/alerting/grafana/rule-1/view").link.params.rule).toBe("rule-1")
	end)

	it("opens short links and other pages in the browser", function()
		expect(rec("https://grafana.example.com/goto/AbC123?orgId=1").browser).toBe(
			"https://grafana.example.com/goto/AbC123?orgId=1"
		)
		expect(rec("https://grafana.example.com/").browser).toBe("https://grafana.example.com/")
		expect(rec("https://grafana.example.com/d/bad%2Fuid").browser).toBe("https://grafana.example.com/d/bad%2Fuid")
	end)
end)

describe("grafana_url.build", function()
	it("round-trips a dashboard link through its Grafana page", function()
		local l = rec("https://grafana.example.com/d/abc?from=now-6h&viewPanel=4&var-job=a%20b").link
		local page = GrafanaUrl.build(l, "https://grafana.example.com", json.encode)
		expect(rec(page :: string).link).toEqual(l)
	end)

	it("round-trips a query link through an explore page", function()
		local l = {
			action = "query",
			params = { context = "prod", expr = 'sum(up{job="x"})', ds = "prom1", from = "now-2h", to = "now" },
			vars = {},
		}
		local page = GrafanaUrl.build(l, "https://grafana.example.com", json.encode)
		expect(rec(page :: string).link).toEqual(l)
	end)
end)

return nil
