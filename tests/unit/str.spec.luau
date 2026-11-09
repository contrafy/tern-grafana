--!strict
-- Str.firstLine replaces Effect.firstLine and Keychain.firstLine, whose text
-- reaches blocks and toasts: for every error they see it must say the same,
-- and Effect's callers gain only the trailing-whitespace strip Keychain had.
-- Str.trim replaces a dozen local copies of the same pattern.
local Effect = require("../../plugin/lib/effect")
local Keychain = require("../../plugin/lib/auth/keychain")
local Str = require("../../plugin/lib/str")
local t = require("../lib/test")
local describe, it, expect = t.describe, t.it, t.expect

local ERRORS = {
	"runtime error: boom\nstack traceback:\n  [C]: in ?",
	"  plain failure\r\nsecond line",
	"runtime error: ",
	"",
	"\n\nlate",
	"one line",
	"runtime error: runtime error: twice",
}

describe("Str.firstLine", function()
	it("says what Keychain.firstLine says", function()
		for _, e in ERRORS do
			expect(Str.firstLine(e)).toBe(Keychain.firstLine(e))
			expect(Str.firstLine(e .. "  \t")).toBe(Keychain.firstLine(e .. "  \t"))
		end
		expect(Str.firstLine(nil)).toBe(Keychain.firstLine(nil))
	end)

	it("says what Effect.firstLine says for errors without trailing blanks", function()
		for _, e in ERRORS do
			expect(Str.firstLine(e)).toBe(Effect.firstLine(e))
		end
		local err = { message = "x" }
		expect(Str.firstLine(err)).toBe(Effect.firstLine(err))
		expect(Str.firstLine(42)).toBe(Effect.firstLine(42))
	end)

	it("drops trailing blanks", function()
		expect(Str.firstLine("runtime error: bad   \nmore")).toBe("bad")
	end)
end)

describe("Str.trim", function()
	local function copy(s: string): string
		return string.match(s, "^%s*(.-)%s*$") or ""
	end

	it("matches the local copies it replaces", function()
		for _, s in { "", "   ", " a ", "\ta b\n", "x", "  multi\nline  " } do
			expect(Str.trim(s)).toBe(copy(s))
		end
	end)
end)

return nil
