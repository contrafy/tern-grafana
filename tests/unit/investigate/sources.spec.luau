--!strict
-- Investigate starts from what the user is looking at: the selected alert
-- (i), the query block's expression and values (I) and the focused dashboard
-- panel (I). Each only stores a draft and opens the preview: nothing reaches
-- an agent from a key in a source block.
local AlertsState = require("../../../plugin/lib/alerts/state")
local DashState = require("../../../plugin/lib/dashboard/state")
local DS = require("../dashboard/support")
local Fixtures = require("../../lib/fixtures")
local Handoff = require("../../../plugin/lib/investigate/handoff")
local QS = require("../query/support")
local QueryState = require("../../../plugin/lib/query/state")
local Scheme = require("../../../plugin/lib/links/scheme")
local Validate = require("../../../plugin/lib/config/validate")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function key(text: string): any
	return { name = text, text = text, ctrl = false, alt = false, shift = text ~= string.lower(text), meta = false }
end

-- The draft the effects store, after checking they only store and open.
local function draftOf(effects: { any }): any
	expect(#effects).toBe(2)
	local kv, open = effects[1], effects[2]
	expect(kv.kind).toBe("kv_set")
	expect(open.kind).toBe("open")
	local l = assert((Scheme.decode(open.target)), "the open effect must be a tern-grafana link")
	expect(l.action).toBe("investigate")
	expect(kv.key).toBe(Handoff.key(l.params.id))
	expect(kv.value.stage).toBe("draft")
	return json.decode(json.encode(kv.value.subject))
end

describe("alerts inbox", function()
	local cfg = assert(
		Validate.parseFile(
			[[{"default_context": "am", "contexts": {"am": {"alertmanager": {"url": "http://am:9093"}}}}]],
			json.decode
		)
	)
	local env: any = {
		now_ms = 1791577860000,
		decode = json.decode,
		encode = json.encode,
		null = json.null,
		config = cfg,
		kv_get = function(_k: string): any
			return nil
		end,
	}

	local function loaded(): any
		local s, effects = AlertsState.init({}, nil, env)
		for _, e in effects do
			if e.kind == "http" then
				AlertsState.update(s, {
					kind = "http_done",
					tag = e.tag,
					response = {
						status = 200,
						headers = {},
						body = Fixtures.read("alertmanager/0.34.1/alerts.json"),
						timed_out = false,
					},
				}, env)
			end
		end
		return s
	end

	it("i on the selected alert opens the preview with that alert", function()
		local s = loaded()
		for i, r in s.rows do
			if r.kind == "alert" then
				s.sel = i
				break
			end
		end
		local selected = assert(AlertsState.selectedAlert(s))
		local _, effects, handled = AlertsState.key(s, key("i"), env)
		expect(handled).toBe(true)
		local subject = draftOf(effects)
		expect(subject.kind).toBe("alert")
		expect(subject.alert.name).toBe(selected.labels.alertname)
		expect(subject.context).toBe("am")
	end)

	it("the detail's Investigate button does the same", function()
		local s = loaded()
		for i, r in s.rows do
			if r.kind == "alert" then
				s.sel = i
				break
			end
		end
		local _, effects = AlertsState.update(s, { kind = "event", ev = { ev = "action", act = "investigate" } }, env)
		expect(draftOf(effects).kind).toBe("alert")
	end)

	it("says to select an alert when a group header is selected", function()
		local s = loaded()
		s.sel = 1
		local _, effects = AlertsState.key(s, key("i"), env)
		expect(#effects).toBe(0)
		expect(s.note).toBe("Select an alert first.")
	end)
end)

describe("query block", function()
	it("I hands over the expression, its range and the values it shows", function()
		local env = QS.env(QS.config())
		local link = Scheme.encode({ action = "query", params = { context = "lab", expr = "up" }, vars = {} })
		local s, effects = QueryState.init({ link }, nil, env)
		local http = QS.find(effects, "http")
		QueryState.update(s, {
			kind = "http_done",
			tag = http.tag,
			response = QS.response("prometheus/3.15.0/query_range_multi.json"),
		}, env)
		local _, out, handled = QueryState.key(s, key("I"), env)
		expect(handled).toBe(true)
		local subject = draftOf(out)
		expect(subject.kind).toBe("query")
		expect(subject.queries[1].expr).toBe("up")
		expect(subject.range.from).toBe(s.from)
		expect(#subject.values.series > 0).toBe(true)
	end)

	it("I with no expression only says what to do", function()
		local env = QS.env(QS.config())
		local s = QueryState.init({}, nil, env)
		QueryState.key(s, { name = "escape", ctrl = false, alt = false, shift = false, meta = false }, env)
		local _, out = QueryState.key(s, key("I"), env)
		expect(#out).toBe(1)
		expect(out[1].kind).toBe("toast")
	end)
end)

describe("dashboard panel", function()
	it("I hands over the focused panel's interpolated queries and values", function()
		local env = DS.env()
		local version = "12.4.12"
		local s, effects = DashState.init({ "tern-grafana://dashboard?context=lab&uid=tern-panels" }, nil, env)
		local pending: { [string]: any } = {}
		local function apply(list: { any })
			for _, e in list do
				if e.kind == "http" then
					local path = if string.match(e.tag, "^dash/")
						then DS.grafana(version, "dashboard_tern_panels.json")
						elseif string.match(e.tag, "^fs/") then DS.grafana(version, "frontend_settings.json")
						elseif string.match(e.tag, "^user/") then DS.grafana(version, "user.json")
						elseif string.match(e.tag, "^lib/") then DS.grafana(version, "library_element.json")
						else nil
					if path then
						local _, more =
							DashState.update(s, { kind = "http_done", tag = e.tag, response = DS.response(path) }, env)
						apply(more)
					else
						pending[e.tag] = e
					end
				end
			end
		end
		apply(effects)
		local focus = assert(s.focus, "the dashboard focuses its first panel")
		for tag in pending do
			if string.match(tag, "/" .. focus .. "$") then
				DashState.update(s, {
					kind = "http_done",
					tag = tag,
					response = DS.response(DS.grafana(version, "ds_query_prom_range.json")),
				}, env)
			end
		end
		local _, out, handled = DashState.key(s, key("I"), env)
		expect(handled).toBe(true)
		local subject = draftOf(out)
		expect(subject.kind).toBe("panel")
		expect(subject.panel.uid).toBe("tern-panels")
		expect(#subject.queries > 0).toBe(true)
		for _, q in subject.queries do
			-- Dashboard variables are filled in; Grafana's own $__ macros stay for the agent to read.
			expect((string.find((string.gsub(q.expr, "%$__%w+", "")), "$", 1, true))).toBeNil()
		end
		expect(#subject.values.series > 0).toBe(true)
		expect(subject.links[1].label).toBe("Grafana panel")
	end)
end)

return nil
