--!strict
-- The inbox must show what the server says right now: answers to a request
-- the user already moved away from (context switch, refresh) are dropped, a
-- failed refresh keeps the last good alerts on screen with the error, and
-- muted alerts stay out of the way until asked for. Opening the inbox also
-- refreshes the status segment's summary, but only for contexts the poller
-- watches, and the block's saved state never holds alert data.
local Fixtures = require("../../lib/fixtures")
local Render = require("../../../plugin/lib/alerts/render")
local State = require("../../../plugin/lib/alerts/state")
local Summary = require("../../../plugin/lib/alerts/summary")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local Scheme = require("../../../plugin/lib/links/scheme")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local NOW = 1791577860000

local CFG = (function(): any
	local cfg, problems = Validate.parseFile(
		[[{"default_context": "graf", "contexts": {
		"graf": {"grafana": {"url": "http://g"}},
		"am": {"alertmanager": {"url": "http://am:9093"}},
		"prom": {"prometheus": {"url": "http://p:9090"}}},
		"alerts": {"contexts": ["graf", "am"]}}]],
		json.decode
	)
	assert(cfg, problems[1] and Validate.format(problems[1]))
	return cfg
end)()

local function makeEnv(kv: { [string]: any }?): any
	return {
		now_ms = NOW,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		config = CFG,
		kv_get = function(key: string): any
			return if kv then kv[key] else nil
		end,
	}
end

local function ok(path: string): any
	return { status = 200, headers = {}, body = Fixtures.read(path), timed_out = false }
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

local function kinds(effects: { any }): { string }
	local out = {}
	for _, e in effects do
		table.insert(out, e.kind .. (if e.tag then " " .. e.tag else ""))
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

-- Answers every http effect with the fixture for its tag.
local function answer(s: any, effects: { any }, env: any, bodies: { [string]: any }): { any }
	local out = {}
	for _, e in effects do
		if e.kind == "http" then
			local tag = string.match(e.tag, ":(.+)$") :: string
			local _, more = State.update(s, { kind = "http_done", tag = e.tag, response = bodies[tag] }, env)
			for _, m in more do
				table.insert(out, m)
			end
		end
	end
	return out
end

local GRAFANA = {
	am = ok("grafana/12.4.12/alerting_am_alerts_silenced.json"),
	rules = ok("grafana/12.4.12/alerting_prom_alerts.json"),
}

local function names(s: any): { string }
	local out = {}
	for _, r in s.rows do
		if r.kind == "alert" then
			table.insert(out, r.alert.labels.alertname .. ":" .. r.alert.state)
		end
	end
	return out
end

local function loaded(args: { string }?): (any, any, { any })
	local env = makeEnv()
	local s, effects = State.init(args or {}, nil, env)
	local after = answer(s, effects, env, GRAFANA)
	return s, env, after
end

describe("loading", function()
	it("reads Grafana-managed alerts and pending ones, hiding the silenced alert", function()
		local env = makeEnv()
		local s, effects = State.init({}, nil, env)
		expect(kinds(effects)).toEqual({ "http 1:am", "http 1:rules" })
		local after = answer(s, effects, env, GRAFANA)
		expect(names(s)).toEqual({ "TernGrafanaTargetDown:firing", "TernGrafanaPending:pending" })
		expect(#s.alerts).toBe(3)
		expect(State.title(s)).toBe("Alerts: graf (1 firing)")
		expect(find(after, "timer").ms).toBe(60000)
	end)

	it("writes the context's summary for the status segment, keeping other contexts", function()
		local env = makeEnv({ [Summary.KEY] = Summary.payload({ am = Summary.empty(1) }, 1, 60) })
		local s, effects = State.init({}, nil, env)
		local after = answer(s, effects, env, GRAFANA)
		local kv = find(after, "kv_set")
		expect(kv.key).toBe("tern-grafana.alerts.summary")
		expect(kv.value.contexts.graf.firing).toBe(1)
		expect(kv.value.contexts.graf.pending).toBe(1)
		expect(kv.value.contexts.graf.silenced).toBe(1)
		expect(kv.value.contexts.am.updated_ms).toBe(1)
	end)

	it("does not add a context the poller does not watch to the summary", function()
		local env = makeEnv()
		local s, effects = State.init({ "tern-grafana://alerts?context=prom" }, nil, env)
		local after = answer(s, effects, env, { prom = ok("prometheus/3.15.0/alerts.json") })
		expect(find(after, "kv_set")).toBeNil()
		expect(names(s)).toEqual({ "TernAlwaysFiring:firing", "TernTargetDown:firing", "TernPending:pending" })
	end)

	it("drops answers to a request superseded by a context switch", function()
		local env = makeEnv()
		local s, first = State.init({}, nil, env)
		local _, switched = State.update(s, { kind = "event", ev = { ev = "action", act = "ctx", value = "am" } }, env)
		expect(kinds(switched)).toEqual({ "http 2:am" })
		answer(s, first, env, GRAFANA)
		expect(s.loading).toBe(true)
		expect(#s.alerts).toBe(0)
		answer(s, switched, env, { am = ok("alertmanager/0.34.1/alerts.json") })
		expect(#s.alerts).toBe(4)
		expect(s.context).toBe("am")
	end)

	it("keeps the last good alerts on screen when a refresh fails, and marks the summary failed", function()
		local s, env = loaded()
		local _, effects = State.key(s, key("r"), env)
		local after = answer(s, effects, env, {
			am = { status = 0, headers = {}, body = "", error = "timeout", timed_out = true },
			rules = GRAFANA.rules,
		})
		expect(#s.alerts).toBe(3)
		expect(s.error ~= nil).toBe(true)
		expect(find(after, "kv_set").value.contexts.graf.error).toBe("timeout")
	end)

	it("refreshes on its timer only for the current load", function()
		local s, env = loaded()
		local _, stale = State.update(s, { kind = "tick", tag = "auto:0" }, env)
		expect(#stale).toBe(0)
		local _, fresh = State.update(s, { kind = "tick", tag = "auto:" .. s.gen }, env)
		expect(kinds(fresh)).toEqual({ "http 2:am", "http 2:rules" })
	end)

	it("falls back to the default context when a link names an unknown one", function()
		local env = makeEnv()
		local s, effects = State.init({ "tern-grafana://alerts?context=nope" }, nil, env)
		expect(s.context).toBe("graf")
		expect(#effects).toBe(2)
	end)

	it("explains an unroutable context instead of loading nothing", function()
		local env = makeEnv()
		env.config = Validate.parseFile(
			'{"default_context": "l", "contexts": {"l": {"loki": {"url": "http://l"}}}}',
			json.decode
		)
		local s, effects = State.init({}, nil, env)
		expect(#effects).toBe(0)
		expect(s.problem).toBe('context "l" has no alertmanager, grafana or prometheus endpoint')
	end)
end)

describe("filter and view", function()
	it("filters with typed matchers, and escape clears the filter", function()
		local s, env = loaded()
		State.key(s, key("/"), env)
		for c in string.gmatch("severity=info", ".") do
			State.key(s, key(c), env)
		end
		State.key(s, key("", "enter"), env)
		expect(s.filter_text).toBe("severity=info")
		expect(names(s)).toEqual({ "TernGrafanaPending:pending" })
		State.key(s, key("", "escape"), env)
		expect(s.filter_text).toBe("")
		expect(#names(s)).toBe(2)
	end)

	it("shows silenced alerts on demand", function()
		local s, env = loaded()
		State.key(s, key("m"), env)
		expect(names(s)).toEqual({
			"TernGrafanaTargetDown:firing",
			"TernGrafanaPending:pending",
			"TernGrafanaAlwaysFiring:silenced",
		})
	end)

	it("opens a rule's alerts from a link with its rule uid", function()
		local s = loaded({ "tern-grafana://alerts?rule=tern-g-targetdown" })
		expect(names(s)).toEqual({ "TernGrafanaTargetDown:firing" })
	end)

	it("opens the native silence form for the selected alert, prefilled with its labels, and its runbook", function()
		local s, env = loaded()
		State.key(s, key("", "down"), env)
		local _, effects = State.key(s, key("s"), env)
		local link = assert(Scheme.decode(find(effects, "open").target))
		expect(link.action).toBe("silence")
		expect(link.params.context).toBe("graf")
		expect(string.find(link.params.matchers, 'alertname="TernGrafanaTargetDown"', 1, true) ~= nil).toBe(true)
		expect(string.find(link.params.matchers, '__alert_rule_uid__="tern-g-targetdown"', 1, true) ~= nil).toBe(true)
		_, effects = State.key(s, key("o"), env)
		expect(find(effects, "open").target).toBe("https://example.com/runbooks/target-down")
		_, effects = State.key(s, key("d"), env)
		expect(#effects).toBe(0)
		expect(s.note).toBe("This alert has no dashboard link.")
	end)

	it("has no silence page on a Prometheus-only context and says so", function()
		local env = makeEnv()
		local s, effects = State.init({ "tern-grafana://alerts?context=prom" }, nil, env)
		answer(s, effects, env, { prom = ok("prometheus/3.15.0/alerts.json") })
		State.key(s, key("", "down"), env)
		local _, opened = State.key(s, key("s"), env)
		expect(#opened).toBe(0)
		expect(string.find(s.note :: string, "Prometheus has no silences", 1, true) ~= nil).toBe(true)
	end)

	it("collapses a group from its card and keeps the selection on it", function()
		local s, env = loaded()
		State.update(s, { kind = "event", ev = { ev = "toggle", id = "main.groups.g1" } }, env)
		expect(names(s)).toEqual({ "TernGrafanaPending:pending" })
		expect(s.rows[s.sel].kind).toBe("group")
	end)

	it("shows the open alert's labels and annotations without Grafana's internal ones", function()
		local s, env = loaded()
		State.key(s, key("", "down"), env)
		State.key(s, key("", "enter"), env)
		local text = json.encode(Render.view(s, env))
		expect(string.find(text, "runbooks/target-down", 1, true) ~= nil).toBe(true)
		expect(string.find(text, "node-exporter:9999", 1, true) ~= nil).toBe(true)
		expect((string.find(text, "__value_string__", 1, true))).toBeNil()
		expect((string.find(text, "__alert_rule_uid__", 1, true))).toBeNil()
	end)

	it("saves only what to reopen with", function()
		local s, env = loaded()
		State.key(s, key("m"), env)
		expect(State.save(s)).toEqual({
			context = "graf",
			filter = "",
			show_muted = true,
			view = "inbox",
			problems_only = false,
		})
	end)
end)

return nil
