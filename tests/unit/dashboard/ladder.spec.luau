--!strict
-- The ladder decides how each panel appears: native when the registry draws
-- it and its queries run natively, otherwise a Grafana-rendered PNG when the
-- instance has an image renderer, otherwise the solo panel page in a browser
-- pane. Renderer availability comes from /api/frontend/settings (Grafana 11
-- here has none and answers render calls with an error picture; 12 has one).
-- The solo URLs must be the ones Grafana itself serves.
local GrafanaSource = require("../../../plugin/lib/source/grafana")
local Http = require("../../../plugin/lib/transport/http")
local Ladder = require("../../../plugin/lib/dashboard/ladder")
local Model = require("../../../plugin/lib/dashboard/model")
local Queries = require("../../../plugin/lib/dashboard/queries")
local RenderPng = require("../../../plugin/lib/dashboard/render_png")
local Route = require("../../../plugin/lib/config/route")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

-- A registry stand-in: the ladder's own logic is under test here (the real
-- registry's verdicts are covered by the state spec).
local function supports(panel: { [string]: any }, _env: any): (boolean, string?)
	if panel.type == "traces" then
		return false, "traces panels are not drawn natively"
	end
	return true, nil
end

local EXPECTED_RENDERER = { ["11.6.16"] = false, ["12.4.12"] = true }

for _, version in S.VERSIONS do
	local env = S.env()
	local route = assert(Route.route(S.CONFIG, "lab", "dashboards"))
	local fs = S.response(S.grafana(version, "frontend_settings.json"))
	local settings = GrafanaSource.parseFrontendSettings(route, fs, env)
	assert(settings.ok, "frontend settings must parse")
	local renderer = (settings :: any).settings.renderer_available
	local ctx: Ladder.Context = {
		supports = supports,
		renderer_available = renderer,
		scope = {},
		datasources = Queries.frontendDatasources(fs, env),
	}
	local obs = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_observability.json")), env))

	describe("ladder on Grafana " .. version, function()
		it("reads renderer availability from the frontend settings", function()
			expect(renderer).toBe(EXPECTED_RENDERER[version])
		end)

		it("keeps Prometheus and Loki panels native", function()
			for _, id in { 1, 2, 3 } do
				expect(Ladder.decide(assert(Model.findPanel(obs, id)), ctx, env)).toEqual({ mode = "native" })
			end
		end)

		it("sends a panel the registry cannot draw to the renderer, or the browser without one", function()
			local traces = Ladder.decide(assert(Model.findPanel(obs, 5)), ctx, env)
			local tempoTable = Ladder.decide(assert(Model.findPanel(obs, 4)), ctx, env)
			if renderer then
				expect(traces).toEqual({ mode = "png", reason = "traces panels are not drawn natively" })
				-- Tempo search results feed a table natively.
				expect(tempoTable).toEqual({ mode = "native" })
			else
				expect(traces).toEqual({
					mode = "browser",
					reason = "traces panels are not drawn natively; Grafana has no image renderer",
				})
				expect(tempoTable.mode).toBe("native")
			end
		end)

		it("does not draw an unresolved library panel natively", function()
			local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_panels.json")), env))
			local lib = assert(Model.findPanel(d, 18))
			expect(Ladder.nativeBlocker(lib, ctx, env)).toBe("library panel is still loading")
		end)
	end)
end

describe("ladder without settings", function()
	it("falls back to the browser while the renderer is unknown", function()
		local env = S.env()
		local d = Ladder.decide({
			id = 1,
			type = "traces",
			title = "",
			grid = { x = 0, y = 0, w = 24, h = 8 },
			json = { type = "traces" },
		}, { supports = supports, scope = {}, datasources = {} }, env)
		expect(d.mode).toBe("browser")
	end)
end)

describe("render_png solo URLs", function()
	local route = assert(Route.route(S.CONFIG, "lab", "dashboards"))
	local spec: RenderPng.Spec = {
		uid = "tern-panels",
		slug = "tern-panels",
		panel_id = 2,
		org_id = 1,
		from = "now-1h",
		to = "now",
		width = 1000,
		height = 500,
		tz = "UTC",
		vars = {},
	}

	it("builds the render request Grafana answered with the recorded PNG", function()
		-- MANIFEST: grafana/12.4.12/render_d_solo.png
		expect(Http.url(route.endpoint, RenderPng.request(spec))).toBe(
			"http://localhost:3000/render/d-solo/tern-panels/tern-panels?orgId=1&panelId=2&width=1000&height=500&from=now-1h&to=now&tz=UTC"
		)
	end)

	it("adds theme and every variable value, All as $__all", function()
		local s = table.clone(spec)
		s.theme = "dark"
		s.vars = { job = { "node", "prometheus" }, mode = { "$__all" } }
		local q = RenderPng.request(s).query :: { { string } }
		expect(q[8]).toEqual({ "theme", "dark" })
		expect(q[9]).toEqual({ "var-job", "node" })
		expect(q[10]).toEqual({ "var-job", "prometheus" })
		expect(q[11]).toEqual({ "var-mode", "$__all" })
	end)

	it("opens the solo page (not the render API) in the browser pane", function()
		local s = table.clone(spec)
		s.width, s.height, s.tz = nil, nil, "Europe/Berlin"
		s.vars = { handler = { "/api/v1/.*" } }
		expect(RenderPng.soloUrl("https://grafana.example.com", s)).toBe(
			"https://grafana.example.com/d-solo/tern-panels/tern-panels?orgId=1&panelId=2&from=now-1h&to=now&timezone=Europe%2FBerlin&var-handler=%2Fapi%2Fv1%2F.%2A"
		)
	end)

	it("sizes panels like Grafana's grid and maps dashboard time zones", function()
		expect({ RenderPng.size(12, 8) }).toEqual({ 800, 296 })
		expect({ RenderPng.size(24, 8, 1000) }).toEqual({ 1000, 296 })
		expect({ RenderPng.size(2, 1) }).toEqual({ RenderPng.MIN_WIDTH, 30 })
		expect(RenderPng.tz("browser")).toBeNil()
		expect(RenderPng.tz("")).toBeNil()
		expect(RenderPng.tz("utc")).toBe("UTC")
		expect(RenderPng.tz("America/New_York")).toBe("America/New_York")
	end)

	it("keys the render cache by panel, range, size and variables", function()
		local a = RenderPng.cacheKey(spec)
		local b = table.clone(spec)
		b.from = "now-6h"
		local c = table.clone(spec)
		c.vars = { job = { "node" } }
		expect(a == RenderPng.cacheKey(table.clone(spec))).toBe(true)
		expect(a == RenderPng.cacheKey(b)).toBe(false)
		expect(a == RenderPng.cacheKey(c)).toBe(false)
	end)
end)

-- A `-- Dashboard --` panel shows its source panel's results: it is native
-- when the source's queries are (Grafana runs them whatever the source's own
-- rung) and Tern applies the transformations it reuses; a missing source is
-- Grafana's own "Could not find source panel", shown natively.
describe("ladder for -- Dashboard -- panels", function()
	local env = S.env()
	local fs = S.response(S.grafana("12.4.12", "frontend_settings.json"))
	local function panel(id: number, json: { [string]: any }): Model.Panel
		json.id = id
		json.type = json.type or "table"
		return { id = id, type = json.type, title = "P" .. id, grid = { x = 0, y = 0, w = 12, h = 8 }, json = json }
	end
	local function shared(id: number, source: number, extra: { [string]: any }?): Model.Panel
		local target: { [string]: any } = { refId = "A", datasource = { uid = "-- Dashboard --" }, panelId = source }
		local more: { [string]: any } = extra or {}
		for k, v in more do
			target[k] = v
		end
		return panel(id, { datasource = { uid = "-- Dashboard --", type = "datasource" }, targets = { target } })
	end
	local PROM = { uid = "prom3", type = "prometheus" }
	local panels: { [number]: Model.Panel } = {
		[1] = panel(1, {
			-- Not drawn natively itself: its data still is the source's.
			type = "acme-flow-panel",
			datasource = PROM,
			targets = { { refId = "A", expr = "up" } },
			transformations = { { id = "acmeShuffle", options = {} } },
		}),
		[2] = panel(
			2,
			{ datasource = { uid = "tempo", type = "tempo" }, type = "timeseries", targets = { { refId = "A" } } }
		),
		[3] = shared(3, 1),
		[4] = shared(4, 1, { withTransforms = true }),
		[5] = shared(5, 2),
		[6] = shared(6, 3),
		[7] = shared(7, 7),
		[8] = shared(8, 99),
		[9] = shared(9, 1, { topic = "annotations" }),
	}
	local ctx: Ladder.Context = {
		supports = supports,
		renderer_available = true,
		scope = {},
		datasources = Queries.frontendDatasources(fs, env),
		source = function(id: number): Model.Panel?
			return panels[id]
		end,
	}
	local function blocker(id: number): string?
		return Ladder.nativeBlocker(panels[id], ctx, env)
	end

	it("is native when the source panel's queries are, chained ones included", function()
		expect(blocker(3)).toBeNil()
		expect(blocker(6)).toBeNil()
		expect(blocker(8)).toBeNil()
	end)

	it("names what keeps the reused data from being produced natively", function()
		expect(blocker(4)).toBe("reuses panel 1 with its transformations: transformation acmeShuffle is not supported")
		expect(blocker(5)).toBe(
			"reuses panel 2, whose queries are not run natively: tempo queries are not run natively"
		)
		expect(blocker(7)).toBe("-- Dashboard -- queries reference each other in a loop")
		expect(blocker(9)).toBe("reuses another panel's annotations (-- Dashboard --)")
	end)
end)

return nil
