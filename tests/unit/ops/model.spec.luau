--!strict
-- What the Targets, Cardinality and Info tabs read from real answers of both
-- Prometheus versions and the Grafana proxy: a down target must surface
-- first with its scrape error, dropped targets must be counted even when the
-- list is not shown, cardinality lists keep the server's ranking, and the
-- config summary must find jobs, rule files and intervals in the YAML
-- Prometheus prints back.
local Info = require("../../../plugin/lib/ops/info")
local Ops = require("../../../plugin/lib/source/ops")
local S = require("../source/support")
local Targets = require("../../../plugin/lib/ops/targets")
local Tsdb = require("../../../plugin/lib/ops/tsdb")
local Group = require("../../../plugin/lib/alerts/group")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local PROM = { "2.53.5", "3.15.0" }

local SOURCES: { string } = {}
for _, v in PROM do
	table.insert(SOURCES, "prometheus/" .. v .. "/%s.json")
end
for _, v in { "11.6.16", "12.4.12" } do
	table.insert(SOURCES, "grafana/" .. v .. "/ds_proxy_prom_%s.json")
end

local env = table.clone(S.env)
env.now_ms = 1791577900000

local function data(path: string): any
	local r: any = Ops.parse(S.response(path), env, "/api/v1/x")
	assert(r.ok, path)
	return r.data
end

local function filter(text: string): Group.Filter
	return (Group.parseFilter(text)) :: Group.Filter
end

describe("targets", function()
	it("puts the pool with a down target first, down target first, with its scrape error", function()
		for _, src in SOURCES do
			local targets = Targets.normalize(data(string.format(src, "targets")), env)
			expect(#targets.active).toBe(6)
			expect(Targets.counts(targets)).toEqual({ up = 5, down = 1, unknown = 0 })
			local pools = Targets.pools(targets, filter(""), false)
			local names = {}
			for _, p in pools do
				table.insert(names, p.name)
			end
			expect(names).toEqual({ "down", "alertmanager", "loki", "node", "prometheus", "tempo" })
			local down = pools[1].targets[1]
			expect(down.health).toBe("down")
			expect(down.instance).toBe("node-exporter:9999")
			expect(string.find(down.last_error or "", "connection refused", 1, true) ~= nil).toBe(true)
			local am = pools[2].targets[1]
			expect(am.last_error).toBeNil()
			expect(am.url).toBe("http://alertmanager:9093/metrics")
			expect(am.interval).toBe("10s")
			-- Scraped within the minute before capture.
			expect(am.last_scrape_ms ~= nil and env.now_ms - am.last_scrape_ms < 3600000).toBe(true)
		end
	end)

	it("counts dropped targets per pool from droppedTargetCounts", function()
		for _, v in PROM do
			for _, name in { "targets", "targets_dropped" } do
				local targets = Targets.normalize(data("prometheus/" .. v .. "/" .. name .. ".json"), env)
				expect(targets.dropped_count).toBe(0)
				expect(targets.dropped_by_pool.node).toBe(0)
			end
		end
	end)

	it("counts the dropped list when the server has no per-pool totals", function()
		local raw = {
			activeTargets = {},
			droppedTargets = {
				{ discoveredLabels = { __address__ = "a:1", job = "k8s" } },
				{ discoveredLabels = { __address__ = "b:1", job = "k8s" } },
			},
		}
		local targets = Targets.normalize(raw, env)
		expect(targets.dropped_count).toBe(2)
		expect(targets.dropped_by_pool.k8s).toBe(2)
		expect(targets.dropped[2].address).toBe("b:1")
	end)

	it("filters by words, label matchers and health, and narrows to unhealthy", function()
		local targets = Targets.normalize(data("prometheus/3.15.0/targets.json"), env)
		local function instances(f: string, unhealthy: boolean): { string }
			local out = {}
			for _, p in Targets.pools(targets, filter(f), unhealthy) do
				for _, target in p.targets do
					table.insert(out, target.instance)
				end
			end
			return out
		end
		expect(instances("refused", false)).toEqual({ "node-exporter:9999" })
		expect(instances("health=down", false)).toEqual({ "node-exporter:9999" })
		expect(instances('job=~"lo.*"', false)).toEqual({ "loki:3100" })
		expect(instances("", true)).toEqual({ "node-exporter:9999" })
		expect(instances("job=node", true)).toEqual({})
	end)
end)

describe("tsdb", function()
	it("reads head stats and the four top lists in the server's order", function()
		for _, src in SOURCES do
			local tsdb = Tsdb.normalize(data(string.format(src, "tsdb")), env)
			expect((tsdb.head.series or 0) > 1000).toBe(true)
			expect((tsdb.head.min_time_ms or 0) < (tsdb.head.max_time_ms or 0)).toBe(true)
			for _, l in Tsdb.LISTS do
				local list = Tsdb.list(tsdb, l.name)
				expect(#list).toBe(10)
				for i = 2, #list do
					expect(list[i - 1].value >= list[i].value).toBe(true)
				end
			end
			expect(tsdb.memory_by_label[1].name).toBe("__name__")
		end
	end)

	it("honours the limit the request asked for", function()
		for _, v in PROM do
			local tsdb = Tsdb.normalize(data("prometheus/" .. v .. "/tsdb_limit.json"), env)
			expect(#tsdb.series_by_metric).toBe(5)
		end
	end)

	it("steps the limit within its presets", function()
		expect(Tsdb.stepLimit(10, 1)).toBe(20)
		expect(Tsdb.stepLimit(5, -1)).toBe(5)
		expect(Tsdb.stepLimit(100, 1)).toBe(100)
		expect(Tsdb.stepLimit(7, 1)).toBe(20)
	end)

	it("drills into an entry with PromQL both Prometheus versions accept", function()
		expect(Tsdb.drillQuery("series_by_metric", "up")).toBe('count by (job) ({__name__="up"})')
		expect(Tsdb.drillQuery("values_by_label", "instance")).toBe('count by (__name__) ({instance=~".+"})')
		expect(Tsdb.drillQuery("series_by_pair", "job=loki")).toBe('count by (__name__) ({job="loki"})')
		-- UTF-8 label names only exist on 3.x, which needs them quoted.
		expect(Tsdb.drillQuery("memory_by_label", "http.method")).toBe('count by (__name__) ({"http.method"=~".+"})')
		expect(Tsdb.drillQuery("series_by_pair", 'path=/a"b')).toBe('count by (__name__) ({path="/a\\"b"})')
	end)
end)

describe("info", function()
	it("reads build and runtime info of both versions", function()
		for i, src in SOURCES do
			local b = Info.build(data(string.format(src, "buildinfo")), env)
			expect(b.version).toBe(if i == 1 then "2.53.5" else "3.15.0")
			expect(#(b.revision or "")).toBe(40)
			local r = Info.runtime(data(string.format(src, "runtimeinfo")), env)
			expect(r.reload_ok).toBe(true)
			expect(r.retention).toBe("2d")
			expect(r.gogc).toBe("75")
			expect((r.start_ms or 0) > 0).toBe(true)
			expect(r.corruptions).toBe(0)
		end
	end)

	it("lists flags sorted and picks the key ones", function()
		for _, src in SOURCES do
			local flags = Info.flags(data(string.format(src, "flags")), env)
			expect(#flags > 50).toBe(true)
			for j = 2, #flags do
				expect(flags[j - 1].name < flags[j].name).toBe(true)
			end
			local key = Info.keyFlags(flags)
			expect(key[1].name).toBe("config.file")
			expect(key[1].value).toBe("/etc/prometheus/prometheus.yml")
		end
	end)

	it("summarizes the loaded config", function()
		for _, src in SOURCES do
			local yaml = Info.configYaml(data(string.format(src, "config")), env)
			local c = Info.configSummary(yaml :: string)
			expect(c.scrape_interval).toBe("10s")
			expect(c.evaluation_interval).toBe("10s")
			expect(c.jobs).toEqual({ "prometheus", "node", "alertmanager", "loki", "tempo", "down" })
			expect(c.rule_files).toEqual({ "/etc/prometheus/rules/*.yml" })
			expect(c.alertmanagers).toBe(1)
			expect(c.remote_write).toBe(0)
			expect(c.lines > 100).toBe(true)
		end
	end)

	it("finds external labels and remote endpoints", function()
		local c = Info.configSummary(table.concat({
			"global:",
			"  scrape_interval: 15s",
			"  external_labels:",
			"    cluster: prod",
			'    region: "eu-1"',
			"remote_write:",
			"- url: http://mimir/api/v1/push",
			"  name: a",
			"- url: http://other/api/v1/push",
			"remote_read:",
			"- url: http://thanos/read",
		}, "\n"))
		expect(c.external_labels).toEqual({ { name = "cluster", value = "prod" }, { name = "region", value = "eu-1" } })
		expect(c.remote_write).toBe(2)
		expect(c.remote_read).toBe(1)
	end)
end)

return nil
