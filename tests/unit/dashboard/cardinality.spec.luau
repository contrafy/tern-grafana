--!strict
-- The cardinality management label detail dashboard end to end: its query
-- variables run through the cardinality datasource module (the label list,
-- then the hidden multi-value labelValues with "All" as Grafana selects it
-- when nothing is saved), and the pairs table repeats once per label value
-- with that value in its selector. Synthetic dashboard in the recorded shape.
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local LABEL_VALUES = "/api/datasources/proxy/uid/prom/api/v1/cardinality/label_values"

local function param(e: any, name: string): string?
	for _, p in e.request.query or {} do
		if p[1] == name then
			return p[2]
		end
	end
	return nil
end

-- Grafana's answers by request; the pairs tables' selectors are recorded.
-- While `held.on`, the variables' requests stay unanswered (they arrive
-- after the panels were laid out, as on a real network).
local function load(selectors: { string }, held: { on: boolean }): S.Harness
	local env = S.env()
	local s, effects =
		State.init({ "tern-grafana://dashboard?context=lab&uid=cardinality-management-label-detail" }, nil, env)
	local h = S.harness(s, env, function(e: any): any
		local path = e.request.path
		local variable = path == "/api/datasources/proxy/uid/prom/api/v1/labels"
			or (path == LABEL_VALUES and param(e, "limit") == "16")
		if variable and held.on then
			return nil
		end
		if path == LABEL_VALUES and param(e, "label_names[]") ~= "__name__" then
			-- Asked before `label` resolved: Mimir knows no such label.
			return S.body(200, '{"series_count_total":88,"labels":[]}')
		end
		if string.match(e.tag, "^dash/") then
			return S.response("cardinality/dashboard_labels.json")
		elseif string.match(e.tag, "^fs/") then
			return S.response("cardinality/frontend_settings.json")
		elseif string.match(e.tag, "^flag/") then
			return S.response(S.grafana("13.3.1", "ofrep_table_auto_column_widths.json"))
		elseif string.match(e.tag, "^user/") then
			return S.response(S.grafana("13.3.1", "user.json"))
		elseif string.match(e.tag, "^layer/") then
			-- No annotations, no alert rules linked to the dashboard.
			return S.body(200, "[]")
		elseif path == "/api/datasources/proxy/uid/prom/api/v1/labels" then
			return S.response("cardinality/list_labels.json")
		elseif path == LABEL_VALUES and param(e, "selector") == "{}" then
			-- labelValues (limit 16) and the subtotal stat (limit 0).
			return S.response(
				if param(e, "limit") == "0" then "cardinality/label_subtotal.json" else "cardinality/metrics_names.json"
			)
		elseif path == LABEL_VALUES then
			table.insert(selectors, param(e, "selector") or "")
			return S.response("cardinality/pairs_details.json")
		end
		return nil
	end)
	S.drive(h, effects)
	return h
end

-- Answers every held request, until none is left.
local function release(h: S.Harness, held: { on: boolean })
	held.on = false
	while true do
		local tag, e = next(h.pending)
		if tag == nil then
			return
		end
		h.pending[tag] = nil
		local response = assert(h.answer(e), "no answer for " .. tostring(tag))
		local _, more = State.update(h.s, { kind = "http_done", tag = tag, response = response }, h.env)
		S.drive(h, more)
	end
end

describe("cardinality management label detail dashboard", function()
	it("lists labels, selects All label values and repeats the pairs table per value", function()
		local selectors: { string } = {}
		local held = { on = true }
		local h = load(selectors, held)
		release(h, held)
		local label, values
		for _, v in h.s.vars do
			if v.name == "label" then
				label = v
			elseif v.name == "labelValues" then
				values = v
			end
		end
		assert(label and values, "variables")
		expect(label.status).toBe("ready")
		expect(label.values).toEqual({ "__name__" })
		expect(values.status).toBe("ready")
		expect(#values.options).toBe(4)
		expect(values.values).toEqual({ "$__all" })
		table.sort(selectors)
		expect(selectors).toEqual({
			"{__name__='checkout_latency_seconds_bucket'}",
			"{__name__='checkout_requests_total'}",
			"{__name__='queue_depth'}",
			"{__name__='worker_up'}",
		})
		for key, ps in h.s.panels do
			if string.match(key, "^p10") then
				expect(ps.status).toBe("ready")
			end
		end
		expect((next(h.pending))).toBeNil()
	end)
end)

return nil
