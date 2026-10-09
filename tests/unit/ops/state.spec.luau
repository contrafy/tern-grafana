--!strict
-- The ops block loads a tab's endpoints only when the tab first shows (a
-- cardinality scan is not free), drops answers meant for a context the user
-- left, keeps the last good answer next to a failed refresh, and tells a
-- server without an endpoint apart from a failing one. Rules belong to the
-- alerts block: the tab is a link there, opened only on the user's say-so
-- (init must stay side-effect free because Tern re-runs it on restore).
-- Saved state names what to reopen, never server data.
local Fixtures = require("../../lib/fixtures")
local Scheme = require("../../../plugin/lib/links/scheme")
local State = require("../../../plugin/lib/ops/state")
local Validate = require("../../../plugin/lib/config/validate")
local View = require("../../../plugin/lib/ops/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577900000

local CFG = (function(): any
	local cfg, problems = Validate.parseFile(
		[[{"default_context": "lab", "contexts": {
		"lab": {"prometheus": {"url": "http://p:9090"}},
		"g11": {"grafana": {"url": "http://g:3011", "datasources": {"prometheus": "prom3"}}},
		"logs": {"loki": {"url": "http://l:3100"}}}}]],
		json.decode
	)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end)()

local ENV: any = { now_ms = NOW, decode = json.decode, encode = json.encode, null = json.null, config = CFG }

local function ok(path: string): any
	return { status = 200, headers = {}, body = Fixtures.read(path), timed_out = false }
end

local function notFound(): any
	return { status = 404, headers = {}, body = Fixtures.read("loki/3.7.8/targets_404.txt"), timed_out = false }
end

local function key(text: string, name: string?): any
	return {
		name = name or text,
		text = if name then nil else text,
		ctrl = false,
		alt = false,
		shift = false,
		meta = false,
	}
end

local function https(effects: { any }): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "http" then
			table.insert(out, e)
		end
	end
	return out
end

local function tags(effects: { any }): { string }
	local out = {}
	for _, e in https(effects) do
		table.insert(out, e.tag)
	end
	return out
end

local function find(effects: { any }, kind: string): any
	for _, e in effects do
		if e.kind == kind then
			return e
		end
	end
	return nil
end

-- Fixture file for an endpoint under `dir` (a prometheus version dir or a
-- grafana version dir, which names files ds_proxy_prom_<x>).
local function fixture(dir: string, endpoint: string): string
	if string.find(dir, "^grafana/") then
		return dir .. "/ds_proxy_prom_" .. endpoint .. ".json"
	end
	return dir .. "/" .. endpoint .. ".json"
end

local function answer(s: any, effects: { any }, respond: (endpoint: string) -> any): (any, { any })
	local out = {}
	for _, e in https(effects) do
		local endpoint = string.match(e.tag, ":(.+)$") :: string
		local more
		s, more = State.update(s, { kind = "http_done", tag = e.tag, response = respond(endpoint) }, ENV)
		for _, m in more do
			table.insert(out, m)
		end
	end
	return s, out
end

local function from(dir: string): (string) -> any
	return function(endpoint: string): any
		return ok(fixture(dir, endpoint))
	end
end

local function press(s: any, k: any): (any, { any })
	local _, effects = State.key(s, k, ENV)
	return s, effects
end

local function action(s: any, act: string, value: string?): (any, { any })
	return State.update(s, { kind = "event", ev = { ev = "action", act = act, value = value } }, ENV)
end

-- Every text span in a view tree, joined.
local function text(node: any): string
	local out = {}
	local function walk(n: any)
		if type(n) ~= "table" then
			return
		end
		local p = n.p
		if p then
			for _, field in { "spans", "head" } do
				if type(p[field]) == "table" then
					for _, sp in p[field] do
						table.insert(out, sp.t)
					end
				end
			end
			if type(p.text) == "string" then
				table.insert(out, p.text)
			end
			if type(p.items) == "table" then
				for _, item in p.items do
					for _, sp in item.k do
						table.insert(out, sp.t)
					end
					for _, sp in item.v do
						table.insert(out, sp.t)
					end
				end
			end
		end
		for _, c in n.c or {} do
			walk(c)
		end
	end
	walk(node)
	return table.concat(out, " ")
end

local function shows(s: any, needle: string): boolean
	local view: any = View.view(s, ENV)
	return string.find(text(view.main), needle, 1, true) ~= nil
end

local function link(params: { [string]: string }): string
	return Scheme.encode({ action = "ops", params = params, vars = {} })
end

describe("loading tabs", function()
	it("loads buildinfo and the targets on open, and nothing else", function()
		local _, effects = State.init({}, nil, ENV)
		expect(tags(effects)).toEqual({ "1:buildinfo", "1:targets" })
		expect(find(effects, "open")).toBeNil()
		expect(https(effects)[2].request.path).toBe("/api/v1/targets")
	end)

	it("shows targets of both Prometheus versions and through Grafana's proxy", function()
		for _, dir in { "prometheus/2.53.5", "prometheus/3.15.0", "grafana/11.6.16", "grafana/12.4.12" } do
			local ctx = if string.find(dir, "^grafana") then "g11" else "lab"
			local s, effects = State.init({ link({ context = ctx }) }, nil, ENV)
			if ctx == "g11" then
				expect(https(effects)[2].request.path).toBe("/api/datasources/proxy/uid/prom3/api/v1/targets")
			end
			s = answer(s, effects, from(dir))
			expect(State.title(s)).toBe("Ops: " .. ctx .. " (1 down)")
			expect(s.rows[1].kind).toBe("pool")
			expect(s.pools[1].name).toBe("down")
			expect(shows(s, "node-exporter:9999")).toBe(true)
			expect(shows(s, "Prometheus API")).toBe(true)
		end
	end)

	it("loads a tab the first time it shows and reloads it only on r", function()
		local s, effects = State.init({}, nil, ENV)
		s = answer(s, effects, from("prometheus/3.15.0"))
		s, effects = press(s, key("3"))
		expect(s.tab).toBe("cardinality")
		expect(tags(effects)).toEqual({ "1:tsdb" })
		expect(https(effects)[1].request.query).toEqual({ { "limit", "10" } })
		s = answer(s, effects, from("prometheus/3.15.0"))
		s, effects = press(s, key("tab", "tab"))
		expect(s.tab).toBe("info")
		expect(tags(effects)).toEqual({ "1:runtimeinfo", "1:flags", "1:config" })
		s = answer(s, effects, from("prometheus/3.15.0"))
		s, effects = press(s, key("3"))
		expect(#https(effects)).toBe(0)
		s, effects = press(s, key("r"))
		expect(tags(effects)).toEqual({ "1:tsdb" })
	end)

	it("opens on the tab a link names", function()
		local s, effects = State.init({ link({ view = "info" }) }, nil, ENV)
		expect(s.tab).toBe("info")
		expect(tags(effects)).toEqual({ "1:buildinfo", "1:runtimeinfo", "1:flags", "1:config" })
	end)

	it("drops answers for a context the user switched away from", function()
		local s, effects = State.init({}, nil, ENV)
		local stale = effects
		s, effects = action(s, "ctx", "g11")
		expect(tags(effects)).toEqual({ "2:buildinfo", "2:targets" })
		s = answer(s, stale, from("prometheus/3.15.0"))
		expect(s.targets).toBeNil()
		s = answer(s, effects, from("grafana/11.6.16"))
		expect(#(s.targets :: any).active).toBe(6)
	end)

	it("says why a context without any metrics endpoint cannot load", function()
		local s, effects = State.init({ link({ context = "logs" }) }, nil, ENV)
		expect(#https(effects)).toBe(0)
		expect(s.problem ~= nil and string.find(s.problem, "prometheus", 1, true) ~= nil).toBe(true)
		expect(shows(s, "grafana")).toBe(true)
	end)
end)

describe("failures", function()
	it("shows a missing endpoint as unsupported per tab, not as an error", function()
		local s, effects = State.init({}, nil, ENV)
		s = answer(s, effects, function(endpoint: string): any
			return if endpoint == "targets" then notFound() else ok("prometheus/3.15.0/buildinfo.json")
		end)
		expect((s.slots :: any).targets.error.kind).toBe("unsupported")
		expect(shows(s, "Targets unavailable")).toBe(true)
		expect(shows(s, "/api/v1/targets")).toBe(true)
		s, effects = press(s, key("3"))
		s = answer(s, effects, function(): any
			return notFound()
		end)
		expect(shows(s, "Cardinality unavailable")).toBe(true)
		-- Each tab answers for itself: the build info still names the server.
		expect(shows(s, "Prometheus API 3.15.0")).toBe(true)
	end)

	it("keeps the last good targets next to a failed refresh", function()
		local s, effects = State.init({}, nil, ENV)
		s = answer(s, effects, from("prometheus/3.15.0"))
		s, effects = press(s, key("r"))
		s = answer(s, effects, function(): any
			return { status = 0, headers = {}, body = "", error = "connection refused", timed_out = false }
		end)
		expect(#(s.targets :: any).active).toBe(6)
		expect(shows(s, "connection refused")).toBe(true)
		expect(shows(s, "showing the last good answer")).toBe(true)
	end)
end)

describe("actions", function()
	it("filters targets and toggles unhealthy only", function()
		local s, effects = State.init({}, nil, ENV)
		s = answer(s, effects, from("prometheus/3.15.0"))
		s, effects = press(s, key("/"))
		expect(find(effects, "focus").id).toBe("main.filter")
		for _, c in string.split("job=loki", "") do
			s = press(s, key(c))
		end
		s = press(s, key("enter", "enter"))
		expect(#s.pools).toBe(1)
		expect(s.pools[1].name).toBe("loki")
		s = press(s, key("escape", "escape"))
		s = press(s, key("u"))
		expect(#s.pools).toBe(1)
		expect(s.pools[1].name).toBe("down")
	end)

	it("expands a target's detail with its labels and scrape URL", function()
		local s, effects = State.init({}, nil, ENV)
		s = answer(s, effects, from("prometheus/3.15.0"))
		s = press(s, key("j"))
		s = press(s, key("enter", "enter"))
		expect(s.detail).toBe("down http://node-exporter:9999/metrics")
		expect(shows(s, "http://node-exporter:9999/metrics")).toBe(true)
		s = press(s, key("k"))
		s = press(s, key("enter", "enter"))
		-- Collapsing the pool hides its target and closes the detail with it.
		expect(#s.rows).toBe(11)
		expect(s.detail).toBeNil()
	end)

	it("scrolls the keyboard selection into view by an id the view really has", function()
		-- Tern ids: region, then each ancestor's key or 0-based index.
		local function resolve(view: any, id: string): any
			local parts = string.split(id, ".")
			local node = view[parts[1]]
			for i = 2, #parts do
				local found = nil
				for j, c in node.c or {} do
					local k = if c.p and c.p.key ~= nil then tostring(c.p.key) else tostring(j - 1)
					if k == parts[i] then
						found = c
						break
					end
				end
				node = found
				if node == nil then
					return nil
				end
			end
			return node
		end
		local s, effects = State.init({}, nil, ENV)
		s = answer(s, effects, from("prometheus/3.15.0"))
		s, effects = press(s, key("j"))
		local id = find(effects, "reveal").id
		expect(id).toBe("main.pools.p1.r2")
		expect(resolve(View.view(s, ENV), id).p.class).toBe("tg-op-row tg-op-down is-sel")
		s, effects = press(s, key("3"))
		s = answer(s, effects, from("prometheus/3.15.0"))
		s, effects = press(s, key("end", "end"))
		id = find(effects, "reveal").id
		expect(id).toBe("main.l_series_by_metric.g.0.e10.0")
		expect(resolve(View.view(s, ENV), id).p.class).toBe("tg-c")
	end)

	it("opens the alerts Rules view only when asked", function()
		local s, effects = State.init({ link({ view = "rules" }) }, nil, ENV)
		expect(find(effects, "open")).toBeNil()
		expect(tags(effects)).toEqual({ "1:buildinfo" })
		s, effects = press(s, key("enter", "enter"))
		expect(find(effects, "open").target).toBe("tern-grafana://alerts?context=lab&view=rules")
	end)

	it("opens the Query block on a cardinality entry and changes the top N", function()
		local s, effects = State.init({ link({ view = "cardinality" }) }, nil, ENV)
		s = answer(s, effects, from("prometheus/3.15.0"))
		expect(#s.card_rows).toBe(10)
		s, effects = press(s, key("enter", "enter"))
		local opened = Scheme.decode(find(effects, "open").target) :: any
		expect(opened.action).toBe("query")
		expect(opened.params.context).toBe("lab")
		expect(opened.params.expr).toBe('count by (job) ({__name__="tempo_request_duration_seconds_bucket"})')
		s, effects = press(s, key("+"))
		expect(https(effects)[1].request.query).toEqual({ { "limit", "20" } })
		s = State.update(s, { kind = "event", ev = { ev = "toggle", id = "main.l_series_by_pair" } }, ENV)
		expect(#s.card_rows).toBe(20)
		expect(shows(s, "job=loki")).toBe(true)
	end)

	it("copies the config YAML from the Info tab", function()
		local s, effects = State.init({ link({ view = "info" }) }, nil, ENV)
		s = answer(s, effects, from("prometheus/2.53.5"))
		expect(shows(s, "/etc/prometheus/prometheus.yml")).toBe(true)
		expect(shows(s, "prometheus, node, alertmanager, loki, tempo, down")).toBe(true)
		s, effects = press(s, key("y"))
		expect(string.sub(find(effects, "copy").text, 1, 7)).toBe("global:")
	end)
end)

describe("save", function()
	it("keeps what to reopen with and no server data", function()
		local s, effects = State.init({ link({ view = "cardinality", context = "g11" }) }, nil, ENV)
		s = answer(s, effects, from("grafana/12.4.12"))
		local saved = State.save(s)
		expect(saved).toEqual({
			context = "g11",
			tab = "cardinality",
			filter = "",
			unhealthy_only = false,
			tsdb_limit = 10,
			open_lists = { "series_by_metric" },
		})
		local again = State.init({}, json.decode(json.encode(saved)), ENV)
		expect(again.tab).toBe("cardinality")
		expect(again.context).toBe("g11")
	end)
end)

return nil
