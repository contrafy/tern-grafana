--!strict
-- The dashboard model decides which panels exist and where: rows must group
-- the panels Grafana shows under them (an open row owns the panels after it,
-- a collapsed row hides its own), library panels must render as the element
-- they reference, and repeat options must survive for the repeat expansion.
-- Grafana 11 and 12 serve the same provisioned dashboards; both are checked.
local Model = require("../../../plugin/lib/dashboard/model")
local S = require("./support")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local function ids(panels: { Model.Panel }): { number }
	local out = {}
	for _, p in panels do
		table.insert(out, p.id)
	end
	return out
end

for _, version in S.VERSIONS do
	local env = S.env()

	describe("dashboard model tern-panels on Grafana " .. version, function()
		local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_panels.json")), env))

		it("reads title, slug, time, refresh and timezone", function()
			expect(d.uid).toBe("tern-panels")
			expect(d.title).toBe("Tern Panels")
			expect(d.slug).toBe("tern-panels")
			expect(d.folder_title).toBe("Tern Fixtures")
			expect(d.time).toEqual({ from = "now-1h", to = "now" })
			expect(d.refresh).toBe("30s")
			expect(d.timezone).toBe("browser")
		end)

		it("groups panels under rows: open rows own what follows, collapsed rows keep their own", function()
			local rows: { any } = {}
			for _, s in d.sections do
				table.insert(rows, {
					title = if s.row then s.row.title else nil,
					collapsed = if s.row then s.row.collapsed else nil,
					panels = ids(s.panels),
				})
			end
			local expected: { any } = {
				{ title = "Overview", collapsed = false, panels = { 2, 3, 4, 5, 6, 7, 8, 9, 10 } },
				{ title = "Logs and distributions", collapsed = false, panels = { 12, 13, 14 } },
				{ title = "Collapsed details", collapsed = true, panels = { 16, 17 } },
				-- The library panel after the collapsed row is not hidden with it.
				{ panels = { 18 } },
			}
			expect(rows).toEqual(expected)
		end)

		it("keeps gridPos and the panel JSON as Grafana wrote it", function()
			local p = assert(Model.findPanel(d, 8))
			expect(p.type).toBe("bargauge")
			expect(p.grid).toEqual({ x = 12, y = 13, w = 8, h = 4 })
			expect(p.json.options.displayMode).toBe("gradient")
		end)

		it("merges a library panel with its element's model, keeping the dashboard's id and position", function()
			local lib = assert(Model.findPanel(d, 18))
			expect(lib.library_uid).toBe("tern-lib-up")
			expect(lib.type).toBe("library")
			expect(Model.libraryRefs(d)).toEqual({ "tern-lib-up" })
			expect(Model.libraryRequest("tern-lib-up").path).toBe("/api/library-elements/tern-lib-up")

			local model = assert(Model.parseLibrary(S.response(S.grafana(version, "library_element.json")), env))
			Model.applyLibrary(d, "tern-lib-up", model, env)
			local merged = assert(Model.findPanel(d, 18))
			expect(merged.library_uid).toBeNil()
			expect(merged.type).toBe("bargauge")
			expect(merged.title).toBe("Tern library: up by job")
			expect(merged.grid).toEqual({ x = 0, y = 44, w = 12, h = 8 })
			expect(merged.json.targets[1].expr).toBe("sum by (job) (up)")
			expect(#Model.libraryRefs(d)).toBe(0)
		end)

		it("marks a library panel whose element failed to load", function()
			local fresh = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_panels.json")), env))
			Model.applyLibrary(fresh, "tern-lib-up", nil, env)
			local p = assert(Model.findPanel(fresh, 18))
			expect(p.type).toBe("library")
			expect(p.library_uid).toBeNil()
		end)
	end)

	describe("dashboard model tern-variables on Grafana " .. version, function()
		local d = assert(Model.parseResponse(S.response(S.grafana(version, "dashboard_tern_variables.json")), env))

		it("keeps panel and row repeat options", function()
			local p = assert(Model.findPanel(d, 3))
			expect(p.repeat_by).toEqual({ var = "job", direction = "h", max_per_row = 4 })
			local row = d.sections[2].row
			expect(row and row.title).toBe("Instance $instance")
			expect(row and row.repeat_by).toEqual({ var = "instance", direction = "h" })
			expect(ids(d.sections[2].panels)).toEqual({ 6 })
		end)

		it("keeps the templating list for the variables", function()
			expect(#d.templating).toBe(9)
			expect(d.time).toEqual({ from = "now-30m", to = "now" })
		end)
	end)

	describe("dashboard model errors on Grafana " .. version, function()
		it("reports a missing dashboard as not found", function()
			local d, err = Model.parseResponse(S.response(S.grafana(version, "dashboard_missing.json"), 404), env)
			expect(d).toBeNil()
			expect(err).toBe("dashboard not found")
		end)
	end)
end

describe("dashboard model slug", function()
	it("slugifies titles like Grafana", function()
		expect(Model.slug("Tern Logs and Traces")).toBe("tern-logs-and-traces")
		expect(Model.slug("  CPU / Memory (prod)! ")).toBe("cpu-memory-prod")
	end)
end)

return nil
