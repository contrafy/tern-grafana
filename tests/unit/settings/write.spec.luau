--!strict
-- The config file decides which servers get which credentials. A write must
-- never land outside the config path, never replace a symlink someone manages
-- the file through, never overwrite text that changed since the block loaded
-- it, and must keep the previous text in `<config>.bak` while the new text
-- reaches the config only by an atomic rename.
local Json = require("../../../plugin/lib/settings/json")
local Write = require("../../../plugin/lib/settings/write")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local PATH = "/home/u/.config/tern-grafana/config.json"
local OLD = '{"version": 1}\n'
local NEW = '{"version": 1, "default_context": "lab"}\n'

local function disk(text: string?, extra: { [string]: any }?): (path: string) -> Write.Disk
	return function(path: string): Write.Disk
		expect(path).toBe(PATH)
		local d: any = { exists = text ~= nil, text = text, error = nil, linked = false }
		for k, v in (extra or {}) :: { [string]: any } do
			d[k] = v
		end
		return d
	end
end

local function nonce(): string
	return "n1"
end

local function never(): any
	error("must not run before the path checks pass")
end

describe("write plan", function()
	it("backs up the loaded text, writes a hidden temporary file next to the config and renames it over", function()
		local plan, refusal =
			Write.plan({ path = PATH, text = NEW, base_hash = Json.hash(OLD) }, PATH, disk(OLD), nonce)
		expect(refusal).toBeNil()
		expect(plan).toEqual({
			target = PATH,
			dir = "/home/u/.config/tern-grafana",
			backup = PATH .. ".bak",
			current = OLD,
			tmp = "/home/u/.config/tern-grafana/.config.json.tern-grafana-n1.tmp",
			text = NEW,
			argv = { "mv", "-f", "--", "/home/u/.config/tern-grafana/.config.json.tern-grafana-n1.tmp", PATH },
		})
	end)

	it("creates a missing file without a backup", function()
		local plan = Write.plan({ path = PATH, text = NEW }, PATH, disk(nil), nonce) :: Write.Plan
		expect(plan.backup).toBeNil()
		expect(plan.current).toBeNil()
	end)

	it("refuses a path other than the config path without reading it", function()
		local _, refusal = Write.plan({ path = "/etc/passwd", text = NEW }, PATH, never, never)
		expect(refusal).toEqual({ error = "refusing to write outside the config path" })
		_, refusal = Write.plan({ path = "config.json", text = NEW }, "config.json", never, never)
		expect(refusal).toEqual({ error = "the config path has no directory" })
	end)

	it("refuses a symlinked config", function()
		local _, refusal = Write.plan(
			{ path = PATH, text = NEW, base_hash = Json.hash(OLD) },
			PATH,
			disk(OLD, { linked = true }),
			never
		)
		expect(refusal).toEqual({ error = PATH .. " is a symlink; edit the file it points to instead" })
	end)

	it("reports a conflict when the file changed, appeared or vanished since it was loaded", function()
		local _, changed = Write.plan({ path = PATH, text = NEW, base_hash = Json.hash(OLD) }, PATH, disk(NEW), never)
		expect(changed).toEqual({ conflict = true })
		local _, appeared = Write.plan({ path = PATH, text = NEW }, PATH, disk(OLD), never)
		expect(appeared).toEqual({ conflict = true })
		local _, vanished = Write.plan({ path = PATH, text = NEW, base_hash = Json.hash(OLD) }, PATH, disk(nil), never)
		expect(vanished).toEqual({ conflict = true })
	end)

	it("passes a read error through", function()
		local _, refusal =
			Write.plan({ path = PATH, text = NEW }, PATH, disk(nil, { exists = true, error = "boom" }), never)
		expect(refusal).toEqual({ error = "boom" })
	end)

	it("checks the renamed file holds the new text", function()
		local plan = Write.plan({ path = PATH, text = NEW }, PATH, disk(nil), nonce) :: Write.Plan
		expect(Write.verify(plan, NEW)).toBeNil()
		expect(Write.verify(plan, OLD)).toBe("the file does not hold the new text after the rename; check " .. PATH)
		expect(Write.renameFailed("mv: cannot move\nmore")).toBe("mv failed: mv: cannot move")
	end)
end)

return nil
