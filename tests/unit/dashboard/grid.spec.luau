--!strict
-- Public dashboards' grids and dashboard links (grafana.com 11074 Resource
-- Details, the Alertmanager mixin's overview, 9578 and 13639), reproduced by
-- dev dashboard tern-pub-grid: 2-column stats beside a 10-column table
-- keep their gridPos widths instead of wrapping the band (11074 pushed its
-- traffic graph to a row of its own), the half-empty last row of a repeat
-- keeps the width of a full one, and dashboard.links are buttons after the
-- variables (a "dashboards" link a dropdown of the dashboards with its tags).
local S = require("./support")
local State = require("../../../plugin/lib/dashboard/state")
local View = require("../../../plugin/lib/dashboard/view")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

type Harness = S.Harness

local LINK = "tern-grafana://dashboard?context=lab&uid=tern-pub-grid"

local function start(version: string): Harness
	local env = S.env()
	local s, effects = State.init({ LINK }, nil, env)
	local h = S.harness(s, env, function(e: any): any
		local tag = e.tag
		local path = if string.match(tag, "^dash/")
			then "dashboard_tern_pub_grid.json"
			elseif string.match(tag, "^fs/") then "frontend_settings.json"
			elseif string.match(tag, "^flag/") then "ofrep_table_auto_column_widths.json"
			elseif string.match(tag, "^user/") then "user.json"
			elseif string.match(tag, "^dlinks/") then "search_tag_tern.json"
			else nil
		return if path then S.response(S.grafana(version, path)) else nil
	end)
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

local function byKey(h: Harness, key: string): any
	local view = View.view(h.s, h.env) :: any
	return assert(
		find(view.main, function(n)
			return n.p and n.p.key == key
		end),
		key
	)
end

-- The band (row node) holding panel `key`'s card.
local function bandOf(h: Harness, key: string): any
	local view = View.view(h.s, h.env) :: any
	return assert(
		find(view.main, function(n)
			if not (n.p and type(n.p.key) == "string" and string.match(n.p.key, "^row%d+$")) then
				return false
			end
			for _, c in n.c or {} do
				if c.p and c.p.key == key then
					return true
				end
			end
			return false
		end),
		key
	)
end

-- Width in px flexbox gives a row's nodes (bases summing to 1) in a
-- `width` px row with `gap` px gaps: basis less the overflow by shrink x basis.
local function widths(nodes: { any }, width: number, gap: number): { number }
	local over = (#nodes - 1) * gap
	local weight = 0
	for _, n in nodes do
		weight += n.p.shrink * n.p.basis
	end
	local out: { number } = {}
	for _, n in nodes do
		local w = n.p.basis * width - over * n.p.shrink * n.p.basis / weight
		table.insert(out, math.floor(w * 10 + 0.5) / 10)
	end
	return out
end

-- Grafana's w-column width in a W px grid with m px margins.
local function grafana(w: number, width: number, gap: number): number
	return math.floor(((width + gap) * w / 24 - gap) * 10 + 0.5) / 10
end

for _, version in S.VERSIONS do
	describe("tern-pub-grid on Grafana " .. version, function()
		it("gives every node of a band its gridPos width and never wraps a wide band", function()
			local h = start(version)
			local band = byKey(h, "row1")
			expect(band.p.wrap).toBe(false)
			local got = widths(band.c, 1248, 8)
			-- Uptime and its stats (2), the bar gauge (3), the table (10), CPU iowait's stats (2), traffic (7).
			expect(got).toEqual({
				grafana(2, 1248, 8),
				grafana(3, 1248, 8),
				grafana(10, 1248, 8),
				grafana(2, 1248, 8),
				grafana(7, 1248, 8),
			})
		end)

		it("keeps a repeat's half-empty last row as wide per panel as a full row", function()
			local h = start(version)
			-- integration: All of 6 values, 4 per row: 4 then 2 and a gap.
			local full = widths(bandOf(h, "p11").c, 1248, 8)
			local last = widths(bandOf(h, "p11.4").c, 1248, 8)
			expect(#last).toBe(3)
			expect(last[1]).toBe(full[1])
			expect(last[2]).toBe(full[1])
			expect(full[1]).toBe(grafana(6, 1248, 8))
		end)

		it("stacks panels at the full width below Grafana's md breakpoint", function()
			local h = start(version)
			h.env.cols, h.env.rows = 60, 40
			local band = byKey(h, "row1")
			expect(band.p.wrap).toBe(true)
			for _, n in band.c do
				if n.p.tag ~= "div" or n.c then
					expect(n.p.basis).toBe(1)
				end
			end
		end)

		it("shows the dashboard links after the variables", function()
			local h = start(version)
			local docs = byKey(h, "dl.1")
			expect(docs.p.title).toBe("Prometheus documentation")
			expect(docs.p.actions.click).toBe("dl=1")
			local links = State.dashboardLinks(h.s, h.env)
			expect(links[1].url).toBe("https://prometheus.io/docs/")
			-- keepTime and includeVars: the range as written, every variable as
			-- var-<name>; templateSrv.replace's default format globs a multi value.
			expect(links[2].title).toBe("Explore {email,pagerduty,slack,webhook,wechat,webex}")
			expect(links[2].url).toBe(
				"http://localhost:3000/explore?orgId=1&from=now-1h&to=now&var-ds=prom3&var-integration=%24__all"
			)
			expect(byKey(h, "dl.3").p.actions.click).toBe("dls=3")
		end)

		it("opens a link in the browser and lists a dashboards link's dashboards but this one", function()
			local h = start(version)
			local _, effects =
				State.update(h.s, { kind = "event", ev = { ev = "action", act = "dl", value = "1" } }, h.env)
			expect(#effects).toBe(1)
			expect(string.find((effects[1] :: any).target, "prometheus.io", 1, true) ~= nil).toBe(true)
			State.update(h.s, { kind = "event", ev = { ev = "action", act = "dls", value = "3" } }, h.env)
			local items = State.pickerItems(h.s)
			expect(#items > 1).toBe(true)
			local uids: { [string]: boolean } = {}
			for _, l in assert(h.s.picker).links :: any do
				uids[l.uid] = true
			end
			expect(uids["tern-pub-grid"]).toBe(nil)
			expect(uids["tern-pub-chrome"]).toBe(true)
			-- Picking one opens it natively with the time range (keepTime).
			local id
			for _, item in items do
				if item.label == "Tern Pub Chrome" then
					id = item.id
				end
			end
			local _, picked = State.update(h.s, { kind = "event", ev = { ev = "select", item = id } }, h.env)
			local target = ""
			for _, e in picked do
				if e.kind == "open" then
					target = e.target
				end
			end
			expect(string.find(target, "uid=tern-pub-chrome", 1, true) ~= nil).toBe(true)
			expect(string.find(target, "from=now-1h", 1, true) ~= nil).toBe(true)
		end)
	end)
end

return nil
