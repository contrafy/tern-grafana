--!strict
-- Basic auth sends base64(user:password); one wrong padding byte and every
-- request fails with 401, so the encoder is checked against RFC 4648.
local Base64 = require("../../../plugin/lib/auth/base64")
local t = require("../../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

describe("base64", function()
	it("matches the RFC 4648 section 10 test vectors", function()
		expect(Base64.encode("")).toBe("")
		expect(Base64.encode("f")).toBe("Zg==")
		expect(Base64.encode("fo")).toBe("Zm8=")
		expect(Base64.encode("foo")).toBe("Zm9v")
		expect(Base64.encode("foob")).toBe("Zm9vYg==")
		expect(Base64.encode("fooba")).toBe("Zm9vYmE=")
		expect(Base64.encode("foobar")).toBe("Zm9vYmFy")
	end)

	it("uses the standard alphabet for the high indices", function()
		expect(Base64.encode("\251\255\191")).toBe("+/+/")
		expect(Base64.encode("\0\0\0")).toBe("AAAA")
		expect(Base64.encode("\255\255\255")).toBe("////")
	end)

	it("encodes UTF-8 bytes as bytes", function()
		expect(Base64.encode("é")).toBe("w6k=")
	end)

	it("encodes a typical basic credential", function()
		expect(Base64.encode("Aladdin:open sesame")).toBe("QWxhZGRpbjpvcGVuIHNlc2FtZQ==")
	end)
end)

return nil
