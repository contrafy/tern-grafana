--!strict
-- Url.percentEncode replaces three copies that build outgoing URLs and link
-- texts: every byte must encode exactly as before.
local Http = require("../../plugin/lib/transport/http")
local Scheme = require("../../plugin/lib/links/scheme")
local Url = require("../../plugin/lib/url")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("Url.percentEncode", function()
	it("keeps unreserved characters and encodes the rest as upper-case %XX", function()
		expect(Url.percentEncode("aZ09-._~")).toBe("aZ09-._~")
		expect(Url.percentEncode("a b/c?d=e&f!'()*")).toBe("a%20b%2Fc%3Fd%3De%26f%21%27%28%29%2A")
	end)

	it("matches the copies it replaces on every byte", function()
		local all = {}
		for b = 0, 255 do
			all[b + 1] = string.char(b)
		end
		local s = table.concat(all) .. 'rate(x{job="a"}[5m]) é'
		expect(Url.percentEncode(s)).toBe(Scheme.percentEncode(s))
		expect(Url.percentEncode(s)).toBe(Http.escape(s))
	end)
end)

return nil
