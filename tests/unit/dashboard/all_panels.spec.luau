--!strict
-- tern-all-panels (one panel per core type plus the clock panel) as both
-- Grafanas serve it, against the queries their frontends sent
-- (ds_query_all_panels_<id>.request.json): panel time overrides and query
-- options must produce the same range and resolution, every panel lands on
-- the rung its type allows, and the no-query gauges draw Grafana's
-- placeholder value.
local Gauge = require("../../../plugin/lib/panels/gauge")
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local View = require("../../../plugin/lib/dashboard/view")
local json = require("../../lib/json")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

-- The capture's "now": panel 3 (timeFrom 2h, no shift) ends there.
local function captureNow(version: string): number
	local r = S.doc(S.grafana(version, "ds_query_all_panels_3.request.json"))
	return tonumber(r.to) :: number
end

type Harness = { s: State.State, env: any, pending: { [string]: any } }

local function fixtureFor(version: string, tag: string): string?
	if string.match(tag, "^dash/") then
		return S.grafana(version, "dashboard_tern_all_panels.json")
	elseif string.match(tag, "^fs/") then
		return S.grafana(version, "frontend_settings_all_panels.json")
	elseif string.match(tag, "^user/") then
		return S.grafana(version, "user.json")
	end
	return nil
end

local function apply(h: Harness, version: string, effects: { any })
	for _, e in effects do
		local path = if e.kind == "http" then fixtureFor(version, e.tag) else nil
		if path then
			local _, more = State.update(h.s, { kind = "http_done", tag = e.tag, response = S.response(path) }, h.env)
			apply(h, version, more)
		elseif e.kind == "http" or e.kind == "timer" then
			h.pending[e.tag] = e
		end
	end
end

local function start(version: string): Harness
	local env = S.env()
	env.now_ms = captureNow(version)
	local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=tern-all-panels" }, nil, env)
	local h: Harness = { s = s, env = env, pending = {} }
	apply(h, version, effects)
	return h
end

local function query(h: Harness, id: number): any
	for tag, e in h.pending do
		if string.match(tag, "^q/%d+/%d+/p" .. id .. "$") then
			return json.decode(e.request.body)
		end
	end
	error("no query for panel " .. id)
end

for _, version in S.VERSIONS do
	local newGauge = version == "12.4.12"

	describe("tern-all-panels on Grafana " .. version, function()
		it("queries over the panel's timeFrom/timeShift range as Grafana's frontend did", function()
			local h = start(version)
			for _, id in { 2, 3 } do
				local sent = S.doc(S.grafana(version, "ds_query_all_panels_" .. id .. ".request.json"))
				local body = query(h, id)
				expect(body.from).toBe(sent.from)
				expect(body.to).toBe(sent.to)
			end
			-- Panel 3's maxDataPoints 50 and min interval 2m set the resolution.
			local sent3 = S.doc(S.grafana(version, "ds_query_all_panels_3.request.json")).queries[1]
			local q3 = query(h, 3).queries[1]
			expect(q3.maxDataPoints).toBe(sent3.maxDataPoints)
			expect(q3.intervalMs).toBe(sent3.intervalMs)
		end)

		it("shows the override info in the header unless hideTimeOverride", function()
			local h = start(version)
			expect((h.s.panels.p2.time :: any).info).toBe("Last 30 minutes timeshift -1h")
			expect((h.s.panels.p3.time :: any).info).toBe("")
		end)

		it("never queries the no-query gauges, text and input clocks", function()
			local h = start(version)
			for _, id in { 8, 9, 15, 37, 38, 39, 41 } do
				for tag in h.pending do
					expect(string.match(tag, "^q/%d+/%d+/p" .. id .. "$")).toBeNil()
				end
				expect(h.s.panels["p" .. id].decision.mode).toBe("native")
			end
			-- The clock with a query source does query.
			expect(query(h, 40) ~= nil).toBe(true)
		end)

		it("draws the noValue gauges with Grafana's placeholder (numeric 0) and the neutral bar", function()
			local h = start(version)
			local features = if newGauge then { newGauge = true } else {}
			expect(h.s.settings.features.newGauge == true).toBe(newGauge)
			local d = h.s.dashboard :: any
			local function panel(id: number): any
				for _, sec in d.sections do
					for _, p in sec.panels do
						if p.id == id then
							return p.json
						end
					end
				end
				error("no panel " .. id)
			end
			local g8 = Gauge.specs(panel(8), {}, h.env, { key = "k", features = features })[1]
			expect(g8.text).toBe("6")
			expect(g8.fill_from).toBe(0)
			local g9 = Gauge.specs(panel(9), {}, h.env, { key = "k", features = features })[1]
			expect(g9.text).toBe("0")
			if newGauge then
				-- neutral 6 on 0..16: the bar runs 0..6, red past the 2 step.
				expect(g8.style).toBe("gauge")
				expect(g8.fill_to).toBe(6 / 16)
				expect(g8.bands[#g8.bands].tone).toBe("error")
				-- neutral 6 clamps to max 1: the whole circle, segments in
				-- Grafana's fallback gray.
				expect(g9.style).toBe("circle")
				expect(g9.fill_to).toBe(1)
				expect((g9.segment_tone :: (number) -> string)(0.5)).toBe("neutral")
			else
				-- The old gauge has no options.neutral: an empty bar at 0.
				expect(g8.style).toBe("v1")
				expect(g8.fill_to).toBe(0)
			end
			local view = View.view(h.s, h.env) :: any
			expect(view.main ~= nil).toBe(true)
		end)
	end)
end

return nil
