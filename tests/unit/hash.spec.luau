--!strict
-- Hash outputs are persisted or compared (Loki line ids, settings base_hash,
-- watch default names, handoff nonces): the shared functions must return
-- exactly what each copy they replace returns.
local BlobCache = require("../../plugin/lib/render/blob_cache")
local FrameLoki = require("../../plugin/lib/frame/loki")
local Hash = require("../../plugin/lib/hash")
local SettingsJson = require("../../plugin/lib/settings/json")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local INPUTS = { "", "a", "foobar", '{job="api"}\nline text', string.rep("\255\0\127", 300) }

describe("Hash.fnv1a32", function()
	it("pins the published FNV-1a 32 vectors", function()
		expect(Hash.fnv1a32hex("")).toBe("811c9dc5")
		expect(Hash.fnv1a32hex("a")).toBe("e40c292c")
		expect(Hash.fnv1a32hex("foobar")).toBe("bf9cf968")
	end)

	it("matches the Loki line id and settings base_hash copies", function()
		for _, s in INPUTS do
			expect(Hash.fnv1a32hex(s)).toBe(FrameLoki.hash(s))
			expect(Hash.fnv1a32hex(s) .. "-" .. #s).toBe(SettingsJson.hash(s))
			expect(string.format("%08x", Hash.fnv1a32(s))).toBe(FrameLoki.hash(s))
		end
	end)
end)

describe("Hash.fnv1a64", function()
	it("pins the published FNV-1a 64 vectors", function()
		expect(Hash.fnv1a64("")).toBe("cbf29ce484222325")
		expect(Hash.fnv1a64("a")).toBe("af63dc4c8601ec8c")
		expect(Hash.fnv1a64("foobar")).toBe("85944171f73967e8")
	end)

	it("is what BlobCache.fnv1a64 returns", function()
		for _, s in INPUTS do
			expect(BlobCache.fnv1a64(s)).toBe(Hash.fnv1a64(s))
		end
	end)
end)

return nil
