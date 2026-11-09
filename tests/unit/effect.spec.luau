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
end)

describe("toastLevel", function()
	-- Tern raises on a level it does not know, which would lose the toast.
	it("keeps Tern's levels and shows anything else as info", function()
		expect(Effect.toastLevel("success")).toBe("success")
		expect(Effect.toastLevel("error")).toBe("error")
		expect(Effect.toastLevel("info")).toBe("info")
		expect(Effect.toastLevel("warn")).toBe("info")
		expect(Effect.toastLevel(nil)).toBe("info")
	end)
end)

describe("errorView", function()
	it("names the block, the failing step and the error", function()
		local view = Effect.errorView("tern-grafana.query", "update(http_done)", "boom")
		local main = view.main :: any
		expect(main.c[1].p.spans[1].t).toBe("tern-grafana.query failed in update(http_done)")
		expect(main.c[2].p.spans[1].t).toBe("boom")
	end)

	it("shows one line, never a Lua stack traceback", function()
		local err = "runtime error: tern.process.run op: No such file or directory (os error 2)\n"
			.. "stack traceback:\n\t[C] function run\n\tplugin/transport_host.luau:95"
		local main = Effect.errorView("tern-grafana.dashboard", "init", err).main :: any
		expect(main.c[2].p.spans[1].t).toBe("tern.process.run op: No such file or directory (os error 2)")
		for _, child in main.c do
			expect((string.find(child.p.spans[1].t, "traceback", 1, true))).toBeNil()
		end
	end)
end)

return nil
