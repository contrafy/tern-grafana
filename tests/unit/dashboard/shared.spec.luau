--!strict
-- A `-- Dashboard --` panel (public/app/plugins/datasource/dashboard/
-- datasource.ts) shows another panel's results: Tern sends no query for it,
-- feeds it the source panel's frames (with the source's transformations when
-- the query says withTransforms), queries a source that is not on screen for
-- it, and shows Grafana's "Could not find source panel" when the source is
-- gone. The reused frames are derived once per source answer, so the view
-- memo (keyed on data identity) does not redraw for nothing.
local PanelState = require("../../../plugin/lib/dashboard/panel_state")
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local LINK = "tern-grafana://dashboard?context=lab&uid=tern-sql"

type Harness = { s: State.State, env: any, pending: { [string]: any } }

-- Answers the loading requests from fixtures; panel queries stay pending.
local function apply(h: Harness, version: string, dashboard: string?, effects: { any })
	for _, e in effects do
		if e.kind ~= "http" then
			continue
		end
		local response: any = nil
		if string.match(e.tag, "^dash/") then
			response = if dashboard
				then S.body(200, dashboard)
				else S.response(S.grafana(version, "dashboard_tern_sql.json"))
		elseif string.match(e.tag, "^fs/") then
			response = S.response(S.grafana(version, "frontend_settings_sql.json"))
		elseif string.match(e.tag, "^user/") then
			response = S.response(S.grafana(version, "user.json"))
		end
		if response then
			local _, more = State.update(h.s, { kind = "http_done", tag = e.tag, response = response }, h.env)
			apply(h, version, dashboard, more)
		else
			h.pending[e.tag] = e
		end
	end
end

local function start(version: string, link: string, solo: boolean, dashboard: string?): Harness
	local env = S.env()
	local s, effects
	if solo then
		s, effects = PanelState.init({ link }, nil, env)
	else
		s, effects = State.init({ link }, nil, env)
	end
	local h: Harness = { s = s, env = env, pending = {} }
	apply(h, version, dashboard, effects)
	return h
end

-- Pending query tags by panel state key.
local function queries(h: Harness): { [string]: string }
	local out: { [string]: string } = {}
	for tag in h.pending do
		local k = string.match(tag, "^q/%d+/%d+/(.+)$")
		if k then
			out[k] = tag
		end
	end
	return out
end

local function answer(h: Harness, version: string, key: string, pid: number)
	local tag = assert(queries(h)[key], "no pending query for " .. key)
	h.pending[tag] = nil
	local response = S.response(S.grafana(version, "ds_query_sql_" .. pid .. ".json"))
	State.update(h.s, { kind = "http_done", tag = tag, response = response }, h.env)
end

local function displayNames(frame: any): { string }
	local out: { string } = {}
	for _, f in frame.fields do
		table.insert(out, if f.config and f.config.displayName then f.config.displayName else f.name)
	end
	return out
end

for _, version in S.VERSIONS do
	describe("-- Dashboard -- panels of tern-sql on Grafana " .. version, function()
		it("draws every tern-sql panel natively: SQL, the expression and the reusing panel", function()
			local h = start(version, LINK, false)
			local modes: { [string]: string } = {}
			for k, ps in h.s.panels do
				modes[k] = ps.decision.mode .. (if ps.decision.reason then ": " .. ps.decision.reason else "")
			end
			expect(modes).toEqual({
				p1 = "native",
				p2 = "native",
				p3 = "native",
				p4 = "native",
				p5 = "native",
				p6 = "native",
				p7 = "native",
			})
		end)

		it("sends no query for the reusing panel and shows the source's transformed frames", function()
			local h = start(version, LINK, false)
			local q = queries(h)
			expect(q.p4 ~= nil).toBe(true)
			expect(q.p6).toBeNil()
			expect(h.s.panels.p6.decision.mode).toBe("native")
			answer(h, version, "p4", 4)
			local ps = h.s.panels.p6
			expect(ps.status).toBe("ready")
			local data = assert(ps.data, "panel 6 has data")
			expect(#data.frames).toBe(1)
			-- withTransforms: panel 4's organize rename applies, as in Grafana's render.
			expect(displayNames(data.frames[1])).toEqual({ "name", "team", "region", "replicas", "Error rate" })
			expect(#data.frames[1].fields[1].values).toBe(4)
			-- Another panel's answer leaves the reused frames (and the view memo) alone.
			answer(h, version, "p1", 1)
			expect(h.s.panels.p6.data == data).toBe(true)
		end)

		it("queries the source panel for the reusing panel when the source is not shown", function()
			local h = start(version, "tern-grafana://panel?context=lab&uid=tern-sql&panel=6", true)
			local q = queries(h)
			expect(q["=p4"] ~= nil).toBe(true)
			expect(q.p4).toBeNil()
			expect(h.s.panels.p6.status).toBe("loading")
			answer(h, version, "=p4", 4)
			local ps = h.s.panels.p6
			expect(ps.status).toBe("ready")
			expect(#(assert(ps.data, "panel 6 has data")).frames[1].fields).toBe(5)
		end)

		it("shows Grafana's error when the source panel does not exist", function()
			local doc = S.doc(S.grafana(version, "dashboard_tern_sql.json"))
			for _, p in doc.dashboard.panels do
				if p.id == 6 then
					p.targets[1].panelId = 99
				end
			end
			local h = start(version, LINK, false, json.encode(doc))
			local ps = h.s.panels.p6
			expect(ps.decision.mode).toBe("native")
			expect(ps.status).toBe("error")
			expect(ps.error).toBe(State.NO_SOURCE_PANEL)
		end)
	end)
end

return nil
