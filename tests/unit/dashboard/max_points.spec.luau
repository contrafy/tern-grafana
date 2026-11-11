--!strict
-- A panel asks for as many points as it is wide, as Grafana's
-- SceneQueryRunner does (maxDataPoints from the panel's container width):
-- the dashboard block's width in px laid out on Grafana's grid, each
-- w-column panel w/24 x (W + 8) - 8. A resize alone sends nothing (Grafana
-- only remembers the new width); the next query the panel sends anyway (a
-- refresh, a range or variable change) takes it.
local Core = require("../../../plugin/lib/dashboard/core")
local PanelState = require("../../../plugin/lib/dashboard/panel_state")
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local LINK = "tern-grafana://dashboard?context=lab&uid=tern-sql"
local VERSION = S.VERSIONS[1]

local function loading(e: any): any
	if string.match(e.tag, "^dash/") then
		return S.response(S.grafana(VERSION, "dashboard_tern_sql.json"))
	elseif string.match(e.tag, "^fs/") then
		return S.response(S.grafana(VERSION, "frontend_settings_sql.json"))
	elseif string.match(e.tag, "^flag/") then
		return S.response(S.grafana(VERSION, "ofrep_table_auto_column_widths.json"))
	elseif string.match(e.tag, "^user/") then
		return S.response(S.grafana(VERSION, "user.json"))
	end
	return nil
end

-- The pending /api/ds/query bodies by panel state key (taken off pending).
local function take(h: S.Harness): { [string]: any }
	local out: { [string]: any } = {}
	for tag, e in h.pending do
		local k = string.match(tag, "^q/%d+/%d+/(.+)$")
		if k then
			out[k] = json.decode(e.request.body)
			h.pending[tag] = nil
		end
	end
	return out
end

local function answer(h: S.Harness, tag: string)
	local response = S.response(S.grafana(VERSION, "ds_query_sql_4.json"))
	local _, effects = State.update(h.s, { kind = "http_done", tag = tag, response = response }, h.env)
	S.drive(h, effects)
end

describe("maxDataPoints from the panel width", function()
	it("sends each panel's width in px and keeps it until the panel queries again", function()
		local env = S.env()
		env.cols, env.rows = 200, 50
		local s, effects = State.init({ LINK }, nil, env)
		local h = S.harness(s, env, loading)
		S.drive(h, effects)
		local tags: { [string]: string } = {}
		for tag in h.pending do
			local k = string.match(tag, "^q/%d+/%d+/(.+)$")
			if k then
				tags[k] = tag
			end
		end
		local first = take(h)
		-- 200 cells: a 1580 px grid; panel 1 is 12 columns, panel 3 eight.
		expect(Core.designWidth(env)).toBe(1580)
		expect(first.p1.queries[1].maxDataPoints).toBe(786)
		expect(first.p3.queries[1].maxDataPoints).toBe(521)

		-- Narrower: an answer runs the machine again, and nothing is re-sent.
		env.cols = 100
		answer(h, tags.p4)
		expect((next(take(h)))).toBeNil()

		-- A refresh sends every query again, at the width the panels have now.
		local _, more = State.update(
			h.s,
			{ kind = "key", key = { name = "r", text = "r", ctrl = false, alt = false, shift = false, meta = false } } :: any,
			env
		)
		S.drive(h, more)
		local again = take(h)
		expect(again.p1.queries[1].maxDataPoints).toBe(391)
		-- 1 h / 391 = 9.2 s, Grafana's 10s, raised to SqlDatasource's 1m.
		expect(again.p1.queries[1].intervalMs).toBe(60000)
	end)

	it("gives a pinned panel the whole width", function()
		local env = S.env()
		env.cols, env.rows = 200, 50
		local s, effects = PanelState.init({ "tern-grafana://panel?context=lab&uid=tern-sql&panel=3" }, nil, env)
		local h = S.harness(s, env, loading)
		S.drive(h, effects)
		expect(take(h).p3.queries[1].maxDataPoints).toBe(1580)
	end)
end)

return nil
