--!strict
-- tern-fid2-table reproduces the user's Grafana Incident and cardinality
-- dashboards, checked against Grafana's own render of the same panels:
-- - a custom `$__all` all value reads "All" in panel titles (Grafana titles
--   use the text format), while queries and descriptions keep it raw;
-- - a newest-first time column (Grafana Incident's tables) draws the same
--   time series as the oldest-first one: Grafana joins on time, which sorts;
-- - the paginated table shows usePaginatedRows' pages (1 - 13 of 22 rows at
--   a 600px panel with small rows), its Metric column as data links that
--   open the interpolated URL, and its gradient gauge fading from blue into
--   yellow past the 30% step.
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local Table = require("../../../plugin/lib/panels/table")
local Timeseries = require("../../../plugin/lib/panels/timeseries")
local Transform = require("../../../plugin/lib/panels/transform")
local TsGradient = require("../../../plugin/lib/render/ts_gradient")
local PS = require("../panels/support")
local View = require("../../../plugin/lib/dashboard/view")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Harness = S.Harness

local function fixtureFor(version: string, tag: string): string?
	if string.match(tag, "^dash/") then
		return S.grafana(version, "dashboard_tern_fid2_table.json")
	elseif string.match(tag, "^fs/") then
		return S.grafana(version, "frontend_settings.json")
	elseif string.match(tag, "^user/") then
		return S.grafana(version, "user.json")
	end
	local id = tonumber(string.match(tag, "^q/%d+/%d+/p(%d+)$"))
	return if id then S.grafana(version, "ds_query_fid2_table_" .. id .. ".json") else nil
end

local function start(version: string): Harness
	local env = S.env()
	local s, effects = State.init({ "tern-grafana://dashboard?context=lab&uid=tern-fid2-table" }, nil, env)
	local h = S.harness(s, env, function(e: any): any
		local path = fixtureFor(version, e.tag)
		return if path then S.response(path) else nil
	end, true)
	S.drive(h, effects)
	return h
end

local function find(node: any, pred: (any) -> boolean): any
	if type(node) ~= "table" then
		return nil
	end
	if pred(node) then
		return node
	end
	for _, c in node.c or {} do
		local hit = find(c, pred)
		if hit then
			return hit
		end
	end
	return nil
end

local function findAll(node: any, pred: (any) -> boolean, out: { any }?): { any }
	local list = out or {}
	if type(node) ~= "table" then
		return list
	end
	if pred(node) then
		table.insert(list, node)
	end
	for _, c in node.c or {} do
		findAll(c, pred, list)
	end
	return list
end

local function card(h: Harness, key: string): any
	local view: any = View.view(h.s, h.env)
	local hit = find(view.main, function(n)
		return n.k == "card" and n.p.key == key
	end)
	assert(hit, "card " .. key)
	return hit
end

local function action(h: Harness, act: string, value: string): { any }
	local _, effects = State.update(h.s, { kind = "event", ev = { ev = "action", act = act, value = value } }, h.env)
	return effects
end

local function panel(version: string, id: number): any
	for _, p in PS.decode("grafana/" .. version .. "/dashboard_tern_fid2_table.json").dashboard.panels do
		if p.id == id then
			return p
		end
	end
	error("no panel " .. id)
end

local function reversed(frame: any): any
	local fields = {}
	for i, f in frame.fields do
		local values = {}
		for j = #f.values, 1, -1 do
			table.insert(values, f.values[j])
		end
		local copy = table.clone(f)
		copy.values = values
		fields[i] = copy
	end
	local out = table.clone(frame)
	out.fields = fields
	return out
end

for _, version in S.VERSIONS do
	describe("tern-fid2-table on Grafana " .. version, function()
		it("titles a custom $__all all value as All", function()
			local h = start(version)
			expect(card(h, "p1").p.head[1].t).toBe("Daily incidents of All")
			expect(card(h, "p2").p.head[1].t).toBe("Highest cardinality metrics of All")
		end)

		it("draws a newest-first time column as Grafana's time-sorted series", function()
			local p = panel(version, 1)
			local frames = Transform.prepare(p, PS.frames(version, "fid2_table_1"), PS.env)
			local times = frames[1].fields[1].values
			expect(times[1] > times[#times]).toBe(true)
			local opts = { key = "p", from_ms = times[#times] - 86400000, to_ms = times[1] + 86400000 }
			local _, newest = Timeseries.view(p, frames, PS.env, opts)
			local _, oldest = Timeseries.view(p, { reversed(frames[1]) }, PS.env, opts)
			expect(newest.p.bytes).toBe(oldest.p.bytes)
		end)

		it("pages rows as Grafana does and flips pages from the pager", function()
			local p = panel(version, 2)
			local frames = Transform.prepare(p, PS.frames(version, "fid2_table_2"), PS.env)
			local tbl = Table.build(p, frames, PS.env, { key = "t", size = { w = 1000, h = 600 } })
			expect(tbl.pager).toEqual({ page = 1, pages = 2, size = 13, total = 22 })
			expect(#tbl.rows).toBe(13)
			local last = Table.build(p, frames, PS.env, { key = "t", size = { w = 1000, h = 600 }, page = 2 })
			expect(#last.rows).toBe(9)
			expect(last.rows[9][1].text).toBe("scrape_samples_scraped")
			local h = start(version)
			local pager = find(card(h, "p2"), function(n)
				return n.p and n.p.key == "next"
			end)
			action(h, "tpage", string.match(pager.p.actions.click, "^tpage=(.+)$") :: string)
			expect(h.s.pages.p2).toBe(2)
			local sum = find(card(h, "p2"), function(n)
				return n.p and n.p.key == "sum"
			end)
			expect(string.match(sum.p.text, " of 22 rows$") ~= nil).toBe(true)
		end)

		it("opens the Metric data link with the row and variables interpolated", function()
			local h = start(version)
			local links = findAll(card(h, "p2"), function(n)
				return n.p and n.p.class == "tgp-cv tgp-dlink"
			end)
			expect(#links > 0).toBe(true)
			local effects = action(h, "dlink", string.match(links[1].p.actions.click, "^dlink=(.+)$") :: string)
			local url = effects[1] and effects[1].target
			assert(type(url) == "string", "browse effect")
			local decoded = string.gsub(url, "%%(%x%x)", function(hex: string): string
				return string.char(tonumber(hex, 16) :: number)
			end)
			expect(string.match(decoded, "url=(.*)$")).toBe(
				"http://localhost:3000/d/tern-fid2-table/?var-metric=GRAFANA_ALERTS&row=1&var-sev=$__all"
			)
		end)

		-- custom.width 300 on Metric, minWidth 300 on roles, id hidden.
		it("sizes columns from custom.width and custom.minWidth", function()
			local p = panel(version, 2)
			local frames = Transform.prepare(p, PS.frames(version, "fid2_table_2"), PS.env)
			local tbl = Table.build(p, frames, PS.env, { key = "t" })
			local heads, widths, mins = {}, {}, {}
			for _, c in tbl.columns do
				table.insert(heads, c.head)
				widths[c.head], mins[c.head] = c.width, c.min_width
			end
			expect(heads).toEqual({ "Metric", "No. of series", "% of total", "debriefStatus", "roles" })
			expect(widths.Metric).toBe(300)
			expect(mins.roles).toBe(300)
		end)

		it("fades the gauge from blue into yellow past the 30% step", function()
			local p = panel(version, 2)
			local frames = Transform.prepare(p, PS.frames(version, "fid2_table_2"), PS.env)
			local tbl = Table.build(p, frames, PS.env, { key = "t" })
			local cell = tbl.rows[1][3]
			expect(cell.text).toBe("54.3%")
			local blue, yellow = TsGradient.stopClass("blue", nil), TsGradient.stopClass("yellow", nil)
			local segs = cell.segments :: { any }
			expect(#segs).toBe(2)
			expect({ segs[1].from, segs[1].to, segs[2].from, segs[2].to }).toEqual({ blue, blue, blue, yellow })
			-- Blue holds to halfway to the step (15% of the bar): 0.15 / 0.543.
			expect(math.abs(segs[1].width - 0.15 / 0.543) < 0.01).toBe(true)
			-- 20.7% is short of the step: plain blue.
			expect(#(tbl.rows[2][3].segments :: { any })).toBe(1)
		end)
	end)
end

return nil
