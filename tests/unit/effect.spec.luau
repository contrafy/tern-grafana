--!strict
-- Machines may return a bare node or named regions; Tern draws nothing for a
-- bare node passed as the BlockView itself, so the runner must tell them
-- apart. A machine that raised must still show something readable.
local Effect = require("../../plugin/lib/effect")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("regions", function()
	it("puts a bare node in the main region", function()
		local node = { k = "col", c = {} }
		expect(Effect.regions(node).main).toBe(node)
	end)

	it("passes named regions through, so a layer or dock survives", function()
		local view = { main = { k = "col" }, layer = { k = "col" } }
		expect(Effect.regions(view :: any)).toBe(view)
	end)
end)

describe("errorView", function()
	it("names the block, the failing step and the error", function()
		local view = Effect.errorView("tern-grafana.query", "update(http_done)", "boom")
		local main = view.main :: any
		expect(main.c[1].p.spans[1].t).toBe("tern-grafana.query failed in update(http_done)")
		expect(main.c[2].p.spans[1].t).toBe("boom")
	end)
end)

return nil
