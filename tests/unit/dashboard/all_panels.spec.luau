--!strict
-- tern-all-panels (one panel per core type plus the clock panel) as both
-- Grafanas serve it, against the queries their frontends sent
-- (ds_query_all_panels_<id>.request.json): panel time overrides and query
-- options must produce the same range and resolution, every panel lands on
-- the rung its type allows, and the no-query gauges draw Grafana's
-- placeholder value.
local Gauge = require("../../../plugin/lib/panels/gauge")
local SvgGauge = require("../../../plugin/lib/render/svg_gauge")
local PS = require("../panels/support")
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local View = require("../../../plugin/lib/dashboard/view")
local json = require("../../lib/json")
local Thresholds = require("../../../plugin/lib/units/thresholds")
local TsGradient = require("../../../plugin/lib/render/ts_gradient")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

-- The capture's "now": panel 3 (timeFrom 2h, no shift) ends there.
local function captureNow(version: string): number
	local r = S.doc(S.grafana(version, "ds_query_all_panels_3.request.json"))
	return tonumber(r.to) :: number
end

type Harness = S.Harness

local function fixtureFor(version: string, tag: string): string?
	if string.match(tag, "^dash/") then
		return S.grafana(version, "dashboard_tern_all_panels.json")
	elseif string.match(tag, "^fs/") then
		return S.grafana(version, "frontend_settings_all_panels.json")
	elseif string.match(tag, "^flag/") then
		return S.grafana(version, "ofrep_table_auto_column_widths.json")
	elseif string.match(tag, "^user/") then
		return S.grafana(version, "user.json")
	end
	return nil
end

local function start(version: string, vars: string?): Harness
	local env = S.env()
	env.now_ms = captureNow(version)
	local s, effects =
		State.init({ "tern-grafana://dashboard?context=lab&uid=tern-all-panels" .. (vars or "") }, nil, env)
	local h = S.harness(s, env, function(e: any): any
		local path = fixtureFor(version, e.tag)
		return if path then S.response(path) else nil
	end, true)
	S.drive(h, effects)
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
	-- 12.4 draws the new gauge behind its feature toggle (on in the dev stack); 13 always does.
	local newGauge = version ~= "11.6.16"

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
				-- neutral 6 on 0..16: the bar runs 0..6; the gradient blends
				-- green into #EAB839 up to the 2 step, red from there.
				expect(g8.style).toBe("gauge")
				expect(g8.fill_to).toBe(6 / 16)
				local red = TsGradient.stopClass(Thresholds.color("red"))
				expect(g8.gradient).toEqual({
					{ at = 0, class = TsGradient.stopClass(Thresholds.color("green")) },
					{ at = 2 / 16, class = TsGradient.stopClass(Thresholds.color("#EAB839")) },
					{ at = 2 / 16, class = red },
					{ at = 1, class = red },
				})
				-- neutral 6 clamps to max 1: the whole circle, segments in
				-- Grafana's fallback gray.
				expect(g9.style).toBe("circle")
				expect(g9.fill_to).toBe(1)
				expect((g9.segment_class :: (number) -> string)(0.5)).toBe("tgp-fx tgp-neutral")
			else
				-- The old gauge has no options.neutral: an empty bar at 0.
				expect(g8.style).toBe("v1")
				expect(g8.fill_to).toBe(0)
			end
			local view = View.view(h.s, h.env) :: any
			expect(view.main ~= nil).toBe(true)
		end)

		-- Panel 10: 8 segments on 0..100 with neutral 50. RadialBarSegmented
		-- fills a segment only when its start lies between the value and the
		-- neutral point (start inclusive, end exclusive): 13.3.1's recorded
		-- 12% fills the segments starting at 12.5, 25 and 37.5, 12.4's 21%
		-- two; a value of 46 leaves none to fill and 31 one (as on Grafana
		-- 13's live render).
		it("fills the segments whose start lies between the value and the neutral point", function()
			if not newGauge then
				return
			end
			local h = start(version)
			local p10: any
			for _, sec in (h.s.dashboard :: any).sections do
				for _, p in sec.panels do
					if p.id == 10 then
						p10 = p.json
					end
				end
			end
			local frames = PS.frames(version, "all_panels_10")
			local opts = { key = "k", features = { newGauge = true }, size = { w = 600, h = 480 } }
			local g = Gauge.specs(p10, frames, h.env, opts)[1]
			expect(g.segments).toBe(8)
			expect(g.fill_to).toBe(0.5)
			local function filled(value: number): number
				local spec = table.clone(g)
				spec.fill_from = value
				spec.width, spec.height = 300, 280
				local svg = SvgGauge.render(spec)
				local _, tracks = string.gsub(svg, "tgg%-track", "")
				return 8 - tracks
			end
			local want = 0
			for k = 0, 7 do
				if k / 8 >= g.fill_from and k / 8 < 0.5 then
					want += 1
				end
			end
			expect(want >= 2).toBe(true)
			expect(filled(g.fill_from)).toBe(want)
			expect(filled(0.46)).toBe(0)
			expect(filled(0.31)).toBe(1)
		end)

		-- Panel 10 reduces with lastNotNull: from 12.4 on, RadialSparkline
		-- passes showHighlights, so the Sparkline marks the calc's sample
		-- (getSparklineHighlight) with a 6 px point in the line's color, the
		-- plot padded 3 px for it. The old gauge (11.6) has no sparkline.
		it("marks the reduced sample on the radial gauge's sparkline", function()
			local h = start(version)
			local p10: any
			for _, sec in (h.s.dashboard :: any).sections do
				for _, p in sec.panels do
					if p.id == 10 then
						p10 = p.json
					end
				end
			end
			local frames = PS.frames(version, "all_panels_10")
			local features = if newGauge then { newGauge = true } else {}
			local g = Gauge.specs(p10, frames, h.env, { key = "k", features = features })[1]
			if not newGauge then
				expect(g.spark).toBeNil()
				return
			end
			local spark = g.spark :: { number? }
			expect(g.spark_highlight).toBe(#spark)
			g.width, g.height = 300, 280
			local svg = SvgGauge.render(g)
			local class, cx, cy = string.match(svg, '<circle class="([^"]*)" cx="([%d.]+)" cy="([%d.]+)" r="3"/>')
			expect(class).toBe(g.spark_class)
			local path = assert(string.match(svg, 'tg%-line" fill="none" stroke%-width="1" d="([^"]*)"'))
			local lx, ly = string.match(path, " ([%d.]+) ([%d.]+)$")
			expect({ cx, cy }).toEqual({ lx, ly })
		end)

		-- RadialSparkline draws lineInterpolation smooth: one monotone cubic
		-- between each pair of samples, through every sample and never past
		-- the higher or lower of the two (no overshoot above a spike).
		it("smooths the radial gauge's sparkline without overshooting its samples", function()
			if not newGauge then
				return
			end
			local h = start(version)
			local p10: any
			for _, sec in (h.s.dashboard :: any).sections do
				for _, p in sec.panels do
					if p.id == 10 then
						p10 = p.json
					end
				end
			end
			local g = Gauge.specs(p10, PS.frames(version, "all_panels_10"), h.env, {
				key = "k",
				features = { newGauge = true },
			})[1]
			g.width, g.height = 300, 280
			local svg = SvgGauge.render(g)
			local path = assert(string.match(svg, 'tg%-line" fill="none" stroke%-width="1" d="([^"]*)"'))
			local present = 0
			for _, v in g.spark :: { number? } do
				if v then
					present += 1
				end
			end
			local _, cubics = string.gsub(path, "C", "")
			expect(cubics).toBe(present - 1)
			expect((string.find(path, "L", 1, true))).toBeNil()
			local y0 = assert(tonumber(string.match(path, "^M[%d.]+ ([%d.]+)")))
			for c1, c2, y1 in string.gmatch(path, "C[%d.]+ ([%d.]+) [%d.]+ ([%d.]+) [%d.]+ ([%d.]+)") do
				local lo, hi = math.min(y0, tonumber(y1) :: number), math.max(y0, tonumber(y1) :: number)
				for _, c in { tonumber(c1) :: number, tonumber(c2) :: number } do
					expect(c >= lo - 0.01 and c <= hi + 0.01).toBe(true)
				end
				y0 = tonumber(y1) :: number
			end
		end)

		-- Grafana gives every panel its gridPos height whatever it shows; in
		-- the grid every panel type is exactly that tall: cut there (a
		-- wrapped countdown clock never outgrows its row) and never shorter
		-- (a short stat keeps its slot, so bands line up as in Grafana).
		it("sizes every grid panel to its Grafana height", function()
			local h = start(version)
			expect(View.heightLines(8)).toBe(18) -- 8 rows: 296 px of 16 px lines
			local view = View.view(h.s, h.env) :: any
			local cards = 0
			local function walk(n: any)
				local p = n.p
				if p and type(p.key) == "string" and string.match(p.key, "^p%d+$") then
					cards += 1
					local lines = string.format("%dlines", View.heightLines(8))
					expect(p.max and p.max.h).toBe(lines)
					expect(p.min and p.min.h).toBe(lines)
					return
				end
				for _, c in n.c or {} do
					walk(c)
				end
			end
			walk(view.main)
			-- Every tern-all-panels panel is 8 rows high.
			expect(cards).toBe(#h.s.order)
		end)

		-- Grafana's traces panel draws Tempo trace frames; Tern's traces
		-- module does too, so the panel queries Tempo through /api/ds/query.
		it("runs the traces panel's Tempo query natively and draws the waterfall", function()
			local sent = S.doc(S.grafana(version, "ds_query_all_panels_27.request.json")).queries[1]
			-- The capture filled the trace_id textbox from the URL.
			local h = start(version, "&var-trace_id=" .. sent.query)
			expect(h.s.panels.p27.decision.mode).toBe("native")
			local q = query(h, 27).queries[1]
			expect(q.query).toBe(sent.query)
			expect(q.queryType).toBe("traceId")
			expect(q.datasource.type).toBe("tempo")
			for tag in h.pending do
				if string.match(tag, "^q/%d+/%d+/p27$") then
					State.update(h.s, {
						kind = "http_done",
						tag = tag,
						response = S.response(S.grafana(version, "ds_query_all_panels_27.json")),
					}, h.env)
				end
			end
			expect(h.s.panels.p27.status).toBe("ready")
			-- Expanded, the panel is the waterfall, not an error or no-data line.
			State.update(h.s, { kind = "event", ev = { ev = "action", act = "expand", value = "p27" } }, h.env)
			local view = View.view(h.s, h.env) :: any
			local text = json.encode(view.main)
			expect((string.find(text, "No data", 1, true))).toBeNil()
			expect((string.find(text, "failed", 1, true))).toBeNil()
			-- The trace's root span heads the waterfall.
			expect(string.find(text, '"t":"payments: "', 1, true) ~= nil).toBe(true)
		end)

		-- The stat panels as the dashboard block draws them (State + View, the
		-- recorded answers): each value is one SVG line of BigValue's size for
		-- the panel's Grafana box, its height within the card body under the
		-- card's height cap. Grafana draws "No targets" about 70 px tall in
		-- its 400x296 panel; a body-text size or a wrapped line is wrong.
		it("sizes the stat values like Grafana within the card", function()
			local h = start(version)
			for tag in h.pending do
				local id = string.match(tag, "^q/%d+/%d+/p(%d+)$")
				if id == "5" or id == "6" then
					State.update(h.s, {
						kind = "http_done",
						tag = tag,
						response = S.response(S.grafana(version, "ds_query_all_panels_" .. id .. ".json")),
					}, h.env)
				end
			end
			local rendered, assets = View.view(h.s, h.env)
			local view: any = rendered
			local function stat(key: string): (any, number)
				local card: any = nil
				local function walk(n: any)
					if card == nil and type(n) == "table" then
						if n.p and n.p.key == key then
							card = n
							return
						end
						for _, c in n.c or {} do
							walk(c)
						end
					end
				end
				walk(view.main)
				assert(card, "card " .. key)
				local image: any = nil
				local function find(n: any)
					if image == nil and type(n) == "table" then
						if n.k == "image" then
							image = n
							return
						end
						for _, c in n.c or {} do
							find(c)
						end
					end
				end
				find(card)
				assert(image, "value image of " .. key)
				local px = assert(tonumber(string.match(assets[image.p.asset].bytes, 'font%-size="(%d+)"')))
				return image, px
			end
			-- p5 has a title and a description: one head line holding both.
			local body = View.cardHeight(8, false, true, false, true)
			local up, upPx = stat("p5")
			local none, nonePx = stat("p6")
			expect(up.p.alt).toBe("5")
			expect(none.p.alt).toBe("No targets")
			-- Width-bound: Grafana's 386 px panel (a w=6 panel in a 1600 px
			-- window) draws it at 70.2 px over 360 px of text; Tern lays the
			-- panel out 400 px wide (no padding, 1 px border: 374 px of text).
			expect(nonePx >= 68 and nonePx <= 74).toBe(true)
			expect(upPx >= 100).toBe(true)
			for _, image in { up, none } do
				local lines = assert(tonumber(string.match(image.p.max.h, "^(%d+)lines$")))
				expect(lines * View.LINE_PX <= body).toBe(true)
			end
		end)
	end)
end

return nil
